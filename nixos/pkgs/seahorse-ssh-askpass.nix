{
  runCommand,
  seahorse,
}:

runCommand "seahorse-ssh-askpass" { } ''
  mkdir -p $out/bin
  ln -s ${seahorse}/libexec/seahorse/ssh-askpass $out/bin/seahorse-ssh-askpass
''
