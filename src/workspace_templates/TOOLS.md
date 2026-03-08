
# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## Capabilities in this deployment

- **Git is allowed.** You can run git commands (via `git_operations` and, when needed, the `shell` tool). Security policy does not block git.
- **Shell:** Restricted only by allowed_paths; you can run commands in the workspace.
- When asked what you can access, say you can use git (status, add, commit, push, etc.), file read/write/edit, memory, and shell within the workspace.

## Git: which tool to use

- **Use the `git_operations` tool** for: status, diff, log, branch, commit, add, checkout, stash, **and push** (operation `"push"`).
- **Use the `shell` tool** for: `git init`, `git remote add`, `git clone`, and any git command not in the list above.
- Run git from the workspace directory: `/nullclaw-data/workspace` (or pass `cwd`).
- **Push:** Set remote to HTTPS (`https://github.com/USER/REPO.git`) and ensure `GITHUB_TOKEN` is in env; use `git_operations` with operation `push`. Or use SSH (`git@github.com:USER/REPO.git`) if `GIT_SSH_KEY_B64` is set.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.
