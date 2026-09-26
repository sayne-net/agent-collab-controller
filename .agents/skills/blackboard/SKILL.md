---
name: blackboard
description: Manage the dual-session blackboard (.ai/blackboard.md) for collaboration between human and coding agents (e.g., Cursor, Gemini Antigravity, Claude Code). Use to inspect live blackboard state, update notes, or understand turn coordination.
---

# Dual-Session Blackboard Skill

Use this skill when collaborating via the ephemeral blackboard (`.ai/blackboard.md`, template: `.ai/blackboard.example.md`).

## Golden Rules for Agents
1. **Mandatory file edit under your scratchpad heading**: Agents communicate via `.ai/blackboard.md`. You **must** use your file editing tool (targeted chunk/block replacement) to write and update your response directly in `.ai/blackboard.md` under your assigned scratchpad heading (e.g. `### Agent 1 Scratchpad` or `### Agent 2 Scratchpad`). Do not only reply in chat. Never modify or wipe the other agent's section. Never write under or overwrite `### Human (Lead)` (human-owned). You **may** set **your** row in the Agent Roles `Sign-off (Complete)` column to `[x]` when the session issue is resolved — not the Human's row.
2. **Canonical Board Only**: Target the live gitignored `.ai/blackboard.md` on the active working tree. **Never** write to `blackboard.example.md` (template), `.ai/history/*` (archives), or `.ai/saved/*` (snapshots). Verify GitHub Issue and Objective match the kickoff prompt before editing.
3. **Ephemeral tape**: Never commit `.ai/blackboard.md` to git. Durable truth belongs in GitHub issues and documentation.
4. **No shadow project boards**: Do **not** create extraneous tracking files (`TASKS.md`, `ARCHITECTURE.md`, `AI_COLLAB.md`).

## Standard Dual-Session Roles

| Role | Meaning |
|------|---------|
| `implement` | Lands the change (code, tests, or documentation). Only ONE agent may hold implement at any time. |
| `review` | Reads the other agent’s notes/commits, tests, comments, and verifies. Does not race the same files. |
| `advise` | Read-only analysis. **FORBIDDEN:** tracked files, git push. Allowed and REQUIRED write: `.ai/blackboard.md` under your scratchpad heading only. 🟢 GO does **not** promote you to implement. |
| `inventory` | Codebase/tool reads, status check, git log. No code writes. |
| `plan` | Propose approach and risks in your scratchpad. Do not edit tracked files unless the Human Lead requests it. |
| `idle` | Read the board, do not act. Stops two agents from implementing at once. |

*Common pairs: `implement` + `review`, `advise` + `advise` (discussion mode), `inventory` + `review`, `plan` + `idle`, `implement` + `idle`.*

**🟢 GO means continue in the assigned role. It is not a promotion to `implement`.**

When the linked task or GitHub issue is **resolved**: tick **your** Agent Roles `Sign-off (Complete)` cell `[x]` **and** append `Sign-off: [x]` in your scratchpad.

## Operator Launchers
- **Desktop GUI**: Double-click `scripts\blackboard-ui.bat` or run `pwsh .\scripts\blackboard-ui.ps1`.
- **Install Desktop Icon**: Run `pwsh .\scripts\install-desktop-shortcut.ps1`.
- **CLI Update**: Run `pwsh .\scripts\prompt-collab.ps1 -Prompt "<prompt>" -Issue <N>`.
