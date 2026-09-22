// Preserve unrelated values while updating the ignored project environment.

import { chmod, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

function setValue(source: string, name: string, value: string) {
  const lines = source ? source.replace(/\n$/, "").split("\n") : [];
  const pattern = new RegExp(`^\\s*${name}\\s*=`);
  const index = lines.findIndex((line) => pattern.test(line));
  const assignment = `${name}=${value}`;

  if (index === -1) {
    if (lines.length && lines.at(-1) !== "")
      lines.push("");

    lines.push(assignment);
  } else {
    lines[index] = assignment;
  }

  return lines.join("\n") + "\n";
}

export async function saveEnvironment(values: Record<string, string>) {
  const path = fileURLToPath(new URL("../.env", import.meta.url));
  let source = await readFile(path, "utf8").catch(
    (error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return "";
      throw error;
    }
  );

  for (const [name, value] of Object.entries(values))
    source = setValue(source, name, value);

  await writeFile(path, source, { encoding: "utf8", mode: 0o600 });
  await chmod(path, 0o600);
}
