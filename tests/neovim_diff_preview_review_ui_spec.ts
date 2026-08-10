import assert from "node:assert/strict";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { Component } from "@earendil-works/pi-tui";
import { requestManualReview } from "../pi-extensions/neovim-diff-preview/review-ui.js";

const summary = {
  path: "example.ts",
  justification: "Keep the manual review controls visible and understandable.",
};

const theme = {
  bold: (text: string) => text,
  fg: (_color: string, text: string) => text,
  bg: (color: string, text: string) =>
    color === "toolPendingBg" ? `\x1b[48;2;15;31;26m${text}\x1b[49m` : text,
};

/** Mount one review component and drive it with raw terminal keys. */
async function choose(keys: string[]): Promise<string> {
  let component: Component | undefined;
  let toolsExpanded = false;
  let expansionToggles = 0;
  let renders = 0;
  const context = {
    ui: {
      getToolsExpanded: () => toolsExpanded,
      setToolsExpanded(value: boolean) {
        toolsExpanded = value;
        expansionToggles++;
      },
      custom<T>(factory: Function): Promise<T> {
        return new Promise<T>((done) => {
          component = factory(
            { requestRender: () => renders++ },
            theme,
            {
              matches: (data: string, action: string) =>
                data === "\x0f" && action === "app.tools.expand",
            },
            done,
          );
        });
      },
    },
  } as unknown as ExtensionContext;

  const decision = requestManualReview(context, summary);
  assert(component);
  const rendered = component.render(80).join("\n");
  assert(rendered.includes("\x1b[48;2;15;31;26m"));
  assert(rendered.includes(summary.path));
  assert(rendered.includes(summary.justification));

  for (const key of keys) component.handleInput?.(key);
  if (keys.some((key) => key === "\x1b[A" || key === "\x1b[B")) {
    assert(renders > 0);
  }
  if (keys.includes("\x0f")) {
    assert.equal(expansionToggles, 1);
    assert.equal(toolsExpanded, true);
  }
  return decision;
}

assert.equal(await choose(["y"]), "accept");
assert.equal(await choose(["n"]), "reject");
assert.equal(await choose(["t"]), "talk");
assert.equal(await choose(["\x1b"]), "talk");
assert.equal(await choose(["\x1b[B", "\r"]), "reject");
assert.equal(await choose(["\x0f", "t"]), "talk");

console.log("neovim-diff-preview-review-ui-spec-ok");
