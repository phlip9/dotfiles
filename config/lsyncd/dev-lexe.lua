settings {
    nodaemon = true,
}
sync {
    default.rsyncssh,
    source = "/home/phlip9/dev/lexe",
    host = "phlip9@lexe-dev",
    targetdir = "/home/phlip9/dev/lexe",
    exclude = {
        "**/doc/api/",
        "**/ios/Flutter/.last_build_id",
        "*~",
        ".dart_tool/",
        ".flutter-plugins",
        ".flutter-plugins-dependencies",
        ".git/",
        ".gradle",
        ".packages",
        ".pub-cache/",
        ".pub/",
        "/build/",
        "app.*.map.json",
        "app.*.symbols",
    },
    excludeFrom = "/home/phlip9/dev/lexe/.gitignore",
    rsync = {
        archive = true,
        compress = true,
    },
    delay = 1,
}
