# Agent Collab Controller 🎮

> **Human-in-the-Loop Dual-Agent Workflow & Desktop Controller**  
> Pair-program with two AI agents (Cursor, Gemini Antigravity, Claude Code, etc.) on a single working tree without collisions, divergence, or prompt chaos.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%20(PowerShell%20%2F%20WPF)-informational)]()

---

## Why Agent Collab Controller?

Running multiple autonomous AI coding agents in parallel usually leads to one of two failure modes:
1. **The Merge Conflict Nightmare**: Two agents edit the same files concurrently, corrupting state and breaking the working tree.
2. **The Runaway Loop**: Fully autonomous loops diverge from user intent, burning tokens on hallucinations or incorrect architectures.

**Agent Collab Controller** introduces a structured, human-guided dual-session paradigm:
- 👑 **Human-in-the-Loop Steering**: You are `Human (Lead)`. You set current objectives, capture alignment decisions, and steer direction between turns.
- 🔒 **Concurrency Safety**: Strict mutual exclusion—**only ONE agent holds `implement`** at any moment. The other agent reviews, advises, or idles.
- ⚡ **Ephemeral Scratchpad vs. Durable Memory**: High-frequency coordination happens in a local, gitignored tape (`.ai/blackboard.md`). Permanent decisions live in GitHub Issues, commits, and your codebase docs.
- 🖥️ **Native Desktop Controller**: A sleek, dark-themed WPF desktop app with:
  - 1-click tailored kickoff prompt copying & direct window focus paste.
  - Built-in Git Review Diff viewer (including untracked files).
  - GitHub Issue tracking and automatic issue closing via `gh` CLI.
  - Automatic session snapshotting to `.ai/history/`.
  - 3-way sign-off gating before closing a project.

---

## Quickstart (5 Minutes)

### 1. Drop into Your Repository
Copy `scripts/`, `.ai/`, and optionally `.agents/` or `.cursor/` into your existing project repository:
```text
your-project/
├── .ai/
│   └── blackboard.example.md     # Template board
├── scripts/
│   ├── blackboard-ui.bat         # Double-click launcher
│   ├── blackboard-ui.ps1         # Native WPF controller
│   ├── install-desktop-shortcut.ps1
│   └── prompt-collab.ps1         # CLI helper
└── ...
```

Ensure your `.gitignore` contains:
```gitignore
.ai/blackboard.md
```

### 2. Launch the Controller
- Double-click `scripts\blackboard-ui.bat`, or run:
  ```powershell
  pwsh .\scripts\blackboard-ui.ps1
  ```
- *(Optional)* Create a desktop shortcut by running:
  ```powershell
  pwsh .\scripts\install-desktop-shortcut.ps1
  ```

### 3. Start a Session
1. **Enter Objective**: Describe what you want accomplished in the **Current Objective & Prompt** box.
2. **Assign Roles**:
   - Set **Agent 1** (e.g. Cursor) to `implement`.
   - Set **Agent 2** (e.g. Gemini Antigravity) to `review`.
3. **Copy & Paste Kickoff**: Click **📋 Copy Agent 1** (or **🚀 Send Agent 1**) to paste the generated prompt directly into your agent's chat window.
4. **Watch & Steer**:
   - The implementing agent writes code, updates progress in its scratchpad, and commits changes.
   - The reviewing agent tests and audits the diff.
   - You can review working tree changes instantly via the **🔍 Review Diff** button.
5. **Sign-off & Close**:
   - When all tasks and verification steps are complete, all 3 participants sign off (`[x]`).
   - Click **🏁 Close Project** to archive the session tape to `.ai/history/` and reset the board.

---

## Role Matrix

| Role | Meaning | Permissions |
|------|---------|-------------|
| `implement` | Active builder | Modifies tracked repo files, writes tests, implements features. Max 1 agent. |
| `review` | Auditor & verifier | Inspects diffs, runs test suites, provides verification feedback in scratchpad. |
| `advise` | Strategic analyst | Proposes architectures, reviews trade-offs. Forbidden from modifying files. |
| `inventory`| Inspector | Reads environment status, tooling, and repository layout. |
| `plan` | Architect | Outlines milestones and approaches before implementation approval. |
| `idle` | Passive standby | Silent mode. Prevents race conditions. |

For detailed protocol rules, see [docs/PROTOCOL.md](docs/PROTOCOL.md).

---

## System Requirements
- **OS**: Windows 10/11
- **PowerShell**: PowerShell 7 (`pwsh`) recommended, or Windows PowerShell 5.1
- **GitHub CLI** *(Optional)*: `gh` for fetching/creating/closing GitHub issues directly from the controller UI

---

## License

This project is licensed under the [MIT License](LICENSE).
