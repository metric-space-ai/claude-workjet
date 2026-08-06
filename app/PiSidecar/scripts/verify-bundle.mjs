import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const releaseRoot = path.resolve(packageRoot, "../ReleaseInputs");
const bundle = await readFile(path.join(releaseRoot, "ctox-pi-sidecar.mjs"), "utf8");
const forbidden = [
  ["absolute user path", /\/(?:Users|home)\/[A-Za-z0-9._-]+\//],
  ["source map trailer", /^\s*(?:\/\/|\/\*)[#@]\s*sourceMappingURL=/m],
  ["private key", /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/],
  ["AWS access key", /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
  ["GitHub token", /\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/],
  ["OpenAI-style secret", /\bsk-[A-Za-z0-9_-]{24,}\b/],
  ["native addon", /(?:^|["'`/])[^"'`\s]*\.node(?:["'`]|$)/m],
  ["TUI module", /pi-(?:coding-agent\/.*modes\/interactive|tui)/],
  ["package manager", /pi-coding-agent\/.*package-manager/],
  ["version updater", /pi-coding-agent\/.*version-check/],
];
const failures = forbidden.filter(([, pattern]) => pattern.test(bundle)).map(([name]) => name);
if (failures.length) throw new Error(`bundle policy failed: ${failures.join(", ")}`);

const metafile = JSON.parse(await readFile(path.join(releaseRoot, "ctox-pi-sidecar.metafile.json"), "utf8"));
const packageNames = new Set();
const externalImports = new Set();
for (const input of Object.keys(metafile.inputs)) {
  const marker = "node_modules/";
  const index = input.lastIndexOf(marker);
  if (index < 0) continue;
  const parts = input.slice(index + marker.length).split("/");
  packageNames.add(parts[0].startsWith("@") ? `${parts[0]}/${parts[1]}` : parts[0]);
}
for (const input of Object.values(metafile.inputs)) {
  for (const imported of input.imports ?? []) if (imported.external) externalImports.add(imported.path);
}
const allowedExternalImports = new Set(["buffer", "node:fs", "node:net", "node:path", "node:url", "process"]);
const unexpectedImports = [...externalImports].filter((name) => !allowedExternalImports.has(name));
if (unexpectedImports.length) throw new Error(`unexpected external imports: ${unexpectedImports.join(", ")}`);
const licenses = JSON.parse(await readFile(path.join(releaseRoot, "ctox-pi-sidecar.licenses.json"), "utf8"));
const licensedNames = new Set(licenses.packages.map((entry) => entry.name));
const missingLicenses = [...packageNames].filter((name) => !licensedNames.has(name));
const extraLicenses = [...licensedNames].filter((name) => !packageNames.has(name));
if (missingLicenses.length || extraLicenses.length) throw new Error(`license inventory mismatch; missing=${missingLicenses} extra=${extraLicenses}`);
console.log(`bundle_bytes=${Buffer.byteLength(bundle)} packages=${[...packageNames].sort().join(",")} builtins=${[...externalImports].sort().join(",")}`);
