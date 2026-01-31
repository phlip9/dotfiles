# Evaluation Error Handling

This document covers how nixpkgs handles evaluation failures, broken packages,
and the `checkMeta` system.

## check-meta.nix Overview

**File:** `pkgs/stdenv/generic/check-meta.nix` (744 lines)

This module validates derivation metadata and attributes, controlling which
packages are allowed to evaluate based on various criteria.

## Validity Checks

### Check Categories

The `checkValidity` function returns one of:
- `null` - Package is valid
- `{ reason; errormsg; remediation; }` - Package failed validation

```nix
checkValidity = attrs:
  # Fatal errors (cannot be ignored)
  if metaInvalid (attrs.meta or { }) then
    { reason = "unknown-meta"; ... }
  else if checkOutputsToInstall attrs then
    { reason = "broken-outputs"; ... }

  # Ignorable errors
  else if hasDeniedUnfreeLicense attrs && !(hasAllowlistedLicense attrs) then
    { reason = "unfree"; ... }
  else if hasBlocklistedLicense attrs then
    { reason = "blocklisted"; ... }
  else if hasDeniedNonSourceProvenance attrs then
    { reason = "non-source"; ... }
  else if hasDeniedBroken attrs then
    { reason = "broken"; ... }
  else if hasUnsupportedPlatform attrs && !allowUnsupportedSystem then
    { reason = "unsupported"; ... }
  else if hasDisallowedInsecure attrs then
    { reason = "insecure"; ... }
  else
    null;
```

### Reason Strings

These reason strings are used by ofBorg and other CI tools:

| Reason | Meaning |
|--------|---------|
| `unknown-meta` | Invalid meta attribute types |
| `broken-outputs` | `meta.outputsToInstall` references non-existent outputs |
| `unfree` | Unfree license and not allowed |
| `blocklisted` | License is explicitly blocklisted |
| `non-source` | Binary/non-source package and not allowed |
| `broken` | `meta.broken = true` |
| `unsupported` | Platform not in `meta.platforms` or in `meta.badPlatforms` |
| `insecure` | `meta.knownVulnerabilities` is non-empty |

## handleEvalIssue Configuration

The `config.handleEvalIssue` function allows custom handling of eval failures:

```nix
# From ci/eval/outpaths.nix
nixpkgsArgs = {
  config = {
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
  };
};
```

### Hydra Behavior

When `config.inHydra = true`:
- Error messages are shortened
- `throw` is used instead of `abort` for recoverable errors
- ofBorg can catch and categorize failures

```nix
# From check-meta.nix
inHydra = config.inHydra or false;

# Error message format differs
msg = if inHydra then
  "Failed to evaluate ${getNameWithVersion attrs}: «${invalid.reason}»: ${invalid.errormsg}"
else
  ''
    Package '${getNameWithVersion attrs}' in ${pos_str meta} ${invalid.errormsg}, refusing to evaluate.
  '' + invalid.remediation;
```

## Meta Type Validation

When `config.checkMeta = true`, meta attribute types are validated:

```nix
metaTypes = {
  description = str;
  mainProgram = str;
  longDescription = str;
  homepage = union [ (listOf str) str ];
  license = union [ (listOf licenseType) licenseType ];
  maintainers = listOf (attrsOf any);
  platforms = platforms;
  hydraPlatforms = listOf str;
  broken = bool;
  tests = { name = "test"; verify = x: x == {} || (isDerivation x && x ? meta.timeout); };
  # ... many more
};

checkMetaAttr = k: v:
  if metaTypes ? ${k} then
    if metaTypes'.${k} v then [ ]
    else [ "key 'meta.${k}' has invalid value; expected ${metaTypes.${k}.name}, got\n    ${toPretty v}" ]
  else
    [ "key 'meta.${k}' is unrecognized; expected one of: [${...}]" ];
```

## Allow Predicates

Fine-grained control over what packages are allowed:

