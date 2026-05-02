---
title: 'overcooked! 2 — RCE via -overrideMonoSearchPath, plus DLL hijacking on a writable install dir, on a Unity LTS that will never get fixed'
description: 'Unity 2017.4 ships an arg that redirects mono assembly loading to attacker-controlled paths. The engine is end-of-life, the official patch starts at 2019.1, so this game will never get the fix. Plus the install dir is user-writable so the same primitive lands via DLL hijack, and Assembly-CSharp.dll has zero obfuscation so a weaponized mscorlib is trivial to build'
pubDate: '2026-05-02'
category: 'exploits'
---

Overcooked! 2 ships on Unity **2017.4.8f1**. Unity's official patch for the `-overrideMonoSearchPath` argument-injection bug (CVE-2025-59489) starts at Unity 2019.1. Everything older than 2019.1 is **permanently** out of scope — Unity isn't going to backport. So Overcooked! 2 is, by Unity's own roadmap, never going to be fixed unless the developer (Team17) rebuilds the game on a newer engine, which they have no apparent plans to do.

That makes this a fun case study in *forever-vulnerable* shipped software. Below is what the bug actually does, how I confirmed it on the Steam build, why the local-launch attack vector is wider than the CVE write-ups suggest, and why even community patching is harder than it should be on this title.

## the build

```text
Game        : Overcooked! 2 (Steam AppID 728880)
Developer   : Team17 / Ghost Town Games
Engine      : Unity 2017.4.8f1   (file version 2017.4.8.5945332)
Mono build  : 32-bit (Mono\EmbedRuntime\mono.dll)
Patched in  : Unity 2019.1+ (will never apply to this game)
Install dir : C:\Program Files (x86)\Steam\steamapps\common\Overcooked! 2\
              ACL: BUILTIN\Users:(F)        ← STANDARD-USER WRITABLE
```

Two things worth flagging from the build inventory itself before any actual exploitation. First, **Mono is 32-bit** — the bug applies *exactly* to the 32-bit Mono runtime configuration per Unity's own advisory; this game is the canonical vulnerable shape. Second, **the install directory is writable by `BUILTIN\Users:(F)`** — that's Steam's default ACL on installed games, not an OS quirk, and it changes which findings are practical because any same-user process can drop files into the game directory.

## what `-overrideMonoSearchPath` does (the CVE itself)

Unity's player binary (`UnityPlayer.dll` on Windows) parses a number of command-line arguments at startup. One of them, `-overrideMonoSearchPath <path>`, takes a directory and feeds it to two Mono runtime functions:

```c
mono_set_assemblies_path(path);
mono_assembly_setrootdir(path);
```

After this point the Mono runtime uses `<path>` as its primary search location for *every* .NET assembly the game loads — including `mscorlib.dll`, `Assembly-CSharp.dll` (the game code), `UnityEngine.dll`, and every reference assembly in `Overcooked2_Data/Managed/`. There is no signature check, no path restriction, no integrity verification, no allowlist. If you can drop a DLL named `mscorlib.dll` into `<path>` before the game starts, it loads and the Mono runtime calls into it — including running any `[ModuleInitializer]` or any type's static constructor that the runtime touches during initialization.

The Unity advisory describes this as **CWE-426 (Untrusted Search Path) plus CWE-94 (Improper Code Generation)**. Both fit. CVSS 8.4. Unity's actual patch in 2019.1+ is to mangle the parser-side string so the argument no longer matches: `overrideMonoSearchPath` becomes `8verrideMonoSearchPath` in the binary. They didn't change parser logic; they changed the *string the parser compares against* so user input never matches it. That's the same approach Unity took for several other command-line argument fixes in the same advisory cluster. Pragmatic; doesn't fix the parser; leaves "is this engine version patched" as a string-search question rather than a behavioral one.

## confirming the Steam build is vulnerable

Two checks, both run on a fresh Steam install at `C:\Program Files (x86)\Steam\steamapps\common\Overcooked! 2\`.

**Check 1: Unity version.** The build manifest at `Overcooked2_Data/data.unity3d` and the file version of `UnityPlayer.dll` both report `2017.4.8.5945332` → Unity 2017.4.8f1. Pre-2019.1, so structurally vulnerable.

**Check 2: the unpatched string is present in `UnityPlayer.dll`.**

```python
data = open(r"C:\Program Files (x86)\Steam\steamapps\common\Overcooked! 2\UnityPlayer.dll", "rb").read()
print("vulnerable string at:", data.find(b"overrideMonoSearchPath"))
print("patched variant at:  ", data.find(b"8verrideMonoSearchPath"))
```

Output:

```text
vulnerable string at: 14989996
patched variant at:  -1
```

Offset `0xE4B1AC`. The mangled patched form is absent. Adjacent bytes within ~20KB of that offset include `mono_set_assemblies_path` (offset 14997672), `mono_set_dirs` (offset 15001776), `mscorlib.dll`, `Failed loading assembly`, and `Found Assembly:%s` — confirming the string is part of the actual Mono loader codepath and not some unrelated reference.

That's enough to know the argument is parsed and reachable. The next test is whether it actually changes assembly resolution at runtime.

## confirming the argument is honored at runtime (without payloading)

The cleanest live test: launch the game with `-overrideMonoSearchPath` pointing to an empty directory. If Mono honors it, the game crashes immediately on assembly resolution because `mscorlib.dll` won't be found at the redirected path.

```powershell
mkdir C:\temp\empty_mono
& "C:\Program Files (x86)\Steam\steamapps\common\Overcooked! 2\Overcooked2.exe" `
    -overrideMonoSearchPath C:\temp\empty_mono
```

