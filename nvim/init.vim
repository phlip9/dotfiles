" PRELUDE {{{

    " Note: Skip initialization for vim-tiny or vim-small.
    if !1 | finish | endif

    " No vi compatibility
    " Also needed for cool vim stuff
    if &compatible
        set nocompatible
    endif

    " dein setup
    if has('vim_starting')
        set runtimepath+=$XDG_CONFIG_HOME/nvim/plugins/repos/github.com/Shougo/dein.vim
    endif

    call dein#begin(expand('$XDG_CONFIG_HOME/nvim/plugins/'))
    call dein#add('Shougo/dein.vim')

    " Rebind mapleader to something more accessible.
    let mapleader = ','

    " python3 setup
    let python3 = '/usr/local/bin/python3.5'
    let g:python3_host_prog = python3
    "" disable python
    " let g:loaded_python3_provider = 1
    "" skip if_has('python3') check
    " let g:python3_host_skip_check = 1

" SETUP }}}

" BUNDLES {{{

" vimproc - Interactive command execution in Vim {{{

    call dein#add('Shougo/vimproc.vim',
                \ {
                \   'if': executable('make'),
                \   'build': 'make'
                \ })

" vimproc }}}

" Solarized Color Scheme {{{

    call dein#add('altercation/vim-colors-solarized')

    let g:solarized_termtrans=1
    let g:solarized_termcolors=256

" Solarized Color Scheme }}}

" vim-rooter - Change vim root directory to project root {{{

    call dein#add('airblade/vim-rooter')

" }}}

" delimitMate - Autocompletion for delimiters {{{

    call dein#add('Raimondi/delimitMate')

" delimitMate }}}

" NERDCommenter - Easily comment lines or blocks of text {{{

    " Mappings:
    " <leader>c  - Toggle current line comment
    " <leader>cm - Block comment
    " <leader>c$ - Comment from cursor to end of line
    " <leader>cA - Comment from cursor to end of line and go into insert mode

    call dein#add('scrooloose/nerdcommenter')

" NERDCommenter }}}

" Syntastic - syntax and error checking {{{

    call dein#add('scrooloose/syntastic')
    let syntastic_javascript_checkers = ['jshint', 'jscs']

    let g:syntastic_python_python_exec = python3

    let g:syntastic_cpp_compiler = 'g++'
    let g:syntastic_cpp_compiler_options = ' -std=c++11 -stdlib=libc++'

" Syntastic }}}

" vim-test - Run tests at the speed of thought {{{

    " Mappings:
    " <leader>t<Space> Run the test nearest to the cursor
    " <leader>tf Test the current file
    " <leader>ts Test the current suite
    " <leader>tl Run the last test
    " <leader>tv Open the test file for the last run tests

    call dein#add('janko-m/vim-test',
                \ {
                \   'lazy': 1,
                \   'on_cmd': [
                \     'TestNearest', 'TestFile', 'TestSuite', 'TestLast', 'TestVisit'
                \   ]
                \ })

    nnoremap <silent> <leader>t<Space> :TestNearest<CR>
    nnoremap <silent> <leader>tf :TestFile<CR>
    nnoremap <silent> <leader>ts :TestSuite<CR>
    nnoremap <silent> <leader>tl :TestLast<CR>
    nnoremap <silent> <leader>tv :TestVisit<CR>

    let test#strategy = "neovim"

" }}}

" vim-ref - View reference docs for keyword under cursor {{{

    " Mappings:
    " ---------
    "
    " (In global)
    " <leader>r - open reference docs for keyword under cursor
    "
    " (In reference viewer)
    " <CR> - (same as K)
    " <C-t> - ref backward
    " <C-o> - ref backward
    " <C-i> - ref forward

    call dein#add('thinca/vim-ref',
                \ {
                \   'depends': 'vimproc.vim'
                \ })

    let g:ref_no_default_key_mappings = 1
    let g:ref_pydoc_cmd = "python3 -m pydoc"

    nnoremap <leader>r :call ref#K('normal')<CR>

    " Can use as a unite source
    " :Unite ref/pydoc

" }}}

" vim-fugitive - Vim Git integration {{{

    call dein#add('tpope/vim-fugitive',
                \ {
                \   'if': executable('git'),
                \   'augroup' : 'fugitive'
                \ })

" vim-fugitive }}}

