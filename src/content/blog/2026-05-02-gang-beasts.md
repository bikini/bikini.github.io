---
title: 'gang beasts — pre-auth network RCE in a wobbly-arms party game'
description: 'unpatched mbedTLS DTLS heap overflow (CVE-2023-43615) reachable through Unity Relay, plus client-trusted auth, hardcoded dev IDs, remote input puppeteering, EB subdomain takeover, and 21 other findings'
pubDate: '2026-05-02'
category: 'exploits'
---

I sat down to look at Gang Beasts because a friend wouldn't stop sending me clips of his ragdoll punching mine off a blimp. I figured if I had to lose at it I might as well understand the engine. A week later I had **25 distinct findings**, the headline being a **pre-authentication network RCE** in mbedTLS that reaches through Unity Relay into every host's process — no Steam ticket, no game ownership, no foothold required. Just join an allocation and send a malformed DTLS handshake.

The other 24 are what happens when you ship a 2018-era stack — deprecated HLAPI networking, a custom UDP relay, IL2CPP without CFG on a 77MB native blob, client-trusted authentication — to ten million players and then never touch it again.

## the build

```text
Game        : Gang Beasts
Engine      : Unity 2021.3.33f1   (patched: 2021.3.56f2 → vulnerable)
Backend     : IL2CPP, x86_64 Windows
Steam AppID : 285900
Build hash  : ee5a2aa03ab2
Networking  : UNET HLAPI + custom CoreNet UDP layer + Unity Relay (DTLS)
PlayFab     : Title B556E, SDK 2.166.230512 (May 2023)
```

`UnityPlayer.dll` is 28.1 MB. `GameAssembly.dll` is 49.4 MB. **Neither has Control Flow Guard.** `Gang Beasts.exe`, `OVRPlugin.dll`, `lib_burst_generated.dll`, `nn_piaPlugin.dll`, `libvhacd.dll` — all CFG-less. Only the two Microsoft-provided Party DLLs (`PartyWin.dll`, `XGamingRuntimeThunks.dll`) have CFG enabled. That's the *headline-under-the-headline*: 77 MB of CFG-free native code as ROP fodder.

## VULN-25 — pre-auth network RCE via mbedTLS DTLS (CVE-2023-43615)

This is the one that reframes the whole assessment. `UnityPlayer.dll` embeds an unpatched mbedTLS containing a heap buffer overflow in DTLS handshake fragment reassembly. When a fragmented handshake message arrives:

1. The reassembly function allocates a buffer based on `total_message_length` from fragment 1.
2. For each subsequent fragment, it calls `memcpy(buffer + fragment_offset, payload, fragment_length)`.
3. **No bounds check** on `fragment_offset + fragment_length` vs the allocated buffer.

I verified by hooking the function in the live process with Frida and disassembling the memcpy site:

```text
RVA 0x1006127:  call <allocator>             ; sized by total_message_length
RVA 0x10061B0:  fragment_offset = 3-byte BE  ; from header bytes 6-8
RVA 0x10061E4:  fragment_length = 3-byte BE  ; from header bytes 9-11
                                              ; "or rdi, rax" — len in rdi
RVA 0x10061FD:  call <debug log>
RVA 0x1006202:  mov rdx, [rbx+0xd8]           ; SRC = message data
RVA 0x1006209:  lea rcx, [rsi+r14]            ; DST = buffer + fragment_offset
RVA 0x100620D:  add rdx, 0xc                  ; skip 12-byte handshake header
RVA 0x1006211:  mov r8, rdi                   ; SIZE = fragment_length
RVA 0x1006214:  call <memcpy>                 ; OVERFLOW
        ^^^ no comparison of (offset+len) vs buffer_size
            no comparison of fragment_offset vs total_message_length ^^^
```

