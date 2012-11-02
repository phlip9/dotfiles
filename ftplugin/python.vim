" Python config file
" comply /w pep8 and indent smarter
" see http://henry.precheur.org/vim/python
setlocal tabstop=4
setlocal softtabstop=4
setlocal shiftwidth=4
" setlocal textwidth=79         " this is annoying
setlocal smarttab
setlocal expandtab

" python press F5 to run
nnoremap <F5> :w!<CR>:!python %<CR>

" autocomplete
set omnifunc=pythoncomplete#Complete
