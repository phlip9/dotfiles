# writeTypedPython3Bin - `writers.writePython3Bin`, but the build also
# typechecks the script w/ ty, against its `libraries`.
#
# ex: writeTypedPython3Bin "hello" { libraries = [ python3Packages.rich ]; }
#       ./hello.py
{
  lib,
  python3,
  python3Packages,
  ty,
  writeShellScript,
  writers,
}:
name:
{
  libraries ? [ ],
  flakeIgnore ? [ ],
  doCheck ? true,
  ...
}@args:
let
  # The script's runtime python, so ty resolves its imports.
  python = python3.withPackages (lib.toFunction libraries);

  ignoreArg = lib.optionalString (flakeIgnore != [ ]) (
    "--ignore " + lib.concatMapStringsSep "," lib.escapeShellArg flakeIgnore
  );

  # Same flake8 check as nixpkgs' writers, but w/ the repo's 80-column limit
  # (flake8 default: 79), then ty. ty checks a file w/o a .py extension fine
  # when given its path.
  check = writeShellScript "python-check.sh" ''
    set -euo pipefail
    ${python3Packages.flake8}/bin/flake8 --show-source --max-line-length 80 \
      ${ignoreArg} "$1"
    ${ty}/bin/ty check --python ${python} --error-on-warning \
      --no-progress --color never "$1"
  '';
in
writers.makeScriptWriter (
  (removeAttrs args [
    "libraries"
    "flakeIgnore"
    "doCheck"
  ])
  // {
    inherit (python) interpreter;
    check = lib.optionalString doCheck check;
  }
) "/bin/${name}"
