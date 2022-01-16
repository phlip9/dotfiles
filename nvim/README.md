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

To efficiently download and install all patched Source Code Pro fonts:

```bash
$ cd ~/.local/share/fonts
$ curl https://github.com/powerline/fonts/tree/master/SourceCodePro \
    | sed -n -e 's/^.*href="\(.*\.otf\)".*$/https:\/\/github.com\1?raw=true/p' \
    | xargs wget
$ ls \
    | sed -n -e 's/^\(.*\)?raw=true/\1/p' \
    | xargs -p -I'{}' mv '{}'?raw=true '{}'
```


### _Optional_: Haskell setup ###

```
$ cabal update
$ cabal install ghc-mod
```


### _Optional_: Rust setup ###

```
$ curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash

#  default host triple: default
#    default toolchain: stable
#              profile: default
# modify PATH variable: no

$ rustup update nightly
$ rustup component add rust-src rustfmt clippy

# Install rusty-tags
$ cargo install rusty-tags

# Generate tags
$ cd my_rust_project/
$ rusty-tags vi

# Install cargo watch
$ RUSTFLAGS="-C target-cpu=native" cargo install cargo-watch

# Install rust-analyzer
$ git clone https://github.com/rust-analyzer/rust-analyzer
$ cd rust-analyzer
$ RUSTFLAGS="-C target-cpu=native" cargo xtask install --server --jemalloc

# (OSX) If rust-lldb doesn't work:
$ brew unlink python
$ brew unlink python@2
```


### _Optional_: C/C++ setup ###

Install clang

```
# (Debian|Ubuntu)
$ sudo apt install clang
```


### _Optional_: Install ripgrep ###

```
$ RUSTFLAGS="-C target-cpu=native" cargo +nightly install --features="simd-accel" ripgrep
```


### _Optional_: Install Other Rust Utilities ###

```
$ RUSTFLAGS="-C target-cpu=native" cargo install bat exa fastmod fd-find
```


### _Optional_: Install FZF ###

```
$ git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
$ ~/.fzf/install

# fuzzy auto-completion (y)
# key bindings          (y)
# update shell config   (n)
```


### _Optional_: Install Universal Ctags ###

```
# (OSX)
$ brew install --HEAD universal-ctags/universal-ctags/universal-ctags

# (Other)
$ git clone git@github.com:universal-ctags/ctags.git
$ cd ctags
$ ./autogen.sh
$ ./configure
$ make && sudo make install
```


### _Optional_: Install picolisp (Scheme auto-formatting) ###

```bash
# (Ubuntu/Debian/WSL)
$ sudo apt install picolisp
```

## Neovim ##


Setup a Python virtual environment for neovim:

```
# (Ubuntu/Debian/WSL) Install venv
$ sudo apt install python3.9-venv

$ mkvenv nvim_py
$ workon nvim_py

# Make sure the installed pip is up-to-date
$ pip install --upgrade pip
# Ensure that we remove the old neovim python package first
$ pip uninstall neovim pynvim
$ pip install pynvim
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
$ sudo apt ninja-build gettext libtool libtool-bin autoconf automake cmake g++ pkg-config unzip curl doxygen
$ 

# (RHEL|Fedora|CentOS)
$ sudo yum install libtool ninja-build cmake
```

Compile and install `nvim`

```
$ git clone git@github.com:neovim/neovim.git
$ cd neovim
$ git checkout v0.6.0
$ make CMAKE_BUILD_TYPE=Release
$ sudo make install
$ make distclean
```


### Install coc.nvim dependencies (nvm, nodejs, yarn)

```
# (OSX)
$ brew install node yarn

# (Other) Install node using nvm
$ curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash
$ nvm install --lts

# (Other) Install node using direct install
$ curl --proto '=https' --tlsv1.2 -sSf https://install-node.now.sh/lts | bash

# (Other) Install yarn
$ curl --proto '=https' --tlsv1.2 -sSfL https://yarnpkg.com/install.sh | bash 

# If dein doesn't auto-build coc.nvim, you may need to invoke yarn manually
$ cd nvim/plugins/repos/github.com/neoclide/coc.nvim
$ yarn install --frozen-lockfile
```


### Install Plugins ###

Install all plugins

```
$ nvim +":call dein#update()" +qa
$ nvim +":UpdateRemotePlugins" +qa
```

If dein.vim complains about git clone key permissions, do this then try again:

```
$ cd $XDG_CONFIG_HOME/nvim/plugins/repos/github.com/Shougo/dein.vim
$ git remote set-url origin https://github.com/Shougo/dein.vim.git
```
