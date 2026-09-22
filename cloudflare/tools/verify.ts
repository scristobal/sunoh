#!/usr/bin/env node
// Verify a published release without downloading its map or asset bodies.

import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";

import {
  readImportEnvironment,
  readPublishEnvironment,
} from "./environment.ts";
import {
  cloudStorage,
  localStorage,
  type Storage,
} from "./publish.ts";

const RELEASES_PREFIX = "releases";
const RELEASE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

interface ManifestFile {
  bytes: number;
  sha256: string;
}

interface Manifest {
  files: Record<string, ManifestFile>;
}

async function packageFiles(directory: string, prefix = ""): Promise<string[]> {
  const files = [];

  for (
    const entry of await readdir(
      join(directory, prefix),
      { withFileTypes: true }
    )
  ) {
    const name = prefix + entry.name;

    if (entry.isDirectory())
      files.push(...await packageFiles(directory, name + "/"));
    else if (entry.isFile() && name !== "manifest.json")
      files.push(name);
  }

  return files;
}

async function readManifest(directory: string) {
  const bytes = await readFile(join(directory, "manifest.json"));
  let manifest: Manifest;

  try {
    manifest = JSON.parse(bytes.toString("utf8")) as Manifest;
  } catch {
    throw new Error("manifest.json is not valid JSON");
  }

  if (!manifest.files || typeof manifest.files !== "object")
    throw new Error("Manifest does not contain a files object");

  const actual = (await packageFiles(directory)).sort();
  const declared = Object.keys(manifest.files).sort();

  if (actual.join("\n") !== declared.join("\n"))
    throw new Error("Package files do not exactly match manifest.json");

  for (const name of declared) {
    if (name.startsWith("/") || name.includes("..") || name.includes("\\"))
      throw new Error(`Unsafe manifest path: ${name}`);

    const expected = manifest.files[name];

    if (
      !Number.isSafeInteger(expected.bytes) ||
      expected.bytes < 0 ||
      !/^[a-f0-9]{64}$/i.test(expected.sha256)
    ) {
      throw new Error(`Invalid manifest entry for ${name}`);
    }

    expected.sha256 = expected.sha256.toLowerCase();
    const details = await stat(join(directory, name));

    if (details.size !== expected.bytes) {
      throw new Error(
        `Size mismatch for ${name}: ${details.size}, expected ${expected.bytes}`
      );
    }
  }

  return { bytes, manifest };
}

function matches(
  object: { bytes: number; sha256?: string },
  expected: ManifestFile
) {
  return object.bytes === expected.bytes &&
    object.sha256?.toLowerCase() === expected.sha256;
}

async function verifyLocalFile(
  path: string,
  name: string,
  expected: ManifestFile
) {
  const initial = await stat(path);
  const hash = createHash("sha256");
  const source = createReadStream(path);
  let bytes = 0;

  console.log(`Hashing local ${name}: ${expected.bytes} bytes`);

  for await (const chunk of source) {
    bytes += chunk.length;
    hash.update(chunk);
  }

  const current = await stat(path);

  if (
    initial.size !== current.size ||
    initial.mtimeMs !== current.mtimeMs ||
    initial.ctimeMs !== current.ctimeMs
  ) {
    throw new Error(`File changed while hashing ${name}`);
  }

  if (bytes !== expected.bytes)
    throw new Error(`Size changed while hashing ${name}`);

  const digest = hash.digest("hex");

  if (digest !== expected.sha256)
    throw new Error(`SHA-256 mismatch for ${name}: ${digest}`);

  console.log(`Verified local ${name}`);
}

async function verify(
  storage: Storage,
  directory: string,
  releaseId: string
) {
  if (!RELEASE_ID_PATTERN.test(releaseId)) {
    throw new Error(
      "Release ID must start with a letter or number and contain only " +
      "letters, numbers, periods, underscores and hyphens"
    );
  }

  const { bytes: manifestBytes, manifest } = await readManifest(directory);
  const prefix = `${RELEASES_PREFIX}/${releaseId}`;
  const manifestHash = createHash("sha256").update(manifestBytes).digest("hex");
  const expectedObjects = {
    ...manifest.files,
    "manifest.json": {
      bytes: manifestBytes.length,
      sha256: manifestHash,
    },
  };
  const remoteManifestBytes = await storage.read(`${prefix}/manifest.json`);

  if (!remoteManifestBytes)
    throw new Error(`Published manifest has no body: ${prefix}/manifest.json`);

  if (!remoteManifestBytes.equals(manifestBytes))
    throw new Error("Published manifest does not match local manifest.json");

  for (const [name, expected] of Object.entries(manifest.files))
    await verifyLocalFile(join(directory, name), name, expected);

  const actualKeys = await storage.list(`${prefix}/`);
  const expectedKeys = Object.keys(expectedObjects)
    .map((name) => `${prefix}/${name}`)
    .sort();

  if (actualKeys.join("\n") !== expectedKeys.join("\n"))
    throw new Error("Published objects do not exactly match the local package");

  for (const [name, expected] of Object.entries(manifest.files)) {
    const object = await storage.head(`${prefix}/${name}`);

    if (!object || !matches(object, expected))
      throw new Error(`Published size or SHA-256 metadata mismatch for ${name}`);
  }

  const confirmedManifestBytes = await storage.read(`${prefix}/manifest.json`);
  const confirmedManifest = await storage.head(`${prefix}/manifest.json`);

  if (
    !confirmedManifestBytes?.equals(manifestBytes) ||
    !confirmedManifest ||
    !matches(confirmedManifest, expectedObjects["manifest.json"])
  ) {
    throw new Error(
      "Published manifest content, size or SHA-256 metadata does not match"
    );
  }

  console.log(
    `Verified local package against R2 bucket ${storage.bucket} at ${prefix}.`
  );
}

async function run(local: boolean, releaseId: string) {
  if (local) {
    const environment = readImportEnvironment();
    const storage = await localStorage(
      environment.RUNTIME_PATH,
      environment.R2_BUCKET
    );

    try {
      await verify(storage, environment.PACKAGE_PATH, releaseId);
    } finally {
      await storage.close();
    }

    return;
  }

  const environment = readPublishEnvironment();
  const storage = cloudStorage(environment);

  try {
    await verify(storage, environment.PACKAGE_PATH, releaseId);
  } finally {
    await storage.close();
  }
}

try {
  const { values } = parseArgs({
    options: {
      "release-id": { type: "string" },
      local: { type: "boolean", default: false },
    }
  });

  if (!values["release-id"])
    throw new Error("Release ID is required");

  await run(values.local, values["release-id"]);
} catch (error) {
  console.error((error as Error).message);
  process.exitCode = 1;
}