" vim-gitgutter - Show git diff in the gutter {{{
    " Mappings:
    " <leader>gg - Toggle git gutter
    " <leader>hs - Stage hunk
    " <leader>hr - Revert hunk
    " <leader>hn - Next hunk
    " <leader>hp - Previous hunk

    " Don't automatically set mappings.
    let g:gitgutter_map_keys = 0

    call dein#add('airblade/vim-gitgutter',
                \ {
                \   'if': has('signs') && executable('git')
                \ })

    nmap <leader>gg :GitGutterToggle<CR>

    " Hunk management
    nmap <leader>hs :GitGutterStageHunk<CR>
    nmap <leader>hr :GitGutterRevertHunk<CR>

    nmap <leader>hn :GitGutterNextHunk<CR>
    nmap <leader>hp :GitGutterPrevHunk<CR>

" vim-gitgutter }}}

" deoplete.nvim - neovim autocomplete {{{
    
    call dein#add('Shougo/deoplete.nvim', { 'if': has('python3') })

    let g:deoplete#enable_at_startup = 1

    if !exists('g:deoplete#omni_patterns')
        let g:deoplete#omni_patterns = {}
    endif

    " Custom auto completion trigger patterns
    let g:deoplete#omni_patterns.c = '[^. *\t](\.|->)\w*'
    "let g:deoplete#omni_patterns.cpp = '[^.[:digit:] *\t]\%(\.\|->\)\w*\|\h\w*::\w*'
    let g:deoplete#omni_patterns.ruby = ['[^. *\t]\.\w*\|\h\w*::']

    " Disable the annoying autocomplete window
    set completeopt-=preview

" }}}

" neosnippet - vim snippets {{{

    call dein#add('Shougo/neosnippet')
    call dein#add('Shougo/neosnippet-snippets', { 'depends': 'neosnippet' })

    " Plugin key-mappings.
    imap <C-k> <Plug>(neosnippet_expand_or_jump)
    smap <C-k> <Plug>(neosnippet_expand_or_jump)
    xmap <C-k> <Plug>(neosnippet_expand_target)

    " SuperTab like snippets behavior.
    imap <expr><TAB> neosnippet#expandable_or_jumpable() ?
                \ "\<Plug>(neosnippet_expand_or_jump)"
                \: pumvisible() ? "\<C-n>" : "\<TAB>"
    smap <expr><TAB> neosnippet#expandable_or_jumpable() ?
                \ "\<Plug>(neosnippet_expand_or_jump)"
                \: "\<TAB>"

    " For snippet_complete marker.
    if has('conceal')
        set conceallevel=2 concealcursor=i
    endif

" }}}

" SudoEdit.vim - Easily write to protected files {{{

    call dein#add('chrisbra/SudoEdit.vim', { 'on_cmd': ['SudoWrite', 'SudoRead'] })

" SudoEdit.vim }}}

" vim-multiple-cursors - Emulate Sublime Text's multiple cursors feature {{{

    " Mappings:
    " Ctrl-n - Select current/next word
    " Ctrl-p - Select previous word
    " Ctrl-x - Skip current word

    call dein#add('terryma/vim-multiple-cursors')

" vim-multiple-cursors }}}

" vim-airline - Lightweight yet fancy status line {{{

    call dein#add('bling/vim-airline')

    set laststatus=2

    let g:airline_powerline_fonts=1

    " powerline symbols
    " If these look like garbage, then you need to install the patched
    " powerline fonts: https://github.com/powerline/fonts
    let g:airline_symbols = {}
    let g:airline_symbols.space = ' '
    let g:airline_left_sep = ''
    let g:airline_left_alt_sep = ''
    let g:airline_right_sep = ''
    let g:airline_right_alt_sep = ''
    let g:airline_symbols.branch = ''
    let g:airline_symbols.readonly = ''
    let g:airline_symbols.linenr = ''

    " airline buffer tab line "
    let g:airline#extensions#tabline#enabled = 1
    
    " straight separators for tabline
    let g:airline#extensions#tabline#left_sep = ''
    let g:airline#extensions#tabline#left_alt_sep = '|'

" vim-airline }}}

