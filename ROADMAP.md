# ROADMAP — Vibe Coding with NullClaw & Nano Bots

This file is your **mission control map**: how the bot(s) are wired, where to tune “brain / code / muscle,” and how to grow from a single Telegram bot into a **team of nano bots** that ship code for you.

---

## 1. Architecture: Brain, Code, Muscle

| Layer | What it is | Where it lives | You tune it via |
|-------|------------|----------------|-----------------|
| **Brain** | LLM choice, system prompt, memory, persona | Config (model, agents), workspace markdown (SOUL, USER, IDENTITY, AGENTS), memory backend | `config.json` / Dockerfile config block; `src/workspace_templates/*.md` |
| **Code** | Workspace files, tools (git, file_*, shell), skills, scripts | Workspace dir (`/nullclaw-data/workspace` in Docker), tools in config | USER.md, AGENTS.md, TOOLS.md; autonomy + tools in config |
| **Muscle** | Execution (sandbox, runtime), channels (Telegram, web), deployment (Railway, CI) | Config (channels, runtime, security), Dockerfile, Railway, GitHub | Dockerfile, Railway env, `config.json` (channels, gateway) |

- **Brain** = what the agent “knows” and “is” (model + prompts + memory).
- **Code** = what it can read/write and run (workspace + tools + git).
- **Muscle** = how it talks to you and where it runs (Telegram, web, Railway, GitHub).

---

## 2. File Map — What Lives Where

### 2.1 Workspace templates (baked into image; bot loads at runtime)

| File | Purpose | Edit in repo → reflected in bot after rebuild |
|------|---------|------------------------------------------------|
| `src/workspace_templates/USER.md` | About **you** (name, timezone, context) | Yes — COPY’d into image workspace |
| `src/workspace_templates/IDENTITY.md` | Who the **bot** is (name, vibe, emoji) | Yes — COPY’d into image workspace |
| `src/workspace_templates/SOUL.md` | Bot **persona** (tone, boundaries, continuity) | Yes — add COPY in Dockerfile if you want it in image |
| `src/workspace_templates/AGENTS.md` | **Operational rules** (session startup, memory, safety) | Yes — add COPY in Dockerfile if you want it in image |
| `src/workspace_templates/TOOLS.md` | **Local notes** (SSH, devices, env-specific) | Yes — add COPY in Dockerfile if you want it in image |
| `src/workspace_templates/HEARTBEAT.md` | **Periodic checklist** (what to check when heartbeat runs) | Optional — add COPY if you use heartbeat |
| `src/workspace_templates/BOOTSTRAP.md` | First-run “birth certificate”; usually deleted after use | Optional |

Right now the Dockerfile COPYs only `USER.md` and `IDENTITY.md`. To have SOUL, AGENTS, TOOLS (and optionally HEARTBEAT) in the image too, add matching `COPY` lines in the Dockerfile config stage.

### 2.2 Config (brain + code + muscle settings)

| Where | What | Purpose |
|-------|------|---------|
| **Dockerfile** (heredoc `config.json`) | Models, agents.defaults, agent.max_tool_iterations, channels (Telegram), memory, gateway | Single place for “live” config in Railway image |
| **Railway env vars** | `OPENROUTER_API_KEY`, `NULLCLAW_WORKSPACE`, etc. | Secrets and overrides without rebuilding |
| **Optional:** `config.railway.json` | Full config file | If you switch to COPY config instead of heredoc |

### 2.3 Credentials (GitHub, APIs, etc.)

- **GitHub (for bots that ship code):** Use a **dedicated machine user or PAT** (not your personal account). Store in Railway as env vars, e.g. `GITHUB_TOKEN` or `NULLCLAW_GITHUB_TOKEN`. The **git** tool (and any CI) use git config / env for auth.
- **Other APIs:** Prefer env vars (e.g. `OPENROUTER_API_KEY`) and reference them from config or tools.

---

## 3. How Vibe Coding Works (Single Bot Today)

