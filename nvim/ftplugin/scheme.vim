setlocal tabstop=2
setlocal softtabstop=2
setlocal shiftwidth=2
setlocal smarttab
setlocal expandtab

if executable('picolispfmt')
    setlocal equalprg='picolispfmt'
endif

hi Delimiter ctermfg=166