" vim-tern - Javascript autocompletion {{{

    " ## Commands ##
    " TernDef: Jump to the definition of the thing under the cursor.
    " TernDoc: Look up the documentation of something.
    " TernType: Find the type of the thing under the cursor.
    " TernRefs: Show all references to the variable or property under the cursor.
    " TernRename: Rename the variable under the cursor.

    call dein#add('marijnh/tern_for_vim',
                \ { 
                \   'if': executable('npm'),
                \   'lazy': 1,
                \   'build': 'npm install',
                \   'on_ft': ['javascript'],
                \ })

    " Display function signatures in the completion menu
    let g:tern_show_signature_in_pum = 1

" }}}

" vim-javascript - Javascript syntax and indent file {{{

    call dein#add('pangloss/vim-javascript',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['javascript']
                \ })

" }}}

" vim-node - Tools to make Vim superb for developing with Node.js {{{

    " Mappings:
    " gj : Use on paths or requires to open file Node would

    call dein#add('moll/vim-node',
                \ {
                \   'if': executable('node'),
                \   'lazy': 1,
                \   'on_ft': ['javascript']
                \ })

" }}}

" vim-coffee-script - Coffee script syntax highlighting and indenting {{{

    call dein#add('kchmck/vim-coffee-script',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['coffee']
                \ })

" vim-coffee-script }}}

" vim_cpp_indent - Google C++ indent style {{{

    call dein#add('phlip9/google-vim_cpp_indent',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['cpp']
                \ })

" vim_cpp_indent }}}

" deoplete-clang - C/C++ Autocomplete integrated with deoplete {{{

    call dein#add('zchee/deoplete-clang',
                \ {
                \   'if': executable('clang'),
                \   'depends': 'deoplete.nvim',
                \   'lazy': 1,
                \   'on_ft': ['c', 'cpp']
                \ })

    " `echo -n ...` strips the trailing newline from output
    let cmd = 'echo -n `llvm-config-3.6 --libdir`'
    let g:deoplete#sources#clang#libclang_path = system(cmd) . '/libclang.so'
    let g:deoplete#sources#clang#clang_header = '/usr/include/clang'

" }}}

" rust.vim - Rust file detection and syntax highlighting {{{

    au BufNewFile,BufRead *.rs setf rust

    call dein#add('rust-lang/rust.vim',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['rust']
                \ })

" }}}

" vim-racer - code completion for Rust {{{

    call dein#add('racer-rust/vim-racer',
                \ {
                \   'if': executable('racer'),
                \   'lazy': 1,
                \   'on_ft': ['rust']
                \ })

    let g:racer_no_default_keymappings = 1

    let $RUST_SRC_PATH = $HOME . '/dev/rust/src/'
    "let g:racer_cmd = $HOME . '/dev/dotfiles/vim/bundle/racer/target/release/racer'

" }}}

" ghcmod.vim - Haskell linting and syntax checking {{{

    call dein#add('eagletmt/ghcmod-vim',
                \ {
                \   'if': executable('ghc-mod'),
                \   'lazy': 1,
                \   'on_ft': ['haskell']
                \ })

" ghcmod.vim }}}

" javacomplete - Java omnicomplete {{{

    "NeoBundleLazy 'Shougo/javacomplete',
                "\ {
                "\   'autoload': { 'filetypes': ['java'] },
                "\   'build_commands': 'javac',
                "\   'build': {
                "\     'unix': 'javac ./autoload/Reflection.java',
                "\   }
                "\ }

" }}}

" vim-monster - Ruby omnicomplete {{{

    "call dein#add('osyo-manga/vim-monster',
                "\ {
                "\   'if': executable('rct-complete'),
                "\   'depends': 'vimproc.vim',
                "\   'lazy': 1,
                "\   'on_ft': 'ruby'
                "\ })

    ""let g:monster#debug#enable = 1
    "let g:monster#completion#rcodetools#backend = "async_rct_complete"

" }}}

" vim-scala - Scala syntax plugin {{{

    call dein#add('derekwyatt/vim-scala',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['scala']
                \ })

" }}}

" pep8-indent - Python indenting {{{

    call dein#add('hynek/vim-python-pep8-indent',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['python']
                \ })

" pep8-indent }}}

