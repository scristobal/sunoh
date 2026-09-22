// Validate Wrangler's actual build inputs against the Worker's runtime dependencies.
import { readFileSync, realpathSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const worker = fileURLToPath(new URL("../", import.meta.url));
const root = resolve(worker, "..");

export function checkBundle(metadata) {
  const manifest = JSON.parse(readFileSync(resolve(worker, "package.json"), "utf8"));
  const lock = JSON.parse(readFileSync(resolve(root, "package-lock.json"), "utf8"));
  const dependencies = new Set();

  function dependency(name, from) {
    for (let directory = from; directory.startsWith(root); directory = dirname(directory)) {
      const path = resolve(directory, "node_modules", name);
      const entry = lock.packages[relative(root, path)];
      if (!entry) continue;
      if (entry.link) throw new Error(`Worker runtime cannot depend on workspace ${name}.`);
      const installed = realpathSync(path);
      if (dependencies.has(installed)) return;
      dependencies.add(installed);
      for (const child of Object.keys(entry.dependencies ?? {})) dependency(child, path);
      return;
    }
    throw new Error(`Runtime dependency ${name} is missing from the lockfile.`);
  }

  for (const name of Object.keys(manifest.dependencies ?? {})) dependency(name, worker);
  const source = realpathSync(resolve(worker, "src"));
  const allowed = [source, ...dependencies];
  const inputs = Object.keys(metadata.inputs ?? {});
  if (!inputs.length) throw new Error("The Worker bundle has no recorded inputs.");

  for (const input of inputs) {
    const path = realpathSync(resolve(worker, input));
    if (!allowed.some(directory => path.startsWith(directory + sep)))
      throw new Error(`Worker bundle includes local tooling or an undeclared runtime dependency: ${input}`);
  }
  for (const output of Object.values(metadata.outputs ?? {})) {
    for (const imported of output.imports ?? []) {
      if (imported.external && !imported.path.startsWith("cloudflare:"))
        throw new Error(`Worker bundle has an unbundled dependency: ${imported.path}`);
    }
  }
  return inputs.length;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const metadata = JSON.parse(readFileSync(resolve(worker, "dist/bundle.json"), "utf8"));
  console.log(`Verified ${checkBundle(metadata)} Worker bundle inputs; local tooling is excluded.`);
}
