#!/usr/bin/env node
// Pass the project's validated account and management credential to Terraform.

import { spawnSync } from "node:child_process";
import { randomUUID, createHash } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

import { readInfrastructureEnvironment } from "./environment.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const directory = resolve(root, "infra");
const stateKey = "production/terraform.tfstate";

export function assertActiveDeployment(expected: string, actual: string | undefined) {
  if (actual !== expected)
    throw new Error(
      "The active Worker deployment differs from Terraform state. " +
      "Import the active deployment before planning; do not overwrite it silently."
    );
}

async function main() {
  process.umask(0o077);
  const configuration = readInfrastructureEnvironment();
  const stateSecret = createHash("sha256").update(configuration.CLOUDFLARE_API_TOKEN).digest("hex");
  const environment: NodeJS.ProcessEnv = {
    ...process.env,
    TF_VAR_account_id: configuration.CLOUDFLARE_ACCOUNT_ID,
    TF_VAR_bucket_name: configuration.R2_BUCKET,
    TF_VAR_bucket_location: configuration.R2_LOCATION,
    TF_VAR_state_bucket_name: configuration.TF_STATE_BUCKET,
    AWS_ACCESS_KEY_ID: configuration.CLOUDFLARE_API_TOKEN_ID,
    AWS_SECRET_ACCESS_KEY: stateSecret,
  };
  // These credentials are independent of any AWS session in the parent shell.
  delete environment.AWS_SESSION_TOKEN;
  delete environment.AWS_PROFILE;

  function terraform(args: string[], capture = false) {
    const result = spawnSync("terraform", [`-chdir=${directory}`, ...args], {
      cwd: root,
      env: environment,
      encoding: "utf8",
      stdio: capture ? ["ignore", "pipe", "pipe"] : "inherit",
      maxBuffer: 16 * 1024 * 1024,
    });
    if (result.error) throw new Error("Could not start Terraform.");
    if (result.status !== 0) {
      if (capture) throw new Error("Terraform state could not be read.");
      process.exit(result.status ?? 1);
    }
    return result.stdout;
  }

  async function checkDeployment() {
    const state = JSON.parse(terraform(["show", "-json"], true));
    const deployment = state.values?.root_module?.resources?.find(
      (resource: { address: string }) => resource.address === "cloudflare_workers_deployment.tiles"
    );
    if (!deployment) throw new Error("Import the existing Worker deployment before planning.");

    const response = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${configuration.CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${encodeURIComponent(deployment.values.script_name)}/deployments`,
      {
        headers: { Authorization: `Bearer ${configuration.CLOUDFLARE_API_TOKEN}` },
        redirect: "error",
        signal: AbortSignal.timeout(30_000),
      }
    );
    if (!response.ok) throw new Error(`Cannot check the active deployment (HTTP ${response.status}).`);
    const body = await response.json() as { success: boolean; result?: { deployments?: { id: string }[] } };
    if (!body.success) throw new Error("Cloudflare could not confirm the active deployment.");
    assertActiveDeployment(deployment.values.id, body.result?.deployments?.[0]?.id);
  }

  async function backup() {
    const client = new S3Client({
      region: "auto",
      endpoint: `https://${configuration.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com`,
      forcePathStyle: true,
      credentials: {
        accessKeyId: configuration.CLOUDFLARE_API_TOKEN_ID,
        secretAccessKey: stateSecret,
      },
    });
    try {
      const current = await client.send(new GetObjectCommand({
        Bucket: configuration.TF_STATE_BUCKET,
        Key: stateKey,
      }));
      const body = await current.Body?.transformToByteArray();
      if (!body?.length) throw new Error("Empty Terraform state.");
      const key = `backups/${new Date().toISOString()}-${randomUUID()}.tfstate`;
      await client.send(new PutObjectCommand({
        Bucket: configuration.TF_STATE_BUCKET,
        Key: key,
        Body: body,
        ContentType: "application/json",
        IfNoneMatch: "*",
      }));
      console.log(`Saved private state backup: ${key}`);
    } catch {
      throw new Error("Could not back up remote Terraform state. No apply was started.");
    } finally {
      client.destroy();
    }
  }

  const [action, ...args] = process.argv.slice(2);
  switch (action) {
    case "init":
      await mkdir(directory, { recursive: true });
      await writeFile(resolve(directory, "backend.local.hcl"), [
        `bucket = ${JSON.stringify(configuration.TF_STATE_BUCKET)}`,
        `key = ${JSON.stringify(stateKey)}`,
        `endpoints = { s3 = "https://${configuration.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com" }`,
        "",
      ].join("\n"), { mode: 0o600 });
      terraform(["init", "-backend-config=backend.local.hcl", ...args]);
      break;
    case "plan":
      await rm(resolve(directory, ".terraform/production.tfplan"), { force: true });
      await checkDeployment();
      terraform(["plan", "-out=.terraform/production.tfplan", ...args]);
      break;
    case "apply":
      if (args.length) throw new Error("Apply takes no arguments; review just terraform plan first.");
      await checkDeployment();
      await backup();
      terraform(["apply", ".terraform/production.tfplan"]);
      break;
    case "audit":
      await checkDeployment();
      terraform(["plan", "-detailed-exitcode", ...args]);
      break;
    case "backup":
      await backup();
      break;
    case "run":
      terraform(args);
      break;
    default:
      throw new Error("Choose init, plan, apply, audit, backup or run.");
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error((error as Error).message);
    process.exitCode = 1;
  });
}
