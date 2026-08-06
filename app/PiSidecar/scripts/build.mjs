import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const releaseRoot = path.resolve(packageRoot, "../ReleaseInputs");
const output = path.join(releaseRoot, "ctox-pi-sidecar.mjs");
const metafilePath = path.join(releaseRoot, "ctox-pi-sidecar.metafile.json");
const lockfile = JSON.parse(await readFile(path.join(packageRoot, "package-lock.json"), "utf8"));

await mkdir(releaseRoot, { recursive: true });
const result = await build({
  entryPoints: [path.join(packageRoot, "src/index.ts")],
  outfile: output,
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  sourcemap: false,
  sourcesContent: false,
  legalComments: "eof",
  metafile: true,
  charset: "utf8",
  logLevel: "warning",
  banner: { js: "import { createRequire as __workjetCreateRequire } from 'node:module'; const require = __workjetCreateRequire(import.meta.url); // Workjet Pi sidecar; @earendil-works/pi-agent-core 0.80.2; generated, do not edit." },
  plugins: [{
    name: "narrow-pi-ai-compat",
    setup(buildApi) {
      buildApi.onResolve({ filter: /^@earendil-works\/pi-agent-core$/ }, () => ({
        path: path.join(packageRoot, "node_modules/@earendil-works/pi-agent-core/dist/agent-loop.js"),
      }));
      buildApi.onResolve({ filter: /^@earendil-works\/pi-ai\/compat$/ }, () => ({
        path: path.join(packageRoot, "src/pi-ai-compat-shim.ts"),
      }));
    },
  }],
});
await writeFile(metafilePath, `${JSON.stringify(result.metafile, null, 2)}\n`);
const bytes = await readFile(output);
const hash = createHash("sha256").update(bytes).digest("hex");
await writeFile(path.join(releaseRoot, "ctox-pi-sidecar.sha256"), `${hash}  ctox-pi-sidecar.mjs\n`);
const bundledInputs = new Map();
const externalImports = new Set();
for (const input of Object.keys(result.metafile.inputs)) {
  const marker = "node_modules/";
  const index = input.lastIndexOf(marker);
  if (index < 0) continue;
  const parts = input.slice(index + marker.length).split("/");
  const name = parts[0].startsWith("@") ? `${parts[0]}/${parts[1]}` : parts[0];
  bundledInputs.set(name, (bundledInputs.get(name) ?? 0) + 1);
}
for (const input of Object.values(result.metafile.inputs)) {
  for (const imported of input.imports ?? []) if (imported.external) externalImports.add(imported.path);
}
const allowedLicenses = new Set(["MIT", "Apache-2.0", "ISC", "BSD-2-Clause", "BSD-3-Clause"]);
const inventory = [];
for (const [name, bundledInputCount] of [...bundledInputs].sort(([left], [right]) => left.localeCompare(right))) {
  const installed = JSON.parse(await readFile(path.join(packageRoot, "node_modules", ...name.split("/"), "package.json"), "utf8"));
  const locked = lockfile.packages[`node_modules/${name}`];
  if (!locked?.resolved || !locked?.integrity) throw new Error(`missing lock provenance for bundled package ${name}`);
  if (!allowedLicenses.has(installed.license)) throw new Error(`unknown or disallowed license for ${name}: ${installed.license}`);
  inventory.push({
    name,
    version: installed.version,
    license: installed.license,
    repository: typeof installed.repository === "string" ? installed.repository : installed.repository?.url ?? null,
    resolved: locked.resolved,
    integrity: locked.integrity,
    bundledInputCount,
  });
}
await writeFile(path.join(releaseRoot, "ctox-pi-sidecar.licenses.json"), `${JSON.stringify({ schema: 1, generatedFrom: ["PiSidecar/package-lock.json", "ctox-pi-sidecar.metafile.json"], packages: inventory }, null, 2)}\n`);
await writeFile(path.join(releaseRoot, "README.md"), `# CTOX Pi sidecar release input\n\nGenerated only from the reviewable source in \`app/PiSidecar\` using npm's integrity-locked clean install and esbuild 0.28.1.\n\n- Pi upstream: https://github.com/earendil-works/pi\n- Pi version: 0.80.2\n- Upstream tag commit: \`0201806adfa825ab3d7957a4267d46e5030fd357\`\n- npm publish gitHead: \`ec6311beb5b24fc918e5031173608447582d7262\`\n- Bundle SHA-256: \`${hash}\`\n- Bundled packages: ${inventory.map((item) => `\`${item.name}@${item.version}\``).join(", ")}\n- External Node built-ins: ${[...externalImports].sort().map((name) => `\`${name}\``).join(", ")}\n\nVerify with \`shasum -a 256 -c ctox-pi-sidecar.sha256\` from this directory. The metafile and license inventory are retained as audit evidence.\n`);
console.log(`${hash}  ${output}`);
