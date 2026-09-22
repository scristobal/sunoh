// PMTiles/R2 adapter derived from Protomaps' BSD-3-Clause Cloudflare Worker:
// https://github.com/protomaps/PMTiles/tree/182d5b3cfdc2f5a6adbc54630c612da2f6086bdd/serverless/cloudflare
// See LICENSE. Adaptations: one map package, local HTTP origins, style/assets,
// strict XYZ validation, and GET/HEAD/OPTIONS handling.

import {
  Compression,
  EtagMismatch,
  PMTiles,
  ResolvedValueCache,
  TileType
} from "pmtiles";
import type { RangeResponse, Source } from "pmtiles";

interface Env {
  BUCKET: R2Bucket
  VERSION: WorkerVersionMetadata
  LOCAL_RELEASE_ID?: string
}

class NotFound extends Error {}

async function decompress(
  data: ArrayBuffer,
  compression: Compression
): Promise<ArrayBuffer> {
  if (compression === Compression.None || compression === Compression.Unknown)
    return data;

  if (compression !== Compression.Gzip)
    throw new Error("Unsupported archive compression");

  return new Response(
    new Response(data).body!.pipeThrough(new DecompressionStream("gzip"))
  ).arrayBuffer();
}

const directories = new ResolvedValueCache(25, undefined, decompress);

class R2Source implements Source {
  constructor(
    private bucket: R2Bucket,
    private key: string
  ) {}

  getKey() {
    return this.key;
  }

  async getBytes(
    offset: number,
    length: number,
    _signal?: AbortSignal,
    etag?: string
  ): Promise<RangeResponse> {
    const object = await this.bucket.get(this.key, {
      range: { offset, length },
      ...(etag ? { onlyIf: { etagMatches: etag } } : {}),
    });

    if (!object) throw new NotFound("Archive not found");
    if (!("body" in object)) throw new EtagMismatch();

    return { data: await object.arrayBuffer(), etag: object.etag };
  }
}

function response(
  body: BodyInit | null,
  status = 200,
  type = "application/json"
): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": type,
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
      "Access-Control-Allow-Headers": "Range",
      "Cache-Control": status === 200 ? "public, max-age=86400" : "no-store",
    }
  });
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const match = /^\/([A-Za-z0-9][A-Za-z0-9._-]*)\/(.+)$/.exec(url.pathname);

  if (!match) return response("Not found", 404, "text/plain");

  const [, releaseId, path] = match;
  const storageReleaseId = releaseId === "release" && env.LOCAL_RELEASE_ID
    ? env.LOCAL_RELEASE_ID
    : releaseId;
  const bucketPrefix = `releases/${storageReleaseId}`;
  const publicPrefix = `${url.origin}/${releaseId}`;

  if (path === "style.json") {
    const object = await env.BUCKET.get(`${bucketPrefix}/style.json`);
    if (!object) throw new NotFound("Style not found");

    // Assets and TileJSON follow the release and origin actually used by the
    // Simulator, including HTTP, localhost ports and SSH tunnels.
    const style = (await object.text())
      .replace(
        /\{origin\}\/releases\/[A-Za-z0-9][A-Za-z0-9._-]*\//g,
        `${publicPrefix}/`
      )
      .replaceAll("{origin}/release/", `${publicPrefix}/`)
      .replaceAll("{origin}", url.origin);
    return response(style);
  }

  if (path === "manifest.json") {
    const object = await env.BUCKET.get(`${bucketPrefix}/manifest.json`);
    if (!object) throw new NotFound("Map not found");

    return response(object.body);
  }

  const asset = /^assets\/([A-Za-z0-9_@.-]+\.(?:json|png|ttf))$/.exec(path);

  if (asset) {
    const object = await env.BUCKET.get(`${bucketPrefix}/assets/${asset[1]}`);
    if (!object) throw new NotFound("Asset not found");

    const type = asset[1].endsWith(".png")
      ? "image/png"
      : asset[1].endsWith(".ttf")
        ? "font/ttf"
        : "application/json";

    return response(object.body, 200, type);
  }

  const tile = /^(\d+)\/(\d+)\/(\d+)\.mvt$/.exec(path);

  if (path !== "tiles.json" && !tile)
    return response("Not found", 404, "text/plain");

  const xyz = tile ? tile.slice(1).map(Number) : undefined;

  if (xyz) {
    const [z, x, y] = xyz;

    if (
      !Number.isSafeInteger(z) ||
      z < 0 ||
      z > 26 ||
      !Number.isSafeInteger(x) ||
      !Number.isSafeInteger(y) ||
      x < 0 ||
      y < 0 ||
      x >= 2 ** z ||
      y >= 2 ** z
    ) {
      return response("Invalid tile coordinates", 400, "text/plain");
    }
  }

  const archive = new PMTiles(
    new R2Source(env.BUCKET, `${bucketPrefix}/map.pmtiles`),
    directories,
    decompress
  );
  const header = await archive.getHeader();

  if (header.tileType !== TileType.Mvt)
    return response("Expected vector PMTiles", 400, "text/plain");

  if (!xyz)
    return response(JSON.stringify(await archive.getTileJson(publicPrefix)));

  const [z, x, y] = xyz;

  if (z < header.minZoom || z > header.maxZoom) return response(null, 204);

  const data = await archive.getZxy(z, x, y);

  // PMTiles JS has already decompressed the tile. Do not claim gzip encoding.
  return data
    ? response(data.data, 200, "application/vnd.mapbox-vector-tile")
    : response(null, 204);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (request.method === "OPTIONS") return response(null, 204);

    if (request.method !== "GET" && request.method !== "HEAD") {
      const denied = response("Method not allowed", 405, "text/plain");
      denied.headers.set("Allow", "GET, HEAD, OPTIONS");
      return denied;
    }

    try {
      const cacheUrl = new URL(request.url);
      cacheUrl.searchParams.set("__worker_version", env.VERSION.id);

      if (env.LOCAL_RELEASE_ID)
        cacheUrl.searchParams.set("__local_release", env.LOCAL_RELEASE_ID);

      const key = new Request(cacheUrl, { method: "GET" });
      let result = await caches.default.match(key);

      if (!result) {
        result = await route(request, env);

        if (result.status === 200)
          ctx.waitUntil(caches.default.put(key, result.clone()));
      }

      return request.method === "HEAD"
        ? new Response(null, { status: result.status, headers: result.headers })
        : result;
    } catch (error) {
      if (error instanceof NotFound)
        return response(error.message, 404, "text/plain");

      console.error(error);
      return response("Unable to read map", 500, "text/plain");
    }
  },
};