The game window flashes briefly and dies. Unity's output log at `%LOCALAPPDATA%\..\LocalLow\Team17\Overcooked2\Player.log` confirms:

```text
mono_assembly_setrootdir = "C:\temp\empty_mono"
Could not load assembly mscorlib
Aborted
```

The redirected path was honored. If `mscorlib.dll` existed there, it would be loaded and `DllMain` (or the static constructor of any imported type) would run. **Full code execution inside the game process, with the user's privileges, before any game code runs.**

I did not weaponize the PoC — there's no need to ship a working `mscorlib.dll` to demonstrate the bug. Confirming that the Mono root directory was redirected is sufficient. The full evidence bundle is captured in `main.py`: PE arch (`x86 32-bit`), `UnityPlayer.dll` SHA-256 + version, binary scan with corroborating markers, runtime launch with a benign canary file in the staging directory, Unity log copy, and a JSON+text report ready for submission.

## delivery vectors

The argument has to reach the launcher somehow. There are three realistic paths in increasing order of how much the user has to do.

**1. Co-located malware.** Any malicious process running as the same user can spawn the game with arbitrary arguments via `CreateProcess`. This is unconditional — once you have user-context code execution, you can also persist via this mechanism (every game launch becomes a re-trigger of your payload). Not impressive on its own (you already have RCE) but useful as a persistence mechanism that survives the user removing your initial loader.

**2. Direct shortcut / batch / `.lnk` poisoning.** Anyone who can write a `.lnk` or `.bat` in a place the user runs from (Desktop, Start Menu, somewhere on `PATH`) can prepend the argument. This is a common malware persistence trick — replace the user's Overcooked! 2 desktop shortcut with one that adds `-overrideMonoSearchPath` plus a path you've staged. The user double-clicks Overcooked! 2 like normal; your payload runs every launch. Persistent across reboots, survives game updates, and the icon and target executable still point at the legitimate game so it looks fine in tooltips.

**3. Steam URI handler (mostly closed).** Historically `steam://run/728880//-overrideMonoSearchPath%20<path>` would launch the game with the argument pre-populated, on older Steam clients. Valve patched the URI handler to filter dangerous parameters in 2024, so modern Steam blocks this. **But if the user has an unpatched Steam client (or any Steam-protocol-handler-like tool that does its own URI parsing), a single browser navigation does it.** The fix is on Valve's side; if a user opted out of Steam updates or uses a third-party launcher, they're still exposed.

For a serious targeted attack, vector 2 (a malicious shortcut) is the most reliable. For mass-casualty drive-by, vector 3 was the dream and is mostly closed at the Steam layer.

## the parallel finding — DLL hijacking from a user-writable install dir

The Unity advisory I'm working from has a numbered list of related findings; #4 is DLL hijacking. It's not part of CVE-2025-59489 but it lands at the same target via a different primitive — and the consequence is identical (arbitrary code execution inside the game process, persistent on every launch). Worth covering because it changes the practical fix story.

`UnityPlayer.dll` and `Overcooked2.exe` import a list of system DLLs that are not shipped in the install directory. Windows' DLL search order means the game directory (CWD) is checked *first* for these:

```text
version.dll
winhttp.dll
dxgi.dll
d3d11.dll
xinput1_3.dll
... and more
```

Combined with the `BUILTIN\Users:(F)` ACL on the install dir, **any local user can drop a `version.dll` (or any of the others) into the install directory** and Windows' loader will pick it up before the real one in `System32`. The proxy DLL needs to forward the legitimate exports to the real `version.dll` to keep the game functional, then run whatever it wants from `DllMain`. PoC was a 17-export `version.dll` proxy that forwarded to `C:\Windows\System32\version.dll` and shelled out from `DllMain`.

The kicker is that **`UnityPlayer.dll` itself is in a user-writable directory.** Standard users can replace the entire engine binary. CVE-2025-59489 is more impactful as a *demo* because it needs no file modification to exploit, but the writable install dir means that even the patched form of the bug — replace `UnityPlayer.dll` with a hex-edited copy that mangles the string — can be *un-patched* by any local attacker who wants the original behavior back. "The user community patches their local install" runs into the same wall: any same-user malware undoes the patch.

This is also why the **community-patcher fix path** (below) is fragile in practice. The patch lasts until Steam's "verify integrity of game files" reverts it, OR until any local malicious process re-overwrites it. There's no signature check on `UnityPlayer.dll` because Unity doesn't ship signed binaries here.

## Assembly-CSharp.dll is unobfuscated — weaponized mscorlib is trivial

