vim-settings
============

Vim settings for use across different computers


# Setup / Dependencies

## General Dependencies

Install luajit

        # sudo apt-get install luajit libluajit-5.1-2 libluajit-5.1-common libluajit-5.1-dev


## Haskell setup:

        $ cabal update

Add cabal bin files to PATH and install ghc-mod

        $ echo "export PATH=$PATH:$HOME/.cabal/bin" >> ~/.bashrc
        $ cabal install ghc-mod


Compile vim
===========

We need to compile vim with all the necessary features.

Install vim dependencies

        $ sudo apt-get build-dep vim

Compile vim

        $ mkdir src
        $ cd src
        $ wget ftp://ftp.vim.org/pub/vim/unix/vim-7.4.tar.bz2
        $ tar -jxvf vim-7.4.tar.bz2
        $ cd vim-74
        $ ./configure --enable-fail-if-missing --enable-pythoninterp=yes \
            --enable-rubyinterp=dynamic --enable-cscope --enable-multibyte \
            --enable-fontset --with-features=huge --enable-luainterp=yes \
            --with-luajit --enable-gui=no --with-x --with-compiledby="Philip"
        $ make
        $ sudo make install
        $ make distclean


Install
=======

Install NeoBundle
    
        $ git clone git@github.com:Shougo/neobundle.vim.git bundle/neobundle.vim

Install all plugins
    
        $ vim +NeoBundleInstall +qa
