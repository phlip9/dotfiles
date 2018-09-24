nvim-settings
=============

Neovim settings for use across different computers


## Setup / Dependencies ##


### General Dependencies ###

        $ sudo apt-get install rsync silversearcher-ag
        $ sudo pip3 install neovim


### _Optional_: Powerline fonts ###

Install patched powerline fonts from: https://github.com/powerline/fonts


### _Optional_: Haskell setup ###

        $ cabal update
        $ cabal install ghc-mod


### _Optional_: Rust setup ###

Install `rustc`:

        $ git clone git@github.com:rust-lang/rust.git
        $ cd rust
        $ ./configure
        $ make
        $ sudo make install
        $ make clean

Install `cargo`:

        $ git clone --recursive https://github.com/rust-lang/cargo
        $ cd cargo
        $ ./configure
        $ make
        $ sudo make install
        $ make clean

Install `racer`:

        $ cargo install racer


### _Optional_: C/C++ setup ###

Install clang

        $ sudo apt-get install clang


### Neovim ###

Install `nvim` dependencies

        $ sudo apt-get install libtool libtool-bin autoconf automake cmake g++ pkg-config unzip

Compile and install `nvim`

        $ git clone git@github.com:neovim/neovim.git
        $ cd neovim
        $ make CMAKE_BUILD_TYPE=Release
        $ sudo make install
        $ make clean


### Install ###

Install neovim/python-client

        $ sudo pip3 install --upgrade neovim

Install dein plugin manager
    
        $ git clone git@github.com:Shougo/dein.vim.git plugins/repos/github.com/Shougo/dein.vim

Install all plugins
    
        $ nvim +":call dein#update()" +qa
