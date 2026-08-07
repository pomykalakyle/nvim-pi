# Hands-Free Mode Design

## Summary

Hands-Free Mode uses three cooperating pieces:

- A new [macOS speech companion](#macos-speech-companion) that we will write in Swift.
- A [Hands-Free controller](#neovim-controller) inside Neovim, activated through [`:CodexHandsfree`](#neovim-activation-command).
- Small [hook scripts](#codex-lifecycle-bridge) that Codex runs when its state changes.

The user starts the mode by selecting the Codex terminal that should be controlled and running [`:CodexHandsfree`](#neovim-activation-command) from Neovim.
The command binds Hands-Free Mode to the selected numbered Codex terminal slot.
The macOS speech companion captures microphone audio and converts it to text.
Neovim starts and stops the companion automatically, so the user never operates it as a separate application.
The [Neovim controller](#neovim-controller) receives the recognized text, decides whether it is dictation or a command, and sends the resulting action to the bound Codex terminal.
The [Codex lifecycle bridge](#codex-lifecycle-bridge) tells Neovim when Codex starts or finishes a turn and when Codex needs an approval decision.
Codex itself continues to run in the existing terminal UI.

## Architecture

```text
Activation:

User runs :CodexHandsfree -> Neovim Hands-Free controller -> selected Codex terminal slot

Speech input:

User -> microphone -> macOS speech companion
                              |
                              | recognized text and voice activity
                              v
                    Neovim Hands-Free controller
                              |
                              | text or an interrupt action
                              v
                       bound Codex terminal

Codex state:

bound Codex terminal -> Codex hook script -> Neovim Hands-Free controller
bound Codex terminal <- allow or deny <- Codex hook script <- Neovim Hands-Free controller
```

## How the Components Work Together

### Starting Hands-Free Mode

1. The user selects the Codex terminal that should be controlled and runs [`:CodexHandsfree`](#neovim-activation-command) from Neovim.
2. The command asks the [terminal provider](#terminal-provider-changes) for the stable slot ID of the selected Codex terminal.
3. Activation fails visibly if the selected slot does not contain a live Codex terminal.
4. The [Neovim controller](#neovim-controller) binds Hands-Free Mode to the resolved slot ID.
5. Neovim starts the [macOS speech companion](#macos-speech-companion) as a child process.
6. The companion opens the microphone and reports when speech recognition is ready.
7. Neovim begins accepting speech after the companion is ready if the bound Codex terminal is idle.
8. If Codex is already working, Hands-Free Mode remains active but waits for the turn to finish before accepting speech.

### Sending a Message

1. The companion receives microphone audio and sends recognized text to Neovim through the [speech event protocol](#speech-event-protocol).
2. The Neovim controller accumulates that text as the current draft.
3. The controller submits the draft when it recognizes "Submit that message" or measures 10 seconds of silence.
4. Submission uses the [terminal provider](#terminal-provider-changes) to write the message and an Enter key to the terminal job that runs the bound Codex session.
5. From Codex's perspective, the submitted text is ordinary terminal input, just as if the user had typed it.
6. The [`UserPromptSubmit` hook](#codex-lifecycle-bridge) reports the Codex session and turn that are about to receive the prompt, allowing the Neovim controller to associate later events with the bound terminal.

### Detecting That Codex Finished

1. Codex runs a [`Stop` hook](#codex-lifecycle-bridge) when the current turn ends.
2. `Stop` is Codex's name for this turn-ended lifecycle event and is separate from the user's spoken "Stop" command.
3. The hook script sends the session ID, turn ID, and terminal slot ID to Neovim.
4. The running Neovim instance receives that local message through its RPC interface.
5. RPC is the request channel that allows a local script to call a function inside the running Neovim process.
6. The controller verifies that the event belongs to the bound terminal and returns to `ready`.

### Handling an Approval

1. Codex runs a [`PermissionRequest` hook](#codex-lifecycle-bridge) before it asks whether an edit or tool call should proceed.
2. The hook tells the Neovim controller which Codex session and request are waiting, then pauses for a decision.
3. The controller changes to `approval_pending`, so ordinary speech is ignored and only "Approve," "Reject," or the exit phrase is meaningful.
4. The speech companion converts the spoken response to text and sends it to the controller.
5. The controller returns an `allow` or `deny` decision to the waiting hook.
6. The hook returns that decision to Codex, and Codex continues or rejects the action normally.

### Stopping or Exiting

When the user says "Stop" during a turn, the companion sends the recognized word to Neovim and the controller sends Codex's verified interrupt action to the bound terminal.
When the user says "Exit hands-free mode," Neovim stops the companion, discards any unsent draft, removes temporary approval state, and leaves any running Codex turn alone.

## Components

### Neovim Activation Command

`:CodexHandsfree` is the user-facing activation mechanism.
The user runs it as a Neovim command after selecting the Codex terminal that should be controlled.

The command asks the numbered-terminal provider for the selected Codex terminal's stable slot ID.
It then calls the Neovim controller directly with that slot ID.
The activation command is implemented entirely inside the Neovim configuration.

If Hands-Free Mode is already active, the command leaves the existing binding unchanged and reports that state visually.
Activation success or failure is shown through a Neovim notification.
`:CodexHandsfreeStop` is the manual Neovim command for ending an active mode.

### macOS Speech Companion

The macOS speech companion is a small program included in this Neovim configuration.
It is written in Swift because Swift can call the native microphone and speech-recognition services provided by macOS.
Apple's Speech framework is the operating-system library that performs the on-device speech recognition.
Within that framework, `SpeechAnalyzer` manages the continuous stream of microphone audio.
`SpeechTranscriber` converts the speech in that audio stream into recognized text.
Those two names refer to Apple framework components inside the companion, not additional programs the user must install or operate.

The companion owns only microphone capture and transcription.
It does not decide what recognized words mean and does not communicate with Codex directly.

The companion:

- Request and retain microphone permission.
- Capture microphone audio continuously while the mode is active.
- Use `SpeechAnalyzer` and `SpeechTranscriber` with progressive live transcription.
- Emit provisional and finalized transcript segments.
- Measure acoustic voice activity so the 10-second timer reflects actual silence rather than a delay in transcription results.
- Stop promptly when Neovim closes its input or terminates the process.
- Emit a structured error before exiting when capture or transcription fails.

The companion is packaged as a signed background application with a stable bundle ID so macOS can retain microphone authorization across launches.
Neovim builds the application automatically the first time Hands-Free Mode needs it and reuses the resulting release build.

### Speech Event Protocol

Neovim will launch the companion as a child process and consume newline-delimited JSON from standard output.
Standard output is a private text stream from the companion back to Neovim, not text displayed in the Codex terminal.
The companion sends small event messages through that stream instead of calling Neovim or Codex directly.
Every line must contain one complete event.

Initial event types:

| Event | Required fields | Meaning |
| --- | --- | --- |
| `ready` | `backend` | Microphone capture and transcription are ready. |
| `speech_started` | `timestamp_ms` | Acoustic speech began. |
| `speech_ended` | `timestamp_ms` | Acoustic speech ended. |
| `transcript_partial` | `utterance_id`, `text` | Replaceable provisional text. |
| `transcript_final` | `utterance_id`, `text` | Final text for one utterance. |
| `error` | `code`, `message`, `recoverable` | Capture or transcription failed. |
| `stopped` | `reason` | The companion ended normally. |

The controller must ignore duplicate final events for the same `utterance_id`.
Unknown fields and event types should be ignored so the protocol can be extended compatibly.

### Neovim Controller

The Lua controller owns all Hands-Free Mode state and user-visible behavior.
The controller is one cohesive Lua component that owns the state machine, companion lifecycle, and public commands.

The controller will track:

- Whether Hands-Free Mode is active.
- The bound terminal slot ID, buffer, and job.
- The corresponding Codex session and active turn when known.
- The current state.
- Finalized draft text and provisional text.
- The most recent voice-activity time.
- The 10-second submission timer.
- The single pending approval request, if any.
- The speech-companion process and generation ID.

A generation ID must distinguish the current companion process from callbacks arriving after an older process was stopped.
Late events from an old generation must have no effect.

### Terminal Provider Changes

The numbered-terminal provider remains the owner of terminal instances.
It should expose operations equivalent to:

- Get the stable ID of the currently selected Codex terminal.
- Resolve a stable slot ID to its live buffer and terminal job.
- Send text to a specified slot with or without submission.
- Send the installed Codex version's interrupt input to a specified slot.
- Notify Hands-Free Mode before a bound slot is closed or discarded.

Each Codex terminal process should receive `CODEX_NVIM_SERVER`, which identifies the running Neovim instance, and `CODEX_NVIM_SLOT_ID`, which identifies its numbered terminal slot.
Each process also receives `CODEX_HANDSFREE_STATE_DIR`, which identifies a private runtime directory owned by that Neovim process.
Hook scripts inherit all three values and use them when notifying Neovim.
This avoids confusing concurrent activity from different numbered terminals.

Closing, replacing, or losing the bound slot ends Hands-Free Mode.
Selecting a different visible slot does not change the binding.

### Codex Lifecycle Bridge

A Codex lifecycle hook is a script that Codex automatically runs when a specific event occurs.
The design adds hands-free hook scripts to the existing hook configuration instead of trying to infer Codex state from text drawn in the terminal.

| Hook | Hands-Free responsibility |
| --- | --- |
| `SessionStart` | Associate a Codex session with `CODEX_NVIM_SLOT_ID`. |
| `UserPromptSubmit` | Mark the corresponding slot as working and record the active turn. |
| `PermissionRequest` | Register one pending approval and wait for its spoken decision. |
| `Stop` | Mark the turn complete and return the bound mode to message listening. |
| `SessionEnd` | End a mode bound to the ended session or slot. |

The hook bridge should be inactive for terminals without an active Hands-Free Mode instance, except for the minimal per-slot lifecycle state needed to determine whether activation occurs while Codex is ready or working.

Hooks from multiple configuration sources run concurrently.
The hands-free approval hook therefore needs to coexist with the current Bash auto-allow hook and Vibing Mode hook:

- A spoken rejection returns `deny`, which takes precedence over any concurrent `allow`.
- A spoken approval returns `allow`.
- Outside Hands-Free Mode, the hook returns no decision and preserves the existing approval behavior.
- When Hands-Free Mode is known to be active but its decision bridge fails, the hook must deny rather than silently approve.

Approval requests and decisions need a unique request ID in addition to the session and turn IDs.
A decision must never be reusable by a later request.

The hook process cannot block Neovim's event loop while waiting.
The bridge uses a private state directory with atomic request and decision files keyed by a generated request ID.
Each hook process polls only for its matching decision while Neovim writes decisions atomically.
Runtime files must be owner-only and removed after completion, timeout, or mode exit.
The runtime directory is unique to the running Neovim process so simultaneous Neovim instances cannot consume each other's events or decisions.

### Visual Feedback

At minimum, activation, termination, and startup failure will use Neovim notifications.

The design includes one small persistent state indicator when it can reuse the existing Codex status infrastructure without broad UI changes.
Activation, termination, and failure notifications are sufficient if that integration is disproportionate.

## State Model

The controller has four active states:

| State | Meaning | Accepted speech |
| --- | --- | --- |
| `ready` | Codex can accept a new message. | Normal dictation and "Submit that message." |
| `working` | A Codex turn is running. | "Stop." |
| `approval_pending` | Codex is waiting for one permission decision. | "Approve." or "Reject." |
| `stopping` | The companion and local state are being cleaned up. | Nothing. |

The global phrase "Exit hands-free mode" is recognized in every active state except `stopping`.

Expected transitions:

```text
inactive
   |
   | activate
   v
ready -- submit --> working -- Stop hook --> ready
                       |
                       | PermissionRequest
                       v
                 approval_pending
                       |
                       | approve or reject
                       v
                    working

any active state -- exit phrase / terminal loss / fatal error --> inactive
```

An approval decision normally returns to `working`, not directly to `ready`.
The later `Stop` hook is authoritative for turn completion.

## Transcript and Command Handling

Only finalized transcript segments can change durable state in v1.
Partial text may be displayed or used for diagnostics, but it must not approve, reject, submit, exit, or modify the committed draft.

Before command comparison, a finalized utterance is:

1. Trimmed.
2. Converted to lowercase.
3. Stripped of trailing sentence punctuation.
4. Collapsed to single spaces.

The complete normalized utterance must equal the command phrase.
A command word inside a longer sentence remains ordinary speech.

Command interpretation is deterministic:

| State | Exact phrase | Action |
| --- | --- | --- |
| `ready` | `submit that message` | Submit the non-empty draft immediately. |
| `working` | `stop` | Interrupt the bound Codex turn. |
| `approval_pending` | `approve` | Allow the pending request. |
| `approval_pending` | `reject` | Deny the pending request. |
| Any active state | `exit hands-free mode` | End the mode. |

In `working` and `approval_pending`, finalized non-command speech is discarded and is never queued for the next turn.

### Message Draft

In `ready`, each non-command final segment is appended to the draft in recognition order.
The controller must prevent duplicated segments when a provisional result is replaced by a final result.

The 10-second timer:

- Does not start before the draft contains non-empty text.
- Starts when acoustic speech ends.
- Is cancelled when speech starts again.
- Is restarted after each later speech end.
- Submits only if the draft is still non-empty and the state is still `ready`.
- Is cancelled when the draft is submitted, discarded, or the state changes.

The control phrase is never included in the submitted text.
Exiting the mode discards the current draft.

## Sending and Interrupting

Message submission uses the existing terminal channel but targets the bound slot explicitly.
The controller writes the dictated text first and sends carriage return as a separate terminal write 200 milliseconds later.
This delay crosses Codex's 120-millisecond paste-burst suppression window so the carriage return is interpreted as the Enter key that submits the prompt instead of a pasted newline.
A successful channel write moves the controller to `working`; a failed write leaves the draft intact, ends the mode, and reports an error.

The integration must use a verified interrupt action for the installed Codex TUI.
The controller will send that action to the bound terminal job.
It must not send a guessed control character that might terminate the entire Codex session.

If the installed TUI cannot be interrupted reliably through its terminal control surface, the design must be revisited before implementing `stop`.
Migrating the entire integration to App Server is the structured fallback and is not part of v1.

## Activation

The user activates Hands-Free Mode by selecting a Codex terminal and running [`:CodexHandsfree`](#neovim-activation-command).
The command resolves the selected terminal's stable slot ID and asks the [Neovim controller](#neovim-controller) to start the mode for that slot.

Activation succeeds only after:

- A live originating slot is resolved.
- The originating Codex process has the hands-free environment installed.
- The speech companion starts.
- Microphone capture and transcription report `ready`.
- The controller can establish the initial Codex state for that slot.

If any condition fails, the mode remains inactive and shows a visual error.
An originating Codex terminal created before the hands-free environment was installed must be closed and reopened before activation.

## Failure and Recovery

| Failure | Required behavior |
| --- | --- |
| Microphone permission denied | Activation fails visibly. |
| Speech companion fails during use | End the mode, discard the unsent draft, and leave Codex running. |
| Bound terminal disappears | End the mode immediately. |
| Transcript backend disconnects | End the mode rather than pretending to listen. |
| Approval bridge fails while active | Deny the pending request and end or visibly degrade the mode. |
| Hook event lacks a known slot | Ignore it; never redirect it to the visible slot. |
| Neovim exits | Terminate the speech companion and remove runtime files. |
| Stale companion or timer callback fires | Ignore it using generation and request IDs. |

Ending Hands-Free Mode does not interrupt an active Codex turn.
The spoken sequence "stop" followed by "exit hands-free mode" remains the way to do both.

## Privacy and Security

- Apple transcription remains on-device after the required speech model asset is installed.
- Raw microphone audio is not written to disk.
- Transcript events exist only in process memory unless diagnostic logging is explicitly enabled.
- Diagnostic logging must omit raw audio and approval tool inputs by default.
- Approval request and decision files must be accessible only to the current user.
- No approval decision may be inferred from partial speech.
- A bridge failure must never produce an approval.

## Alternatives

### Wispr Flow Desktop

The installed consumer application is not selected as the primary backend.
Its hands-free flow is oriented around an active text field and pastes text when a dictation session ends.
It does not provide the state-aware event stream needed for persistent message dictation, interruption, and approval handling.
UI or Accessibility automation around it would be brittle and would add more permissions.

### Wispr Flow API

Wispr's WebSocket API can stream audio and return partial and final transcriptions, so it could implement the speech-companion protocol.
Access is currently exclusive and requires Flow team approval.
The installed desktop application does not establish API access.

If API access becomes available, Wispr is a viable replacement backend.

### OpenAI Realtime Transcription

OpenAI's transcription-only Realtime API can stream transcript deltas without a spoken assistant response.
It is the preferred fallback if Apple transcription is not accurate enough for the user's voice or coding vocabulary.

This option requires an API key, network availability, and usage cost.
The companion would retain local voice-activity timing and command interpretation; only transcription transport would change.

### Codex App Server

App Server exposes structured turn start, completion, interruption, approval, and experimental realtime-audio operations.
It would remove several terminal integration compromises, but adopting it means building a new Codex client surface instead of preserving the current TUI.
It remains a future option and is not part of v1.

## Decisions

| Decision | Status |
| --- | --- |
| Preserve the existing Codex TUI | Selected |
| Own orchestration in Neovim | Selected |
| Use deterministic state-gated commands | Accepted behavior |
| Use Apple Speech as the first backend | Selected |
| Keep the speech backend replaceable | Selected |
| Use Codex hooks instead of terminal scraping | Selected |
| Bind to a stable numbered terminal slot | Accepted behavior |
| Resolve approvals through `PermissionRequest` | Selected |
| Package the Swift companion as a signed background application | Selected |
| Activate from Neovim with `:CodexHandsfree` | Selected |
| Use supported Codex extension points without modifying Codex | Required |

## Sources

- [Apple Speech framework](https://developer.apple.com/documentation/speech/)
- [Apple SpeechAnalyzer introduction](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Codex hooks](https://learn.chatgpt.com/docs/hooks)
- [Codex developer commands](https://learn.chatgpt.com/docs/developer-commands)
- [Codex App Server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [Wispr Flow API quickstart](https://api-docs.wisprflow.ai/quickstart)
- [Wispr Flow WebSocket API](https://api-docs.wisprflow.ai/websocket_api)
- [Wispr Flow hands-free mode](https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free)
