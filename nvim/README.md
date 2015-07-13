vim-settings
============

Vim settings for use across different computers


## Setup / Dependencies ##


### General Dependencies ###

Install ag (the silver searcher)

        $ sudo apt-get install silversearcher-ag
        $ sudo pip3 install neovim


### _Optional_: Haskell setup ###

        $ cabal update

Add cabal bin files to PATH and install ghc-mod

        $ echo "export PATH=$PATH:$HOME/.cabal/bin" >> ~/.bashrc
        $ cabal install ghc-mod


### Compile neovim ###

We need to compile vim with all the necessary features.

Install nvim dependencies

        $ sudo apt-get install libtool autoconf automake cmake libncurses5-dev g++ pkg-config unzip ninja-build

Compile nvim

        $ git clone git@github.com:neovim/neovim.git
        $ cd neovim
        $ make
        $ sudo make install
        $ make clean


### Install ###

Install NeoBundle
    
        $ git clone git@github.com:Shougo/neobundle.vim.git bundle/neobundle.vim

Install all plugins
    
        $ nvim +NeoBundleInstall +qa
