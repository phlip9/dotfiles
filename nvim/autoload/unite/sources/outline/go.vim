"=============================================================================
" File    : autoload/unite/sources/outline/defaults/go.vim
" Author  : rhysd <lin90162@yahoo.co.jp>
" Updated : 2014-05-31
" Author  : phlip9 <philiphayes9@gmail.com>
" Updated : 2017-04-21
"
" Licensed under the MIT license:
" http://www.opensource.org/licenses/mit-license.php
"=============================================================================

" Modified Go outline that supports multi-line functions

function! unite#sources#outline#go#outline_info() abort
    return s:outline_info
endfunction

let s:Util = unite#sources#outline#import('Util')

let s:outline_info = {
            \ 'heading' : '^\s*\%(func\>\|type\s\+\h\w*\s\+\%(struct\|interface\)\=\)',
            \ 'highlight_rules' : [
            \   {
            \       'name' : 'comment',
            \       'pattern' : '/\/\/.*/',
            \   },
            \   {
            \       'name' : 'function',
            \       'pattern' : '/\%(([^)]*)\s\+\)\=\zs\h\w*\ze\s*([^)]*)/',
            \   },
            \   {
            \       'name' : 'interface',
            \       'pattern' : '/\h\w*\ze : interface/',
            \       'highlight' : unite#sources#outline#get_highlight('type'),
            \   },
            \   {
            \       'name' : 'struct',
            \       'pattern' : '/\h\w*\ze : struct/',
            \       'highlight' : unite#sources#outline#get_highlight('type'),
            \   },
            \   {
            \       'name' : 'type',
            \       'pattern' : '/\h\w*\ze : type/',
            \   },
            \ ],
            \ }

function! s:outline_info.create_heading(which, heading_line, matched_line, context) abort
    if a:which !=# 'heading'
        return {}
    endif

    let word = a:heading_line
    let level = 0
    let type = 'generic'

    " Type

    if word =~# '^\s*type\>'
        let matches = matchlist(word, '^\s*\zstype\s\+\(\h\w*\)\s\+\([[:alpha:][\]_][[:alnum:][\]_]*\)')
        if matches[2] =~# '\%(interface\|struct\)'
            let type = matches[2]
            let word = matches[1] . ' : ' . matches[2]
        else
            let type = 'type'
            let word = matches[1] . ' : type'
        endif
        let level = s:Util.get_indent_level(a:context, a:context.heading_lnum)

    " Function

    elseif word =~# '^\s*func\>'
        let type = 'function'

        let lines = a:context.lines
        let lnum = a:context.heading_lnum + 1
        let limit = min([lnum + 2, len(lines) - 1])

        " A function definition might be split across multiple lines, so we
        " want to join all the lines together into a single line.
        if word !~# '\s*{$'
            while lnum <= limit
                let line = lines[lnum]
                let word = join([word, line], ' ')
                if line =~# '\s*{$'
                    break
                endif
                let lnum += 1
            endwhile
        endif

        " remove the 'func' prefix
        let word = substitute(word, '\<func\s*', '', '')

        " remove the ending curly brace '{'
        let word = substitute(word, '\s*{$', '', '')

        let level = s:Util.get_indent_level(a:context, a:context.heading_lnum)
    endif

    if level > 0
        let heading = {
                    \ 'word' : word,
                    \ 'level': level,
                    \ 'type' : type,
                    \ }
    else
        let heading = {}
    endif

    return heading
endfunction
