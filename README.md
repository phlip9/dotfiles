phlip9's dotfiles
=================

+ Install neovim:
https://github.com/phlip9/dotfiles/blob/master/nvim/README.md


# New Machine Setup #


### Create a new ssh keypair and add to Github ###

```
$ ssh-keygen -t ed25519
```

+ Add the key to: https://github.com/settings/keys

+ Append the following to `~/.ssh/config`:

```
Host *
    UseKeychain yes
    AddKeysToAgent yes
    IdentityFile ~/.ssh/id_ed25519
```

```
# (OSX) Add private key to keychain
$ ssh-add -AK ~/.ssh/id_ed25519
```

## Debian|Ubuntu|WSL ##


### Install tmux ###

+ Install tmux build dependencies

```
$ sudo apt install m4 libevent-dev libncurses5-dev autogen automake pkg-config libtool perl bison
```

+ Build tmux from source

```
$ cd ~/dev
$ git clone git@github.com:tmux/tmux.git
$ cd tmux
$ git checkout 3.0
$ ./autogen.sh
$ ./configure
$ make && sudo make install
```


## OSX ##


### Clone phlip9/dotfiles ###

```
$ mkdir ~/dev
$ cd ~/dev
$ git clone https://github.com/phlip9/dotfiles.git
$ cd dotfiles

# upgrade pip
$ sudo -H python3.6 -m pip install --upgrade pip

# run dotfiles install
$ python3.6 install.py

# source our personal bashrc settings
$ echo "[ -f ~/.bashrc ] && source ~/.bashrc" >> ~/.bash_profile
$ source ~/.bash_profile
```


### Install Brew ###

```
$ curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/Homebrew/install/master/install.sh | bash
$ brewperm
```


### Install tmux ###

```
$ brew install tmux
```


### Install Magnets from the Apple App Store ###


### Install Irssi for IRC ###

```
brew install irssi
```


### Install Karabiner for Caps Lock (tap) -> Escape ###

+ Download and install from:
  https://pqrs.org/osx/karabiner/index.html

+ Under complex rules, hit import from internet

+ Import the Caps Lock rev. 2 rules

+ Unmap Escape

+ Remap Caps Lock -> Control when as a modifier and Escape when hit alone



## RHEL|Fedora|CentOS ##


## Setup the dotfiles

```
$ mkdir ~/dev
$ cd ~/dev
$ git clone git@github.com:phlip9/dotfiles.git
$ python3.6 install.py
```


## Install autoconf/automake

```
sudo yum install autoconf automake
```


## Upgrade `tmux`

+ The default tmux version (2.2) is too old.

```
$ git clone git@github.com:tmux/tmux.git
$ cd tmux
$ git checkout 3.0
$ sudo yum install libevent-devel ncurses-devel
$ ./autogen.sh
$ ./configure
$ make && sudo make install
```


### Windows/WSL-specific

## Install wsltty

+ Pretty much the only terminal emulator that supports tmux
+ https://github.com/mintty/wsltty
