phlip9's dotfiles
=================

+ Install neovim:
https://github.com/phlip9/dotfiles/blob/master/nvim/README.md


# New Machine Setup #


### Create a new ssh keypair and add to Github ###

```
$ ssh-keygen -t ed25519
```

Add the key to:
https://github.com/settings/keys


## Debian|Ubuntu ##


TODO


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
$ echo ". ~/.bashrc" >> ~/.bash_profile
$ source ~/.bash_profile
```


### Install Brew ###

```
$ /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
$ sudo chown -R $(whoami) /usr/local/lib /usr/local/sbin
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
$ cd ~/dev
$ git clone git@github.com:tmux/tmux.git
$ cd tmux
$ git checkout 2.7
$ sudo yum install libevent-devel ncurses-devel
$ ./autogen.sh
$ ./configure
$ make && sudo make install
```
