#!/usr/bin/env node
// Write validated, non-secret selections to the ignored project environment.

import { parseArgs } from "node:util";

import {
  readCloudEnvironment,
  readPackageEnvironment,
  readRuntimeEnvironment,
} from "./environment.ts";
import { saveEnvironment } from "./settings.ts";

async function configure() {
  const { values } = parseArgs({
    options: {
      account: { type: "string" },
      "r2-location": { type: "string" },
      "package-path": { type: "string" },
      "runtime-path": { type: "string" },
    }
  });
  const cloud =
    values.account !== undefined || values["r2-location"] !== undefined;
  const packagePath = values["package-path"];
  const runtimePath = values["runtime-path"];

  const selections = [
    cloud,
    packagePath !== undefined,
    runtimePath !== undefined,
  ];

  if (selections.filter(Boolean).length !== 1)
    throw new Error("Configure exactly one cloud, package or runtime setting");

  if (cloud) {
    const environment = readCloudEnvironment({
      ...process.env,
      ...(values.account ? { CLOUDFLARE_ACCOUNT_ID: values.account } : {}),
      ...(values["r2-location"]
        ? { R2_LOCATION: values["r2-location"] }
        : {}),
    });

    await saveEnvironment({
      CLOUDFLARE_ACCOUNT_ID: environment.CLOUDFLARE_ACCOUNT_ID,
      R2_BUCKET: environment.R2_BUCKET,
      R2_LOCATION: environment.R2_LOCATION,
    });

    console.log(
      `Configured Cloudflare account ${environment.CLOUDFLARE_ACCOUNT_ID}, ` +
      `R2 bucket ${environment.R2_BUCKET} and location ${environment.R2_LOCATION}.`
    );
    return;
  }

  if (packagePath !== undefined) {
    const environment = readPackageEnvironment({
      ...process.env,
      PACKAGE_PATH: packagePath,
    });

    await saveEnvironment({ PACKAGE_PATH: environment.PACKAGE_PATH });
    console.log(`Configured package path ${environment.PACKAGE_PATH}.`);
    return;
  }

  if (runtimePath === undefined)
    throw new Error("Runtime path is required");

  const environment = readRuntimeEnvironment({
    ...process.env,
    RUNTIME_PATH: runtimePath,
  });

  await saveEnvironment({ RUNTIME_PATH: environment.RUNTIME_PATH });
  console.log(`Configured runtime path ${environment.RUNTIME_PATH}.`);
}

try {
  await configure();
} catch (error) {
  console.error((error as Error).message);
  process.exitCode = 1;
}
