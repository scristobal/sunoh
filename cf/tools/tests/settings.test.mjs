import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("workspace commands save settings in the root environment file", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "sunoh-settings-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const workspace = join(root, "tools");
  await mkdir(workspace);
  await copyFile(new URL("../settings.ts", import.meta.url), join(workspace, "settings.ts"));
  await writeFile(join(root, ".env"), "EXISTING=preserved\n");

  const result = spawnSync(process.execPath, ["--input-type=module", "-e", `
    import { saveEnvironment } from './settings.ts';
    await saveEnvironment({ RUNTIME_PATH: '/example/runtime' });
  `], { cwd: workspace, encoding: "utf8" });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(await readFile(join(root, ".env"), "utf8"),
    "EXISTING=preserved\n\nRUNTIME_PATH=/example/runtime\n");
  assert.equal((await stat(join(root, ".env"))).mode & 0o777, 0o600);
  await assert.rejects(stat(join(workspace, ".env")), { code: "ENOENT" });
});
