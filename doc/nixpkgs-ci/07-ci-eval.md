# CI Evaluation Infrastructure

This document covers the GitHub Actions-based evaluation infrastructure in
`ci/eval/`.

## Overview

The `ci/eval/` directory contains a parallel evaluation system used by GitHub
Actions to detect package changes and regressions in PRs.

## Architecture

```
┌────────────────────────┐
│   attrpaths.nix        │  Fast single-threaded enumeration
│   (superset of attrs)  │  of all possible job attrpaths
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│   chunk.nix            │  Splits attrpaths into N chunks
│   (parallel chunks)    │  for parallel evaluation
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│   outpaths.nix         │  Evaluates release.nix with
│   (actual eval)        │  custom config for CI
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│   default.nix          │  Orchestrates chunked evaluation
│   (orchestration)      │  and comparison
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│   diff.nix / compare/  │  Compares before/after,
│   (analysis)           │  generates reports
└────────────────────────┘
```

## attrpaths.nix

**Purpose:** Quickly enumerate all derivation attrpaths without fully
evaluating them.

```nix
{
  lib ? import (path + "/lib"),
  trace ? false,
  path ? ./../..,
  extraNixpkgsConfigJson ? "{}",
}:
let
  justAttrNames = path: value:
    let
      result =
        if path == [ "AAAAAASomeThingsFailToEvaluate" ] || !(lib.isAttrs value) then
          [ ]
        else if lib.isDerivation value then
          [ path ]
        else
          lib.pipe value [
            (lib.mapAttrsToList (name: value:
              lib.addErrorContext "while evaluating package set attribute path '${
                lib.showAttrPath (path ++ [ name ])
              }'" (justAttrNames (path ++ [ name ]) value)
            ))
            lib.concatLists
          ];
    in
    lib.traceIf trace "** ${lib.showAttrPath path}" result;

  outpaths = import ./outpaths.nix {
    inherit path;
    extraNixpkgsConfig = builtins.fromJSON extraNixpkgsConfigJson;
    attrNamesOnly = true;  # Key optimization
  };

  # Manually add variant stdenvs that are disabled with attrNamesOnly
  paths = [
    [ "pkgsLLVM" "stdenv" ]
    [ "pkgsArocc" "stdenv" ]
    [ "pkgsZig" "stdenv" ]
    [ "pkgsStatic" "stdenv" ]
    [ "pkgsMusl" "stdenv" ]
  ] ++ justAttrNames [ ] outpaths;

  names = map lib.showAttrPath paths;
in
{ inherit paths names; }
```

**Usage:**
```bash
nix-instantiate --eval --strict --json ci/eval/attrpaths.nix -A names
```

## outpaths.nix

**Purpose:** Evaluate release.nix with CI-specific configuration.

```nix
{
  includeBroken ? true,
  path ? ./../..,
  attrNamesOnly ? false,
  systems ? builtins.fromJSON (builtins.readFile ../supportedSystems.json),
  extraNixpkgsConfig ? { },
}:
let
  nixpkgsJobs = import (path + "/pkgs/top-level/release.nix") {
    inherit attrNamesOnly;
    supportedSystems = if systems == null then [ builtins.currentSystem ] else systems;
    nixpkgsArgs = {
      config = {
        allowAliases = false;
        allowBroken = includeBroken;
        allowUnfree = true;
        allowInsecurePredicate = x: true;
        allowVariants = !attrNamesOnly;
        checkMeta = true;

        handleEvalIssue = reason: errormsg:
          let
            fatalErrors = [ "unknown-meta" "broken-outputs" ];
          in
          if builtins.elem reason fatalErrors then
            abort errormsg
          else if !includeBroken && builtins.elem reason [ "broken" "unfree" ] then
            throw "broken"
          else if builtins.elem reason [ "unsupported" ] then
            throw "unsupported"
          else
            true;

        inHydra = true;
      } // extraNixpkgsConfig;
      __allowFileset = false;
    };
  };

  nixosJobs = import (path + "/nixos/release.nix") {
    inherit attrNamesOnly;
    supportedSystems = ...;
  };

  # Blacklist jobs that don't work well with CI eval
  blacklist = [
    "tarball" "metrics" "manual" "darwin-tested"
    "unstable" "stdenvBootstrapTools" "moduleSystem" "lib-tests"
  ];

  # Ensure recurseForDerivations is set properly
  tweak = lib.mapAttrs (name: val:
    if name == "recurseForDerivations" then true
    else if lib.isAttrs val && val.type or null != "derivation" then
      recurseIntoAttrs (tweak val)
    else val
  );
in
tweak ((removeAttrs nixpkgsJobs blacklist) // {
  nixosTests.simple = nixosJobs.tests.simple;
})
```

## chunk.nix

**Purpose:** Split evaluation into parallel chunks.

