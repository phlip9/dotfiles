#!/usr/bin/env python3
# Install the dotfiles

import os
import os.path as path
import argparse

def force(generator):
    """Force a generator (like calling list(generator) but ignoring the
    return value)"""
    while True:
        try:
            next(generator)
        except StopIteration:
            break

def install_dotfile(dotfile):
    """install_dotfile first removes any file/directory at the install
    location and then makes a symbolic link to the local file at the
    target destination."""
    src = dotfile[0]
    dest = dotfile[1]

    if path.exists(dest):
        if path.isdir(dest) and not path.islink(dest):
            os.rmdir(dest)
        else:
            os.remove(dest)
    os.symlink(src, dest)

def install_dotfiles(dotfiles_dir, install_dir):
    dotfiles = [(path.join(dotfiles_dir, "bashrc"),
                 path.join(install_dir, ".bashrc")),
                (path.join(dotfiles_dir, "vim", "vimrc"),
                 path.join(install_dir, ".vimrc")),
                (path.join(dotfiles_dir, "vim"),
                 path.join(install_dir, ".vim")),
                (path.join(dotfiles_dir, "tmux.conf"),
                 path.join(install_dir, ".tmux.conf")),
                (path.join(dotfiles_dir, "Xresources"),
                 path.join(install_dir, ".Xresources")),
                (path.join(dotfiles_dir, "gitconfig"),
                 path.join(install_dir, ".gitconfig"))]

    force(map(install_dotfile, dotfiles))

def main():
    parse = argparse.ArgumentParser()
    parse.add_argument('--dotfiles-dir', action='store', dest='dotfiles_dir',
                       default=path.dirname(path.abspath(__file__)), type=str,
                       help="""Directory of the dotfiles to install (defaults
                       to the script directory).""")
    parse.add_argument('--install-dir', action='store', dest='install_dir',
                       default=os.getenv('HOME'), type=str,
                       help="""Where to install the dotfiles (defaults to
                       $HOME).""")

    args = parse.parse_args()

    dotfiles_dir = path.abspath(args.dotfiles_dir)
    install_dir = path.abspath(args.install_dir)

    install_dotfiles(dotfiles_dir, install_dir)

if __name__ == "__main__":
    main()
