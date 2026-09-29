# Changelog

All notable changes to **AI Collab Controller** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases adopt 80's and 90's arcade game names as optional release codenames.

## [v1.3.0] — Joust

### Changed
- **Target repo**: `blackboard-ui.ps1 -TargetRepo <path>` opens that working tree. The last repo is stored in `$HOME/.blackboard/config.json`. Close Project asks before committing when the git root is the controller itself. Controller self-update still uses the controller checkout.
- **Auto Step off**: The checkbox defaults to off. Advancing a phase badge does not rewrite seat roles.
- **Close Project**: Tracked dirty files are confirmed from `git status`. Secrets and `.ai/` stay refused. Optional `.ai/close-allow.json` (`paths` wildcards) can narrow the set. Push is skipped while a refused path is still dirty.
- **Handoff**: Copy Prompt is the primary control. Send and re-prompt buttons are labeled best-effort.
- **Docs**: README quickstart is the single global install. PROTOCOL.md matches the phase combo and says phases do not assign roles.

## [v1.2.39] — Defender

### Fixed
- **Close Project allowlist**: Root `CHANGELOG.md` and `README.md` are now allowlisted in `Test-CloseProjectAllowedPath`. The stale `docs/CHANGELOG.md` entry is gone.

## [v1.2.38] — Frogger

### Fixed
- **Sign-off latch**: An unsigned newest scratchpad turn no longer restores that seat’s checkbox from a stale `[x]` in the role table. A phase change clears all three sign-off boxes and writes them open.

## [v1.2.37] — Centipede

### Fixed
- **Debrief preserved on Close Cycle**: Accepting 'Yes' to complete the close cycle during `closing` auto-advance now runs `Invoke-CloseProjectGitShip` to ship allowlisted code, and advances directly into `debrief` instead of calling `Invoke-CloseProjectWorkflow` (which previously skipped debrief and reset the board). Project archiving, issue closing, and resetting the board to `ready` are preserved until `debrief` completes (or via manual Close Project click).

## [v1.2.36] — Galaga

### Added
- **Promote to Prompt selection & append**: `btnPromoteNotes` now detects highlighted selection in Human Notes, strips markdown bullet prefixes, and appends to the Objective & Prompt box via `Join-TextWithSeparator` instead of overwriting it.
- **Post-deployment lifecycle (`closing` -> `debrief` -> `ready`)**: Completed `closing` sign-offs advance directly to `debrief` (conversational `advise` seats) for post-run review. When Human Lead and AI sign-offs complete in `debrief`, `New Chat` is automatically armed (unless targeting Codex) and the workflow auto-advances to `ready`.
- **Default startup state (`ready`)**: Replaces `closed` with `ready` as the unconfigured / idle default start state for the controller and after session archiving.
- **Codex New Chat UI disabling**: When the kickoff prompt targets Codex (Seat 1 is Codex, Seat 2 is Codex, or Both includes Codex), the New Chat checkbox is automatically cleared and disabled (`IsEnabled = $false`).
- **High-visibility Codex alert**: When New Chat is disabled for Codex, a prominent bold, larger-font warning flashes in bright color in `txtSafetyWarning` and `txtStatus`, instructing the operator to manually open a new chat in the Codex app.
- **Prompt buttons lockout when script is newer**: When `scripts/blackboard-ui.ps1` is newer on disk, prompt dispatch buttons (`btnSendKickoffPrompt`, `btnCopyKickoffPrompt`, `btnRepromptCursor`, `btnRepromptGemini`, `btnRepromptBoth`, `btnCompareNotes`) are locked in red (`#F38BA8` with dark bold text, `🔒 ... (Locked)` label, and click guard) until the controller is relaunched.
- **Relaunch button slow-flash**: When the controller script on disk is newer, the Relaunch button slow-flashes between soft warning colors displaying `⏭️ Relaunch is needed`.
- **Relaunch lock during active AI updates**: The Relaunch button is locked and disabled (`🔒 Relaunch (AI Updating Code)`) while an AI is actively writing code to prevent premature restarts during file writes.
- **Unsigned closing rollback**: With Auto Step on during `closing`, a new AI scratchpad turn without `Sign-off: [x]` returns the phase to `implement`, matching the test phase rollback.
- **Close Project gating on sign-offs**: Prompt user to Close Project and run the git commit/push audit upon completing all 3 sign-offs in `closing` (advancing to `debrief` if declined) and in `debrief` (arming New Chat and moving to `ready` if declined). Preserves `$script:ClosingSignoffsCompleted` flag so manual Close Project button in `debrief` or `ready` still enables git commit and push.

