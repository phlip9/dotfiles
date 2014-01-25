#!/usr/bin/env python3
# Install the dotfiles

import os.path as path
from os import symlink

def install_vim(dotfiles_dir, install_dir):
    symlink(path.join(dotfiles_dir, "vim"),
            path.join(install_dir, ".vim"))

    symlink(path.join(dotfiles_dir, "vim", "vimrc"),
            path.join(install_dir, ".vimrc"))

def install_xresources(dotfiles_dir, install_dir):
    symlink(path.join(dotfiles_dir, "Xresources"),
            path.join(install_dir, ".Xresources"))

def install_dotfiles(dotfiles_dir, install_dir):
    install_vim(dotfiles_dir, install_dir)
    install_xresources(dotfiles_dir, install_dir)

if __name__=="__main__":
    dotfiles_dir = path.dirname(path.abspath(__file__))
    install_dir = "/home/phlip9"
    install_dotfiles(dotfiles_dir, install_dir)
