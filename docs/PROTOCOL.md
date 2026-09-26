# Dual-Session Collaboration Protocol

A lightweight, human-in-the-loop coordination protocol for pair-programming with two autonomous AI agents on a single working tree.

---

## The Core Concept

Most multi-agent frameworks run autonomous loops that quickly diverge, race each other, or lose alignment with the developer. 

**Agent Collab Controller** solves this with three principles:
1. **Human Steering**: The human developer remains the Lead (`Human (Lead)`), defining objectives, alignment decisions, and approving phase transitions.
2. **Mutual Exclusion (The Implement Lock)**: Only **one** agent may hold the `implement` role at any time. The other agent is placed in `review`, `advise`, or `idle`. This completely eliminates concurrent file write conflicts.
3. **Ephemeral Scratchpad vs. Durable Memory**: Fast, scratch-pad coordination happens in a local, gitignored markdown file (`.ai/blackboard.md`). Permanent decisions and task tracking belong in GitHub Issues, commits, and project documentation.

---

## Flow Control States

| Flow State | Meaning |
|------------|---------|
| `🟢 GO` | Proceed with work in the currently assigned role. |
| `🟡 PAUSE` | Wait for human clarification or decision. Agents must not execute modifying actions. |
| `🔴 ALL STOP` | Immediate halt. Both agents must idle and cease work. |

> [!IMPORTANT]
> `🟢 GO` means continue in your **assigned** role. It is **never** a promotion to `implement`.

---

## Role Matrix

| Role | Permitted Actions | Forbidden Actions |
|------|-------------------|-------------------|
| `implement` | Edit repository files, run local commands, execute tests, draft documentation. | Dual-implementing when another agent is already implementing. |
| `review` | Read-only inspection, run verification tests, audit diffs. Append review notes to scratchpad. | Editing the implementer's active files or committing unreviewed code. |
| `advise` | Analyze questions, propose approaches, recommend decisions in scratchpad. | Editing tracked project files, committing to git, making external state changes. |
| `plan` | Outline architecture, risks, and milestones in scratchpad. | Implementing code before plan approval. |
| `inventory` | Read repository status, inspect environment, check logs. | Mutating project files. |
| `idle` | Passive state. Do not run tools. | Any file or system mutation. |

---

## The Blackboard Lifecycle

1. **Kickoff**: Human Lead launches the WPF Controller (`scripts\blackboard-ui.bat`), enters the objective, selects roles (e.g. Agent 1: `implement`, Agent 2: `review`), and clicks **Copy Kickoff** (or **Send**).
2. **Execution**:
   - The implementing agent writes code, updates progress in its scratchpad, and commits changes locally.
   - The reviewing agent inspects the working tree diff (via the controller's built-in Review Diff viewer) and appends feedback.
3. **Verification & Sign-off**:
   - Once all tests pass and requirements are verified, each agent marks their sign-off cell `[x]`.
   - When all 3 participants (Human + Agent 1 + Agent 2) have signed off, the **Close Project** button activates.
4. **Close Project**:
   - Automatically archives the current blackboard session into `.ai/history/blackboard-<timestamp>.md`.
   - Optionally closes the linked GitHub issue via `gh CLI`.
   - Cleans the active blackboard and resets roles to `idle`.
