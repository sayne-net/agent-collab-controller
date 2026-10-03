# Dual-Session Collaboration Protocol

A lightweight, human-in-the-loop coordination protocol for pair-programming with two autonomous AI agents on a single working tree.

---

## The Core Concept

Most multi-agent frameworks run autonomous loops that quickly diverge, race each other, or lose alignment with the developer. 

**AI Collab Controller** solves this with three principles:
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

## Where the controller runs

Install the controller once (for example `$HOME/agent-collab-controller`). Launch it with `-TargetRepo` set to the project working tree. The last opened repo is stored in `$HOME/.blackboard/config.json`. Close Project git commands use that target. Updating the controller app uses the controller checkout. An in-repo copy of `blackboard-ui.ps1` that only forwards to this install stays a frozen shim.

## The Blackboard Lifecycle

### Phase Progression Ladder

Phases are status badges. They do not assign seat roles. **Auto Step** mode defaults to `Off`. When active, gated sign-offs advance the badge one step and leave the role dropdowns alone. The operator, or a workflow preset the operator selects, sets roles. Pitch still forces both seats to `advise`. At most one seat may be `implement`.

The phase combo is:

`ready` → `pitch` → `discuss` → `plan` → `implement` → `review` → `test` → `debrief`

`debrief` returns to `ready` when that badge advances or project close is confirmed. `plan`, `review`, and `debrief` are real badges, not aliases.

1. **Pitch**: Agents suggest options without touching code. Both seats are `advise`.
2. **Discuss**: Agents debate trade-offs. Consensus lines can promote to Alignment before exiting discuss.
3. **Plan**: Architecture notes. Roles stay as the operator set them.
4. **Implement**: Entering implement defaults both seats to `review`; Human Lead assigns the implementer. Exactly one agent writes code. The other reviews, advises, or idles.
5. **Review** and **Test**: Verification notes. Roles are not rewritten when the badge changes. In test phase, implementer sign-off is gated on `pwsh .\scripts\blackboard-ui-test.ps1` printing `PASS`.
6. **Debrief**: Post-run review with unbounded structured suggestions (Process, Work, Rules). Objective prompt text is strictly preserved until answers are written. Human Lead uses **Close Project** (after debrief completion) to audit the **target** repo, confirm tracked files, and optionally push. Secrets and `.ai/` are refused. Push waits until refused paths are gone. Snapshots stay in that repo's `.ai/history/`.

### Auto Step Modes & Sign-Off Advancement

Auto Step supports four modes via the header dropdown (`cbAutoStepMode`):
- `Off`: Auto-advance is disabled. Phase selection remains fully manual.
- `L1 (Lead)`: Advances the phase badge when Human (Lead) sign-off is checked.
- `L2 (Lead + Seat 1)`: Advances when Human Lead and Seat 1 (if active/gated) sign-offs are checked.
- `L3 (Lead + Both)`: Advances when Human Lead and both active/gated seats are checked.

Each phase uses the sign-off checkboxes (`Human`, `AI 1`, `AI 2`). A scratchpad counts as signed off only when the latest top-level note says `Sign-off: [x]`. Older `[x]` lines in that pad do not carry into the next phase.

When required sign-offs for the active Auto Step mode are complete while Flow Control is `🟢 GO`, the controller clears the checkboxes, saves them unchecked, and auto-advances one phase badge without changing roles.

Unchecking a box never moves backward. Auto-advance is blocked during `🟡 PAUSE` or `🔴 ALL STOP`.
Intermediate advances do not commit or push git; final shipping remains safely on the **Close Project** button.

### Kickoff Auto-Switch

The Kickoff panel includes an **⇄ Auto-Switch** checkbox (`chkAutoSwitchSeat`, default off). When enabled, successfully copying or sending a prompt to `Seat 1` automatically flips the target dropdown to `Seat 2`, and vice versa. When the target is set to `Both`, Auto-Switch remains inactive.

### Pushback & Chat Brevity

1. **Constructive Pushback**: Agents are permitted to push back against the Lead when technical correctness or project safety is at stake. Put the full argument and justification into your scratchpad note first, then output at most one concise line in chat summarizing the pushback.
2. **Chat Brevity**: Chat responses must remain concise results only (status, key findings, or one-line pushback). All detailed proposals, tables, code snippets, and analysis belong in the blackboard scratchpad.

### Automated UI & Workflow Verification

Run the headless verification suite:
```powershell
pwsh .\scripts\blackboard-ui-test.ps1
```
This tests Alignment item code extraction, prompt roundtrips, F5 / Refresh disk reloading, DeepSeek profile integration, default phase role assignments, gate persistence, Implementation Scope roundtrip, Auto Step modes L1–L3, Kickoff Auto-Switch, and reconcile auto-transitions. Implementer sign-off is gated on this command printing `PASS`.
