# nix package set configuration
# - allow unfree android SDK packages
let
  # allowed unfree package names
  allowed = {
    android-sdk-build-tools = null;
    android-sdk-cmdline-tools = null;
    android-sdk-ndk = null;
    android-sdk-platform-tools = null;
    android-sdk-platforms = null;
    android-sdk-tools = null;
    build-tools = null;
    cmake = null;
    cmdline-tools = null;
    ndk = null;
    platform-tools = null;
    platforms = null;
    tools = null;
  };

  # inlined lib.getName to avoid circular dependency
  getName = x:
    if builtins.isString x
    then (builtins.parseDrvName x).name
    else x.pname or (builtins.parseDrvName x.name).name;
in {
  android_sdk.accept_license = true;
  allowUnfreePredicate = pkg: allowed ? ${getName pkg};
}