### allowUnfreePredicate

```nix
{
  config.allowUnfree = false;
  config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "vscode" "nvidia-x11" ];
}
```

### allowBrokenPredicate

```nix
{
  config.allowBroken = false;
  config.allowBrokenPredicate = pkg:
    builtins.elem (lib.getName pkg) [ "some-temporarily-broken-pkg" ];
}
```

### allowInsecurePredicate / permittedInsecurePackages

```nix
{
  config.permittedInsecurePackages = [
    "openssl-1.0.2u"
  ];
  # or
  config.allowInsecurePredicate = pkg:
    pkg.pname == "openssl" && lib.hasPrefix "1.0" pkg.version;
}
```

## Environment Variables

Override checks via environment:

| Variable | Effect |
|----------|--------|
| `NIXPKGS_ALLOW_UNFREE=1` | Allow unfree packages |
| `NIXPKGS_ALLOW_BROKEN=1` | Allow broken packages |
| `NIXPKGS_ALLOW_INSECURE=1` | Allow insecure packages |
| `NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1` | Allow unsupported platforms |
| `NIXPKGS_ALLOW_NONSOURCE=1` | Allow binary packages |

## assertValidity Function

The final check that determines if a package can be evaluated:

```nix
assertValidity = { meta, attrs }:
  let
    invalid = checkValidity attrs;
    warning = checkWarnings attrs;
  in
  if isNull invalid then
    if isNull warning then
      { valid = "yes"; handled = true; }
    else
      # Warnings don't block evaluation
      warning // { valid = "warn"; handled = ...; }
  else
    let
      handled = if config ? handleEvalIssue
        then config.handleEvalIssue invalid.reason msg
        else throw msg;
    in
    invalid // { valid = "no"; handled = handled; };
```

The result is used in `commonMeta`:

```nix
commonMeta = { validity, attrs, pos, references }:
  {
    # ... other meta fields ...

    # Expose check results
    unfree = hasUnfreeLicense attrs;
    broken = isMarkedBroken attrs;
    unsupported = hasUnsupportedPlatform attrs;
    insecure = isMarkedInsecure attrs;

    available = validity.valid != "no"
      && ((config.checkMetaRecursively or false) ->
          all (d: d.meta.available or true) references);
  };
```

## CI Evaluation Error Handling

### builtins.tryEval Usage

For packages that might fail to evaluate:

```nix
# From release-python.nix
packagePython = mapAttrs (name: value:
  let
    res = builtins.tryEval (
      if isDerivation value then
        value.meta.isBuildPythonPackage or [ ]
      else if value.recurseForDerivations or false then
        packagePython value
      else
        [ ]
    );
  in
  optionals res.success res.value
);
```

### Hydra's Behavior

Hydra uses `nix-instantiate` or `hydra-eval-jobs` which:
1. Catches `throw` exceptions and marks the job as "eval failed"
2. Propagates `abort` exceptions, failing the entire evaluation
3. Records the error message for display in the web UI

This is why `handleEvalIssue` uses:
- `abort` for fatal errors that indicate Nixpkgs bugs
- `throw` for expected failures (broken, unsupported, etc.)
- `true` to silently skip (e.g., unfree packages in Hydra)

## Warning Checks

Non-fatal warnings that don't block evaluation:

```nix
checkWarnings = attrs:
  if hasNoMaintainers attrs then
    { reason = "maintainerless"; errormsg = "has no maintainers or teams"; ... }
  else
    null;

hasNoMaintainers = attrs:
  (!attrs ? outputHash)  # Not a FOD
  && (attrs ? meta.description)  # Looks like a real package
  && (attrs.meta.maintainers or [ ] == [ ])
  && (attrs.meta.teams or [ ] == [ ]);
```

Warnings are only shown when explicitly enabled:

```nix
{
  config.showDerivationWarnings = [ "maintainerless" ];
}
```
