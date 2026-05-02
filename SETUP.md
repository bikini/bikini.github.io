# bikini — blog setup

Live URL (after first deploy): **https://bikini.github.io/**

---

## One-time setup (do these once, then forget)

Open PowerShell in this folder, then:

```powershell
# 1. Authenticate ONCE (browser opens, OAuth flow). Token is stored locally.
gh auth login
#    Pick: GitHub.com -> HTTPS -> Yes (auth Git with credentials) -> Login with web browser

# 2. Create the public repo and push the code in one command
git init -b main
git add -A
git commit -m "init blog"
gh repo create bikini.github.io --public --source . --push

# 3. Tell GitHub Pages to deploy from Actions (one API call, no web UI)
gh api -X POST "repos/bikini/bikini.github.io/pages" -f "build_type=workflow"
```

That's it. After this, you never log in to github.com again. The token `gh` stored
locally lets `git push` work forever.

Within ~2 minutes, your site is live at **https://bikini.github.io/**.

---

## Daily use — write a post

```powershell
.\new-post.ps1 "Title of my post"
```

What happens:
1. A new file appears at `src/content/blog/YYYY-MM-DD-title-of-my-post.md` with frontmatter pre-filled.
2. Your editor (VS Code if installed, else Notepad) opens it.
3. You write in markdown, save, close the editor.
4. The script auto-commits and pushes.
5. GitHub Actions builds the site (~1 min).
6. Your post is live at `https://bikini.github.io/blog/YYYY-MM-DD-title-of-my-post/`.

You never touched the GitHub website.

### Variants

```powershell
.\new-post.ps1 "Half-formed thought" -NoPush     # save as draft, don't publish yet
.\publish.ps1 "fix typos in welcome post"        # push edits to existing files
```

---

## Preview locally before publishing (optional)

```powershell
npm run dev
```

Opens at <http://localhost:4321>. Hot-reloads as you edit.

---

## Customize

- **Site title / tagline**: edit `src/consts.ts` (two lines)
- **About page**: edit `src/pages/about.astro`
- **Theme/colors**: edit `src/styles/global.css`
- **Header links**: edit `src/components/Header.astro`

---

## Attack-surface notes

- The only credential you ever enter into GitHub.com is the one-time `gh auth login` browser flow. After that, all pushes use the locally-stored OAuth token.
- The repo is public, so anyone can read it — don't put secrets in `.md` files. The repo's `.gitignore` already excludes `.env`, `node_modules`, and `dist`.
- If you ever want to revoke access: <https://github.com/settings/applications> → revoke "GitHub CLI". Re-running `gh auth login` re-issues a token.
- For an extra layer: enable a passkey on your GitHub account. Then even if your laptop is compromised, an attacker can't log in to add a co-maintainer.
