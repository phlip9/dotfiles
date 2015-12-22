" Java vim settings
setlocal tabstop=2                   " A tab is 4 spaces
setlocal expandtab                   " Always uses spaces instead of tabs
setlocal softtabstop=2               " Insert 4 spaces when tab is pressed
setlocal shiftwidth=2                " An indent is 4 spaces
setlocal smarttab                    " Indent instead of tab at start of line
setlocal shiftround                  " Round spaces to nearest shiftwidth multiple
setlocal nojoinspaces                " Don't convert spaces to tabs

" Searches downward from the given directory for a file called
" '.vim_classpath' and returns the path to said file or '' if it can't be
" found.
fu! s:FindVimClasspath(from_dir)
    let dir = fnamemodify(a:from_dir, ':p:h')
    let root_dir_flag = 0

    while !empty(dir)
        let vim_classpath = dir . '/.vim_classpath'
        if filereadable(vim_classpath)
            return vim_classpath
        endif

        if root_dir_flag
            return ''
        endif

        let dir = fnamemodify(dir, ':h')
        if dir =~ '^\/$'
            let root_dir_flag = 1
        endif
    endwhile

    return ''
endfu

" Simple parser for .vim_classpath files
" classpath_cmd - executes the command and adds the output to the classpath
" classpath_path - adds the jar/directory to the classpath
" source_cmd - executes the command and adds the output to the source set
" source_path - adds the file/directory to the source set
fu! s:ParseVimClasspath(vim_classpath)
    let vim_classpath_dir = fnamemodify(a:vim_classpath, ':p:h')

    if filereadable(a:vim_classpath)
        let lines = readfile(a:vim_classpath)

        for line in lines
            let line_split = split(line, '=')

            let key = line_split[0]
            let value = line_split[1]

            if !empty(key) && !empty(value)
                if key == "classpath_cmd"
                    let cmd = 'cd ' . vim_classpath_dir . ' && ' . value
                    let classpath = system(cmd)
                    let classpath = substitute(classpath, '\n\+$', '', '')
                    call javacomplete#AddClassPath(classpath)
                    let $CLASSPATH = classpath . ':' . $CLASSPATH

                elseif key == "classpath_path"
                    let classpath = value
                    " not an absolute path
                    if classpath[0] != '/'
                        let classpath = vim_classpath_dir . '/' . classpath
                    endif
                    let classpath = substitute(classpath, '\n\+$', '', '')
                    call javacomplete#AddClassPath(l:classpath)
                    let $CLASSPATH = classpath . ':' . $CLASSPATH

                elseif key == "source_cmd"
                    let cmd = 'cd ' . vim_classpath_dir . ' && ' . value
                    let source_path = system(cmd)
                    let source_path = substitute(source_path, '\n\+$', '', '')
                    call javacomplete#AddSourcePath(source_path)

                elseif key == "source_path"
                    let source_path = value
                    " not an absolute path
                    if source_path[0] != '/'
                        let source_path = vim_classpath_dir . '/' . source_path
                    endif
                    let source_path = substitute(source_path, '\n\+$', '', '')
                    call javacomplete#AddSourcePath(source_path)

                endif
            endif
        endfor

        let g:loaded_vim_classpath = 1
    endif
endfu

"if !exists('g:loaded_vim_classpath')
    "let g:loaded_vim_classpath = 0
"endif

"if !g:loaded_vim_classpath
    "let s:vim_classpath = s:FindVimClasspath(expand('.'))
    "if !empty(s:vim_classpath)
        "call s:ParseVimClasspath(s:vim_classpath)
    "endif
"endif

