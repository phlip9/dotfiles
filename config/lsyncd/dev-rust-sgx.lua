settings {
    nodaemon = true,
}
sync {
    default.rsyncssh,
    source = "/home/phlip9/dev/rust-sgx",
    host = "phlip9@lexe-dev",
    targetdir = "/home/phlip9/dev/rust-sgx",
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
