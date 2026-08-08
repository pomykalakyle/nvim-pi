import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const globalRoot = execFileSync("npm", ["root", "--global"], { encoding: "utf8" }).trim();
const piRoot = join(globalRoot, "@earendil-works", "pi-coding-agent");
const jitiUrl = pathToFileURL(join(piRoot, "node_modules", "jiti", "lib", "jiti.mjs")).href;
const { createJiti } = await import(jitiUrl);
const jiti = createJiti(import.meta.url, {
  alias: {
    "@earendil-works/pi-coding-agent": join(piRoot, "dist", "index.js"),
    "@earendil-works/pi-tui": join(piRoot, "node_modules", "@earendil-works", "pi-tui", "dist", "index.js"),
    typebox: join(piRoot, "node_modules", "typebox", "build", "index.mjs"),
  },
});

for (const spec of [
  "./neovim_diff_preview_result_spec.ts",
  "./neovim_diff_preview_tools_spec.ts",
  "./neovim_diff_preview_extension_spec.ts",
]) {
  await jiti.import(spec);
}