1. **You** → Telegram (or another channel) → “Add feature X and open a PR.”
2. **Brain** — Bot has context from USER.md, IDENTITY.md, SOUL, AGENTS (if present), and memory backend.
3. **Code** — Bot uses tools: `file_read`, `file_write`, `file_edit`, `git_operations` (status, add, commit, branch, etc.). With autonomy and allowlists, it can run `shell` in a controlled way.
4. **Muscle** — Bot runs on Railway; workspace is `/nullclaw-data/workspace`. To “ship,” it needs git configured (and, if pushing, GitHub credentials via env).
5. **Outcome** — Bot edits files, commits, and can push to a branch (or you run a deploy from that branch via CI/Railway).

Constraints: `max_tool_iterations` limits how many tool steps per turn; autonomy level and `allowed_commands` / `allowed_paths` define what it can run and where.

---

## 4. Nano Bots: Team + Mission Control

### 4.1 Concepts

- **Orchestrator** = Your main bot (e.g. the one on Telegram). It receives the mission, breaks it down, and delegates.
- **Nano bots** = Specialized agents. In NullClaw they are implemented as:
  - **Named agents** in config (`agents.list[]`) with different models/prompts (e.g. `researcher`, `coder`, `reviewer`).
  - **Delegate tool** — orchestrator calls `delegate` with `agent` + `prompt` (and optional `context`) to hand a subtask to a named agent.
  - **Spawn tool** — run a one-off “subagent” task with a restricted tool set (no delegate/spawn/message to avoid infinite recursion).

So: **one orchestrator** in Telegram; **multiple named agents** in config; orchestrator uses **delegate** (and optionally **spawn**) to create a “team of nano bots.”

### 4.2 Config shape for a team

In your baked-in `config.json` (or full config file) you’d have something like:

```json
"agents": {
  "defaults": {
    "model": { "primary": "openrouter/deepseek/deepseek-chat", "fallback": "..." }
  },
  "list": [
    { "id": "orchestrator", "model": { "primary": "openrouter/deepseek/deepseek-chat" }, "system_prompt": "You are mission control. Break tasks down and delegate to specialist agents." },
    { "id": "researcher", "model": { "primary": "openrouter/..." }, "system_prompt": "You research and summarize. Return concise findings." },
    { "id": "coder", "model": { "primary": "openrouter/..." }, "system_prompt": "You implement changes in the repo. Use file_* and git_operations." }
  ]
}
```

Orchestrator session gets the full tool set (including `delegate`); it calls `delegate(agent: "researcher", prompt: "...")` or `delegate(agent: "coder", prompt: "...")` so the “nano bots” are just different agents invoked via the same process.

### 4.3 Mission control: “See what everyone is doing”

- **Today (single process):** Logs on Railway show what the main process is doing. Tool calls (and thus delegate/spawn) are part of the same run; you see activity in Railway logs.
- **Observability:** NullClaw has an **Observer** abstraction (Noop, Log, File, Multi). Configuring a non-noop observer (e.g. Log or File) gives you a stream of events (e.g. tool calls, delegate calls) that you can treat as “mission control” output.
- **Structured visibility later:** You can add a small “mission control” view by: (1) having the orchestrator post status updates to a channel (e.g. Telegram) or (2) writing status to a file in the workspace or to memory, and reading that from a dashboard or script. No built-in UI exists; it’s “logs + optional status messages.”

So: **mission control** = Railway logs + optional Observer + optional status messages (Telegram or workspace file) from the orchestrator.

---

## 5. Shipping Code: Git + GitHub + Railway

### 5.1 Flow

1. **Workspace on Railway** = `/nullclaw-data/workspace`. If this is a git repo (or you clone into it at startup), the bot can run `git_operations` (status, add, commit, checkout, branch, etc.).
2. **Git credentials** — Use a **separate GitHub identity** (machine user or PAT). Set in Railway, e.g.:
   - `GITHUB_TOKEN` (or `NULLCLAW_GITHUB_TOKEN`) for HTTPS auth.
   - Git config in the image or at startup: `git config user.name "bot-name"`, `git config user.email "bot@...",` and use the token for push (e.g. `https://TOKEN@github.com/org/repo.git`).
