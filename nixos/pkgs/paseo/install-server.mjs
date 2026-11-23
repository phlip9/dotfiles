// Trace Paseo's daemon and CLI runtime closure w/ @vercel/nft and copy the
// resolved files into the server derivation output without retaining store
// references to the build-time `nodeModules` derivation.
//
// Drops unused local speech (sherpa-onnx + silero_vad.onnx) and build-only
// compilers (esbuild, typescript). When upgrading Paseo, diff upstream's
// entry points, runtimeDependencies, and additionalInputs:
// see: upstream scripts/trace-daemon.mjs

import {
  copyFileSync,
  chmodSync,
  lstatSync,
  mkdirSync,
  readlinkSync,
  realpathSync,
  symlinkSync,
} from "node:fs";
import { glob, readFile, readdir, readlink as fsReadlink } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

const REPO_ROOT = process.cwd();
const nmStore = path.resolve(process.argv[2]);
const outRoot = path.resolve(process.argv[3]);

const requireFromRoot = createRequire(path.join(REPO_ROOT, "package.json"));
const { nodeFileTrace } = requireFromRoot("@vercel/nft");

function requireFrom(importer) {
  return createRequire(path.join(REPO_ROOT, importer));
}

const terminalModule = "packages/server/dist/server/terminal/terminal.js";

// Resolve-only and computed requires need explicit graph edges so nft retains
// package exports, manifests, and workspace symlinks used at runtime.
const runtimeDependencies = new Map([
  ["packages/cli/dist/commands/daemon/local-daemon.js", ["@getpaseo/server"]],
  [terminalModule, ["@getpaseo/cli/bin/paseo", "node-pty/package.json"]],
]);

// Fail early if a required runtime edge cannot resolve.
for (const [importer, specifiers] of runtimeDependencies) {
  for (const specifier of specifiers) {
    requireFrom(importer).resolve(specifier);
  }
}

// Let node-pty select the native addon it actually loads and retain its dir.
const terminalRequire = requireFrom(terminalModule);
const ptyLoader = terminalRequire.resolve("node-pty/lib/utils");
const { dir: ptyNativeDir } = terminalRequire(ptyLoader).loadNativeModule("pty");
const ptyNativeRoot = path.resolve(path.dirname(ptyLoader), ptyNativeDir);
const ptyNativeFiles = (await readdir(ptyNativeRoot, { withFileTypes: true }))
  .filter((entry) => entry.isFile())
  .map((entry) => path.join(ptyNativeRoot, entry.name));

// Daemon, CLI, and forked terminal worker entry points.
const entries = [
  "packages/cli/dist/index.js",
  "packages/server/dist/scripts/supervisor-entrypoint.js",
  "packages/server/dist/server/terminal/terminal-worker-process.js",
];

// Non-require runtime data files and workspace root manifest.
const additionalInputs = [
  "package.json",
  "packages/server/dist/server/skills/**",
  "packages/server/dist/server/builtin-plugins/**",
  "packages/server/dist/server/terminal/shell-integration/**",
  "packages/server/dist/server/server/agent/providers/opencode/**/bridge-plugin.bundle.mjs",
  "packages/server/.env.example",
  ...ptyNativeFiles,
];

const nmPrefix = nmStore + path.sep;

