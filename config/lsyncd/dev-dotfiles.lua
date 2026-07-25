settings {
    nodaemon = true,
}
sync {
    default.rsyncssh,
    source = "/home/phlip9/dev/dotfiles",
    host = "sauna",
    targetdir = "/home/phlip9/dev/dotfiles",
    exclude = {
        "*~",
        ".git/",
    },
    excludeFrom = "/home/phlip9/dev/dotfiles/.gitignore",
    rsync = {
        archive = true,
        compress = true,
    },
    delay = 1,
}
