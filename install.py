#!/usr/bin/env python3
# Install the dotfiles

import argparse
import errno
import os
import os.path as path
import shutil
import subprocess


def force(generator):
    """
    Force a generator (like calling list(generator) but ignoring the
    return value)
    """
    while True:
        try:
            next(generator)
        except StopIteration:
            break


def mkdirs(filename):
    dirname = path.dirname(filename)
    try:
        os.makedirs(dirname)
    except OSError as e:
        if e.errno != errno.EEXIST:
            raise e


def install_dotfile(dotfile):
    """
    install_dotfile first removes any file/directory at the install
    location and then makes a symbolic link to the local file at the
    target destination.
    """
    src = dotfile[0]
    dest = dotfile[1]

    print("Installing symlink from %s to %s" % (src, dest))

    if path.exists(dest):
        if path.isdir(dest) and not path.islink(dest):
            shutil.rmtree(dest)
        else:
            os.remove(dest)
    else:
        mkdirs(dest)

    os.symlink(src, dest)


def install_dotfiles(dotfiles_dir, install_dir):
    dotfiles = [
                #  (path.join(dotfiles_dir, "bashrc"),
                #   path.join(install_dir, ".bashrc")),
                #  (path.join(dotfiles_dir, "nvim"),
                #   path.join(install_dir, ".config", "nvim")),
                #  (path.join(dotfiles_dir, "tmux.conf"),
                #   path.join(install_dir, ".tmux.conf")),
                #  (path.join(dotfiles_dir, "urxvt"),
                #   path.join(install_dir, ".urxvt")),
                #  (path.join(dotfiles_dir, "Xresources"),
                #   path.join(install_dir, ".Xresources")),
                #  (path.join(dotfiles_dir, "Xresources"),
                #   path.join(install_dir, ".Xdefaults")),
                #  (path.join(dotfiles_dir, "inputrc"),
                #   path.join(install_dir, ".inputrc")),
                #  (path.join(dotfiles_dir, "config", "git"),
                #   path.join(install_dir, ".config", "git")),
                #  (path.join(dotfiles_dir, "irssi"),
                #   path.join(install_dir, ".irssi")),
                (path.join(dotfiles_dir, "ctags.d"),
                 path.join(install_dir, ".ctags.d")),
                #  (path.join(dotfiles_dir, "rusty-tags"),
                #   path.join(install_dir, ".rusty-tags")),
                (path.join(dotfiles_dir, "alacritty.yml"),
                 path.join(install_dir, ".config", "alacritty", "alacritty.yml")),
                ]

    # instead of linking the whole dotfiles/bin directory, we'll link each
    # individual script
    scripts = os.listdir(path.join(dotfiles_dir, "bin"))
    scripts = filter(lambda script: path.isfile(path.join(dotfiles_dir, "bin", script)), scripts)
    scripts = ((path.join(dotfiles_dir, "bin", script),
                path.join(install_dir, ".local", "bin", script))
               for script in scripts)
    dotfiles.extend(scripts)

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
