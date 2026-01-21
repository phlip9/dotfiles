settings {
    nodaemon = true,
}
sync {
    default.rsyncssh,
    source = "/home/phlip9/dev/dotfiles",
    host = "omnara1",
    targetdir = "/home/phlip9/dev/dotfiles",
    exclude = {
        "*~",
        ".git/",
    },
    excludeFrom = "/home/phlip9/dev/rust-sgx/.gitignore",
    rsync = {
        archive = true,
        compress = true,
    },
    delay = 1,
}
