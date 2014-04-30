" Haskell Vim settings "
setlocal tabstop=8                   " A tab is 8 spaces
setlocal expandtab                   " Always uses spaces instead of tabs
setlocal softtabstop=8               " Insert 8 spaces when tab is pressed
setlocal shiftwidth=4                " An indent is 4 spaces
setlocal smarttab                    " Indent instead of tab at start of line
setlocal shiftround                  " Round spaces to nearest shiftwidth multiple
setlocal nojoinspaces                " Don't convert spaces to tabs

" ghcmod.vim keybindings "
" ====================== "

" Print identifier info "
nnoremap <leader>hn :GhcModInfo<CR>

" Insert subexpression type "
nnoremap <leader>hi :GhcModTypeInsert<CR>

" Print subexpression type "
nnoremap <leader>ht :GhcModType<CR>
