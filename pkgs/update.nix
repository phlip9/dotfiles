# Run: nix-shell pkgs/update.nix
# Or:  nix-shell pkgs/update.nix --arg packageNames '[ "claude-code" "codex" ]'
{
  packageNames ? [ ],
}:
let
  dotfiles = import ../. { };
  inherit (dotfiles) lib pkgs;
  inherit (builtins)
    listToAttrs
    removeAttrs
    toJSON
    toString
    tryEval
    ;

  # Package definitions live in the stable and NixOS package sets.
  pkgsDirs = map toString [
    ./.
    ../nixos/pkgs
  ];

  # Packages that can't be evaluated (missing deps, use abort which tryEval
  # can't catch)
  skipPackages = [ ];

  # Attach each package's full top-level attr path before merging package sets.
  mkPackageDefs =
    attrPrefix: packageSet:
    lib.mapAttrs (name: package: {
      attrPath = "${attrPrefix}.${name}";
      inherit package;
    }) packageSet;

  phlipPackageDefs = mkPackageDefs "phlipPkgs" dotfiles.phlipPkgs;
  phlipNixosPackageDefs = mkPackageDefs "phlipPkgsNixos" dotfiles.phlipPkgsNixos;

  # NixOS packages take precedence when both sets define the same attr.
  packageDefs = removeAttrs (
    phlipPackageDefs // phlipNixosPackageDefs
  ) skipPackages;

  # Check if package is defined in pkgs/ or nixos/pkgs/ via meta.position
  isLocalPackage =
    pkg:
    let
      pos = pkg.meta.position or null;
      # meta.position is "path:line", extract the path
      filePath = if pos != null then lib.head (lib.splitString ":" pos) else null;
    in
    filePath != null
    && lib.any (pkgsDir: lib.hasPrefix "${pkgsDir}/" filePath) pkgsDirs;

  # Try to get a package with updateScript, returns null if eval fails or no
  # updateScript
  tryUpdatablePackageDef =
    packageDef:
    let
      result = tryEval (
        let
          pkg = packageDef.package;
        in
        if lib.isDerivation pkg && pkg ? updateScript && isLocalPackage pkg then
          packageDef
        else
          null
      );
    in
    if result.success then result.value else null;

  # Find all packages with updateScript (filter out nulls from failed evals)
  packagesWithUpdateScript = lib.filterAttrs (_: packageDef: packageDef != null) (
    lib.mapAttrs (_: tryUpdatablePackageDef) packageDefs
  );

  # Select requested packages, or every updatable package when none are given.
  packages =
    if packageNames != [ ] then
      listToAttrs (
        map (
          pkgName:
          let
            packageDef = packageDefs.${pkgName} or (throw "Package '${pkgName}' not found");
            pkg = packageDef.package;
          in
          if pkg.updateScript or null == null then
            throw "Package '${pkgName}' has no updateScript"
          else
            {
              name = pkgName;
              value = packageDef;
            }
        ) packageNames
      )
    else
      packagesWithUpdateScript;

  # Normalize updateScript to command list
  getUpdateScript =
    pkg:
    let
      script = pkg.updateScript;
    in
    map toString (lib.toList (script.command or script));

  # Build package data for runner
  packageData = lib.mapAttrs (
    _: packageDef:
    let
      pkg = packageDef.package;
    in
    {
      inherit (packageDef) attrPath;
      name = pkg.name;
      pname = lib.getName pkg;
      oldVersion = lib.getVersion pkg;
      updateScript = getUpdateScript pkg;
    }
  ) packages;

  packagesJson = pkgs.writeText "packages.json" (
    toJSON (lib.attrValues packageData)
  );

in
pkgs.mkShellNoCC {
  packages = with pkgs; [
    bash
    curl
    jq
    ripgrep
  ];
  shellHook = ''
    exec ${./update.sh} ${packagesJson}
  '';

  passthru = {
    inherit packageData packagesJson;
  };
}
