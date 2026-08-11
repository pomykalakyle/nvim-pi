import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  Box,
  type Component,
  matchesKey,
  Text,
} from "@earendil-works/pi-tui";

export type ReviewDecision = "accept" | "reject" | "talk";

type ReviewSummary = {
  path: string;
  justification: string;
};

const OPTIONS: Array<{
  key: Parameters<typeof matchesKey>[1];
  label: string;
  value: ReviewDecision;
}> = [
  { key: "y", label: "Accept", value: "accept" },
  { key: "n", label: "Reject", value: "reject" },
  { key: "t", label: "Talk about it", value: "talk" },
];

/**
 * Present the focused decision UI for one pending manual proposal.
 * Provenance: vibed=true, reviewed=false.
 */
export function requestManualReview(
  ctx: ExtensionContext,
  summary: ReviewSummary,
): Promise<ReviewDecision> {
  return ctx.ui.custom<ReviewDecision>(/** Provenance: vibed=true, reviewed=false. */ (tui, theme, keybindings, done) => {
    let selected = 0;

    // Rebuild from state on each render so navigation updates immediately.
    const component: Component = {
      /** Provenance: vibed=true, reviewed=false. */
      render(width: number): string[] {
        const box = new Box(1, 1, /** Provenance: vibed=true, reviewed=false. */ (text) => theme.bg("toolPendingBg", text));
        const lines = [
          theme.fg("accent", theme.bold("Manual Review")),
          `${theme.fg("muted", "File:")} ${summary.path}`,
          `${theme.fg("muted", "Why:")} ${summary.justification}`,
          "",
          ...OPTIONS.map(/** Provenance: vibed=true, reviewed=false. */ (option, index) => {
            const row =
              `${index === selected ? "▶" : " "} (${option.key}) ${option.label}`;
            return index === selected ? theme.fg("accent", row) : row;
          }),
          "",
          theme.fg("dim", "↑/↓ move · enter confirm · esc talk"),
        ];
        box.addChild(new Text(lines.join("\n"), 0, 0));
        return box.render(width);
      },
      /** Provenance: vibed=true, reviewed=false. */
      handleInput(data: string): void {
        // Keep Pi's normal tool-detail toggle available while review owns focus.
        if (keybindings.matches(data, "app.tools.expand")) {
          ctx.ui.setToolsExpanded(!ctx.ui.getToolsExpanded());
          return;
        }

        // Letter shortcuts commit only while this component owns keyboard focus.
        const direct = OPTIONS.find(/** Provenance: vibed=true, reviewed=false. */ (option) => matchesKey(data, option.key));
        if (direct) return done(direct.value);
        if (matchesKey(data, "escape")) return done("talk");
        if (matchesKey(data, "enter")) return done(OPTIONS[selected]!.value);
        if (matchesKey(data, "up")) {
          selected = (selected + OPTIONS.length - 1) % OPTIONS.length;
        } else if (matchesKey(data, "down")) {
          selected = (selected + 1) % OPTIONS.length;
        }
        else return;
        tui.requestRender();
      },
      /** Provenance: vibed=true, reviewed=false. */
      invalidate(): void {},
    };
    return component;
  });
}
