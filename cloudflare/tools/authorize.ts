#!/usr/bin/env node
// Validate and save bucket-scoped credentials entered by the authorize recipe.

import { readR2Credentials } from "./environment.ts";
import { saveEnvironment } from "./settings.ts";

try {
  const environment = readR2Credentials();

  await saveEnvironment({
    R2_ACCESS_KEY_ID: environment.R2_ACCESS_KEY_ID,
    R2_SECRET_ACCESS_KEY: environment.R2_SECRET_ACCESS_KEY,
  });

  console.log("Saved R2 publication credentials.");
} catch (error) {
  console.error((error as Error).message);
  process.exitCode = 1;
}
