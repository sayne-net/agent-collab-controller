# AI Collab Controller 🎮

> **Two Models Deliberate, You Decide (AI Collab Coding)**<br/>
> Pair-program with two AI agents (tested with Cursor & Gemini Antigravity) on a single working tree with structured multi-agent deliberation, mutual exclusion safety, and human-in-the-loop steering.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%20(PowerShell%20%2F%20WPF)-informational)]()
[![Built With](https://img.shields.io/badge/Vibe%20Coded-100%25%20AI%20Pair--Programmed-8A2BE2)](README.md)

> ⚡ **100% Vibe Coded**: This entire project, protocol, and desktop controller are **100% vibe coded** through human-in-the-loop pair programming using **Cursor** & **Gemini (Antigravity)**.
>
> 🧪 **Testing Notice**: Currently, this workflow and controller have **only been tested with Cursor and Gemini (Antigravity)**. While other coding agents may work with the blackboard protocol, they have not yet been validated.

---

![AI Collab Controller - Active Dual-Session Cockpit](docs/images/controller-main-window.png)
*Note: Screenshots shown are UI captures demonstrating the dual-session cockpit.*

---

## Why AI Collab Controller?

Running multiple autonomous AI coding agents in parallel usually leads to one of two failure modes:
1. **The Merge Conflict Nightmare**: Two agents edit the same files concurrently, corrupting state and breaking the working tree.
2. **The Runaway Loop**: Fully autonomous loops diverge from user intent, burning tokens on hallucinations or incorrect architectures.

While git worktrees can isolate file modifications across branches, **worktrees alone do not provide deliberation**. 

**AI Collab Controller** introduces structured, human-guided dual-session collaboration:
- 👑 **Human-in-the-Loop Steering**: You are `Human (Lead)`. You set current objectives, capture alignment decisions, and arbitrate between turns.
- 💬 **Structured Multi-Agent Deliberation**: Agents pitch, discuss trade-offs, and draft plans together before writing code (`pitch → discuss → plan → implement → review → test → debrief`).
- 🔒 **Mechanical Concurrency Safety**: Strict mutual exclusion—**only ONE agent may hold `implement`** at any moment. Prompt dispatchers mechanically refuse dual-implement prompt generation.
- ⚡ **Ephemeral Scratchpad vs. Durable Memory**: High-frequency turn coordination happens in a local, gitignored tape (`.ai/blackboard.md`). Permanent decisions live in GitHub Issues, commits, and your codebase docs.
- 🖥️ **Native Desktop Cockpit**: A sleek, dark-themed WPF desktop app with:
  - 1-click tailored kickoff prompt copying & direct window focus paste.
  - Built-in Git Review Diff viewer (including untracked files).
  - GitHub Issue tracking and automatic issue closing via `gh` CLI.
  - Automatic session snapshotting to `.ai/history/`.
  - 3-way sign-off gating before closing a project.

---

## Architecture: Protocol & Cockpit

The project is structured in two decoupled layers:

1. **The Protocol (`docs/PROTOCOL.md`)**: A platform-neutral, zero-daemon coordination specification based on standard markdown (`.ai/blackboard.md`), phase ladders, role matrices, and sign-off contracts. Portable across any IDE or agent system (Cursor, Antigravity, Claude Code, Codex, CLI).
2. **The Desktop Controller (`scripts/blackboard-ui.ps1`)**: A high-productivity reference cockpit built in PowerShell/WPF for Windows that automates prompt templating, window focusing, git diff inspection, test validation, and GitHub synchronization.

For complete specification details, see [docs/PROTOCOL.md](docs/PROTOCOL.md).

---

## Quickstart (5 Minutes)

### 1. Install once
Clone this repository once, for example to `$HOME\agent-collab-controller`. Do not copy `scripts/` into each project. The controller points at an external working tree.

Each target repo should ignore the live board:

```gitignore
.ai/blackboard.md
```

### 2. Launch against a target repo
```powershell
pwsh $HOME\agent-collab-controller\scripts\blackboard-ui.ps1 -TargetRepo C:\path\to\your-project
```

The last opened repo is saved in `$HOME\.blackboard\config.json`. The next launch without `-TargetRepo` restores that repo when it is not the controller checkout.

Optional desktop shortcut for a fixed target:

```powershell
pwsh $HOME\agent-collab-controller\scripts\install-desktop-shortcut.ps1 -TargetRepo C:\path\to\your-project
```

### 3. Start a Session
1. **Enter Objective**: Describe what you want accomplished in the **Current Objective & Prompt** box.
2. **Assign Roles**:
   - Set **AI 1** (e.g. Cursor) to `implement`.
   - Set **AI 2** (e.g. Gemini Antigravity) to `review`.
3. **Copy the kickoff**: Select Seat 1, Seat 2, or Both and click **Copy Prompt**. Paste that clipboard text into the agent chat. (*Send (best-effort)* can automatically focus and paste into supported IDEs).
4. **Watch & Steer**:
   - The implementing agent writes code, updates progress in its scratchpad, and commits changes.
   - The reviewing agent tests and audits the diff.
   - Use **⚖️ Compare Notes** on the Re-prompt row at any time to dispatch a comparison directive to both agents, synthesizing consensus into your scratchpads without clearing Objective or Alignment.
   - Review working tree changes instantly via the **🔍 Review Diff** button:

   ![Built-in Git Review Diff Viewer](docs/images/controller-diff-viewer.png)
   *Note: Demonstration of the git diff and untracked file auditor.*

5. **Sign-off, Ship & Debrief**:
   - When implementation and test verification steps are complete, all 3 participants sign off (`[x]`) to reach `closing`.
   - Accepting the prompt to complete the close cycle ships allowlisted code to git and advances directly into `debrief` for post-run evaluation.
   - Once debrief completes (or upon manual Close Project click), the controller archives the session tape to `.ai/history/`, auto-closes associated GitHub issues, and resets the board to `ready`:

   ![3-Way Sign-off and Close Project](docs/images/controller-signoff-close.png)
   *Note: Demonstration of 3-way sign-off gating and session close.*

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
1. In the controller UI, assign roles, select your target in the Kickoff dropdown, and click **Copy Prompt**. Paste into the agent chat.
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

---

## Operator Reference & FAQ

<details>
<summary><strong>Expand Controller UI & Feature Reference</strong></summary>

- **Auto Step**: Checkbox located on the header row. Enabling Auto Step locks the phase dropdown and advances phases automatically as required sign-offs complete.
- **Stats Window**: The header Stats button displays session statistics (prompts copied, turns taken, completions) persisted locally at `$HOME/.blackboard/stats.json`.
- **Implementation Scope**: The scope dropdown between seats specifies `Code` or `Submit GitHub Issues`. Selecting `Submit GitHub Issues` instructs agents to create issues without editing tracked repository files.
- **Dual-Implement Safety**: If both seats are set to `implement`, the controller triggers a safety warning and blocks prompt copying/sending until roles are corrected.
- **Task Presets**: Presets (`Full`, `Hotfix`, `Docs`, `RFC`) select standard enabled phase badges.
- **Phase Badges**: Supported lifecycle ladder: `ready` → `pitch` → `discuss` → `plan` → `implement` → `review` → `test` → `closing` → `debrief`.
- **Sign-off Latch Integrity**: An unconfirmed latest scratchpad turn leaves the sign-off box open and rolls test/closing phases back to `implement` until verified.
- **Close Project**: Validates tracked dirty files, rejects secrets and `.ai/` files, and blocks push if non-allowlisted dirty paths remain.

</details>

---

## System Requirements & Testing
- **OS**: Windows 10/11
- **PowerShell**: PowerShell 7 (`pwsh`) recommended, or Windows PowerShell 5.1
- **Automated Headless Testing**:
  ```powershell
  pwsh ./scripts/blackboard-ui-test.ps1
  ```
- **GitHub CLI** *(Optional)*: `gh` for fetching/creating/closing GitHub issues directly from the controller UI

---

## Contributing

1. **Issues**: Check existing issues or open a new one using the provided templates.
2. **Conventional Commits**: Format commit messages according to [Conventional Commits](https://www.conventionalcommits.org/) (e.g. `feat(controller): ...`, `test(ci): ...`, `docs: ...`).
3. **Syntax & Headless Test Validation**: Before submitting a PR, verify all PowerShell scripts pass syntax checks and the headless UI test suite:
   ```powershell
   pwsh ./scripts/blackboard-ui-test.ps1
   ```

---

## License

This project is licensed under the [MIT License](LICENSE).
