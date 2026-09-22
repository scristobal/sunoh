import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { checkBundle } from "../scripts/check-bundle.mjs";

const metadata = JSON.parse(readFileSync(new URL("../dist/bundle.json", import.meta.url), "utf8"));

test("the built Worker includes only source and declared runtime dependencies", () => {
  assert.ok(checkBundle(metadata) > 0);
});

test("Worker builds reject local scripts and development-only dependencies", () => {
  for (const input of ["../tools/environment.ts", "../tools/token.ts", "../node_modules/typescript/package.json"]) {
    assert.throws(() => checkBundle({
      ...metadata,
      inputs: { ...metadata.inputs, [input]: {} },
    }), /local tooling or an undeclared runtime dependency/);
  }
});
