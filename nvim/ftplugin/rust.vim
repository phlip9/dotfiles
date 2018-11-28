setlocal tabstop=4
setlocal softtabstop=4
setlocal shiftwidth=4
setlocal smarttab
setlocal expandtab

setlocal omnifunc=racer#Complete

" Rust ctags
" ==========
"             ./tags;  search for `tags` file from current file downwards
"               tags;  search for `tags` file from cwd downwards
" $RUST_SRC_PATH/tags  Use rust src tags
setlocal tags=./tags;,tags;,$RUST_SRC_PATH/tags

" TODO: Uncomment when deoplete supports custom completion patterns
" let g:neocomplete#sources#omni#input_patterns.rust = '[^.[:digit:] *\t]\%(\.\|->\)\w*\|\h\w*::\w*'

