/^# regenerate timep_flamegraph.pl$/ {
    print "# nix patch: copy packaged timep_flamegraph.so into timep tmpdir"
    print "cp -f " timepFlamegraphPl " \"${timep_TMPDIR0}/lib/${USER}-${EUID}/timep_flamegraph.pl\""
    skip = 1
    next
}
/^# regenerate timep\.so$/ {
    print "# nix patch: copy packaged timep.so into timep tmpdir"
    print "cp -f " timepSo " \"${timep_TMPDIR0}/lib/${USER}-${EUID}/timep.so\""
    skip = 1
    next
}
skip && /^EEEOOOFFF$/ {
    skip = 0
}
!skip {
    print
}