Looking inside `Overcooked2_Data/Managed/Assembly-CSharp.dll` with any .NET reverse-engineering tool (dnSpy, ILSpy, dotPeek):

- No obfuscation. Class names, method names, string literals all human-readable.
- Game logic is fully reverse-engineerable in minutes.
- Type signatures and entry points to the Unity engine are obvious.

The relevance to this finding: **building a weaponized `mscorlib.dll` for the `-overrideMonoSearchPath` payload is trivial** because you can study exactly which `mscorlib` types and methods the game touches during startup. You don't have to ship a bit-perfect substitute — you only need to satisfy the references the game's static initializers actually make. Without obfuscation on the game side, you can audit those references in five minutes.

For a more sophisticated payload — one that loads, runs your code, *and* lets the game continue functioning — the same lack of obfuscation lets you write a `mscorlib.dll` that proxies most calls back to a renamed copy of the legitimate one. You preserve normal gameplay while persistently running attacker code. The game looks completely normal to the user.

## the practical fix is a community patch, and it doesn't really hold

Since Team17 isn't shipping an update and Unity isn't backporting, the realistic options for a paranoid user are:

1. **Run Unity's binary patcher tool against the local `UnityPlayer.dll`.** The tool literally hex-replaces `overrideMonoSearchPath` with `8verrideMonoSearchPath` in place. Five minutes of work, breaks the argument parser without touching anything else.

2. **Hex edit by hand:**

   ```python
   import os
   p = r"C:\Program Files (x86)\Steam\steamapps\common\Overcooked! 2\UnityPlayer.dll"
   with open(p, "rb") as f:
       data = bytearray(f.read())
   idx = data.find(b"overrideMonoSearchPath")
   data[idx] = ord("8")  # 'o' -> '8'
   with open(p, "wb") as f:
       f.write(data)
   ```

3. **Don't run the game from untrusted shortcuts.** This is the workaround for users who don't want to modify game files. It's also nearly unenforceable in practice because the malicious shortcut looks identical to the real one.

The patches don't really hold for two compounding reasons:

- **Steam's "Verify integrity of game files"** reverts modified `UnityPlayer.dll`. So any user-initiated repair undoes the fix. The patcher has to be re-applied after every Steam update or verification.
- **The install dir is user-writable.** Same-user malware can re-overwrite `UnityPlayer.dll` with the original at any time. Any persistence mechanism a malicious actor sets up can include "re-revert the patch every minute."

So the realistic security posture is: **this game is exploitable forever, and the only durable mitigation is "don't install it on a machine that runs untrusted shortcuts or untrusted local processes."** Which is a posture you should already have, but isn't one most game players have.

## why this category of bug keeps shipping

The Unity advisory lists ~20 different command-line arguments that touch sensitive runtime behavior — `-overrideMonoSearchPath` is one of the worst, but `-xrsdk-pre-init-library` (which I covered separately in the Gang Beasts writeup, where it shows up in 2021.3 LTS games) and friends have similar shapes. The pattern: an engine vendor ships generic arguments useful for development/debugging, those arguments survive into release builds because nobody strips them, and any developer who builds on the engine inherits the attack surface.

The mitigation Unity actually shipped — mangling the strings in the binary — is the smallest possible patch: it doesn't fix the parser, it just makes the matching string never appear in command-line input. That's pragmatic — a real fix would require auditing every command-line entry and deciding which are safe — but it leaves a long tail of:

- Pre-2019.1 games that will never get the patch (Overcooked! 2 is one, Boneloaf's earlier titles are others, dozens of indie LTS-2017 games are in the same boat).
- Patched games where the binary patcher hasn't been applied (Steam doesn't push it; the user has to know to apply it).
- Games where the patch is re-undone by Steam integrity verification.

The actual remediation pipeline for the affected population is **community-maintained patchers, not vendor updates.** That's a structurally different state than "this CVE is fixed in a patch you'll get automatically."

## the takeaway

Two things to chew on:

1. **End-of-life engine versions are forever-vulnerable.** Pre-2019.1 Unity will never get this fix. Any shipped game built on a pre-2019.1 Unity is permanently exposed unless the developer rebuilds. There are *thousands* of such games. The actual remediation pipeline for that population is community-maintained patchers, not vendor updates. And as we saw above, even that pipeline is fragile because the install dir is writable, the patch survives only until the next Steam verify, and same-user malware can re-undo it at will.

2. **String-mangling patches are weird, but defensible.** It feels gross that the official remediation is "rename the string in the binary so the argument doesn't match." But it's also the smallest, lowest-risk delta — Unity didn't have to touch the parser, the Mono loader, or any other code. It's a reminder that a fix doesn't have to be elegant to be effective; it just has to break the chain. The downside is that detection becomes a string-search question — `find -exec grep -l "overrideMonoSearchPath"` over your install of every Unity game, then prioritize patching the ones that match — rather than a behavioral one, which makes "is everything I have safe?" much harder to answer in a real environment.

For Overcooked! 2 specifically: cute game, permanently broken security boundary. If you launch it from anything other than the verified Steam shortcut on a machine where you trust every other process running as your user, you're trusting whoever wrote the launcher.
