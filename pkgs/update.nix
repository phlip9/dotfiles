# Run: nix-shell pkgs/update.nix
# Or:  nix-shell pkgs/update.nix --arg packageNames '[ "claude-code" "codex" ]'
{
  packageNames ? [ ],
}:
let
  dotfiles = import ../. { };
  inherit (dotfiles) lib pkgs;
  inherit (builtins)
    filter
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

  # All phlipPkgs and phlipPkgsNixos except skipped ones.
  phlipPkgsCombined = removeAttrs (
    dotfiles.phlipPkgs // dotfiles.phlipPkgsNixos
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
  tryGetPackageWithUpdateScript =
    name:
    let
      result = tryEval (
        let
          pkg = phlipPkgsCombined.${name};
        in
        if lib.isDerivation pkg && pkg ? updateScript && isLocalPackage pkg then
          pkg
        else
          null
      );
    in
    if result.success && result.value != null then
      {
        inherit name;
        pkg = result.value;
      }
    else
      null;

  # Find all packages with updateScript (filter out nulls from failed evals)
  packagesWithUpdateScript = listToAttrs (
    filter (x: x != null) (
      map (
        name:
        let
          r = tryGetPackageWithUpdateScript name;
        in
        if r != null then
          {
            name = r.name;
            value = r.pkg;
          }
        else
          null
      ) (lib.attrNames phlipPkgsCombined)
    )
  );

  # Select requested packages, or every updatable package when none are given.
  packages =
    if packageNames != [ ] then
      listToAttrs (
        map (
          pkgName:
          let
            pkg = phlipPkgsCombined.${pkgName} or (throw "Package '${pkgName}' not found");
          in
          if pkg.updateScript or null == null then
            throw "Package '${pkgName}' has no updateScript"
          else
            {
              name = pkgName;
              value = pkg;
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
  packageData = lib.mapAttrs (name: pkg: {
    name = pkg.name;
    pname = lib.getName pkg;
    oldVersion = lib.getVersion pkg;
    attrPath = name;
    updateScript = getUpdateScript pkg;
  }) packages;

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
