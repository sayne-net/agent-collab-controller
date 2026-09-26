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

### Phase Progression Ladder

The default project lifecycle follows a structured 5-phase ladder:
`pitch` $\rightarrow$ `discuss` $\rightarrow$ `implement` $\rightarrow$ `test` $\rightarrow$ `closed`

1. **Pitch**: Agents suggest additions, improvements, alternatives, and options to the objective without touching code. Human Lead chooses what graduates to discussion. Both seats stay `advise`. Switching the phase to pitch sets both role dropdowns to advise, and the kickoff hard stop still forbids tracked edits if a seat was left on implement.
2. **Discuss**: Agents debate trade-offs, answer architectural questions, and align on agreed decisions. Consensus lines auto-promote to Alignment.
3. **Implement**: Exactly one agent writes code and documents changes while the other reviews.
4. **Test**: Agents and Human Lead verify script, UI, and functionality, recording pass/fail evidence in scratchpads.
5. **Closed**: All sign-offs complete; Human Lead uses the **Close Project** button to audit git, commit allowlisted changes, push, and archive.

### Phase Sign-Off & Advancement

- Each phase uses the three sign-off checkboxes (`Human`, `AI 1`, `AI 2`). A scratchpad counts as signed off only when the latest top-level note says `Sign-off: [x]`. Older `[x]` lines in that pad do not carry into the next phase.
- When all 3 participants mark sign-off complete (`[x]`) while Flow Control is `🟢 GO`, the controller clears the checkboxes and auto-advances to the next phase on the ladder.
- Unchecking a box never moves backward. Auto-advance is blocked during `🟡 PAUSE` or `🔴 ALL STOP`.
- Intermediate advances do not commit or push git; final shipping remains safely on the **Close Project** button.