### Fixed
- **Test auto-step precedence & turn regex**: Auto-advance to `closing` takes precedence over unsigned rollback when all 3 sign-offs are present. Fixed `Get-LatestTurnText` regex to match top-level turns and avoid erroneously latching onto child bullets.

### Changed
- **Removed automatic relaunch timer**: Controller never relaunches automatically; restarts are operator-driven.
- **Build vs. release distinction**: README clearly identifies `v1.2.36` as the current development build while preserving `v1.2.25` as the latest official GitHub release.

## [v1.2.35]

### Added
- **No empty separators**: Objective and Alignment boxes drop trailing `---` dividers. A `---` is inserted only when non-empty text is appended, making no-op updates cleanly idempotent.
- **Auto relaunch**: When `scripts/blackboard-ui.ps1` stays newer on disk through an 8-second settle and the form is clean, the open window automatically relaunches itself.
- **Unsigned test rollback**: With Auto Step on during `test`, a new AI scratchpad turn without `Sign-off: [x]` automatically returns the phase to `implement` and unchecks sign-off boxes.

## [v1.2.34]

### Added
- **Kickoff dry run**: A `Dry run` checkbox logs the selected target and New Chat arm state to the status bar without copying to the clipboard or dispatching prompts to agents (Refs #3).

## [v1.2.33]

### Fixed
- **Codex New Chat tooltip**: Hover text matches the manual fail-safe behavior. Codex New Chat copies the kickoff and prompts the operator to open and verify the chat manually before pasting.

## [v1.2.32]

### Fixed
- **Codex New Chat fail-safe**: Prevents sending unverified shortcuts into ChatGPT desktop app. Leaves prompt copied, keeps the one-shot armed, and directs the operator to verify chat creation manually.

## [v1.2.31]

### Added
- **Deleted PNG diff support**: Removed `.png` files now display the last image in Review Diff (committed deletions use upstream blob; working-tree deletions use HEAD blob).

## [v1.2.30]

### Added
- **Committed PNG diff in Review Diff**: Review Diff embeds images from `origin/..HEAD` as well as the working tree. Changed PNGs display upstream vs HEAD images side-by-side.

## [v1.2.29]

### Added
- **Codex seat profile**: Added `Codex` seat client option targeting the `ChatGPT` desktop process.

## [v1.2.28]

### Added
- **Auto-step roles**: Advancing a phase automatically applies that phase's role pair (pitch/discuss: both advise; plan: plan + idle; implement: review + implement; review/test: both review; closing: both idle).
- **Closing phase**: Auto-step from test stops at `closing` with both seats idle for final sign-off before project close.
- **PNG image diffs**: Review Diff renders `.png` files as visual images instead of raw bytes.

## [v1.2.27]

### Fixed
- **ChatGPT Desktop Send**: Focuses ChatGPT desktop window, clicks lower-center composer, and pastes the prompt.

## [v1.2.26]

### Added
- **ChatGPT Client Profile Support**: Added `ChatGPT` as a selectable AI profile in Seat 1 and Seat 2 client dropdowns (`cbSeat1Client`, `cbSeat2Client`).
- **Profile Auto-Injection**: Bootstrap automatically injects missing built-in profiles into existing `clients.json` files without requiring manual configuration resets.

## [v1.2.25]

### Fixed
- **Prompt Phase Sign-off Guidance Injection**: Fixed uninitialized `$signOffGuidance` in `Get-KickoffPromptForAgent`.
- **Mandatory Action Sign-off Instruction**: Added explicit phase sign-off step to kickoff prompts to prevent stalling between phases.

## [v1.2.24]

### Fixed
- **Configuration Schema Resilience**: Automatically normalizes older or partial `clients.json` files on load and save.
- **Visible Save Error Reporting**: Displays configuration save exceptions directly in the controller status bar.
- **Safe Path Resolution**: Uses resilient path resolution for recent board paths.

## [v1.2.23]

### Added
- **5-Phase Collaboration Ladder & Pitch Phase**: Structured project progression (`pitch` -> `discuss` -> `implement` -> `test` -> `closing` -> `closed`).
- **Auto Step Switch & Latched Auto-Advance**: Positioned beside sign-off boxes; automatically advances one phase when all three participants sign off.
- **Modeless Scratchpad Compare**: Side-by-side comparison pop-out window with highlight-only promote into Alignment.
- **Recent Boards Switcher & Board Creator**: Easily switch between recently opened project blackboards.
- **Disk Drift Notice & Dynamic Turn Cues**: Live visual notification when script or board on disk is newer.
- **Enhanced Git Review Diff**: Audits the entire active working tree, including newly created and untracked files.
