# Agent Collab Controller 🎮

> **Human-in-the-Loop Dual-Agent Workflow & Desktop Controller**  
> Pair-program with two AI agents (Cursor, Gemini Antigravity, Claude Code, etc.) on a single working tree without collisions, divergence, or prompt chaos.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%20(PowerShell%20%2F%20WPF)-informational)]()
[![Built With](https://img.shields.io/badge/Vibe%20Coded-100%25%20AI%20Pair--Programmed-8A2BE2)](README.md)

> ⚡ **100% Vibe Coded**: This entire project, protocol, and desktop controller are **100% vibe coded** through human-in-the-loop pair programming using **Cursor** & **Gemini (Antigravity)**.

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
   - Set **AI 1** (e.g. Cursor) to `implement`.
   - Set **AI 2** (e.g. Gemini Antigravity) to `review`.
3. **Copy & Paste Kickoff**: Click **📋 Copy AI 1** (or **🚀 Send AI 1**) to paste the generated prompt directly into your agent's chat window.
4. **Watch & Steer**:
   - The implementing agent writes code, updates progress in its scratchpad, and commits changes.
   - The reviewing agent tests and audits the diff.
   - You can review working tree changes instantly via the **🔍 Review Diff** button.
5. **Sign-off & Close**:
   - When all tasks and verification steps are complete, all 3 participants sign off (`[x]`).
   - Click **🏁 Close Project** to archive the session tape to `.ai/history/` and reset the board.

> [!TIP]
> **Click-to-Copy Board Path**: The top bar of the controller displays the active blackboard path (`📋 Board: ...`). Click it at any time to instantly copy the full path to your clipboard.

---

## Setting Up Your Agents

The controller is **zero-overhead and zero-daemon**: agents do not need background services, socket listeners, or proprietary extensions. They coordinate entirely through your filesystem using their native file read and write tools.

### Option A: Automatic Grounding via Project Rules & Skills (Recommended)
Place the included agent instruction files in your repository so your agents automatically follow the protocol:

1. **For Cursor**:
   - Copy `.cursor/rules/agent-collab.mdc` to `.cursor/rules/` in your project. Cursor will automatically adhere to the dual-session protocol whenever `.ai/blackboard.md` exists.
2. **For Antigravity, Claude Code, Gemini CLI, or custom agents**:
   - Copy `.agents/skills/blackboard/SKILL.md` into your agent's skill directory (or include its contents in your agent's instructions).
   - Alternatively, add this single directive to your agent instructions:
     > *"Collaborate via `.ai/blackboard.md`. Read your active role and objective. Only update your assigned scratchpad section using targeted replacements. Never race on tracked files."*

### Option B: Zero Setup (Self-Contained Kickoff Prompts)
Even without pre-configuring agent rules or skills, the controller works out of the box:
1. In the controller UI, assign roles and click **📋 Copy AI 1** or **📋 Copy AI 2** (or use **🚀 Send AI 1 / 2** to auto-focus and paste).
2. The generated kickoff prompt injects all required protocol context:
   - Specific identity (`AI 1` or `AI 2`)
   - Assigned role permissions and hard-stop safety constraints
   - Canonical absolute path to `.ai/blackboard.md`
   - Strict instructions to only edit within the agent's assigned scratchpad section

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

## Contributing

Contributions, feedback, and issue reports are welcome!

1. **Issues**: Check existing issues or open a new one using the provided bug report or feature request templates.
2. **Conventional Commits**: Format commit messages according to [Conventional Commits](https://www.conventionalcommits.org/) (e.g. `feat(ui): ...`, `fix(scripts): ...`, `docs: ...`).
3. **Local Testing & Syntax Validation**: Before submitting a PR, verify all PowerShell scripts pass syntax checks:
   ```powershell
   Get-ChildItem -Path scripts/*.ps1 -Recurse | ForEach-Object {
       $errs = $null
       $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
       if ($errs) { throw "$($_.Name) has syntax errors" }
   }
   ```
4. **Pull Requests**: Open a pull request against `main`. Ensure all CI syntax checks pass and fill out the PR checklist.

---

## License

This project is licensed under the [MIT License](LICENSE).