Confirmed in the live process: `UnityPlayer.dll` base `0x7ffa61190000`, size `0x1CFF000`, 75 instances of the string `dtls`, mbedTLS function-name strings (`dtls_ssl_*`, `dtls_cipher_*`), and `dtls\builds\library\` build-path strings — that is mbedTLS source, vendored.

The attack: send fragment 1 declaring a small `total_message_length` (small alloc), then fragment 2 with `fragment_offset + fragment_length` overrunning. The bytes after the buffer are fully attacker-controlled.

### why this is reachable through Unity Relay

`RelayPostBox` hardcodes `NET_PROTOCOL = "dtls"` for all multiplayer comms. Unity Relay forwards raw DTLS records between peers — they're processed by the vulnerable mbedTLS code in the *host's* `UnityPlayer.dll`, not by Relay. So:

- **Via Unity Relay:** join a relay allocation (trivial — Project ID is leaked in `globalgamemanagers`, see VULN-18), send the malformed handshake, the host process eats it.
- **Via LAN / direct connect:** raw UDP to host IP on the game port. Even worse.

The DTLS layer runs **before any game-level auth** (NetAuthMessage, Steam ticket, lobby password) — this is **pre-auth**. No Steam account, no game purchase, no joined session. The attacker needs only the ability to send packets to the relay or to a host's IP.

### exploitation feasibility

| factor | status |
|---|---|
| CFG on UnityPlayer.dll | NOT ENABLED (DLL chars `0x0160`) |
| ASLR | enabled (need info leak for full chain) |
| DEP | enabled (need ROP) |
| heap layout | Unity allocator is fairly deterministic |
| write primitive | arbitrary offset + data via fragment 2 |

Without CFG, the standard heap-overflow-to-RCE chain is open: heap feng shui to land a vtable-bearing object adjacent to the DTLS reassembly buffer, overflow into its vtable pointer, trigger a virtual call, ROP through the 22.7 MB of CFG-free `UnityPlayer.dll` text gadgets, `VirtualProtect` + shellcode. None of the structural mitigations are in place.

## VULN-1 — `-xrsdk-pre-init-library` (local one-click RCE)

Unity's player binary parses a `-xrsdk-pre-init-library <path>` argument, which during XR initialization gets fed straight into `LoadLibrary()`. No signature check, no path restriction. The fix lives in 2021.3.56f2; Gang Beasts is 2021.3.33f1.

```text
# Direct shortcut / shell — anything that can spawn the process
"Gang Beasts.exe" -xrsdk-pre-init-library "C:\evil\malicious.dll"