" Unite.vim - fuzzy file matching and buffer searching {{{
    
    " Mappings:
    " <space>f - find files
    " <space>/ - run ag with pattern (search)
    " <space>y - show yank history
    " <space>b - switch buffer
    " <space>o - file outline

    call dein#add('Shougo/unite.vim', { 'depends': 'vimproc.vim' })

    " File outline plugin
    call dein#add('Shougo/unite-outline', { 'depends': 'unite.vim' })

    " use ag to for searching
    if executable('ag')
        let g:unite_source_grep_command = 'ag'
        let g:unite_source_grep_default_opts = '--follow --noheading --nocolor --column'
        let g:unite_source_grep_recursive_opt = ''
        let g:unite_source_file_rec_command = 'ag --files-with-matches --follow --nocolor --noheading --column'
		let g:unite_source_rec_async_command = 'ag --files-with-matches --follow --nocolor --nogroup --column -g ""'
    endif

    " ctrlp-like functionality: fuzzy file searching
    nmap <space>f :Unite -buffer-name=files file_rec/async<CR>

    nmap <space>/ :Unite -buffer-name=search grep:.<CR>

    " Show file outline
    nmap <space>o :Unite -buffer-name=outline outline<CR>

    " Start in insert mode
    let g:unite_enable_start_insert = 1
    
    " mru (most-recently-used) file list limit
    let g:unite_source_file_mru_long_limit = 1000

	let g:unite_winheight = 10
	let g:unite_split_rule = 'botright'

" unite.vim }}}

" html5.vim - html5 autocompletion, syntax, and indentation {{{

    call dein#add('othree/html5.vim',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['html']
                \ })

" }}}

" vim-jade - Jade template engine syntax and highlighting {{{

    call dein#add('digitaltoad/vim-jade',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['jade']
                \ })

" }}}

" vim-mustace-handlebars - Mustache & Handlebars syntax highlighting {{{

    call dein#add('mustache/vim-mustache-handlebars')

" }}}

" scss-syntax.vim - scss syntax and indenting {{{

    call dein#add('cakebaker/scss-syntax.vim',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['scss']
                \ })

" }}}

" julia-vim - Julia syntax highlighting and ftplugin {{{

    call dein#add('JuliaLang/julia-vim')
    
    " Turn off the Latex symbol to unicode key mapping
    let g:latex_to_unicode_tab = 0

" }}}

" goyo.vim - distraction free editing {{{

    " ':Goyo' to toggle distraction free mode
    call dein#add('junegunn/goyo.vim',
                \ {
                \   'lazy': 1,
                \   'on_cmd': ['Goyo']
                \ })

" }}}

" Recover.vim - Show a diff when recovering swp files {{{

    call dein#add('chrisbra/Recover.vim')

" }}}

" vim-bbye - Close a buffer without messing up your layout {{{

    call dein#add('moll/vim-bbye',
                \ {
                \   'lazy': 1,
                \   'on_cmd': ['Bdelete']
                \ })

" }}}

" vimfiler.vim - vim file manager {{{

    call dein#add('Shougo/vimfiler.vim',
                \ {
                \   'depends': ['unite.vim']
                \ })

    " replace netr
    let g:vimfiler_as_default_explorer = 1

" }}}

" neossh.vim - SSH interface for neovim {{{

    call dein#add('Shougo/neossh.vim',
                \ {
                \   'depends': ['Shougo/vimproc.vim', 'unite.vim']
                \ })

" }}}

" }}}

" GENERAL {{{

    " Required after all plugins have been declared
    call dein#end()
    "call dein#remote_plugins()

    filetype plugin indent on       " detect filetypes
    syntax on                       " syntax highlighting

    " Call on_source hook when reloading .vimrc.
	if !has('vim_starting')
	  call dein#call_hook('on_source')
	endif

    set history=1000                " make the history larger
    set hidden                      " change buffers w/o having to write first
    set mouse=a                     " enable mouse
    scriptencoding=utf-8            " set encoding to utf-8
    "set shortmess+=filmnrxoOtT      " abbreviate annoying messages

" GENERAL }}}

" VISUAL {{{

    set nu                          " set line numbers
    set showmode                    " show current display mode
    set cursorline                  " show a line under the cursor

    if has('cmdline_info')
        set ruler                                           " show ruler
        set rulerformat=%30(%=\:b%n%y%m%r%w\ %l,%c%V\ %P%)  " uber ruler
        set showcmd                                         " show partial commands in status line
    endif

    " Colorscheme
    set background=dark
    colorscheme solarized

    " Highlight CursorLine as lighter background color
    highlight CursorLine ctermbg=black

    " Make matching text readable
    highlight MatchParen ctermbg=black

    " Sign column color should be the same as the line number column
    highlight SignColumn ctermbg=NONE

    " Make line number column same as background color
    highlight LineNr ctermbg=NONE

    " Don't underline the fold lines
    highlight Folded term=bold cterm=bold ctermbg=NONE

