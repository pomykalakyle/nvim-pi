import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const globalRoot = execFileSync("npm", ["root", "--global"], {
  encoding: "utf8",
}).trim();
const piRoot = join(globalRoot, "@earendil-works", "pi-coding-agent");
const jitiUrl = pathToFileURL(
  join(piRoot, "node_modules", "jiti", "lib", "jiti.mjs"),
).href;
const { createJiti } = await import(jitiUrl);
const jiti = createJiti(import.meta.url, {
  alias: {
    "@earendil-works/pi-coding-agent": join(piRoot, "dist", "index.js"),
  },
});

await jiti.import("./response_timer_extension_spec.ts");
