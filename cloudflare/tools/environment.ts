// Executable documentation and validation for this repository's environment.

import { readFileSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";

import {
  cleanEnv,
  makeValidator,
  port,
  str,
  type ReporterOptions,
  type ValidatorSpec,
} from "envalid";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export const R2_LOCATIONS = [
  "weur",
  "eeur",
  "apac",
  "wnam",
  "enam",
  "oc",
] as const;

const directory = makeValidator<string>((input) => resolve(projectRoot, input));
const nonempty = makeValidator<string>((input) => {
  if (!input.trim()) throw new Error("must not be empty");
  return input;
});
const accountId = makeValidator<string>((input) => {
  if (!/^[a-f0-9]{32}$/i.test(input))
    throw new Error("must be a 32-character hexadecimal Cloudflare Account ID");

  return input;
});
const bucket = makeValidator<string>((input) => {
  if (!/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(input))
    throw new Error("must be a valid R2 bucket name");

  return input;
});
const releaseId = makeValidator<string>((input) => {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(input))
    throw new Error("must be one URL-safe path segment");

  return input;
});

// This object is the canonical environment-variable contract. Keep each
// variable's validation, default and documentation together here.
export const environment = {
  PACKAGE_PATH: directory({
    desc: "Existing directory containing the completed map package files",
    example: "/srv/maps/release",
    default: resolve(projectRoot, "release"),
  }),

  RUNTIME_PATH: directory({
    desc: "Existing directory containing local Wrangler state under wrangler/",
    example: "/srv/sunoh/cloudflare/runtime",
    default: resolve(projectRoot, "runtime"),
  }),

  PORT: port({
    desc: "Loopback port for the development map API",
    default: 8787,
  }),

  LOCAL_RELEASE_ID: releaseId({
    desc: "Release most recently published to local R2 and served through the local release alias",
    default: undefined,
  }),

  CLOUDFLARE_ACCOUNT_ID: accountId({
    desc: "Cloudflare account that owns the production Worker and R2 bucket",
    example: "0123456789abcdef0123456789abcdef",
  }),

  CLOUDFLARE_API_TOKEN: str({
    desc: "Cloudflare management API token for Terraform Workers, R2 and Access resources",
    default: undefined,
  }),

  CLOUDFLARE_API_TOKEN_ID: accountId({
    desc: "ID of the Terraform account API token, also used as its R2 S3 Access Key ID",
  }),

  TF_STATE_BUCKET: bucket({
    desc: "Private R2 bucket holding Terraform state, locks and backups",
    default: "sunoh-terraform-state",
  }),

  R2_LOCATION: str({
    desc: "Immutable location hint used when creating the production R2 bucket",
    choices: R2_LOCATIONS,
    default: "weur",
  }),

  R2_BUCKET: bucket({
    desc:
      "R2 bucket used by local and cloud publication; keep it aligned with " +
      "the BUCKET target declared in worker/wrangler.jsonc",
    default: "maps",
  }),

  R2_ACCESS_KEY_ID: nonempty({
    desc: "Bucket-scoped R2 S3 access key used only for map publication",
  }),

  R2_SECRET_ACCESS_KEY: nonempty({
    desc: "Bucket-scoped R2 S3 secret used only for map publication",
  }),
} as const;

// Inspect the file, not process.env: inherited shell variables are unrelated to
// the project contract. Parsing also handles exports, comments and multiline values.
export function warnUnknownEnvironment(path = resolve(projectRoot, ".env")) {
  let source: string;

  try {
    source = readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw error;
  }

  const unknown = Object.keys(parseEnv(source))
    .filter((name) => !Object.hasOwn(environment, name))
    .sort();

  if (unknown.length) {
    console.warn(
      `Warning: ${path} contains variables not defined in the environment ` +
      `contract: ${unknown.join(", ")}`
    );
  }
}

warnUnknownEnvironment();

type Specs = Record<string, ValidatorSpec<unknown>>;

function reporter<T extends Specs>({ errors }: ReporterOptions<T>) {
  const messages = Object.entries(errors).map(
    ([name, error]) => `${name}: ${(error as Error).message}`
  );

  if (messages.length)
    throw new Error(messages.join("\n"));
}

function existingDirectory(name: string, path: string) {
  if (!statSync(path, { throwIfNoEntry: false })?.isDirectory()) {
    throw new Error(
      `${name} is unavailable: ${path}. Mount the disk or create the intended directory first.`
    );
  }

  return path;
}

