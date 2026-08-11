# Pending edit proposals

Normal `edit` and `write` calls create a pending proposal instead of changing the file immediately.
The proposal stays visible as a read-only Neovim diff while the normal Pi editor remains available. Each Pi workspace can keep one pending proposal without replacing or closing another workspace's preview.

## Flow

```text
edit/write
  → validate the mutation against the current file
  → open the Neovim diff
  → store one pending proposal for the workspace
  → continue the conversation
  → /proposal accept or /proposal reject
```

The model can answer questions and inspect the codebase while a proposal is pending. A later `edit` or `write` for the same path replaces the proposal in place. A proposal for another path is blocked until the current one is resolved.

Tests and Bash commands are also blocked while review is pending. The reviewed change exists only in memory, so tests become meaningful after acceptance.

## Commands

```text
/proposal accept
/proposal reject
```

You can also clearly tell the agent to accept/apply or reject/discard the pending proposal. The agent resolves it through the same guarded flow. Ambiguous feedback does not resolve a proposal.

`accept` writes the latest proposed contents only when the file still matches the snapshot used to build the proposal. If the file changed in the meantime, acceptance fails and the proposal remains pending so the model can revise it against the current file. After a successful acceptance, the command tells the agent what happened and triggers its next turn.

`reject` discards the proposal without changing the file, tells the agent it was rejected, and triggers the agent's next turn.

The footer shows the pending filename and both commands until the proposal is resolved.

## Persistence

Proposal state is appended to the Pi session as extension data. It survives ordinary conversation turns and can be restored when the same session reloads. Session-tree navigation reloads the latest set or clear entry from the selected branch.

A proposal is discarded if it is restored in another working directory, including a copied session opened in another worktree. It must be proposed again against that worktree's files. A restored proposal also cannot be accepted unless its Neovim diff was restored successfully.

The file snapshot and filesystem identity are checked again at acceptance, including whether a proposed new file still does not exist. Existing symlinks are resolved when the proposal is created; retargeting one invalidates the proposal instead of redirecting the accepted write. A new-file proposal requires its parent directory to exist already so that directory identity can be pinned during review and rechecked during acceptance.

## Permission integration

The preview extension registers a narrow Gotgenes authorizer named `neovim-diff-preview`. It allows only the exact `edit` or `write` call whose validated output is already staged as the current proposal. It does not authorize forwarded requests, other tools, another path, or an operation without a successfully rendered preview.

Enable the authorizer alongside Vibing Mode:

```json
{
  "authorizerChain": ["vibing-mode", "neovim-diff-preview"]
}
```

This bypasses the old immediate approval prompt because executing the tool now stores an unapplied proposal. The later `/proposal accept` command performs the mutation directly after the snapshot check.

## Vibing Mode

Request-scoped Vibing Mode keeps its existing immediate behavior:

```text
eligible edit/write → no Neovim proposal → mutate immediately
```

The pending-proposal path is used only when Vibing Mode does not cover the mutation.
