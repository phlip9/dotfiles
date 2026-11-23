// Copy exported Expo web UI assets into `$out` and generate .br/.gz sidecars
// concurrently with bounded parallelism. Brotli quality 9 runs in ~1.6s vs
// ~40.4s at quality 11 on the ~25 MiB bundle for ~0.49 MiB difference on a
// hashed immutable asset.

import { createReadStream, createWriteStream } from "node:fs";
import { cp, mkdir, readdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import {
  constants as zlibConstants,
  createBrotliCompress,
  createGzip,
} from "node:zlib";

const COMPRESS_EXT = new Set([".html", ".js", ".css", ".json", ".svg", ".map"]);

const srcDir = path.resolve(process.argv[2]);
const outDir = path.resolve(process.argv[3]);

await mkdir(outDir, { recursive: true });
await cp(srcDir, outDir, { recursive: true });

const files = [];
async function collect(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await collect(fullPath);
    } else if (
      entry.isFile() &&
      COMPRESS_EXT.has(path.extname(entry.name).toLowerCase())
    ) {
      files.push(fullPath);
    }
  }
}

await collect(outDir);

const jobs = files.flatMap((filePath) => [
  () =>
    pipeline(
      createReadStream(filePath),
      createBrotliCompress({
        params: { [zlibConstants.BROTLI_PARAM_QUALITY]: 9 },
      }),
      createWriteStream(`${filePath}.br`),
    ),
  () =>
    pipeline(
      createReadStream(filePath),
      createGzip(),
      createWriteStream(`${filePath}.gz`),
    ),
]);

const concurrency = Math.max(1, Math.min(os.availableParallelism(), jobs.length));
let nextJob = 0;
await Promise.all(
  Array.from({ length: concurrency }, async () => {
    while (nextJob < jobs.length) {
      const idx = nextJob;
      nextJob += 1;
      await jobs[idx]();
    }
  }),
);