3. **Push** — Bot (or a script you run) does `git push origin branch`. No COPY of credentials in Dockerfile; only env vars.
4. **CI / deploy** — GitHub Actions (or similar) on that repo can run tests and trigger Railway deploy (or build from branch). So: **bot pushes branch → CI runs → deploy** (or you merge and deploy main).

### 5.2 Suggested layout for “bot ships code”

- **One repo** (or one per product) that the bot is allowed to edit. Clone it into workspace at container start, or bake a clone step into the image/entrypoint.
- **Dedicated GitHub user** (e.g. `your-org-bot`) or PAT with minimal scope (repo, write). Env var in Railway.
- **Branch strategy** — Bot works on a branch (e.g. `bot/feature-x`), pushes it; you or CI opens PR and merges, then Railway (or CI) deploys.

### 5.2 Git over SSH (deploy key) — bot can `git push`

The image includes `docker-entrypoint.sh`, which reads an SSH private key from the environment and configures SSH for GitHub so the bot can run `git push` over SSH.

1. **Create a deploy key (or use a dedicated bot key)**  
   - On your machine: `ssh-keygen -t ed25519 -C "nullclaw-bot" -f nullclaw_deploy -N ""`  
   - Add the **public** key (`nullclaw_deploy.pub`) to the GitHub repo: Repo → Settings → Deploy keys → Add (read+write if the bot should push).

2. **Put the private key in Railway**  
   - Base64 (recommended, avoids multiline issues):  
     `cat nullclaw_deploy | base64 -w0`  
   - In Railway → your service → Variables: add  
     - **Name:** `GIT_SSH_KEY_B64`  
     - **Value:** (paste the base64 string)  
   - Or, if your platform supports multiline secrets, you can use **Name** `GIT_SSH_KEY` and **Value** the raw private key (entire contents of `nullclaw_deploy`).

3. **At runtime**  
   - The entrypoint writes the key to `$HOME/.ssh/id_ed25519` and creates `$HOME/.ssh/config` for `Host github.com` with `StrictHostKeyChecking accept-new`.  
   - The bot uses `git remote add origin git@github.com:USER/REPO.git` and `git push -u origin main` (or your branch). No token in env; SSH uses the deploy key.

4. **Tell the bot the repo**  
   - Put the repo URL in `TOOLS.md` or in the task (e.g. “push to git@github.com:myorg/my-repo.git”) so the bot can set the remote and push.

---

## 6. Where to Start — Phased Plan

### Phase 1: Tune the single bot (brain + code + muscle)

1. **Brain**
   - Edit `src/workspace_templates/USER.md` and `IDENTITY.md` (already COPY’d). Add SOUL.md and AGENTS.md to Dockerfile COPY if you want them in the image.
   - In Dockerfile config block, set `agents.defaults.model` and, if you want a clear “orchestrator” persona, add one entry in `agents.list` with a `system_prompt`.
2. **Code**
   - Ensure `agent.max_tool_iterations` is set (e.g. 3 for cheap, or higher when you need long chains). In config, enable the tools you need (default set usually includes file_*, memory, git_operations). If the bot must run shell commands, set `autonomy.allowed_commands` / `allowed_paths` carefully.
3. **Muscle**
   - Railway env: `OPENROUTER_API_KEY`. Telegram already in config. Confirm gateway port and that the service is healthy.

**Deliverable:** One stable Telegram bot that knows you (USER.md), has an identity (IDENTITY.md), and can use file + memory tools (and optionally git) within limits.

### Phase 2: Let the bot touch code and git

