# AI Collab Controller 🎮

> **Human-in-the-Loop Multi-Agent Workflow & Desktop Controller (AI Collab Coding)**<br/>
> Pair-program with two AI agents (tested with Cursor & Gemini Antigravity) on a single working tree without collisions, divergence, or prompt chaos.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%20(PowerShell%20%2F%20WPF)-informational)]()
[![Built With](https://img.shields.io/badge/Vibe%20Coded-100%25%20AI%20Pair--Programmed-8A2BE2)](README.md)

> ⚡ **100% Vibe Coded**: This entire project, protocol, and desktop controller are **100% vibe coded** through human-in-the-loop pair programming using **Cursor** & **Gemini (Antigravity)**.
>
> 🧪 **Testing Notice**: Currently, this workflow and controller have **only been tested with Cursor and Gemini (Antigravity)**. While other coding agents may work with the blackboard protocol, they have not yet been validated.

---

![AI Collab Controller - Active Dual-Session Cockpit](docs/images/controller-main-window.png)
*Note: Screenshots shown are simulated UI captures for demonstration purposes.*

---

## Why AI Collab Controller?

Running multiple autonomous AI coding agents in parallel usually leads to one of two failure modes:
1. **The Merge Conflict Nightmare**: Two agents edit the same files concurrently, corrupting state and breaking the working tree.
2. **The Runaway Loop**: Fully autonomous loops diverge from user intent, burning tokens on hallucinations or incorrect architectures.

**AI Collab Controller** introduces a structured, human-guided dual-session paradigm:
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

## Current Build & Release: v1.2.39 — Defender

- **Latest Release**: `v1.2.39` is both the current build and the latest published GitHub release ([**v1.2.39**](https://github.com/sayne-net/agent-collab-controller/releases/tag/v1.2.39)).
- **Full Lifecycle Ladder**: Auto-stepping guides sessions across `pitch` $\rightarrow$ `discuss` $\rightarrow$ `implement` $\rightarrow$ `test` $\rightarrow$ `closing` $\rightarrow$ `debrief` $\rightarrow$ `ready`.
- **Debrief Preserved on Close Cycle**: Accepting 'Yes' to complete the close cycle during `closing` auto-advance ships allowlisted changes to git and proceeds directly into `debrief`. Session archiving and board reset to `ready` await completion of the debrief phase.
- **Sign-off Latch Integrity**: An unsigned newest scratchpad turn leaves that seat's sign-off box open and rolls test/closing phases back to `implement`. Changing phases clears all three sign-off checkboxes.
- **Safe Shipping Allowlist**: Close Project audits tracked changes and allowlists root `CHANGELOG.md`, `README.md`, controller scripts, and agent instruction rules while blocking `.env`, keys, or credentials.
- **Selection-Aware Promote to Prompt**: Highlighting notes in Human Notes and clicking **Promote** cleanly strips markdown bullet prefixes and appends the selection into Objective & Prompt without overwriting.
- **Codex Safety Guard**: Codex seat profiles automatically clear and disable the New Chat checkbox with prominent manual guidance alerts to protect operator chats.
- **Arcade Codenames**: Releases feature classic 80's & 90's arcade game codenames.
- 📜 **[View Full Release History & Changelog](CHANGELOG.md)**

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
3. **Copy & Paste Kickoff**: Select your target in the Kickoff dropdown (Seat 1, Seat 2, or Both) and click **📋 Copy Prompt** (or **🚀 Send Prompt**) to paste the generated prompt directly into your agent's chat window.
4. **Watch & Steer**:
   - The implementing agent writes code, updates progress in its scratchpad, and commits changes.
   - The reviewing agent tests and audits the diff.
   - Use **⚖️ Compare Notes** on the Re-prompt row at any time to dispatch a comparison directive to both agents, synthesizing consensus into your scratchpads without clearing Objective or Alignment.
   - Review working tree changes instantly via the **🔍 Review Diff** button:

   ![Built-in Git Review Diff Viewer](docs/images/controller-diff-viewer.png)
   *Note: Simulated screenshot demonstrating git diff and untracked file auditing.*

5. **Sign-off, Ship & Debrief**:
   - When implementation and test verification steps are complete, all 3 participants sign off (`[x]`) to reach `closing`.
   - Accepting the prompt to complete the close cycle ships allowlisted code to git and advances directly into `debrief` for post-run evaluation.
   - Once debrief completes (or upon manual Close Project click), the controller archives the session tape to `.ai/history/`, auto-closes associated GitHub issues, and resets the board to `ready`:

   ![3-Way Sign-off and Close Project](docs/images/controller-signoff-close.png)
   *Note: Simulated screenshot demonstrating 3-way sign-off gating and session close.*

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
1. In the controller UI, assign roles, select your target in the Kickoff dropdown, and click **📋 Copy Prompt** (or **🚀 Send Prompt** to auto-focus and paste).
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

