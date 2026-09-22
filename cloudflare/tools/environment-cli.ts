#!/usr/bin/env node
// Expose validated configuration values to Just without duplicating the schema.

import { parseArgs } from "node:util";

import {
  readCloudEnvironment,
  readServeEnvironment,
} from "./environment.ts";

function value() {
  const { values } = parseArgs({
    options: {
      scope: { type: "string" },
      name: { type: "string" },
    }
  });

  if (values.scope === "serve") {
    const environment = readServeEnvironment();

    if (values.name === "RUNTIME_PATH") return environment.RUNTIME_PATH;
    if (values.name === "PORT") return String(environment.PORT);
    if (values.name === "LOCAL_RELEASE_ID" && environment.LOCAL_RELEASE_ID)
      return environment.LOCAL_RELEASE_ID;
  }

  if (values.scope === "cloud") {
    const environment = readCloudEnvironment();

    if (values.name === "CLOUDFLARE_ACCOUNT_ID")
      return environment.CLOUDFLARE_ACCOUNT_ID;
    if (values.name === "R2_LOCATION") return environment.R2_LOCATION;
  }

  throw new Error("Pass a valid --scope and --name combination");
}

try {
  console.log(value());
} catch (error) {
  console.error((error as Error).message);
  process.exitCode = 1;
}
