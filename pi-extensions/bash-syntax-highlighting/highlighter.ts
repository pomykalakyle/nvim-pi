import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import Parser, { Query, type QueryCapture } from "tree-sitter";
import Bash from "tree-sitter-bash";

export type BashThemeColor =
  | "accent"
  | "syntaxComment"
  | "syntaxKeyword"
  | "syntaxNumber"
  | "syntaxOperator"
  | "syntaxString"
  | "syntaxType"
  | "syntaxVariable"
  | "text";

export interface BashHighlightTheme {
  fg(color: BashThemeColor, text: string): string;
}

const require = createRequire(import.meta.url);
const bashPackageDir = dirname(require.resolve("tree-sitter-bash/package.json"));
const highlightQuerySource = readFileSync(
  join(bashPackageDir, "queries", "highlights.scm"),
  "utf8",
);
const parser = new Parser();
parser.setLanguage(Bash);
const highlightQuery = new Query(Bash, highlightQuerySource);

const CAPTURE_COLORS: Readonly<Record<string, BashThemeColor>> = {
  comment: "syntaxComment",
  constant: "syntaxType",
  embedded: "syntaxVariable",
  function: "accent",
  keyword: "syntaxKeyword",
  number: "syntaxNumber",
  operator: "syntaxOperator",
  property: "syntaxVariable",
  string: "syntaxString",
};

type StyledCapture = {
  start: number;
  end: number;
  color: BashThemeColor;
};

/** Provenance: vibed=true, reviewed=false. */
function styledCaptures(captures: QueryCapture[]): StyledCapture[] {
  return captures.flatMap(/** Provenance: vibed=true, reviewed=false. */ (capture) => {
    const color = CAPTURE_COLORS[capture.name];
    if (!color || capture.node.startIndex === capture.node.endIndex) return [];
    return [
      {
        start: capture.node.startIndex,
        end: capture.node.endIndex,
        color,
      },
    ];
  });
}

/**
 * Prefer the smallest capture so nested variables retain their own color inside strings.
 * Provenance: vibed=true, reviewed=false.
 */
function captureForRange(
  captures: StyledCapture[],
  start: number,
  end: number,
): StyledCapture | undefined {
  return captures
    .filter(/** Provenance: vibed=true, reviewed=false. */ (capture) => capture.start <= start && capture.end >= end)
    .sort(/** Provenance: vibed=true, reviewed=false. */ (left, right) => left.end - left.start - (right.end - right.start))[0];
}

/**
 * Highlight Bash using tree-sitter-bash's bundled, command-aware standard query.
 * Provenance: vibed=true, reviewed=false.
 */
export function highlightBashCommand(
  command: string,
  theme: BashHighlightTheme,
): string {
  if (!command) return "";

  try {
    const tree = parser.parse(command);
    const captures = styledCaptures(highlightQuery.captures(tree.rootNode));
    const boundaries = [
      0,
      command.length,
      ...captures.flatMap(/** Provenance: vibed=true, reviewed=false. */ (capture) => [capture.start, capture.end]),
    ]
      .filter(/** Provenance: vibed=true, reviewed=false. */ (index) => index >= 0 && index <= command.length)
      .sort(/** Provenance: vibed=true, reviewed=false. */ (left, right) => left - right)
      .filter(
        /** Provenance: vibed=true, reviewed=false. */ (index, position, all) =>
          position === 0 || index !== all[position - 1],
      );

    let highlighted = "";
    for (let index = 0; index < boundaries.length - 1; index += 1) {
      const start = boundaries[index];
      const end = boundaries[index + 1];
      if (start === undefined || end === undefined || start === end) continue;
      const text = command.slice(start, end);
      const capture = captureForRange(captures, start, end);
      highlighted += theme.fg(capture?.color ?? "text", text);
    }
    return highlighted;
  } catch {
    return theme.fg("text", command);
  }
}