# One-click via browser, on a Steam client old enough to skip Valve's URI filter
steam://run/285900//-xrsdk-pre-init-library%20C:/evil/malicious.dll
```

`DllMain` runs *before* the rest of the engine; you have full code execution at user privilege. Same shape as the Overcooked! 2 finding I wrote up earlier (different argument: `-overrideMonoSearchPath` for IL2Mono games, `-xrsdk-pre-init-library` for IL2CPP). Different argument, same Unity-LTS-too-old-to-get-the-patch story.

## VULN-21 + VULN-22 — auth bypass and hardcoded dev IDs

**The auth model is "trust the client."** `NetAuthMessage` (TypeDefIndex 993):

```csharp
public class NetAuthMessage : MessageBase {
    public bool   ClientAuthPassed;  // 0x10 — CLIENT CONTROLLED
    public int    Players;           // 0x14
    public string PlatformID;        // 0x18 — Steam ID, NOT VERIFIED
    public string Password;          // 0x20 — lobby password, plaintext
    public double Version;           // 0x28
    public bool   Debug;             // 0x30 — CLIENT CONTROLLED
}
```

A complete symbol-table search of `GameAssembly.dll` confirms **none** of the Steamworks auth functions are present:

| function | purpose | present |
|---|---|---|
| `BeginAuthSession` | validate client's auth ticket | NOT FOUND |
| `ValidateAuthTicketResponse` | receive validation result | NOT FOUND |
| `GetAuthSessionTicket` | generate auth ticket | NOT FOUND |
| `EndAuthSession` | end validation session | NOT FOUND |
| `UserHasLicenseForApp` | verify game ownership | NOT FOUND |

The host has nothing to verify against. Attack vectors:

1. **Identity spoofing.** Set `PlatformID` to any Steam ID — impersonate any player in the lobby.
2. **Auth bypass.** Set `ClientAuthPassed=true`, skip checks.
3. **Free-to-play.** No ownership check — play without buying.
4. **Ban evasion.** Trivially flip `PlatformID` to dodge platform-ID-based bans.

**Now the second half of the chain.** `GBServerItemSpawner` (TypeDefIndex 2178) has a hardcoded array `DEVELOPER_IDS` of Steam64 IDs. The `AuthenticateRequest(NetworkConnection)` method at RVA `0x63D5F0` checks incoming spawn requests against this list. Match → spawn requests authorized.

Pulled from `global-metadata.dat` at offset `0x006A0BD8` (4 consecutive `ulong`):

```text
76561198007011733
76561198024748411
76561197974864268
76561197968617818
```

Combined with VULN-21 (no PlatformID verification), any player can:

1. Connect to a lobby normally.
2. Send `NetAuthMessage` with `PlatformID = "76561198007011733"`.
3. The server's `AuthenticateRequest` matches → spawn calls authorized.
4. Send `NetSpawnObjectMessage(objectID, worldPos, randomiseRotation)` to spawn anything anywhere.

That's developer-tier privilege on every host, on every lobby, by every player.

## VULN-12 — remote input injection (puppet your opponent)

This is my favorite and it's barely a security bug; it's an architecture decision.

There are **two** `[Command]` (client→server) methods in the entire codebase:

```csharp
CmdAlterDigitalInput(string input, bool value)   // RVA 0x51AE70
CmdAlterAnalogueInput(string input, float value) // RVA 0x51AE60
```

Both are on `InputState : NetworkBehaviour`. The `string input` parameter is used as a dictionary key into the local input handler — no allowlist, no validation, just `dict[input]?.Set(value)`. Disassembly of `CmdAlterDigitalInput`:

```text
mov rcx, [...]            ; load input dictionary
call StringDict_TryGet    ; lookup attacker key
test rax, rax
je 0x51C639               ; bail on unknown key (safe, no crash)
mov byte ptr [rdi + 0x10], al   ; write attacker-controlled value
```

A malicious client connected to the same lobby can send `CmdAlterDigitalInput("Jump", true)` *with another player's `NetworkInstanceId`* and the server dispatches it as if that player pressed jump. The HLAPI does not enforce that the command's owning client matches the target object's owner — that's left to the developer, and Boneloaf left it off.

Inputs that work:

| input | type | effect |
|---|---|---|
| `Jump` | digital | force a jump |
| `Grab Left` / `Grab Right` | digital | force a grab |
| `Headbutt` / `Kick` | digital | trigger the strike |
| `Move X` / `Move Y` | analog | steer the victim |
| `Duck` | digital | crouch them |

Practical effect: in any public lobby, one player can puppet the other four. Walk them off the truck, headbutt their teammate, drop them off the gondola at the worst possible moment. There is no anticheat watching for this; the inputs look identical to the victim "doing it themselves."

## VULN-10 / VULN-11 — DataReader DoS and LobbySnapshot heap exhaustion

I went into the network surface expecting a remote RCE in the lobby protocol because the game uses **deprecated HLAPI** (Unity dropped support in 2018) plus a custom `CoreNet` UDP layer on top. That combo is usually a goldmine.

The conclusion for *most* of the protocol is unsatisfying — **IL2CPP saves them**. `NetBuffer.ReadByte` has two bounds checks. `NetBuffer.ReadBytes` truncates length to a 16-bit counter (`inc ax` at `GameAssembly.dll+0x779419`) and per-element-checks regardless. `NetworkReader.ReadString` caps at 32KB. `ChannelBuffer.HandleFragment` has 16-bit-truncated fragment lengths.

But the developer's *own* deserializer skipped that. `DataReader.ReadString` (RVA `0x7E7D50`) reads an attacker-controlled `int32` count, then loops that many times concatenating UTF-16 chars. **No upper bound.**

```text
0x7E7DCB: call ReadInt32       ; attacker-controlled
0x7E7DD2: test eax, eax        ; allow zero/negative early return
0x7E7DE0: <loop>               ; for i in range(count):
0x7E7DEC: cmp rdx, rcx; jg overflow
0x7E7DF6: call ReadUInt16      ; returns 0 silently on OOB
0x7E7E34: cmp ebx, esi; jl loop ; ignores OOB, keeps going
```

`ReadUInt16` returning 0 on OOB saves this from heap corruption — the loop just builds a string of nulls. Send `count = 0x7FFFFFFF` and the server thread enters a 2-billion-iteration loop of O(n²) string concats. Wedged forever, exhausting heap as it goes. Affects every lobby message with string fields.

**`LobbySnapshot` has the same disease at the next layer up:** nested arrays whose sizes come from the wire. `LOBBY_COMPLETE_PLAYER_STATE` (flag 21) gets you to:

```text
LobbySnapshot
  └─ ConnectionStateBeast[] (count from wire)
       ├─ bool[] _allowed     (count from wire)
       ├─ string[] _name      (count from wire, each string = ReadString)
       ├─ OnlineID[] _id      (count from wire)
       └─ BeastInfo[]         (count from wire)
            └─ CostumeSaveEntry (nested strings)
