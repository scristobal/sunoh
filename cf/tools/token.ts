#!/usr/bin/env node
// Declare service credentials in Terraform and display the explicitly selected pair.

import { spawnSync } from "node:child_process";
import { readFile, rename, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));

export function validateTokenName(name: string | undefined): asserts name is string {
  if (!name || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(name))
    throw new Error("Token name must be one safe filename segment (up to 80 characters).");
}

export async function declareToken(path: string, name: string, hours: number) {
  validateTokenName(name);
  if (!Number.isSafeInteger(hours) || hours < 1 || hours > 8760)
    throw new Error("Lifetime must be a whole number of hours between 1 and 8760.");

  const configuration = JSON.parse(await readFile(path, "utf8"));
  if (Object.hasOwn(configuration.service_tokens, name))
    throw new Error("This service token is already declared. Edit its Terraform declaration to change it.");
  configuration.service_tokens[name] = { duration: `${hours}h` };
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, JSON.stringify(configuration, null, 2) + "\n", { flag: "wx" });
  await rename(temporary, path);
}

interface Credential {
  account_id: string;
  id: string;
  client_id: string;
  client_secret?: string;
  expires_at: string;
}

export function chooseCredential(current: Credential) {
  if (!current.client_secret)
    throw new Error("Terraform has no secret for this token. Replace the token through Terraform.");
  const expiry = Date.parse(current.expires_at);
  if (!Number.isFinite(expiry) || expiry <= Date.now())
    throw new Error("This service token is expired or has an invalid expiry.");
  return { client_id: current.client_id, client_secret: current.client_secret };
}

async function main() {
  const [action, name, hours = "720"] = process.argv.slice(2);
  validateTokenName(name);
  if (action === "create") {
    await declareToken(resolve(root, "infra/tokens.auto.tfvars.json"), name, Number(hours));
    console.log("Declared the token. Run just terraform plan, review it, then just terraform apply.");
    return;
  }
  if (action !== "show") throw new Error("Choose create or show.");

  const result = spawnSync(process.execPath, [
    resolve(root, "tools/infrastructure.ts"), "run", "output", "-json", "service_tokens",
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1024 * 1024 });
  if (result.status !== 0) throw new Error("Cannot read Terraform service tokens; initialize the backend first.");
  const current = JSON.parse(result.stdout)[name] as Credential | undefined;
  if (!current) throw new Error("Token is not present in Terraform state. Apply its declaration first.");
  const credential = chooseCredential(current);
  console.log(`CF-Access-Client-Id: ${credential.client_id}`);
  console.log(`CF-Access-Client-Secret: ${credential.client_secret}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error((error as Error).message);
    process.exitCode = 1;
  });
}
