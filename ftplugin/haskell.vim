" Haskell Vim settings "
set tabstop=8                   " A tab is 8 spaces
set expandtab                   " Always uses spaces instead of tabs
set softtabstop=8               " Insert 8 spaces when tab is pressed
set shiftwidth=4                " An indent is 4 spaces
set smarttab                    " Indent instead of tab at start of line
set shiftround                  " Round spaces to nearest shiftwidth multiple
set nojoinspaces                " Don't convert spaces to tabs

" ghcmod.vim keybindings "
" ====================== "

" Print type info "
nnoremap <leader>hi :GhcModInfo<CR>

" Insert type "
nnoremap <leader>ht :GhcModTypeInsert<CR>
