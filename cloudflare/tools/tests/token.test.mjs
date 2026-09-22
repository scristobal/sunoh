import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { chooseCredential, declareToken, validateTokenName } from "../token.ts";
import { assertActiveDeployment } from "../infrastructure.ts";

test("declaration preserves other tokens and refuses overwriting or invalid input", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "sunoh-terraform-token-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "tokens.json");
  await writeFile(path, JSON.stringify({ service_tokens: { existing: { duration: "24h" } } }));
  await declareToken(path, "developer", 720);
  const expected = { service_tokens: { existing: { duration: "24h" }, developer: { duration: "720h" } } };
  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), expected);
  await assert.rejects(declareToken(path, "developer", 24));
  await assert.rejects(declareToken(path, "new", 0));
  assert.throws(() => validateTokenName("../secret"));
  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), expected);
});

test("credentials require a Terraform-managed secret and a valid future expiry", () => {
  const current = { account_id: "account", id: "token", client_id: "client", client_secret: "secret", expires_at: "2099-01-01T00:00:00Z" };
  assert.deepEqual(chooseCredential(current), { client_id: "client", client_secret: "secret" });
  assert.throws(() => chooseCredential({ ...current, client_secret: undefined }));
  assert.throws(() => chooseCredential({ ...current, expires_at: "2000-01-01T00:00:00Z" }));
  assert.throws(() => chooseCredential({ ...current, expires_at: "invalid" }));
});

test("deployment guard rejects manual deployment changes and missing active deployments", () => {
  assert.doesNotThrow(() => assertActiveDeployment("expected", "expected"));
  assert.throws(() => assertActiveDeployment("expected", "manual"));
  assert.throws(() => assertActiveDeployment("expected", undefined));
});
