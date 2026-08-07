# Hands-Free Mode

## Purpose

Hands-Free Mode lets the user operate one Codex session through speech after deliberately starting the mode. Once it starts, the user does not need to use the keyboard or mouse to dictate and submit messages, approve or reject actions, interrupt Codex, or end the mode.

Codex responses remain visual. Hands-Free Mode does not read responses aloud.

## Starting the Mode

The user selects the Codex terminal that should be controlled and runs `:CodexHandsfree` as a Neovim command.

Starting the mode:

- Binds Hands-Free Mode to the selected Codex terminal.
- Builds the bundled speech companion automatically the first time it is needed.
- Starts microphone capture automatically.
- Requires no additional keyboard, mouse, shortcut, or push-to-talk action.
- Shows the current hands-free state in the Codex pane title.

Hands-Free Mode is never enabled automatically when Neovim or Codex opens. It is always an explicit opt-in.

Only one originating Codex terminal is controlled for the lifetime of the mode. Voice input does not move to another numbered terminal, even if another terminal becomes visible or active.

The first activation may display the standard macOS microphone-permission prompt.
After the user grants permission, later activations reuse the signed companion application's stable identity.

Codex terminals that were already open when this feature was installed must be closed and reopened before they can use Hands-Free Mode.

## Listening for a Message

When the originating Codex terminal is ready for a new message, Hands-Free Mode listens for normal dictation.

A non-empty dictated message is submitted in either of these ways:

- The user says the standalone phrase "Submit that message." Submission happens immediately.
- The user stops speaking for 10 continuous seconds. Submission happens when the silence period expires.

The 10-second delay allows time for short thinking pauses.

"Submit that message" is a control phrase and is not included in the message sent to Codex. Silence before the user begins a message does not submit anything.

## While Codex Is Working

After a message is submitted, Hands-Free Mode stops accepting ordinary message dictation until the current Codex turn finishes. Speech during this period is not queued as a future message.

The standalone word "stop" interrupts the current Codex turn. It does not end Hands-Free Mode. Once Codex is ready again, the mode returns to listening for a new message.

Outside an active Codex turn, the word "stop" has no special meaning and may be part of ordinary dictation.

## Approvals

When Codex is visibly waiting for approval of an edit or another tool call, Hands-Free Mode accepts two standalone commands:

- "Approve" approves only the single pending action.
- "Reject" rejects only the single pending action.

After either decision, Hands-Free Mode remains active and Codex continues according to that decision.

"Approve" and "reject" are commands only while an approval is pending. At other times, they are ordinary dictated words. A longer sentence containing either word is not treated as an approval decision.

## State-Aware Commands

Spoken controls are recognized only when they make sense for the current state:

| State | Accepted speech |
| --- | --- |
| Ready for a message | Normal dictation and "Submit that message" |
| Codex working | "Stop" |
| Approval pending | "Approve" or "Reject" |
| Any active state | "Exit hands-free mode" |

This state gating prevents ordinary sentences from accidentally approving, rejecting, stopping, or submitting an action.

## Ending the Mode

The standalone phrase "Exit hands-free mode" ends Hands-Free Mode immediately from any state.
The user can also run `:CodexHandsfreeStop` in Neovim to end the mode manually.

Ending the mode:

- Stops microphone capture and voice control.
- Discards any dictated message that has not yet been submitted.
- Does not interrupt a Codex turn that is already running.
- Shows a visual confirmation that Hands-Free Mode has ended.

If the user wants to interrupt a running turn before exiting, they can say "stop" and then "exit hands-free mode."

Hands-Free Mode remains active indefinitely until the user says the exit phrase or the originating Codex terminal is lost. It does not end merely because the user has been silent.

If the originating terminal closes, exits, is removed, or becomes unavailable, Hands-Free Mode ends automatically. It never transfers silently to another terminal.

## Visual Feedback

All Codex responses remain visual; no response text is spoken aloud.

The Codex pane title persistently shows "Starting microphone," "Listening," "Codex working," or "Awaiting approval" while Hands-Free Mode is active.
Neovim notifications report when the mode starts, ends, or cannot start.

If microphone capture cannot start, Hands-Free Mode must remain inactive and show a visual error instead of appearing to work without listening.
