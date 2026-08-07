# Vibing Mode authorizer investigation

## Summary

Vibing Mode previously stopped enabling after Pi reloaded extensions. The local extension left an old `permissions:ready` listener attached to Pi's shared event bus. That stale listener registered the old `vibing-mode` authorizer before the new extension instance, causing duplicate registration.

The extension now saves the event subscription cleanup function and calls it during `session_shutdown`. Registration failures also retain their error message instead of being reported only as an unavailable authorizer.

## Environment

- Pi version: `0.83.0`
- Permission system: `@gotgenes/pi-permission-system@24.0.0`
- Vibing Mode package: `pi-extensions/vibing-mode`
- Permission configuration: `~/.pi/agent/extensions/pi-permission-system/config.json`
- Configured authorizer chain: `['vibing-mode']`

The installed permission-system peer requirement is Pi `>=0.79.0`, so the observed versions are compatible.

## What was ruled out

The permission system itself was loaded and functioning:

- Normal `edit` and `write` approval prompts continued to appear.
- Permission review events continued to be written to the permission-system log.
- The global permission configuration resolved successfully.
- The configuration included `vibing-mode` in `authorizerChain`.

This means the failure was not caused by a missing permission extension, invalid permission configuration, unsupported Pi version, or unavailable approval UI.

## Relevant implementation

Vibing Mode registers for permission-service readiness in `pi-extensions/vibing-mode/index.ts`. Pi's `EventBus.on` API returns a cleanup function:

```ts
on(channel: string, handler: (data: unknown) => void): () => void;
```

The extension previously ignored that return value. It now retains the cleanup function:

```ts
const unsubscribePermissionsReady = pi.events.on(
  "permissions:ready",
  registerAuthorizer,
);
```

Its `session_shutdown` handler calls that cleanup before disposing the registered authorizer.

Pi's resource loader reuses its event bus across extension reloads. Reloading extension code therefore does not automatically remove a listener registered directly through `pi.events.on`.

The permission system allows only one authorizer per name. Its authorizer registry throws when `vibing-mode` is already registered:

```ts
if (this.links.has(name)) {
  throw new Error(`An authorizer is already registered for '${name}'.`);
}
```

## Failure sequence before the fix

The reload failure was:

1. The first Vibing Mode extension instance subscribes to `permissions:ready`.
2. Pi reloads extensions while retaining the shared event bus.
3. The old listener remains subscribed because its cleanup function was discarded.
4. The permission system publishes a fresh service and emits `permissions:ready`.
5. The stale listener registers the old instance's `vibing-mode` authorizer first.
6. The new listener attempts to register the same authorizer name.
7. The permission registry throws a duplicate-registration error.
8. The new Vibing Mode instance catches the error and treats registration as unavailable.
9. Subsequent `vibing_mode enable` calls continue to fail in that process.

The stale callback also closes over the old request state, so leaving it registered would be incorrect even if duplicate registration were otherwise tolerated.

## Error reporting

`registerAuthorizer()` still returns `false` and fails closed when the service is absent or registration throws. It now records a plain-language service-unavailable reason or the thrown registration message. The `vibing_mode` tool includes that reason in its failure result while normal edit/write review remains active.

## Supporting observations

- Vibing Mode successfully emitted `vibing_mode.auto_allow` events earlier in the same Pi process.
- After extension/settings reload activity, normal permission prompts continued but Vibing Mode enablement failed.
- The same failure occurred previously and disappeared after restarting Pi.
- A later process successfully produced many `vibing_mode.auto_allow` events, confirming that the policy and authorizer work when registration succeeds.
- The existing isolated Vibing Mode tests passed because they test state and policy behavior, not repeated extension loading against a persistent shared event bus.

## Previous workaround

Before the fix, exiting and restarting the complete Pi process created a fresh event bus and removed stale listeners. Repeating `/reload` could preserve or multiply stale subscriptions.

## Implemented permanent fix

The cleanup returned by `pi.events.on` is now invoked during `session_shutdown`:

```ts
const unsubscribePermissionsReady = pi.events.on(
  "permissions:ready",
  registerAuthorizer,
);

pi.on("session_shutdown", (_event, ctx) => {
  state.reset();
  ctx.ui.setStatus(STATUS_KEY, undefined);
  unsubscribePermissionsReady();
  disposeAuthorizer?.();
  disposeAuthorizer = undefined;
  registeredPermissions = undefined;
  unpublishVibingModeService(service);
});
```

Registration failures are also preserved so the tool can distinguish:

- permission service unavailable;
- duplicate authorizer registration;
- another unexpected registration exception.

The implementation should remain fail-closed: any unsuccessful registration must leave normal edit/write review active.

## Verification

`tests/vibing_mode_reload_spec.mjs` uses one persistent event bus and three extension generations. For each generation it publishes a fresh fake permission service, emits `permissions:ready`, confirms exactly one registration attempt, enables Vibing Mode, checks that an in-project edit is allowed, and checks that an external edit and unrelated tool defer to normal permissions. Each generation shuts down before the next one loads, reproducing Pi's reload lifecycle.

Manual verification should cover repeated `/reload` operations and a full process restart.

## Files consulted

- `pi-extensions/vibing-mode/index.ts`
- `pi-extensions/vibing-mode/state.ts`
- `pi-extensions/vibing-mode/shared.ts`
- `~/.pi/agent/settings.json`
- `~/.pi/agent/extensions/pi-permission-system/config.json`
- `~/.pi/agent/extensions/pi-permission-system/logs/pi-permission-system-permission-review.jsonl`
- `@gotgenes/pi-permission-system/src/authority/authorizer-registry.ts`
- `@gotgenes/pi-permission-system/src/handlers/lifecycle.ts`
- `@gotgenes/pi-permission-system/src/service-lifecycle.ts`
- `@gotgenes/pi-permission-system/docs/cross-extension-api.md`
- Pi `dist/core/event-bus.d.ts`
- Pi `dist/core/resource-loader.js`
