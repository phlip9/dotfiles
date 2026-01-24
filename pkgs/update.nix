# Run: nix-shell pkgs/update.nix
# Or:  nix-shell pkgs/update.nix --argstr package claude-code
{
  package ? null,
}:
let
  dotfiles = import ../. { };
  inherit (dotfiles) lib pkgs;

  # Path to local pkgs directory
  pkgsDir = toString ./.;

  # Packages that can't be evaluated (missing deps, use abort which tryEval
  # can't catch)
  skipPackages = [
    "noctalia-shell" # requires quickshell which isn't in standard package set
  ];

  # All phlipPkgs except skipped ones
  phlipPkgs = builtins.removeAttrs dotfiles.phlipPkgs skipPackages;

  # Check if package is defined in local pkgs/ directory via meta.position
  isLocalPackage =
    pkg:
    let
      pos = pkg.meta.position or null;
      # meta.position is "path:line", extract the path
      filePath = if pos != null then lib.head (lib.splitString ":" pos) else null;
    in
    filePath != null && lib.hasPrefix pkgsDir filePath;

  # Try to get a package with updateScript, returns null if eval fails or no
  # updateScript
  tryGetPackageWithUpdateScript =
    name:
    let
      result = builtins.tryEval (
        let
          pkg = phlipPkgs.${name};
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
  packagesWithUpdateScript = builtins.listToAttrs (
    builtins.filter (x: x != null) (
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
      ) (lib.attrNames phlipPkgs)
    )
  );

  # Select package(s) to update
  packages =
    if package != null then
      let
        pkg = phlipPkgs.${package} or (throw "Package '${package}' not found");
      in
      if pkg.updateScript or null == null then
        throw "Package '${package}' has no updateScript"
      else
        { ${package} = pkg; }
    else
      packagesWithUpdateScript;

  # Normalize updateScript to command list
  getUpdateScript =
    pkg:
    let
      script = pkg.updateScript;
    in
    map builtins.toString (lib.toList (script.command or script));

  # Build package data for runner
  packageData = lib.mapAttrs (name: pkg: {
    name = pkg.name;
    pname = lib.getName pkg;
    oldVersion = lib.getVersion pkg;
    attrPath = name;
    updateScript = getUpdateScript pkg;
  }) packages;

  packagesJson = pkgs.writeText "packages.json" (
    builtins.toJSON (lib.attrValues packageData)
  );

in
pkgs.mkShellNoCC {
  packages = [
    pkgs.jq
    pkgs.bash
  ];
  shellHook = ''
    exec ${./update.sh} ${packagesJson}
  '';

  passthru = {
    inherit packageData packagesJson;
  };
}
