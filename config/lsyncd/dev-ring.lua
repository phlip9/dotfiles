settings {
    nodaemon = true,
}
sync {
    default.rsyncssh,
    source = "/home/phlip9/dev/ring",
    host = "phlip9@lexe-dev",
    targetdir = "/home/phlip9/dev/ring",
    exclude = {
        "*~",
        ".git/",
        "/result",
        "/result-*",
        "/result.*",
        "target/",
    },
    rsync = {
        archive = true,
        compress = true,
    },
    delay = 1,
}
