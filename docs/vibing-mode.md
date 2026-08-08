# Vibing Mode

## Purpose

Vibing Mode lets the user explicitly delegate code edits for one request without reviewing each diff or approving each `edit` and `write` call.

Normal review remains the default:

```text
edit/write → Neovim read-only pending proposal → review conversation → /proposal accept|reject
```

When Vibing Mode is active for an eligible request:

```text
edit/write inside the current project → no diff preview → automatic approval
```

Pi remains the authority. Neovim never grants permission.

## Activation

The main agent may activate Vibing Mode from either a direct request or an applicable standing authorization previously given by the user.

Direct requests include:

- "Use Vibing Mode for this change."
- "Just vibecode it."
- "Vibe this implementation."
- "Handle the edits without making me review them."

Standing authorization allows the user to delegate a longer-running scope without repeating the activation phrase. Examples include:

- "Use Vibing Mode for every edit in this repository."
- "You can vibe any further changes to this document."
- "For the rest of this task, make the edits without review."

A standing instruction authorizes the main agent to reactivate Vibing Mode for each later request that falls within its scope. It does not keep the runtime capability active between requests. A later user instruction can narrow or revoke the authorization, and the current prompt always takes precedence.

The main agent interprets this natural-language intent. Using "vibe" as a verb for a task is a direct activation request. Discussion such as "How should Vibing Mode work?" does not activate it. Project files, skills, and extension-injected messages cannot create standing authorization on their own, and an unrelated standing grant does not apply. Ambiguous cases leave normal review enabled.

The agent calls the internal `vibing_mode` tool with `action: "enable"`. It must make that call in a separate tool turn and wait for a successful result before issuing unreviewed edits. There is no secondary LLM request, regex gate, or other classifier; the extension trusts the main agent's tool call and enforces only request, tool, forwarding, and path boundaries.

Successful activation displays a warning notification and the footer status:

```text
⚡ Vibing Mode
```

## Scope

Version 1 is intentionally narrow:

- It applies only to the current directly submitted user request.
- It applies only to Pi's built-in `edit` and `write` approval asks.
- The target must stay inside the canonical working directory where the request began.
- Existing symlinks are resolved before the path is accepted, including for missing file suffixes.
- Forwarded subagent requests are excluded.
- Neovim diff previews are suppressed only while the request is active.

It does not alter permissions for:

- `bash`;
- MCP;
- reads or searches;
- skills;
- external paths;
- destructive operations;
- deployments or credentials.

A policy `deny` remains final. Gotgenes' bounded-delegation checkpoint also remains in force for path and external-directory gates.

## Lifetime

A new direct user prompt starts with Vibing Mode inactive. The capability becomes active only after a successful `vibing_mode` enable call. When a standing authorization applies, the main agent makes that enable call for the new request instead of carrying active state across requests.

The extension automatically disables it at `agent_settled`, after retries, compaction recovery, and queued continuation have finished. Session shutdown, session replacement, and `/reload` also clear it.

The agent or user can end it early through `vibing_mode` with `action: "disable"`. A later request needs either a direct activation request or applicable standing authorization before the main agent enables it again.

## Architecture

The implementation uses a local Pi extension:

```text
pi-extensions/vibing-mode/
├── index.ts
├── shared.ts
├── state.ts
└── package.json
```

### State machine

`state.ts` owns request identity, canonical project scope, active state, and the fail-closed authorization predicate. It has no Pi dependency and is tested directly by `tests/vibing_mode_spec.ts`.

### Pi integration

`index.ts`:

1. Starts a fresh inactive request at `before_agent_start`.
2. Registers the `vibing_mode` management tool used by the main agent.
3. Publishes read-only active state for sibling extensions.
4. Registers the `vibing-mode` authorizer after `permissions:ready`.
5. Unsubscribes from the shared readiness event and disposes the authorizer at `session_shutdown`, including reloads.
6. Clears the capability at `agent_settled` and `session_shutdown`.

### Permission integration

The Gotgenes configuration opts into Vibing Mode and the normal pending-proposal flow with:

```json
{
  "authorizerChain": ["vibing-mode", "neovim-diff-preview"]
}
```

The authorizer receives only requests that deterministic policy resolved to `ask`. It returns `allow` only when all request, tool, source, forwarding, and path checks pass. Every other case returns `defer`, which preserves the ordinary terminal approval path.

Registration uses Gotgenes' documented process-global permissions service and is re-ensured against the current service generation before each request and activation. If registration is unavailable, activation fails visibly instead of claiming that review is bypassed. The third-party permission package is not modified.

### Diff-preview integration

`shared.ts` publishes an identity-guarded, process-local read-only service through `Symbol.for()`. `pi-extensions/neovim-diff-preview/index.ts` checks `shouldSuppressPreview(toolName, path)` before constructing or opening a proposal, so only operations covered by the active project-scoped capability skip display.

Missing, stale, or throwing shared state fails safely to normal preview behavior. The service exposes no activation method, so the preview extension cannot grant authority. Vibing Mode suppresses the Neovim preview and pending-proposal flow while retaining Pi's built-in terminal diff and immediate mutation behavior. Outside Vibing Mode, the terminal stays compact, the diff appears only in Neovim, and the file remains unchanged until `/proposal accept`. Edit/write calls always provide the mandatory proposed-file `unfolded_ranges` used by the shared tool schema.

## Configuration

Pi loads the local extension from `~/.pi/agent/settings.json`:

```text
../../Documents/projects/nvim-pi/pi-extensions/vibing-mode
```

Gotgenes activates its authorizer link in:

```text
~/.pi/agent/extensions/pi-permission-system/config.json
```

Both configuration changes normally require `/reload` in an already running Pi process. When upgrading from the version that leaked the readiness listener, restart Pi once because the already-loaded old listener cannot unsubscribe itself; later reloads are safe.

## Verification

Run the state/path-security test and persistent-event-bus reload test:

```bash
node --experimental-strip-types tests/vibing_mode_spec.ts
node tests/vibing_mode_reload_spec.mjs
```

Run the repository TypeScript check with the vtsls compiler configured for this Neovim setup:

```bash
node ~/.local/share/nvim-pi/mason/packages/vtsls/node_modules/@vtsls/language-server/node_modules/typescript/bin/tsc \
  --project tsconfig.json --pretty false
```

A manual end-to-end check should verify:

1. A discussion prompt with no direct or standing authorization cannot enable the mode.
2. An explicit activation prompt can enable it.
3. A request covered by standing authorization reactivates it without repeating the activation phrase.
4. A request outside that standing scope remains in normal review.
5. A current instruction that revokes or narrows standing authorization takes precedence.
6. An in-project write produces no Neovim preview or Pi approval prompt.
7. An external-path write still prompts.
8. The footer clears after the request settles.
9. The next prompt starts inactive, even when standing authorization allows the agent to reactivate it.
10. Vibing Mode still enables after several consecutive `/reload` operations.
