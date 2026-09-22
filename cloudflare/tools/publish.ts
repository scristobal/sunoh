#!/usr/bin/env node
// Publish the completed map package to local or cloud R2, with the manifest last.

import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import {
  mkdir,
  open,
  readdir,
  readFile,
  rename,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { hostname } from "node:os";
import { dirname, join, resolve } from "node:path";
import { Readable, Transform } from "node:stream";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import {
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  ListPartsCommand,
  PutObjectCommand,
  S3Client,
  UploadPartCommand,
} from "@aws-sdk/client-s3";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import type { R2UploadedPart } from "@cloudflare/workers-types";

import {
  readImportEnvironment,
  readPublishEnvironment,
  readPublishStorageEnvironment,
} from "./environment.ts";
import { saveEnvironment } from "./settings.ts";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const publicationStateDirectory = join(projectRoot, ".publish");
const multipartStatePath = join(publicationStateDirectory, "multipart.json");
const publicationLockPath = join(publicationStateDirectory, "lock.json");

const RELEASES_PREFIX = "releases";
const RELEASE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const DEFAULT_PART_SIZE_MIB = 4096;
const MAX_PART_SIZE_MIB = 5115;
const DEFAULT_CONCURRENCY = 4;
const MAX_CONCURRENCY = 16;
const MULTIPART_THRESHOLD = 64 * 1024 * 1024;

interface ManifestFile {
  bytes: number;
  sha256: string;
}

interface Manifest {
  files: Record<string, ManifestFile>;
}

interface StoredObject {
  bytes: number;
  sha256?: string;
}

type UploadBody = Buffer | Transform;

export interface Storage {
  bucket: string;
  head(key: string): Promise<StoredObject | undefined>;
  read(key: string): Promise<Buffer | undefined>;
  list(prefix: string): Promise<string[]>;
  put(
    key: string,
    body: UploadBody,
    length: number,
    type: string,
    sha256: string
  ): Promise<void>;
  createMultipart(
    key: string,
    type: string,
    sha256: string
  ): Promise<string>;
  listParts?(
    key: string,
    uploadId: string
  ): Promise<Map<number, RemotePart>>;
  uploadPart(
    key: string,
    uploadId: string,
    part: number,
    body: Transform,
    length: number
  ): Promise<string>;
  completeMultipart(
    key: string,
    uploadId: string,
    parts: { etag: string; part: number }[]
  ): Promise<void>;
  abortMultipart(key: string, uploadId: string): Promise<void>;
  close(): Promise<void>;
}

export interface StorageEnvironment {
  CLOUDFLARE_ACCOUNT_ID: string;
  R2_BUCKET: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
}

interface MultipartIdentity {
  account: string;
  bucket: string;
  key: string;
  path: string;
  bytes: number;
  sha256: string;
  partSize: number;
}

interface MultipartState extends MultipartIdentity {
  version: 1;
  uploadId: string;
  parts: Record<string, string>;
}

interface RemotePart {
  etag: string;
  size: number;
}

interface VerifiedMultipart {
  partHashes: string[];
}

function fileError(error: unknown, code: string) {
  return (error as NodeJS.ErrnoException).code === code;
}

async function writeJson(path: string, value: unknown) {
  await mkdir(publicationStateDirectory, { recursive: true, mode: 0o700 });

  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;

  try {
    await writeFile(temporary, JSON.stringify(value, null, 2) + "\n", {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(temporary, path);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
}

async function removeFile(path: string) {
  await unlink(path).catch((error) => {
    if (!fileError(error, "ENOENT")) throw error;
  });
}

function validMultipartState(value: unknown): value is MultipartState {
  if (!value || typeof value !== "object") return false;

  const state = value as Partial<MultipartState>;

  return state.version === 1 &&
    typeof state.account === "string" &&
    typeof state.bucket === "string" &&
    typeof state.key === "string" &&
    typeof state.path === "string" &&
    Number.isSafeInteger(state.bytes) &&
    state.bytes! >= 0 &&
    typeof state.sha256 === "string" &&
    /^[a-f0-9]{64}$/.test(state.sha256) &&
    Number.isSafeInteger(state.partSize) &&
    state.partSize! > 0 &&
    typeof state.uploadId === "string" &&
    state.uploadId.length > 0 &&
    !!state.parts &&
    typeof state.parts === "object" &&
    Object.entries(state.parts).every(([part, etag]) =>
      /^[1-9]\d{0,3}$|^10000$/.test(part) &&
      typeof etag === "string" &&
      etag.length > 0
    );
}

async function readMultipartState() {
  let source: string;

  try {
    source = await readFile(multipartStatePath, "utf8");
  } catch (error) {
    if (fileError(error, "ENOENT")) return undefined;
    throw error;
  }

  let value: unknown;

  try {
    value = JSON.parse(source);
  } catch {
    throw new Error(`Invalid multipart checkpoint: ${multipartStatePath}`);
  }

  if (!validMultipartState(value))
    throw new Error(`Invalid multipart checkpoint: ${multipartStatePath}`);

  return value;
}

async function writeMultipartState(state: MultipartState) {
  await writeJson(multipartStatePath, state);
}

async function removeMultipartState() {
  await removeFile(multipartStatePath);
}

function processIsRunning(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return !fileError(error, "ESRCH");
  }
}

async function acquirePublicationLock() {
  await mkdir(publicationStateDirectory, { recursive: true, mode: 0o700 });

  while (true) {
    const token = randomUUID();

    try {
      const handle = await open(publicationLockPath, "wx", 0o600);

      try {
        await handle.writeFile(JSON.stringify({
          hostname: hostname(),
          pid: process.pid,
          token,
        }) + "\n");
      } finally {
        await handle.close();
      }

      return token;
    } catch (error) {
      if (!fileError(error, "EEXIST")) throw error;
    }

    let lock: { hostname?: unknown; pid?: unknown };

    try {
      lock = JSON.parse(await readFile(publicationLockPath, "utf8"));
    } catch (error) {
      if (fileError(error, "ENOENT")) continue;
      throw new Error(`Invalid publication lock: ${publicationLockPath}`);
    }

    if (
      lock.hostname === hostname() &&
      Number.isSafeInteger(lock.pid) &&
      !processIsRunning(lock.pid as number)
    ) {
      await removeFile(publicationLockPath);
      continue;
    }

    throw new Error(
      `Another publication holds ${publicationLockPath} ` +
      `(host ${String(lock.hostname)}, process ${String(lock.pid)})`
    );
  }
}

async function releasePublicationLock(token: string) {
  try {
    const lock = JSON.parse(await readFile(publicationLockPath, "utf8")) as {
      token?: unknown;
    };

    if (lock.token === token)
      await removeFile(publicationLockPath);
  } catch (error) {
    if (!fileError(error, "ENOENT")) throw error;
  }
}

async function withPublicationLock<T>(operation: () => Promise<T>) {
  const token = await acquirePublicationLock();

  try {
    return await operation();
  } finally {
    await releasePublicationLock(token);
  }
}

function objectType(name: string) {
  if (name.endsWith(".pmtiles")) return "application/vnd.pmtiles";
  if (name.endsWith(".json")) return "application/json";
  if (name.endsWith(".png")) return "image/png";
  if (name.endsWith(".ttf")) return "font/ttf";
  return "application/octet-stream";
}

function missing(error: unknown) {
  const candidate = error as {
    name?: string;
    $metadata?: { httpStatusCode?: number };
  };

  return candidate.name === "NotFound" ||
    candidate.name === "NoSuchKey" ||
    candidate.name === "NoSuchUpload" ||
    candidate.$metadata?.httpStatusCode === 404;
}

function matches(object: StoredObject, expected: ManifestFile) {
  return object.bytes === expected.bytes &&
    object.sha256?.toLowerCase() === expected.sha256;
}

async function putSmall(
  storage: Storage,
  path: string,
  key: string,
  expected: ManifestFile
) {
  const body = await readFile(path);
  const digest = createHash("sha256").update(body).digest("hex");

  if (body.length !== expected.bytes)
    throw new Error(`Size changed while reading ${key}`);

  if (digest !== expected.sha256)
    throw new Error(`SHA-256 mismatch for ${key}: ${digest}`);

  await storage.put(
    key,
    body,
    body.length,
    objectType(path),
    digest
  );
}

function sameMultipartIdentity(
  state: MultipartState,
  identity: MultipartIdentity
) {
  return state.account === identity.account &&
    state.bucket === identity.bucket &&
    state.key === identity.key &&
    state.path === identity.path &&
    state.bytes === identity.bytes &&
    state.sha256 === identity.sha256 &&
    state.partSize === identity.partSize;
}

function partLength(identity: MultipartIdentity, part: number) {
  const offset = (part - 1) * identity.partSize;
  return Math.min(identity.partSize, identity.bytes - offset);
}

async function verifyMultipartFile(
  path: string,
  key: string,
  expected: ManifestFile,
  partSize: number
): Promise<VerifiedMultipart> {
  console.log(`Verifying ${key} before multipart upload...`);

  const initial = await stat(path);

  if (initial.size !== expected.bytes)
    throw new Error(`Size changed before verifying ${key}`);

  const wholeHash = createHash("sha256");
  const partHashes = [];

  for (let offset = 0; offset < expected.bytes; offset += partSize) {
    const length = Math.min(partSize, expected.bytes - offset);
    const partHash = createHash("sha256");
    const source = createReadStream(path, {
      start: offset,
      end: offset + length - 1,
    });
    let bytes = 0;

    for await (const chunk of source) {
      bytes += chunk.length;
      wholeHash.update(chunk);
      partHash.update(chunk);
    }

    if (bytes !== length)
      throw new Error(`Size changed while verifying ${key}`);

    partHashes.push(partHash.digest("hex"));
  }

  const current = await stat(path);

  if (
    initial.size !== current.size ||
    initial.mtimeMs !== current.mtimeMs ||
    initial.ctimeMs !== current.ctimeMs
  ) {
    throw new Error(`File changed while verifying ${key}`);
  }

  const digest = wholeHash.digest("hex");

  if (digest !== expected.sha256)
    throw new Error(`SHA-256 mismatch for ${key}: ${digest}`);

  console.log(`Verified ${key}: ${expected.sha256}`);
  return { partHashes };
}

async function listRemoteParts(
  storage: Storage,
  key: string,
  uploadId: string
) {
  return storage.listParts
    ? await storage.listParts(key, uploadId)
    : undefined;
}

class MultipartCheckpoint {
  private queue = Promise.resolve();
  private state: MultipartState;

  constructor(state: MultipartState) {
    this.state = state;
  }

  record(part: number, etag: string) {
    const saved = this.queue.then(async () => {
      this.state.parts[String(part)] = etag;
      await writeMultipartState(this.state);
    });

    this.queue = saved.catch(() => undefined);
    return saved;
  }
}

async function createMultipartState(
  storage: Storage,
  identity: MultipartIdentity,
  path: string
) {
  const uploadId = await storage.createMultipart(
    identity.key,
    objectType(path),
    identity.sha256
  );

  const state: MultipartState = {
    version: 1,
    ...identity,
    uploadId,
    parts: {},
  };

  try {
    await writeMultipartState(state);
  } catch (error) {
    try {
      await storage.abortMultipart(identity.key, uploadId);
    } catch (abortError) {
      console.error(
        `Could not abort uncheckpointed upload ${uploadId}: ` +
        `${(abortError as Error).message}`
      );
    }

    throw error;
  }

  console.log(`Started resumable multipart upload for ${identity.key}.`);
  return state;
}

async function prepareMultipart(
  storage: Storage,
  identity: MultipartIdentity,
  path: string
) {
  let state = await readMultipartState();
  let remote: Map<number, RemotePart> | undefined;

  if (state && !sameMultipartIdentity(state, identity)) {
    throw new Error(
      `Multipart checkpoint belongs to ${state.key}. ` +
      "Resume its exact publication or run just package abort cloud."
    );
  }

  if (state) {
    try {
      remote = await listRemoteParts(storage, state.key, state.uploadId);
    } catch (error) {
      if (!missing(error)) throw error;

      console.log(`Saved multipart upload no longer exists for ${state.key}.`);
      await removeMultipartState();
      state = undefined;
    }
  }

  if (!state)
    state = await createMultipartState(storage, identity, path);

  const count = Math.ceil(identity.bytes / identity.partSize);
  const completed = new Map<number, string>();
  let reconciled = false;

  for (const [number, etag] of Object.entries(state.parts)) {
    const part = Number(number);
    const existing = remote?.get(part);

    if (
      part <= count &&
      (!remote || (
        existing?.etag === etag &&
        existing.size === partLength(identity, part)
      ))
    ) {
      completed.set(part, etag);
    } else {
      delete state.parts[number];
      reconciled = true;
    }
  }

  if (reconciled)
    await writeMultipartState(state);

  if (completed.size)
    console.log(`Resuming ${identity.key}: ${completed.size}/${count} parts verified.`);

  return {
    checkpoint: new MultipartCheckpoint(state),
    completed,
    uploadId: state.uploadId,
  };
}

async function uploadMultipartPart(
  storage: Storage,
  identity: MultipartIdentity,
  path: string,
  uploadId: string,
  checkpoint: MultipartCheckpoint,
  expectedHash: string,
  part: number
) {
  const offset = (part - 1) * identity.partSize;
  const length = partLength(identity, part);
  const source = createReadStream(path, {
    start: offset,
    end: offset + length - 1,
  });
  const hash = createHash("sha256");
  const body = new Transform({
    transform(chunk, _encoding, callback) {
      hash.update(chunk);
      callback(null, chunk);
    }
  });

  source.on("error", (error) => body.destroy(error));
  source.pipe(body);

  let etag: string;

  try {
    etag = await storage.uploadPart(
      identity.key,
      uploadId,
      part,
      body,
      length
    );
  } finally {
    source.destroy();
    body.destroy();
  }

  const digest = hash.digest("hex");

  if (digest !== expectedHash)
    throw new Error(`File changed while uploading ${identity.key} part ${part}`);

  await checkpoint.record(part, etag);
  return etag;
}

async function putMultipart(
  storage: Storage,
  account: string,
  path: string,
  key: string,
  expected: ManifestFile,
  partSize: number,
  concurrency: number
) {
  const count = Math.ceil(expected.bytes / partSize);

  if (count > 10000)
    throw new Error(`Too many multipart parts for ${key}: ${count}`);

  const verified = await verifyMultipartFile(path, key, expected, partSize);
  const identity: MultipartIdentity = {
    account,
    bucket: storage.bucket,
    key,
    path,
    bytes: expected.bytes,
    sha256: expected.sha256,
    partSize,
  };
  const { checkpoint, completed, uploadId } = await prepareMultipart(
    storage,
    identity,
    path
  );
  const missingParts = Array.from(
    { length: count },
    (_, index) => index + 1
  ).filter((part) => !completed.has(part));
  let completedBytes = Array.from(completed.keys()).reduce(
    (bytes, part) => bytes + partLength(identity, part),
    0
  );
  let next = 0;
  let failure: unknown;

  async function worker() {
    while (!failure) {
      const index = next++;
      if (index >= missingParts.length) return;

      const part = missingParts[index];

      try {
        const etag = await uploadMultipartPart(
          storage,
          identity,
          path,
          uploadId,
          checkpoint,
          verified.partHashes[part - 1],
          part
        );

        completed.set(part, etag);
        completedBytes += partLength(identity, part);
        console.log(
          `  part ${part}/${count}: ` +
          `${(completedBytes / 1e9).toFixed(2)}/` +
          `${(expected.bytes / 1e9).toFixed(2)} GB`
        );
      } catch (error) {
        failure ??= error;
      }
    }
  }

  await Promise.all(
    Array.from(
      { length: Math.min(concurrency, missingParts.length) },
      () => worker()
    )
  );

  if (failure) {
    console.error(
      `Multipart progress for ${key} was preserved. Repeat the same command to resume.`
    );
    throw failure;
  }

  if (completed.size !== count)
    throw new Error(`Multipart upload is incomplete for ${key}`);

  const parts = Array.from(completed, ([PartNumber, ETag]) => ({
    ETag,
    PartNumber,
  })).sort((a, b) => a.PartNumber - b.PartNumber);

  try {
    await storage.completeMultipart(
      key,
      uploadId,
      parts.map(({ ETag, PartNumber }) => ({
        etag: ETag,
        part: PartNumber,
      }))
    );
    await removeMultipartState();
  } catch (error) {
    console.error(
      `Multipart completion state for ${key} was preserved. ` +
      "Repeat the same command to reconcile it."
    );
    throw error;
  }
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

async function validatePackage(directory: string) {
  const manifestBytes = await readFile(join(directory, "manifest.json"));
  let manifest: Manifest;

  try {
    manifest = JSON.parse(manifestBytes.toString("utf8")) as Manifest;
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

  return { manifest, manifestBytes };
}

async function packageUnchanged(
  storage: Storage,
  prefix: string,
  manifest: Manifest,
  localManifest: Buffer
) {
  const key = `${prefix}/manifest.json`;
  const existing = await storage.head(key);

  if (!existing) return false;

  const remoteManifest = await storage.read(key);

  if (!remoteManifest)
    throw new Error(`Published manifest has no body: ${key}`);

  if (!remoteManifest.equals(localManifest)) return false;

  for (const [name, expected] of Object.entries(manifest.files)) {
    const object = await storage.head(`${prefix}/${name}`);

    if (!object || !matches(object, expected)) return false;
  }

  console.log("Map package is already published unchanged.");
  return true;
}

type LocalBucket = Awaited<ReturnType<Miniflare["getR2Bucket"]>>;

export function cloudStorage(environment: StorageEnvironment): Storage {
  const client = new S3Client({
    endpoint:
      `https://${environment.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    region: "auto",
    forcePathStyle: true,
    requestChecksumCalculation: "WHEN_REQUIRED",
    responseChecksumValidation: "WHEN_REQUIRED",
    credentials: {
      accessKeyId: environment.R2_ACCESS_KEY_ID,
      secretAccessKey: environment.R2_SECRET_ACCESS_KEY,
    },
  });

  return {
    bucket: environment.R2_BUCKET,

    async head(key) {
      try {
        const object = await client.send(new HeadObjectCommand({
          Bucket: environment.R2_BUCKET,
          Key: key,
        }));

        return {
          bytes: object.ContentLength ?? -1,
          sha256: object.Metadata?.sha256,
        };
      } catch (error) {
        if (missing(error)) return undefined;
        throw error;
      }
    },

    async read(key) {
      try {
        const object = await client.send(new GetObjectCommand({
          Bucket: environment.R2_BUCKET,
          Key: key,
        }));

        return object.Body
          ? Buffer.from(await object.Body.transformToByteArray())
          : undefined;
      } catch (error) {
        if (missing(error)) return undefined;
        throw error;
      }
    },

    async list(prefix) {
      const keys = [];
      let continuationToken: string | undefined;

      do {
        const listed = await client.send(new ListObjectsV2Command({
          Bucket: environment.R2_BUCKET,
          Prefix: prefix,
          ...(continuationToken
            ? { ContinuationToken: continuationToken }
            : {}),
        }));

        for (const object of listed.Contents ?? []) {
          if (object.Key) keys.push(object.Key);
        }

        if (!listed.IsTruncated) break;
        if (!listed.NextContinuationToken) {
          throw new Error(
            `R2 truncated the object list without a token for ${prefix}`
          );
        }

        continuationToken = listed.NextContinuationToken;
      } while (true);

      return keys.sort();
    },

    async put(key, body, length, type, sha256) {
      await client.send(new PutObjectCommand({
        Bucket: environment.R2_BUCKET,
        Key: key,
        Body: body,
        ContentLength: length,
        ContentType: type,
        Metadata: { sha256 },
      }));
    },

    async createMultipart(key, type, sha256) {
      const upload = await client.send(new CreateMultipartUploadCommand({
        Bucket: environment.R2_BUCKET,
        Key: key,
        ContentType: type,
        Metadata: { sha256 },
      }));

      if (!upload.UploadId)
        throw new Error(`R2 did not return a multipart upload ID for ${key}`);

      return upload.UploadId;
    },

    async listParts(key, uploadId) {
      const parts = new Map<number, RemotePart>();
      let marker: string | undefined;

      do {
        const listed = await client.send(new ListPartsCommand({
          Bucket: environment.R2_BUCKET,
          Key: key,
          UploadId: uploadId,
          ...(marker ? { PartNumberMarker: marker } : {}),
        }));

        for (const part of listed.Parts ?? []) {
          if (
            Number.isSafeInteger(part.PartNumber) &&
            part.PartNumber! > 0 &&
            typeof part.ETag === "string" &&
            typeof part.Size === "number"
          ) {
            parts.set(part.PartNumber!, {
              etag: part.ETag,
              size: part.Size,
            });
          }
        }

        if (!listed.IsTruncated) break;
        if (!listed.NextPartNumberMarker) {
          throw new Error(
            `R2 truncated the part list without a marker for ${key}`
          );
        }

        marker = listed.NextPartNumberMarker;
      } while (true);

      return parts;
    },

    async uploadPart(key, uploadId, part, body, length) {
      const uploaded = await client.send(new UploadPartCommand({
        Bucket: environment.R2_BUCKET,
        Key: key,
        UploadId: uploadId,
        PartNumber: part,
        Body: body,
        ContentLength: length,
      }));

      if (!uploaded.ETag)
        throw new Error(`R2 did not return an ETag for ${key} part ${part}`);

      return uploaded.ETag;
    },

    async completeMultipart(key, uploadId, parts) {
      await client.send(new CompleteMultipartUploadCommand({
        Bucket: environment.R2_BUCKET,
        Key: key,
        UploadId: uploadId,
        MultipartUpload: {
          Parts: parts.map(({ etag, part }) => ({
            ETag: etag,
            PartNumber: part,
          })),
        },
      }));
    },

    async abortMultipart(key, uploadId) {
      await client.send(new AbortMultipartUploadCommand({
        Bucket: environment.R2_BUCKET,
        Key: key,
        UploadId: uploadId,
      }));
    },

    async close() {
      client.destroy();
    },
  };
}

export async function localStorage(
  runtimePath: string,
  bucketName: string
): Promise<Storage> {
  const runtime = new Miniflare(
    convertV4MiniflareOptions({
      host: "127.0.0.1",
      port: 0,
      modules: true,

      resourcePersistencePath: join(runtimePath, "wrangler/v3"),
      r2Buckets: { BUCKET: bucketName },

      // Content-Length keeps large streams bounded across Node and workerd.
      script: `export default {
        async fetch(request, env) {
          if (request.method !== "PUT")
            return new Response(null, { status: 405 });

          try {
            const params = new URL(request.url).searchParams;
            const key = params.get("key");
            const uploadId = params.get("uploadId");

            if (uploadId) {
              const upload = env.BUCKET.resumeMultipartUpload(key, uploadId);
              const part = await upload.uploadPart(
                Number(params.get("part")),
                request.body
              );

              return Response.json(part);
            }

            await env.BUCKET.put(key, request.body, {
              httpMetadata: { contentType: params.get("type") },
              customMetadata: { sha256: params.get("sha256") }
            });
            return new Response(null, { status: 204 });
          } catch (error) {
            return new Response(error.message, { status: 500 });
          }
        }
      }`,
    })
  );
  const bucket: LocalBucket = await runtime.getR2Bucket("BUCKET");

  async function send(
    key: string,
    body: UploadBody,
    length: number,
    {
      type,
      sha256,
      uploadId,
      part,
    }: {
      type?: string;
      sha256?: string;
      uploadId?: string;
      part?: number;
    }
  ) {
    const url = new URL("http://localhost/publish");
    url.searchParams.set("key", key);

    if (type) url.searchParams.set("type", type);
    if (sha256) url.searchParams.set("sha256", sha256);
    if (uploadId) url.searchParams.set("uploadId", uploadId);
    if (part !== undefined) url.searchParams.set("part", String(part));

    const response = await runtime.dispatchFetch(url.href, {
      method: "PUT",
      body: body instanceof Readable ? Readable.toWeb(body) : body,
      duplex: "half",
      headers: { "Content-Length": String(length) },
    });

    if (!response.ok) {
      throw new Error(
        `Local R2 write failed for ${key} (${response.status}): ` +
        await response.text()
      );
    }

    return response.status === 204
      ? undefined
      : await response.json() as R2UploadedPart;
  }

  return {
    bucket: bucketName,

    async head(key) {
      const object = await bucket.head(key);

      return object
        ? {
            bytes: object.size,
            sha256: object.customMetadata?.sha256,
          }
        : undefined;
    },

    async read(key) {
      const object = await bucket.get(key);
      return object ? Buffer.from(await object.arrayBuffer()) : undefined;
    },

    async list(prefix) {
      const keys = [];
      let cursor: string | undefined;

      do {
        const listed = await bucket.list({
          prefix,
          ...(cursor ? { cursor } : {}),
        });

        keys.push(...listed.objects.map((object) => object.key));

        if (!listed.truncated) break;
        if (!listed.cursor)
          throw new Error(`Local R2 truncated the object list for ${prefix}`);

        cursor = listed.cursor;
      } while (true);

      return keys.sort();
    },

    async put(key, body, length, type, sha256) {
      await send(key, body, length, { type, sha256 });
    },

    async createMultipart(key, type, sha256) {
      const upload = await bucket.createMultipartUpload(key, {
        httpMetadata: { contentType: type },
        customMetadata: { sha256 },
      });

      return upload.uploadId;
    },

    async uploadPart(key, uploadId, part, body, length) {
      const uploaded = await send(key, body, length, { uploadId, part });

      if (!uploaded)
        throw new Error(`Local R2 did not return part ${part} for ${key}`);

      return uploaded.etag;
    },

    async completeMultipart(key, uploadId, parts) {
      const upload = bucket.resumeMultipartUpload(key, uploadId);
      await upload.complete(parts.map(({ etag, part }) => ({
        etag,
        partNumber: part,
      })));
    },

    async abortMultipart(key, uploadId) {
      await bucket.resumeMultipartUpload(key, uploadId).abort();
    },

    async close() {
      await runtime.dispose();
    },
  };
}

async function abortRemoteMultipart(
  storage: Storage,
  state: MultipartState
) {
  try {
    await storage.abortMultipart(state.key, state.uploadId);
  } catch (error) {
    if (!missing(error)) throw error;
  }
}

async function reconcileCompletedMultipart(
  storage: Storage,
  account: string
) {
  const state = await readMultipartState();
  if (!state) return;

  if (state.account !== account || state.bucket !== storage.bucket) {
    throw new Error(
      `Multipart checkpoint targets another account or bucket: ${multipartStatePath}`
    );
  }

  const object = await storage.head(state.key);

  if (object && matches(object, state)) {
    await abortRemoteMultipart(storage, state);
    await removeMultipartState();
    console.log(`Reconciled completed multipart upload for ${state.key}.`);
  }
}

async function abortWithStorage(
  storage: Storage,
  account: string,
  state: MultipartState
) {
  if (state.account !== account || state.bucket !== storage.bucket) {
    throw new Error(
      `Multipart checkpoint targets another account or bucket: ${multipartStatePath}`
    );
  }

  await abortRemoteMultipart(storage, state);
  await removeMultipartState();
  console.log(`Aborted checkpointed multipart upload for ${state.key}.`);
}

async function abortSavedMultipart(local: boolean) {
  const state = await readMultipartState();

  if (!state) {
    console.log("No checkpointed multipart upload to abort.");
    return;
  }

  if (local) {
    const environment = readImportEnvironment();
    const storage = await localStorage(
      environment.RUNTIME_PATH,
      environment.R2_BUCKET
    );

    try {
      await abortWithStorage(
        storage,
        `local:${environment.RUNTIME_PATH}`,
        state
      );
    } finally {
      await storage.close();
    }

    return;
  }

  const environment = readPublishStorageEnvironment();
  const storage = cloudStorage(environment);

  try {
    await abortWithStorage(
      storage,
      environment.CLOUDFLARE_ACCOUNT_ID,
      state
    );
  } finally {
    await storage.close();
  }
}

async function publish(
  storage: Storage,
  account: string,
  directory: string,
  releaseId: string,
  partSizeMiB: number,
  concurrency: number
) {
  if (!RELEASE_ID_PATTERN.test(releaseId)) {
    throw new Error(
      "Release ID must start with a letter or number and contain only " +
      "letters, numbers, periods, underscores and hyphens"
    );
  }

  if (
    !Number.isSafeInteger(partSizeMiB) ||
    partSizeMiB < 5 ||
    partSizeMiB > MAX_PART_SIZE_MIB
  ) {
    throw new Error(
      `Part size must be an integer between 5 and ${MAX_PART_SIZE_MIB} MiB`
    );
  }

  if (
    !Number.isSafeInteger(concurrency) ||
    concurrency < 1 ||
    concurrency > MAX_CONCURRENCY
  ) {
    throw new Error(
      `Concurrency must be an integer between 1 and ${MAX_CONCURRENCY}`
    );
  }

  const prefix = `${RELEASES_PREFIX}/${releaseId}`;
  const { manifest, manifestBytes } = await validatePackage(directory);
  const partSize = partSizeMiB * 1024 * 1024;

  await reconcileCompletedMultipart(storage, account);

  if (await packageUnchanged(storage, prefix, manifest, manifestBytes)) return;

  const names = Object.keys(manifest.files).sort((a, b) =>
    a === "map.pmtiles" ? -1 : b === "map.pmtiles" ? 1 : a.localeCompare(b)
  );

  for (const name of names) {
    const expected = manifest.files[name];
    const key = `${prefix}/${name}`;
    const existing = await storage.head(key);

    if (existing && matches(existing, expected)) {
      console.log(`Unchanged ${name}`);
      continue;
    }

    console.log(
      `${existing ? "Replacing" : "Uploading"} ${key}: ${expected.bytes} bytes`
    );

    if (expected.bytes >= MULTIPART_THRESHOLD) {
      await putMultipart(
        storage,
        account,
        join(directory, name),
        key,
        expected,
        partSize,
        concurrency
      );
    } else {
      await putSmall(storage, join(directory, name), key, expected);
    }

    console.log(`Uploaded ${name}`);
  }

  const manifestHash = createHash("sha256").update(manifestBytes).digest("hex");

  await storage.put(
    `${prefix}/manifest.json`,
    manifestBytes,
    manifestBytes.length,
    "application/json",
    manifestHash
  );

  console.log(
    `Published map package to R2 bucket ${storage.bucket} at ${prefix}.`
  );
}

async function runPublication(
  local: boolean,
  releaseId: string,
  partSizeMiB: number,
  concurrency: number
) {
  if (local) {
    const environment = readImportEnvironment();
    const storage = await localStorage(
      environment.RUNTIME_PATH,
      environment.R2_BUCKET
    );

    try {
      await publish(
        storage,
        `local:${environment.RUNTIME_PATH}`,
        environment.PACKAGE_PATH,
        releaseId,
        partSizeMiB,
        concurrency
      );
      await saveEnvironment({ LOCAL_RELEASE_ID: releaseId });
    } finally {
      await storage.close();
    }

    return;
  }

  const environment = readPublishEnvironment();
  const storage = cloudStorage(environment);

  try {
    await publish(
      storage,
      environment.CLOUDFLARE_ACCOUNT_ID,
      environment.PACKAGE_PATH,
      releaseId,
      partSizeMiB,
      concurrency
    );
  } finally {
    await storage.close();
  }
}

async function main() {
  try {
    const { values } = parseArgs({
      options: {
        "release-id": { type: "string" },
        "part-size-mib": {
          type: "string",
          default: String(DEFAULT_PART_SIZE_MIB),
        },
        concurrency: {
          type: "string",
          default: String(DEFAULT_CONCURRENCY),
        },
        abort: { type: "boolean", default: false },
        local: { type: "boolean", default: false },
      }
    });

    if (values.abort) {
      if (values["release-id"])
        throw new Error("Release ID cannot be used with --abort");

      await withPublicationLock(() => abortSavedMultipart(values.local));
    } else {
      if (!values["release-id"])
        throw new Error("Release ID is required");

      await withPublicationLock(() => runPublication(
        values.local,
        values["release-id"]!,
        Number(values["part-size-mib"]),
        Number(values.concurrency)
      ));
    }
  } catch (error) {
    console.error((error as Error).message);
    process.exitCode = 1;
  }
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  await main();
}