const { fileList, warnings } = await nodeFileTrace(entries, {
  base: REPO_ROOT,
  // Treat top-level node_modules symlinks into `nmStore` as real directories
  // so nft traces them inside REPO_ROOT instead of skipping out-of-tree paths.
  async readlink(targetPath) {
    try {
      const target = await fsReadlink(targetPath);
      return target.startsWith(nmPrefix) ? null : target;
    } catch (err) {
      if (err.code === "EINVAL" || err.code === "ENOENT" || err.code === "UNKNOWN") {
        return null;
      }
      throw err;
    }
  },
  async readFile(filePath) {
    let source;
    try {
      source = await readFile(filePath);
    } catch (err) {
      if (err.code === "ENOENT" || err.code === "EISDIR") return null;
      throw err;
    }
    // Pass only top-level single-line `import` lines of the 11 MiB generated
    // AOT validator so Acorn skips parsing its generated body. Fall back to
    // full source if any unexpected import/require/re-export syntax appears.
    if (filePath.endsWith("/generated/validation/ws-outbound.aot.js")) {
      const text = source.toString("utf8");
      const importLines = [];
      const bodyLines = [];
      let allSingleLine = true;
      for (const line of text.split("\n")) {
        if (line.startsWith("import ")) {
          importLines.push(line);
          if (!/["'][^"']+["']\s*;?\s*$/.test(line)) {
            allSingleLine = false;
          }
        } else {
          bodyLines.push(line);
        }
      }
      const body = bodyLines.join("\n");
      const hasHiddenDep =
        /\brequire\s*\(|\bimport\s*\(|\bexport\b[^\n]*\bfrom\b/.test(body);
      if (allSingleLine && !hasHiddenDep) {
        return importLines.join("\n");
      }
    }
    const deps = runtimeDependencies.get(path.relative(REPO_ROOT, filePath));
    if (!deps) return source;
    const synthetic = deps
      .map((specifier) => `require(${JSON.stringify(specifier)});`)
      .join("\n");
    return `${source}\n${synthetic}`;
  },
  ignore: [
    "sherpa-onnx-*/**",
    "@mariozechner/clipboard-*/**",
    "encoding/**",
    "**/node_modules/esbuild/**",
    "**/node_modules/@esbuild/**",
    "**/node_modules/typescript/**",
    "**/node_modules/@typescript/native-preview*/**",
    "**/*.test.js",
    "**/*.e2e.test.js",
  ],
});

for (const warning of warnings) {
  const msg = warning.message ?? String(warning);
  if (/sherpa-onnx-/.test(msg)) continue;
  console.error("trace warning:", msg);
}

const expanded = new Set(fileList);
for (const pattern of additionalInputs) {
  if (pattern.includes("*")) {
    let matchedCount = 0;
    for await (const matched of glob(pattern, { cwd: REPO_ROOT })) {
      expanded.add(path.relative(REPO_ROOT, path.resolve(REPO_ROOT, matched)));
      matchedCount += 1;
    }
    if (matchedCount === 0) {
      throw new Error(`required runtime glob matched no files: ${pattern}`);
    }
  } else {
    const resolved = path.resolve(REPO_ROOT, pattern);
    lstatSync(resolved);
    expanded.add(path.relative(REPO_ROOT, resolved));
  }
}

// Normalize paths (remapping any `nmStore` realpaths back to repo-relative)
// and drop symlinks pointing into `nmStore`.
const files = new Set();
const forbiddenCompilerRe =
  /(^|\/)node_modules\/(esbuild|@esbuild|typescript|@typescript\/native-preview[^/]*)(\/|$)/;

for (const entry of expanded) {
  const abs = path.resolve(REPO_ROOT, entry);
  let rel = entry;
  if (abs.startsWith(nmPrefix)) {
    rel = path.relative(nmStore, abs);
  } else if (entry.startsWith("..")) {
    continue;
  }
  if (forbiddenCompilerRe.test(rel)) {
    throw new Error(`build-only compiler leaked into server closure: ${rel}`);
  }
  const full = path.join(REPO_ROOT, rel);
  let stat;
  try {
    stat = lstatSync(full);
  } catch (err) {
    if (err.code === "ENOENT") continue;
    throw err;
  }
  if (stat.isSymbolicLink() && realpathSync(full).startsWith(nmPrefix)) {
    continue;
  }
  files.add(rel);
}

const createdDirs = new Set();
for (const rel of [...files].sort()) {
  const src = path.join(REPO_ROOT, rel);
  const dst = path.join(outRoot, rel);
  const dir = path.dirname(dst);
  if (!createdDirs.has(dir)) {
    mkdirSync(dir, { recursive: true });
    createdDirs.add(dir);
  }
  const stat = lstatSync(src);
  if (stat.isSymbolicLink()) {
    symlinkSync(readlinkSync(src), dst);
  } else if (stat.isFile()) {
    copyFileSync(src, dst);
    chmodSync(dst, stat.mode & 0o777);
  }
}
