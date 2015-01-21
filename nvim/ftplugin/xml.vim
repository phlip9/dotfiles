" xml vim settings
setlocal tabstop=2                   " A tab is 2 spaces
setlocal expandtab                   " Always uses spaces instead of tabs
setlocal softtabstop=2               " Insert 2 spaces when tab is pressed
setlocal shiftwidth=2                " An indent is 2 spaces
setlocal smarttab                    " Indent instead of tab at start of line
setlocal shiftround                  " Round spaces to nearest shiftwidth multiple
setlocal nojoinspaces                " Don't convert spaces to tabs

setlocal omnifunc=xmlcomplete#CompleteTags
