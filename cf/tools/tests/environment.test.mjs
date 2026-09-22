import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { environment, readRuntimeEnvironment, warnUnknownEnvironment } from "../environment.ts";

async function fixture(t, source) {
  const directory = await mkdtemp(join(tmpdir(), "sunoh-environment-"));
  const path = join(directory, ".env");
  t.after(() => rm(directory, { recursive: true, force: true }));

  if (source !== undefined)
    await writeFile(path, source);

  const warnings = t.mock.method(console, "warn", () => {});
  const stdout = t.mock.method(console, "log", () => {});
  return { path, directory, warnings, stdout };
}

test("known variables from the full contract do not warn", async (t) => {
  const source = Object.keys(environment).map((name) => `${name}=`).join("\n");
  const { path, warnings } = await fixture(t, source);

  warnUnknownEnvironment(path);

  assert.equal(warnings.mock.callCount(), 0);
});

test("unknown names warn once without values or file changes", async (t) => {
  const source = [
    "UNDECLARED_Z=secret-one",
    "UNDECLARED_A=secret-two",
    "UNDECLARED_Z=secret-three",
  ].join("\n");
  const { path, warnings, stdout } = await fixture(t, source);

  assert.doesNotThrow(() => warnUnknownEnvironment(path));

  assert.equal(warnings.mock.callCount(), 1);
  const message = warnings.mock.calls[0].arguments[0];
  assert.match(message, /Warning:/);
  assert.ok(message.includes(path));
  assert.match(message, /UNDECLARED_A, UNDECLARED_Z$/);
  assert.doesNotMatch(message, /secret/);
  assert.equal(stdout.mock.callCount(), 0);
  assert.equal(await readFile(path, "utf8"), source);
});

test("dotenv exports, quotes, comments and multiline values are parsed", async (t) => {
  const source = [
    "# COMMENTED_NAME=ignored",
    'PORT="8787" # INLINE_COMMENT=ignored',
    'R2_SECRET_ACCESS_KEY="first line',
    'NOT_A_VARIABLE=inside the value"',
    "export UNDECLARED_EXPORTED = 'secret # literal'",
  ].join("\r\n");
  const { path, warnings } = await fixture(t, source);

  warnUnknownEnvironment(path);

  assert.equal(warnings.mock.callCount(), 1);
  const message = warnings.mock.calls[0].arguments[0];
  assert.match(message, /contract: UNDECLARED_EXPORTED$/);
  assert.doesNotMatch(message, /COMMENTED_NAME|INLINE_COMMENT|NOT_A_VARIABLE|secret/);
});

test("prototype properties are not accepted as declared names", async (t) => {
  const { path, warnings } = await fixture(t, "constructor=secret\n");

  warnUnknownEnvironment(path);

  assert.equal(warnings.mock.callCount(), 1);
  assert.match(warnings.mock.calls[0].arguments[0], /contract: constructor$/);
});

test("inherited shell variables are not checked", async (t) => {
  const { path, warnings } = await fixture(t, "# empty environment file\n");
  const name = "SUNOH_UNDECLARED_TEST_SHELL_VARIABLE";
  const previous = process.env[name];
  process.env[name] = "secret";
  t.after(() => {
    if (previous === undefined) delete process.env[name];
    else process.env[name] = previous;
  });

  warnUnknownEnvironment(path);

  assert.equal(warnings.mock.callCount(), 0);
});

test("a missing environment file is allowed", async (t) => {
  const { path, warnings } = await fixture(t);

  assert.doesNotThrow(() => warnUnknownEnvironment(path));
  assert.equal(warnings.mock.callCount(), 0);
});

test("file access errors other than absence are not silently ignored", async (t) => {
  const { directory } = await fixture(t);

  assert.throws(() => warnUnknownEnvironment(directory), { code: "EISDIR" });
});


test("relative runtime paths stay anchored at the repository root from a workspace", () => {
  const expected = resolve(fileURLToPath(new URL("../", import.meta.url)));
  assert.equal(readRuntimeEnvironment({ RUNTIME_PATH: "tools" }).RUNTIME_PATH, expected);
});