```

`1000 states × 200 slots × 500-char names` → ~381 MB of managed-heap pressure on the receiver. GC pressure → OOM → game crash.

Both DoS bugs **amplify** through `RelayPostBox.RerouteMessageToAllClients` (RVA `0x81AEF0`), the host's "fan out to everyone" function. One malicious client → all 10 lobby members crash.

## VULN-13 — player IP disclosure (defeats Steam Relay's IP privacy)

The lobby protocol has dedicated message types `LOBBY_USER_IP_REQUEST` (id 11) and `LOBBY_USER_IP` (id 10). `IPAddressFetcher.GetIPAddress()` (RVA `0x5186B0`) returns the real adapter IP and the response sends it as a string.

Even when using Steam Relay or Unity Relay for game traffic, *this* lobby message causes the target to voluntarily send their real IP through the relay channel. The relay's IP-privacy guarantee is bypassed by the application happily handing out the IP itself. Practical effect: every player who joins a public lobby is doxxable.

## VULN-7 — DLL search-order hijack

`UnityPlayer.dll` and `OVRPlugin.dll` import 10 system DLLs that are not shipped with the game. Windows DLL search order means CWD wins:

```text
version.dll
winhttp.dll
dxgi.dll
d3d11.dll
xinput1_3.dll
... (5 more)
```

Combined with permissive ACLs on the Steam game directory (`BUILTIN\Users:(F)` is the default for Steam-installed games), any local user can drop a `version.dll` proxy into `Gang Beasts\` that forwards real exports and runs whatever it wants on launch. PoC was a 17-export `version.dll` proxy that forwarded to `C:\Windows\System32\version.dll` and shelled out in `DllMain`.

## VULN-14 — `NetAuthMessage.Debug` info leak

Setting `NetAuthMessage.Debug=true` (the same client-controlled bool from VULN-21) triggers `GBServerMemberManager.FinaliseConnection` (RVA `0x63F820`) to call `GBConfigResourceLoader.GetVersion()` and broadcast back `DEBUG_LOG_MESSAGE` (msg type 902) with build version, commit hash, network version, Steam App IDs, matchmaking pool, demo event name. Not RCE — only reads in-memory config — but the kind of thing that should obviously never be in a release build.

## VULN-15 — host relay amplification

`RelayPostBox.RerouteMessageToAllClients(byte[], UserInfo, int)` causes the host to re-broadcast any client message to all connected clients (max 10). A single crafted packet from one malicious client reaches every other player in the lobby. Amplifies VULN-10 (DoS), VULN-11 (heap exhaustion), VULN-12 (input injection), and VULN-13 (IP disclosure) from single-target to mass-target.

## VULN-16 + VULN-17 — Elastic Beanstalk subdomain takeover and plaintext costume HTTP

The `CostumeCloudSaveLoad` class hardcodes `http://gbcostumedb-dev.elasticbeanstalk.com/` as its API backend. Two findings collapse into one:

