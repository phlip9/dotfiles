#!/usr/bin/env python3
# Install the dotfiles

import os.path as path
import os

def force(generator):
    while True:
        try:
            next(generator)
        except StopIteration:
            break

def install_dotfile(dotfile):
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
              path.join(install_dir, ".Xresources"))]

    force(map(install_dotfile, dotfiles))

if __name__=="__main__":
    dotfiles_dir = path.dirname(path.abspath(__file__))
    install_dir = "/home/phlip9"
    install_dotfiles(dotfiles_dir, install_dir)