```nix
{
  lib ? import ../../lib,
  path ? ../..,
  attrpathFile,
  chunkSize,
  myChunk,
  includeBroken,
  systems,
  extraNixpkgsConfigJson,
}:
let
  attrpaths = lib.importJSON attrpathFile;
  myAttrpaths = lib.sublist (chunkSize * myChunk) chunkSize attrpaths;

  unfiltered = import ./outpaths.nix {
    inherit path includeBroken systems;
    extraNixpkgsConfig = builtins.fromJSON extraNixpkgsConfigJson;
  };

  # Filter to only our chunk's attrpaths
  filtered =
    let
      recurse = index: paths: attrs:
        lib.mapAttrs (name: values:
          if attrs ? ${name} then
            if lib.any (value: lib.length value <= index + 1) values then
              attrs.${name}
            else
              recurse (index + 1) values attrs.${name}
              // { recurseForDerivations = true; }
          else
            null
        ) (lib.groupBy (a: lib.elemAt a index) paths);
    in
    recurse 0 myAttrpaths unfiltered;
in
filtered
```

## default.nix (Orchestration)

**Purpose:** Coordinate the evaluation process.

### attrpathsSuperset

Generate the list of all attrpaths:

```nix
attrpathsSuperset = { evalSystem }:
  runCommand "attrpaths-superset.json" {
    src = nixpkgs;
    nativeBuildInputs = [ busybox nix ];
  } ''
    export NIX_STATE_DIR=$(mktemp -d)
    mkdir $out
    export GC_INITIAL_HEAP_SIZE=4g
    nix-instantiate --eval --strict --json --show-trace \
      "$src/ci/eval/attrpaths.nix" \
      -A paths \
      --option restrict-eval true \
      --option allow-import-from-derivation false \
      --option eval-system "${evalSystem}" > $out/paths.json
  '';
```

### singleSystem

Evaluate all packages for one system in parallel chunks:

```nix
singleSystem = { evalSystem, attrpathFile }:
  let
    singleChunk = writeShellScript "single-chunk" ''
      set -euo pipefail
      chunkSize=$1
      myChunk=$2
      system=$3
      outputDir=$4

      export GC_LARGE_ALLOC_WARN_INTERVAL=1000
      export NIX_SHOW_STATS=1
      export NIX_SHOW_STATS_PATH="$outputDir/stats/$myChunk"

      nix-env -f "${nixpkgs}/ci/eval/chunk.nix" \
        --eval-system "$system" \
        --option restrict-eval true \
        --option allow-import-from-derivation false \
        --query --available --out-path --json --meta --show-trace \
        --arg chunkSize "$chunkSize" \
        --arg myChunk "$myChunk" \
        --arg attrpathFile "${attrpathFile}" \
        > "$outputDir/result/$myChunk"
    '';
  in
  runCommand "nixpkgs-eval-${evalSystem}" { ... } ''
    # Parallel chunk evaluation using xargs
    seq -w 0 "$seq_end" |
      xargs -I{} -P"$cores" ${singleChunk} "$chunkSize" {} "$evalSystem" "$chunkOutputDir"

    # Combine results
    cat "$chunkOutputDir"/result/* | jq -s 'add | map_values(.outputs)' > $out/paths.json
    cat "$chunkOutputDir"/result/* | jq -s 'add | map_values(.meta)' > $out/meta.json
  '';
```

### full

Complete evaluation with before/after comparison:

```nix
full = { evalSystems, baseline, touchedFilesJson }:
  let
    diffs = symlinkJoin {
      name = "nixpkgs-eval-diffs";
      paths = map (evalSystem:
        diff {
          inherit evalSystem;
          beforeDir = baseline;
          afterDir = singleSystem { inherit evalSystem; };
        }
      ) evalSystems;
    };
    comparisonReport = compare {
      combinedDir = combine { diffDir = diffs; };
      inherit touchedFilesJson;
    };
  in
  comparisonReport;
```

## diff.nix

Compares before/after evaluation results:

```nix
{
  evalSystem,
  beforeDir,
  afterDir,
}:
runCommand "nixpkgs-eval-diff-${evalSystem}" { ... } ''
  # Generate diff of changed packages
  jq -s '
    {
      added: (.[1] | keys) - (.[0] | keys),
      removed: (.[0] | keys) - (.[1] | keys),
      changed: [
        (.[0] | to_entries[]) as $before |
        (.[1][$before.key]) as $after |
        select($after != null and $after != $before.value) |
        $before.key
      ],
      rebuilds: ...
    }
  ' "${beforeDir}/paths.json" "${afterDir}/paths.json" > $out/diff.json
'';
```

## compare/

Generates human-readable comparison reports:

- `compare/default.nix` - Main comparison logic
- `compare/maintainers.nix` - Extract affected maintainers
- `compare/utils.nix` - Helper functions

## Evaluation Constraints

The CI evaluation uses strict constraints:

```nix
--option restrict-eval true
--option allow-import-from-derivation false
```

This ensures:
- No access to files outside the source tree
- No IFD (import-from-derivation) which would require building
- Reproducible, sandboxed evaluation

## Memory Management

```nix
# Increase GC threshold to reduce GC pauses
export GC_LARGE_ALLOC_WARN_INTERVAL=1000

# Pre-size the heap
export GC_INITIAL_HEAP_SIZE=4g

# Collect stats for analysis
export NIX_SHOW_STATS=1
export NIX_SHOW_STATS_PATH="$outputDir/stats/$myChunk"
```

## Chunk Size

Default chunk size is 5000 attributes:

```nix
chunkSize ? 5000,
```

With ~100,000 packages, this means ~20 parallel evaluation jobs per system.
