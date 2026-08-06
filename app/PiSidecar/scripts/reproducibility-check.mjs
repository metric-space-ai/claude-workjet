import { createHash } from "node:crypto";
import { cp, mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tempRoot = await mkdtemp(path.join(os.tmpdir(), "workjet-pi-repro-"));
try {
  const hashes = [];
  for (const name of ["a", "b"]) {
    const packageRoot = path.join(tempRoot, name, "PiSidecar");
    await cp(sourceRoot, packageRoot, {
      recursive: true,
      filter: (source) => !source.split(path.sep).includes("node_modules"),
    });
    run("npm", ["ci", "--ignore-scripts"], packageRoot);
    run("npm", ["run", "build"], packageRoot);
    const bytes = await readFile(path.join(tempRoot, name, "ReleaseInputs/ctox-pi-sidecar.mjs"));
    hashes.push(createHash("sha256").update(bytes).digest("hex"));
  }
  if (hashes[0] !== hashes[1]) throw new Error(`clean builds differ: ${hashes.join(" != ")}`);
  console.log(`reproducible_sha256=${hashes[0]}`);
} finally {
  await rm(tempRoot, { recursive: true, force: true });
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: "utf8", stdio: "pipe" });
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed:\n${result.stdout}\n${result.stderr}`);
}
