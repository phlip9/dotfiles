{pkgs, ...}: {
  # Fucking java garbage. Just add `$JAVA_HOME` instead of polluting my `$PATH`.
  programs.bash.initExtra = ''
    export JAVA_HOME=${pkgs.jdk11_headless.home}
  '';
}
