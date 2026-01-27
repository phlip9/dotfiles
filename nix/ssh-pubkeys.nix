# Parse `./phlip9.keys` into a list of ssh pubkeys
let
  inherit (builtins)
    readFile
    filter
    split
    isString
    stringLength
    substring
    ;

  startsWith = (str: prefix: substring 0 (stringLength prefix) str == prefix);

  # Read the keys file
  keysTxt = readFile ./phlip9.keys;
  isPubkeyString = s: isString s && stringLength s > 0 && !startsWith s "#";
in

filter isPubkeyString (split "\n" keysTxt)