" VISUAL }}}

" BEHAVIOR {{{

    set backspace=indent,eol,start  " easy backspace
    set linespace=0                 " reduce space between lines

    set showmatch                   " show matching brackets/parenthesis
    set incsearch                   " find as you search
    set hlsearch                    " highlight search
    set ignorecase                  " ignore case
    set smartcase                   " case sensitive when uc

    set wildmenu                    " show list instead of just completing
    set wildmode=list:longest,full  " command completion
    set whichwrap=b,s,h,l,<,>,[,]   " backspace and cursor keys also wrap

    set scrolljump=5                " lines to scroll when cursor leaves screen
    set scrolloff=3                 " min # of lines to keep below cursor

    set foldenable                  " auto fold code

    set gdefault                    " always use /g on :s substitution

    set nowrap                      " warp long lines
    set clipboard=unnamedplus       " place yanked text into the clipboard

    " Remove trailing whitespaces and ^M chars
    autocmd FileType c,cpp,java,php,js,python,twig,xml,yml autocmd BufWritePre <buffer> :call setline(1,map(getline(1,"$"),'substitute(v:val,"\\s\\+$","","")'))

    " ethereum serpent contract language
    au BufNewFile,BufRead *.se set filetype=python

    " custom text folding function
    function! NeatFoldText()
        let line = ' ' . substitute(getline(v:foldstart), '^\s*"\?\s*\|\s*"\?\s*{{' . '{\d*\s*', '', 'g') . ' '
        let lines_count = v:foldend - v:foldstart + 1
        let lines_count_text = '| ' . printf("%10s", lines_count . ' lines') . ' |'
        let foldchar = matchstr(&fillchars, 'fold:\zs.')
        let foldtextstart = strpart(repeat(foldchar, v:foldlevel*2) . '|' . line, 0, (winwidth(0)*2)/3)
        let foldtextend = lines_count_text . repeat(foldchar, 8)
        let foldtextlength = strlen(substitute(foldtextstart . foldtextend, '.', 'x', 'g')) + &foldcolumn
        return foldtextstart . repeat(foldchar, winwidth(0)-foldtextlength) . foldtextend
    endfunction

    set foldtext=NeatFoldText()

" BEHAVIOR }}}

" TAB SETTINGS {{{

    set tabpagemax=15               " max # of tabs per page
    set autoindent                  " indent at same level as previous line
    set expandtab                   " space tabs
    set shiftwidth=4                " 4 spaces per tab
    set softtabstop=4               " backspace deletes pseudo-tab
    set tabstop=4                   " indent every 4 columns

" TAB SETTINGS }}}

" KEYBINDINGS {{{

    " Rebind Arrow keys to something more useful
    " Left and Right indent and un-indent the current line/selection
    nnoremap <silent><Left> <<
    nnoremap <silent><Right> >>

    vnoremap <silent><Left> <gv
    vnoremap <silent><Right> >gv

    " Bind Up and Down keys to add line above and below
    nnoremap <silent><Up> O<Esc>j
    nnoremap <silent><Down> o<Esc>k

    " remap Visual Block selection to something that doesn't conflict with system
    " copy/paste
    nnoremap <leader>v <C-v>

    " map S-J and S-K to next and prev buffer
    nnoremap J :bp<CR>
    nnoremap K :bn<CR>

    " map S-H and S-L to undo and redo
    nnoremap H u
    nnoremap L <C-R>

    " Window movement w/ CTRL + h,j,k,l
    nnoremap <C-h> <C-w>h
    nnoremap <C-j> <C-w>j
    nnoremap <C-k> <C-w>k
    nnoremap <C-l> <C-w>l

    " Reload nvimrc
    nnoremap <silent> <leader>V :source $XDG_CONFIG_HOME/nvim/init.vim<CR>:filetype detect<CR>:exe ":echo 'nvimrc reloaded'"<CR>

" KEYBINDINGS }}}

" POSTLUDE {{{

    " If there are uninstalled bundles found on startup,
    " this will conveniently prompt you to install them.
    if dein#check_install()
        call dein#install()
    endif

" }}}

" vim: foldmethod=marker