1. **Workspace = git repo** — Either clone your “bot repo” into `/nullclaw-data/workspace` at startup (entrypoint script) or build an image that already contains a clone (less ideal for credentials).
2. **GitHub credentials** — Create machine user or PAT; set `GITHUB_TOKEN` (or chosen name) in Railway. Configure git in workspace (entrypoint or Dockerfile) so pushes use that token.
3. **Enable git tool** — Confirm `git_operations` is in the default tool set (it is). Optionally allow `shell` only for git-related commands via autonomy allowlists.
4. **Test** — Ask the bot to make a small change, commit, and push to a branch; you or CI opens PR and merges.

**Deliverable:** Bot can edit repo, commit, and push; you deploy via GitHub + Railway (or CI).

### Phase 3: Nano bots + mission control

1. **Named agents** — Add `agents.list[]` with at least `orchestrator` and 1–2 specialists (e.g. `researcher`, `coder`). Give each a short `system_prompt`.
2. **Delegate** — Ensure the main session’s tool set includes `delegate`. Orchestrator uses “delegate to researcher/coder” for subtasks.
3. **Mission control** — Rely on Railway logs; optionally add Observer (Log/File) and/or have the orchestrator send short status updates to Telegram (e.g. “Delegated X to coder; waiting.” “Coder done: …”).
4. **Spawn (optional)** — For one-off subagent tasks with restricted tools, use `spawn`; keep it for advanced flows so you don’t get recursion.

**Deliverable:** One Telegram “mission control” bot that delegates to specialist agents and reports back; you see activity in logs (and optionally in Telegram).

### Phase 4: Polish and scale

- Add HEARTBEAT.md and cron for periodic checks (e.g. “review open PRs,” “summarize pending tasks”).
- Add more agents or skills as needed.
- Tighten autonomy and allowlists so only intended repos and commands are allowed.
- Consider a simple “mission control” dashboard (e.g. read Observer log or a status file and display in a static page or Notion).

---

## 7. Quick reference

| Goal | Where to look / what to do |
|------|-----------------------------|
| Change what the bot “knows” about you | `src/workspace_templates/USER.md` |
| Change bot identity/persona | `src/workspace_templates/IDENTITY.md`, `SOUL.md` |
| Change operational rules (startup, memory, safety) | `src/workspace_templates/AGENTS.md`; COPY into image in Dockerfile |
| Add local/env notes for tools | `src/workspace_templates/TOOLS.md`; COPY into image |
| Change model or cost | Dockerfile config: `agents.defaults.model.primary` (and fallback) |
| Limit tool steps per turn | Dockerfile config: `agent.max_tool_iterations` |
| Add Telegram / channels | Dockerfile config: `channels.telegram` (and others) |
| Let bot run shell / git | Config: `autonomy.allowed_commands`, `allowed_paths`; git creds in Railway env |
| Add specialist “nano bots” | Config: `agents.list[]` with id + model + system_prompt; use **delegate** from orchestrator |
| See what’s happening | Railway logs; optional Observer; optional status messages to Telegram |
| Ship code | Bot uses `git_operations` (+ optional shell); push via GitHub token in env; CI/Railway deploy from repo |

---

## 8. File checklist (what to COPY into image if you want it)

Current Dockerfile COPYs:

- `src/workspace_templates/USER.md` → `/nullclaw-data/workspace/USER.md`
- `src/workspace_templates/IDENTITY.md` → `/nullclaw-data/workspace/IDENTITY.md`

Optional (add under the same stage, before `chown`):

```dockerfile
COPY src/workspace_templates/SOUL.md    /nullclaw-data/workspace/SOUL.md
COPY src/workspace_templates/AGENTS.md /nullclaw-data/workspace/AGENTS.md
COPY src/workspace_templates/TOOLS.md  /nullclaw-data/workspace/TOOLS.md
```

Then the bot will load SOUL (persona), AGENTS (rules), and TOOLS (your notes) from the workspace at runtime.

---

_Update this ROADMAP as you add agents, channels, or deployment steps so it stays your single source of truth for “how the team works.”_
