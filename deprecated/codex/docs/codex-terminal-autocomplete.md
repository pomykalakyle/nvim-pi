# Codex Terminal Autocomplete

> [!NOTE]
> This document describes planned functionality that has not been implemented yet.

## Purpose

Codex Terminal Autocomplete lets the user request an AI-generated continuation while writing a message in the Codex composer inside Neovim.

The user deliberately requests a suggestion with `Tab`.
Suggestions are never generated automatically while the user types.

The feature is intended to provide a lightweight continuation of the current message rather than edit, rewrite, or analyze the entire draft.

## Availability

Autocomplete is available only when all of the following are true:

- The focused buffer is an active Codex terminal managed by this Neovim configuration.
- Codex is showing its ordinary editable composer.
- The composer contains a visible draft.
- The text cursor is at the end of the draft.
- The visible draft can be identified confidently.

Availability does not depend on which terminal application is running Neovim.
It is not active in ordinary terminal buffers, editor buffers, file pickers, Neo-tree, command lines, or other applications.

The feature may be used while writing a new message or preparing a follow-up message, provided that the ordinary Codex composer remains editable.

## Requesting a Suggestion

When no suggestion is visible, the user presses `Tab` to request one.

The request uses only the visible text that the user has typed into the current Codex composer before the cursor.
Wrapped screen rows are treated as one continuous line of text.
No newline characters are included in the autocomplete context.

The request must not include:

- Text from an editor buffer or another Neovim split.
- Previous Codex messages or responses.
- Codex status text, hints, menus, approval prompts, or other interface content.
- Text from another Codex terminal.
- File contents that the user has not typed into the composer.

Requesting a suggestion does not modify or submit the current Codex message.

Only one suggestion request may be active at a time.
Repeated `Tab` presses while a request is pending do not create duplicate requests.

## Displaying a Suggestion

The suggestion appears visually beside the Codex text cursor as dimmed ghost text.

Ghost text is a preview only.
It is not part of the Codex message until the user accepts it.

A suggestion contains no newline characters.
It may wrap visually when it reaches the edge of the Codex pane, but it remains one continuous piece of text.

The suggestion must remain visually distinguishable from text already present in the composer.
It must not cover or replace existing prompt text.

If the suggestion cannot be displayed confidently, it is discarded without changing the composer.

## Accepting a Suggestion

When a suggestion is visible, the user presses `Tab` again to accept it.

The accepted text is inserted at the current Codex text cursor.
Accepting a suggestion does not submit the message.

After insertion, the suggestion disappears and the user can continue typing normally.

## Dismissing a Suggestion

Pressing `Escape` while a suggestion is visible dismisses the suggestion without changing the Codex message.

The suggestion is also dismissed when:

- The user types another character.
- The user moves the text cursor.
- The Codex composer changes state.
- A Codex menu, popup, approval request, or other modal interface appears.
- The user changes Codex terminals.
- The Codex terminal loses focus.
- The underlying draft no longer matches the text used to request the suggestion.

The action that caused dismissal continues normally unless it was `Escape`, which is consumed only to close the visible suggestion.

## Unavailable and Uncertain States

Autocomplete does not attempt a suggestion when the cursor is in the middle of existing text.

Autocomplete also remains inactive when the complete beginning of the draft is no longer visible because the Codex composer has internally scrolled.

When the feature cannot confidently isolate the visible Codex draft, it must not send partial, unrelated, or guessed context to the autocomplete provider.
It must not insert any text into Codex.

A brief visual indication may explain that autocomplete is unavailable, but it must not interrupt normal Codex use.

The ordinary Codex action currently assigned to `Tab` must remain available through a separate documented shortcut while autocomplete owns `Tab` in eligible composer states.

## Errors and Cancellation

If the autocomplete provider fails, times out, or returns an empty suggestion, the Codex message remains unchanged.

Typing while a request is pending cancels that request for display purposes.
A late result from a cancelled or stale request must never appear or be inserted.

Switching terminals, leaving the Codex terminal, or closing the terminal cancels any pending request and removes any visible suggestion.

## Privacy and Context Boundaries

Autocomplete sends context only after the user presses `Tab`.

The context is limited to the current visible Codex draft before the cursor.
The feature does not automatically include open files, selections, repository contents, previous conversation messages, or other Neovim buffers.

The chosen autocomplete provider and its data handling must be made clear before the feature is enabled.

## First-Version Boundaries

The first version does not:

- Complete text when the cursor is in the middle of the draft.
- Rewrite or replace existing prompt text.
- Generate suggestions automatically while the user types.
- Reconstruct prompt text that has scrolled out of the visible Codex composer.
- Read text from adjacent Neovim splits or editor buffers.
- Provide autocomplete outside the managed Codex terminal.
- Modify Codex itself.
- Depend on Cotypist.

These boundaries favor predictable behavior and prevent unrelated text from entering an autocomplete request.
