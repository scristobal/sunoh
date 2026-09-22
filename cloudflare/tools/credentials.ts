#!/usr/bin/env node
// Verify and save one account API token for Terraform and its S3 backend.

import { readCloudEnvironment } from "./environment.ts";
import { saveEnvironment } from "./settings.ts";

try {
  const environment = readCloudEnvironment();
  const token = environment.CLOUDFLARE_API_TOKEN;
  if (!token || !/^[A-Za-z0-9_-]+$/.test(token))
    throw new Error("Enter a nonempty API token without whitespace.");

  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${environment.CLOUDFLARE_ACCOUNT_ID}/tokens/verify`,
    {
      headers: { Authorization: `Bearer ${token}` },
      redirect: "error",
      signal: AbortSignal.timeout(30_000),
    }
  );
  const body = await response.json() as { success?: boolean; result?: { id?: string; status?: string } };
  if (!response.ok || !body.success || body.result?.status !== "active" || !/^[a-f0-9]{32}$/.test(body.result?.id ?? ""))
    throw new Error("Cloudflare could not verify an active account API token. Nothing was saved.");

  await saveEnvironment({ CLOUDFLARE_API_TOKEN: token, CLOUDFLARE_API_TOKEN_ID: body.result!.id! });
  console.log("Saved the Terraform account token in the ignored, owner-readable .env file.");
} catch (error) {
  console.error(error instanceof Error && !error.message.includes("fetch") ? error.message : "Could not verify and save the Terraform token.");
  process.exitCode = 1;
}
