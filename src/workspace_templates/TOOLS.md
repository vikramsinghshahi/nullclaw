
# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## Git: which tool to use

- **Use the `shell` tool** for: `git init`, `git remote add`, `git push`, `git clone`. The `git_operations` tool does not support these.
- **Use the `git_operations` tool** for: status, diff, log, branch, commit, add, checkout, stash.
- Run git from the workspace directory: `/nullclaw-data/workspace` (or pass `cwd` to the shell tool).
- For push over SSH, the deploy key is already configured in `~/.ssh`; use remote URL like `git@github.com:USER/REPO.git`.

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
