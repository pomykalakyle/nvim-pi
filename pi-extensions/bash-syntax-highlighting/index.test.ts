import assert from "node:assert/strict";
import test from "node:test";
import { highlightBashCommand } from "./highlighter.ts";

const theme = {
  fg(color: string, text: string) {
    return `<${color}>${text}</${color}>`;
  },
};

test("highlights command positions without treating Git subcommands as shell built-ins", () => {
  const highlighted = highlightBashCommand(
    "git status --short --branch && git log -3 --oneline",
    theme,
  );

  assert.equal(
    highlighted,
    [
      "<accent>git</accent>",
      "<text> status </text>",
      "<syntaxType>--short</syntaxType>",
      "<text> </text>",
      "<syntaxType>--branch</syntaxType>",
      "<text> </text>",
      "<syntaxOperator>&&</syntaxOperator>",
      "<text> </text>",
      "<accent>git</accent>",
      "<text> log </text>",
      "<syntaxType>-3</syntaxType>",
      "<text> </text>",
      "<syntaxType>--oneline</syntaxType>",
    ].join(""),
  );
  assert.doesNotMatch(highlighted, /<accent>log<\/accent>/);
});

test("uses the standard Bash captures for keywords, strings, variables, and comments", () => {
  const highlighted = highlightBashCommand(
    `for item in alpha; do printf '%s\\n' "$item"; done # comment`,
    theme,
  );

  assert.match(highlighted, /<syntaxKeyword>for<\/syntaxKeyword>/);
  assert.match(highlighted, /<accent>printf<\/accent>/);
  assert.match(highlighted, /<syntaxString>'%s\\n'<\/syntaxString>/);
  assert.match(highlighted, /<syntaxVariable>item<\/syntaxVariable>/);
  assert.match(highlighted, /<syntaxComment># comment<\/syntaxComment>/);
});