1. **The endpoint is plaintext HTTP**, not HTTPS. All costume cloud data — saves, share codes, cloud avatars — is in the clear. Public-WiFi MITM intercepts and modifies it; nothing protects the channel.
2. **The endpoint is dead.** `nslookup gbcostumedb-dev.elasticbeanstalk.com → NXDOMAIN`. Elastic Beanstalk subdomain names become available for re-registration after the environment is deleted.

```text
Endpoint                                     | Method | Data
---------------------------------------------|--------|---------------------------
/new_costume_post                            | POST   | full costume JSON (b64)
/update_costume_post/{id}                    | POST   | updated costume + ID
/get_costume/bycode/{code}                   | GET    | costume share code
```

Spinning up a new EB environment named `gbcostumedb-dev` lets the attacker intercept every costume save/load/share from every game client worldwide. The dev/prod naming pattern (`-dev` suffix) also implies `gbcostumedb-prod` exists; that one is presumably live but the same plaintext-HTTP problem applies to it.

## VULN-18 — Unity Project ID disclosure

The Unity Services Project Configuration in `globalgamemanagers` exposes:

| field | value |
|---|---|
| Unity Project ID | `39848f19-bb83-4915-8516-cb4afbfcb371` |
| Environment | `production` |
| Company Name | `boneloaf` |

Plus the exact Unity Services SDK versions (Lobby 1.1.2, Relay 1.0.5, Matchmaker 1.1.2, Authentication 2.7.2, Wire 1.2.2, Remote Config 3.1.3, Multiplay 1.0.5, Services Core 1.12.0, QoS 1.2.1).

In isolation, low severity. In combination with VULN-25 it is what makes "join a relay allocation and own everyone in it" trivial — the project ID is the access control on Relay allocations.

## VULN-19 — CCD access token embedded in binary

`CcdRuntimeConfig` (TypeDefIndex 190) has a static `AccessToken` field initialized from serialized data baked into the binary at `ProcessSerializedData` (RVA `0x427900`):

```csharp
public static class CcdRuntimeConfig {
    public static string Environment;  // 0x0
    public static string Bucket;       // 0x8
    public static string Badge;        // 0x10
    public static string AccessToken;  // 0x18  ← embedded credential
}
```

Used by `AddWebRequestOverride` (RVA `0x427300`) to authenticate to Unity Cloud Content Delivery for addressable asset downloads. Memory dump or a Frida hook pulls the token. Token enumerates / downloads (and possibly modifies, depending on permissions) all addressable assets from Unity CCD.

## VULN-20 — PlayFab entity token leakage via Player.log

The game logs the PlayFab session token to `%APPDATA%\..\LocalLow\Boneloaf\Gang Beasts\Player.log` in plaintext:

```text
Auth Token  : dMuca8Wl8Vrc0gcImlWVoA11DVE2
Steam ID    : 76561199705918525
Username    : Jip
Environment : production
```

`Player.log` is world-readable on Windows. Combined with the PlayFab Client API (80+ methods including `ExecuteCloudScript`, `AddUserVirtualCurrency`, `AcceptTrade`, `GetAccountInfo`), any same-user process can replay the session.

## VULN-23 — PlayFab Title ID and SDK disclosure

| field | value |
|---|---|
| Title ID | `B556E` |
| SDK version | `2.166.230512` (May 2023) |
| Build identifier | `adobuild_unitysdk_167` |
| Default API URL | `playfabapi.com` |

Direct PlayFab REST is then a curl away:

```text
POST https://B556E.playfabapi.com/Client/LoginWithCustomID
POST https://B556E.playfabapi.com/Client/ExecuteCloudScript
POST https://B556E.playfabapi.com/Client/GetAccountInfo
```