export function readPackageEnvironment(source = process.env) {
  const values = cleanEnv(
    source,
    { PACKAGE_PATH: environment.PACKAGE_PATH },
    { reporter }
  );

  return {
    PACKAGE_PATH: existingDirectory("PACKAGE_PATH", values.PACKAGE_PATH),
  };
}

export function readRuntimeEnvironment(source = process.env) {
  const values = cleanEnv(
    source,
    { RUNTIME_PATH: environment.RUNTIME_PATH },
    { reporter }
  );

  return {
    RUNTIME_PATH: existingDirectory("RUNTIME_PATH", values.RUNTIME_PATH),
  };
}

export function readImportEnvironment(source = process.env) {
  const packages = readPackageEnvironment(source);
  const runtime = readRuntimeEnvironment(source);
  const values = cleanEnv(
    source,
    { R2_BUCKET: environment.R2_BUCKET },
    { reporter }
  );

  return {
    PACKAGE_PATH: packages.PACKAGE_PATH,
    RUNTIME_PATH: runtime.RUNTIME_PATH,
    R2_BUCKET: values.R2_BUCKET,
  };
}

export function readServeEnvironment(source = process.env) {
  const runtime = readRuntimeEnvironment(source);
  const values = cleanEnv(
    source,
    {
      PORT: environment.PORT,
      LOCAL_RELEASE_ID: environment.LOCAL_RELEASE_ID,
    },
    { reporter }
  );

  return {
    RUNTIME_PATH: runtime.RUNTIME_PATH,
    PORT: values.PORT,
    LOCAL_RELEASE_ID: values.LOCAL_RELEASE_ID,
  };
}

export function readCloudEnvironment(source = process.env) {
  return cleanEnv(
    source,
    {
      CLOUDFLARE_ACCOUNT_ID: environment.CLOUDFLARE_ACCOUNT_ID,
      CLOUDFLARE_API_TOKEN: environment.CLOUDFLARE_API_TOKEN,
      R2_LOCATION: environment.R2_LOCATION,
      R2_BUCKET: environment.R2_BUCKET,
    },
    { reporter }
  );
}

export function readR2Credentials(source = process.env) {
  return cleanEnv(
    source,
    {
      R2_ACCESS_KEY_ID: environment.R2_ACCESS_KEY_ID,
      R2_SECRET_ACCESS_KEY: environment.R2_SECRET_ACCESS_KEY,
    },
    { reporter }
  );
}

export function readPublishStorageEnvironment(source = process.env) {
  return cleanEnv(
    source,
    {
      CLOUDFLARE_ACCOUNT_ID: environment.CLOUDFLARE_ACCOUNT_ID,
      R2_BUCKET: environment.R2_BUCKET,
      R2_ACCESS_KEY_ID: environment.R2_ACCESS_KEY_ID,
      R2_SECRET_ACCESS_KEY: environment.R2_SECRET_ACCESS_KEY,
    },
    { reporter }
  );
}

export function readPublishEnvironment(source = process.env) {
  const packages = readPackageEnvironment(source);
  const storage = readPublishStorageEnvironment(source);

  return {
    PACKAGE_PATH: packages.PACKAGE_PATH,
    CLOUDFLARE_ACCOUNT_ID: storage.CLOUDFLARE_ACCOUNT_ID,
    R2_BUCKET: storage.R2_BUCKET,
    R2_ACCESS_KEY_ID: storage.R2_ACCESS_KEY_ID,
    R2_SECRET_ACCESS_KEY: storage.R2_SECRET_ACCESS_KEY,
  };
}

export function readInfrastructureEnvironment(source = process.env) {
  const values = cleanEnv(source, {
    CLOUDFLARE_ACCOUNT_ID: environment.CLOUDFLARE_ACCOUNT_ID,
    CLOUDFLARE_API_TOKEN: nonempty({ desc: "Run just configure management first" }),
    CLOUDFLARE_API_TOKEN_ID: environment.CLOUDFLARE_API_TOKEN_ID,
    TF_STATE_BUCKET: environment.TF_STATE_BUCKET,
    R2_BUCKET: environment.R2_BUCKET,
    R2_LOCATION: environment.R2_LOCATION,
  }, { reporter });

  const wrangler = JSON.parse(readFileSync(resolve(projectRoot, "worker/wrangler.jsonc"), "utf8"));
  if (wrangler.r2_buckets?.find((binding: { binding: string }) => binding.binding === "BUCKET")?.bucket_name !== values.R2_BUCKET)
    throw new Error("R2_BUCKET must match the local BUCKET binding in worker/wrangler.jsonc.");

  return values;
}
