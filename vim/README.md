vim-settings
============

Vim settings for use across different computers

Install
=======

Install NeoBundle:
    
    git clone git@github.com:Shougo/neobundle.vim.git bundle/neobundle.vim

Install all of the plugins:
    
    vim +NeoBundleInstall +qall

Build vimproc:
    
    cd bundle/vimproc.vim/ && make

Build YouCompleteMe:

    cd bundle/YouCompleteMe && ./install.sh

Dependencies:
=============

 - vim compiled with +python
 - pip
 - pep8
 - ruby
 - rake
 - pytest
 - nose
 - ack
 - pyflakes

Haskell setup:
==============

Update cabal

    cabal update

Add cabal bin files to PATH

    echo "export PATH=$PATH:$HOME/.cabal/bin" >> ~/.bashrc

Install ghc-mod
    
    cabal install ghc-mod