Combined with the leaked entity token (VULN-20), full API impersonation. The 3-year-old SDK adds known-issues risk on top.

## VULN-24 — PlayFab Party test functions in production

`PartyWin.dll` (v1.6.1) exports test/debug functions in the shipped binary:

| export | purpose | risk |
|---|---|---|
| `PartyTestGetLocalUserToken` | extract user auth token | **token theft** |
| `PartyTestRefreshLocalUserToken` | force token refresh | manipulation |
| `PartyTestInjectCreateNewNetworkFailure` | simulate net failure | **DoS injection** |
| `PartyTestStartDestroyingNetwork` | force network destruction | **DoS** |
| `PartyTestGetAudioRenderStatsForTest` | audio debug stats | info disclosure |
| `PartyTestGetJitterBufferStatsForTest` | network debug stats | info disclosure |
| `PartyTestResetAudioRenderStatsForTest` | reset audio stats | debug |

A Frida script or DLL injection calls `PartyTestGetLocalUserToken` to extract the PlayFab entity token from a running game. Combined with VULN-23 (Title ID), full API access as the victim player.

## VULN-2 — deprecated HLAPI + CoreNet message surface

The full attack surface, for completeness — every code in the protocol that an attacker can put bytes into. Highlights from the enum dump:

| code | name | direction | effect |
|---|---|---|---|
| 200-205 | `MODEL_ITEM_NET_INT/FLOAT/STRING` | bidirectional | state manipulation, string injection |
| 210-212 | `MODEL_COLLECTION_NET_MEMBER/PLAYER/PLATFORM` | bidirectional | member / player / platform spoofing |
| 301 | `NET_MEMBER_AUTH_REQUEST` | client→server | **auth bypass (VULN-21)** |
| 305 | `NET_MEMBER_SETUP_STATE` | client→server | state injection |
| 702-704 | `NET_ROUND_EVENT_GAME_SETUP/START/END` | server→client | forced game flow |
| 902 | `DEBUG_LOG_MESSAGE` | server→client | **debug data leak (VULN-14)** |
| 1102 | `NET_PLATFORM_STEAM_TICKET` | client→server | **ticket spoofing** |
| 1110 | `NET_SERVER_TEXT_MESSAGE` | server→client | arbitrary text injection |
| 1120 | `NET_SPAWN_OBJECT` | client→server | **object spawn (VULN-22)** |
| 1121 | `NET_SPAWN_ACTOR` | client→server | **actor spawn (VULN-22)** |
| 1130 | `NET_REQUEST_SINGLE_DISCONNECT` | client→server | force disconnect |

## VULN-4 — debug code shipped in production

The production build still has these compiled in:

- `DevelopmentTestServerUI` — test server config UI
- `GlobalDebug` / `DebugVariables` — runtime debug toggles
- `GUIDebugTool` — overlay with logging
- `DEBUG_LOG_MESSAGE` — network debug log path
- `CSPlayWith` — debug join functionality
- `DevelopmentTestServer.ConnectToLocalServer` — static method, callable

`DirectConnectScript` (RVA `0x5A1330`) and `CoreNet.NetworkManager.LaunchClient(IP, port)` (RVA `0x42EA60`) are reachable from the UI — direct IP connection to an attacker-controlled malicious UNET server.

## the ones that *aren't* exploitable

A few "obviously bad" findings ruled out on close inspection. Worth listing because "is in the binary" ≠ "is reachable":

- **`Newtonsoft.Json` with `TypeNameHandling`.** Three days of trying very hard. Frida hooks confirmed `set_TypeNameHandling` is never called with anything but None. No `$type` injection.
- **`BinaryFormatter`.** In the IL2CPP metadata as part of the .NET BCL. Game code never touches it.
- **`ShellCommand.ExecuteSync`.** Exists. Zero callers in the entire codebase. Dead code.
- **CVE-2020-6016 (Steam GNS).** SDK compiled April 2023, after the fix.
- **Castle.Core dynamic proxy.** Not exploitable — IL2CPP blocks `Reflection.Emit`.

