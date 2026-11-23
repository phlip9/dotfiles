// Fast Metro minifier backed by esbuild instead of JS Terser.
// Used by nixos/pkgs/paseo/default.nix during `expo export --platform web`.
// Production web export does not emit source maps; pass `sourcefile` for
// diagnostics and honor Metro's `keep_classnames` / `keep_fnames` flags.
"use strict";

const esbuild = require("esbuild");

async function minifier({ code, filename, config }) {
  const mangle =
    config?.mangle && typeof config.mangle === "object" ? config.mangle : {};
  const keepNames = Boolean(
    config?.keep_classnames ||
      config?.keep_fnames ||
      mangle.keep_classnames ||
      mangle.keep_fnames,
  );
  const result = await esbuild.transform(code, {
    loader: "js",
    sourcefile: filename,
    minify: true,
    keepNames,
    legalComments: "none",
    sourcemap: false,
  });
  return { code: result.code };
}

module.exports = minifier;
module.exports.default = minifier;
