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

Phases are status badges. They do not assign seat roles. **Auto Step** is off unless the operator turns it on. When it is on, three sign-offs advance the badge one step and leave the role dropdowns alone. The operator, or a workflow preset the operator selects, sets roles. Pitch still forces both seats to `advise`. At most one seat may be `implement`.

The phase combo is:

`ready` → `pitch` → `discuss` → `plan` → `implement` → `review` → `test` → `closing` → `debrief`

`debrief` returns to `ready` when that badge advances. `plan`, `review`, and `closing` are real badges, not aliases of the shorter pitch/discuss/implement/test list.

1. **Pitch**: Agents suggest options without touching code. Both seats are `advise`.
2. **Discuss**: Agents debate trade-offs. Consensus lines can promote to Alignment.
3. **Plan**: Architecture notes. Roles stay as the operator set them.
4. **Implement**: Entering implement defaults both seats to `review`; Human Lead assigns the implementer. Exactly one agent writes code. The other reviews, advises, or idles.
5. **Review** and **Test**: Verification notes. Roles are not rewritten when the badge changes.
6. **Closing** and **Debrief**: Human Lead uses **Close Project** to audit the **target** repo, confirm tracked files, and optionally push. Secrets and `.ai/` are refused. Push waits until refused paths are gone. Snapshots stay in that repo's `.ai/history/`.

### Phase Sign-Off & Advancement

- Each phase uses the three sign-off checkboxes (`Human`, `AI 1`, `AI 2`). A scratchpad counts as signed off only when the latest top-level note says `Sign-off: [x]`. Older `[x]` lines in that pad do not carry into the next phase.
- When all 3 participants mark sign-off complete (`[x]`) while Flow Control is `🟢 GO` and **Auto Step** is on, the controller clears the checkboxes, saves them unchecked, and auto-advances one phase badge without changing roles. Auto Step sits next to the three sign-off boxes and defaults to off. When it is off, the phase stays where it is. A new latest scratchpad note that says `Sign-off: [x]` checks that seat even when the role table is still `[ ]`. A note already present at the last auto-advance does not check it again. Loading the board does not auto-advance unless that new sign-off arrived.
- Unchecking a box never moves backward. Auto-advance is blocked during `🟡 PAUSE` or `🔴 ALL STOP`.
- Intermediate advances do not commit or push git; final shipping remains safely on the **Close Project** button.