## the through-line

Gang Beasts is a 2018-grade Unity stack ported forward into 2021 LTS without any of the stack underneath being modernized. The deprecated HLAPI is what Unity itself recommended migrating off of seven years ago. The custom CoreNet layer on top of it is a developer's deserializer that mostly behaves but blows up on `int32` lengths. The IL2CPP build is large and CFG-less. The XR loader argument is two patch versions behind the fix. The mbedTLS embedded for DTLS is an unpatched 2023-vintage version with a known heap overflow. The "auth" is a string field nobody verifies. The "developer privileges" are a hardcoded list of Steam IDs anyone can claim.

None of these alone is fatal. The combination is: a `steam://` link or poisoned shortcut → local RCE; a relay allocation → pre-auth network RCE on every host; a malicious lobby client → DoS the room and puppet other players; an LAN attacker on the same coffee-shop WiFi → IP-grab everyone, crash the host, claim dev privileges. Every one of these landed because the boundary between "client-controlled bytes" and "thing that runs server-side" was drawn in the wrong place.

The fix list is short and unambitious:

1. Update Unity to 2021.3.56f2+ (or hex-patch `UnityPlayer.dll` to mangle `xrsdk-pre-init-library`, exactly like Unity's official patcher does).
2. Rebuild against a patched mbedTLS (CVE-2023-43615 + post-October-2023 fixes).
3. Bound-check `DataReader.ReadString` and the `LobbySnapshot` array sizes.
4. Validate `[Command]` invocations against the owning client.
5. Validate `NetAuthMessage.PlatformID` with Steam `BeginAuthSession` — actually check ownership and identity, even client-side.
6. Strip the IP-exchange messages, the `NetAuthMessage.Debug` codepath, the `DevelopmentTestServerUI`, and the dev-ID hardcoded list out of release builds.
7. Tighten install-dir ACLs.
8. Build with `/guard:cf` on `UnityPlayer.dll` and `GameAssembly.dll` so the *next* memory-corruption bug isn't a free win.
9. Migrate costume cloud to HTTPS and reclaim the dead EB subdomain (or at least re-point it through Cloudflare so it can't be silently taken over).
10. Pass PlayFab tokens out-of-band; stop logging them in `Player.log`.

Likely outcome: nothing. Party-game studios don't ship security updates for shipped party games. The mbedTLS update alone would require a Unity LTS bump that Boneloaf has no commercial reason to do.

## TL;DR chain

```text
network attacker (anyone on the Internet, or Unity Relay)
  ──► malformed DTLS handshake fragment 1: small total_message_length
  ──► fragment 2: fragment_offset + fragment_length > buffer
  ──► heap overflow in mbedTLS reassembly
  ──► no CFG → ROP through 22.7MB of UnityPlayer.dll text
  ──► pre-auth RCE on host process

local attacker
  ──► .lnk / poisoned shortcut with -xrsdk-pre-init-library evil.dll
  ──► full RCE inside game process, persistent on every launch

network attacker (same lobby)
  ──► NetAuthMessage with PlatformID = 76561198007011733 (dev)
  ──► AuthenticateRequest matches → spawn calls authorized
  ──► NetSpawnObjectMessage → spawn anything anywhere
  ──► CmdAlterDigitalInput("Jump", true) on victim NetworkInstanceId
  ──► puppet victim character
  ──► DataReader.ReadString count=0x7FFFFFFF
  ──► host thread wedged forever, lobby dies
  ──► RerouteMessageToAllClients amplifies any of the above to all 10 players

network observer
  ──► LOBBY_USER_IP_REQUEST(target_id)
  ──► target's real IP via the relay
  ──► defeats Steam Relay IP privacy

local attacker
  ──► read Player.log → PlayFab entity token
  ──► PlayFab API impersonation as victim

attacker with a Cloudflare account
  ──► claim gbcostumedb-dev.elasticbeanstalk.com
  ──► intercept every costume save/load worldwide
```

Cute game. Glass jaw underneath. A week well spent.
