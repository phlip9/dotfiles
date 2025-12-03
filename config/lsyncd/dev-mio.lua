settings {
    nodaemon = true,
}
sync {
    default.rsyncssh,
    source = "/home/phlip9/dev/mio",
    host = "phlip9@lexe-dev",
    targetdir = "/home/phlip9/dev/mio",
    exclude = {
        "*~",
        ".git/",
        "/result",
        "/result-*",
        "/result.*",
        "target/",
    },
    excludeFrom = "/home/phlip9/dev/mio/.gitignore",
    rsync = {
        archive = true,
        compress = true,
    },
    delay = 1,
}
