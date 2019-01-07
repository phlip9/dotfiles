nvim-settings
=============

Neovim settings for use across different computers


## Setup / Dependencies ##


### _Optional_: Powerline fonts ###

To get specialized glyphs like arrows, git symbols, etc... in the neovim status
bar, then install patched powerline fonts from:
https://github.com/powerline/fonts

I use the SourceCodePro font, so I would download and install the fonts from:
https://github.com/powerline/fonts/tree/master/SourceCodePro


### _Optional_: Haskell setup ###

```
$ cabal update
$ cabal install ghc-mod
```


### _Optional_: Rust setup ###

```
$ curl https://sh.rustup.rs -sSf | sh
$ rustup update nightly
$ rustup default nightly
$ rustup component add rust-src rustfmt-preview rls-preview rust-analysis
$ cargo +nightly install rusty-tags

# Generate tags
$ cd my_rust_project/
$ rusty-tags vi
```


### _Optional_: C/C++ setup ###

Install clang

```
# (Debian|Ubuntu)
$ sudo apt-get install clang
```


### _Optional_: Install FZF / Ripgrep ###

```
# (OSX)
$ brew install fzf ripgrep
$ . /usr/local/opt/fzf/install
```


### _Optional_: Install Universal Ctags ###

```
# (OSX)
$ brew install --HEAD universal-ctags/universal-ctags/universal-ctags
```

## Neovim ##


Setup a Python virtual environment for neovim:

```
$ mkvenv nvim_py
$ workon nvim_py

# Make sure the installed pip is up-to-date
$ pip install --upgrade pip
$ pip install neovim
$ deactivate
```


### (OSX) Install Neovim using Brew ###

```
$ brew install nvim
```


### (Unix) Build Neovim from source ###


Install `nvim` build dependencies

```
# (Debian|Ubuntu)
$ sudo apt-get install libtool libtool-bin autoconf automake cmake g++ pkg-config unzip

# (RHEL|Fedora|CentOS)
$ sudo yum install libtool ninja-build cmake
```

Compile and install `nvim`

```
$ git clone git@github.com:neovim/neovim.git
$ cd neovim
$ make CMAKE_BUILD_TYPE=Release
$ sudo make install
$ make distclean
```


### Install Plugins ###

Install `dein` plugin manager

```
$ cd dotfiles/nvim
$ git clone git@github.com:Shougo/dein.vim.git plugins/repos/github.com/Shougo/dein.vim
```


### Install Plugins ###

Install all plugins

```
$ nvim +":call dein#update()" +qa
$ nvim +":UpdateRemotePlugins" +qa
```
