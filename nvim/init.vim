" PRELUDE {{{

    " Note: Skip initialization for vim-tiny or vim-small.
    if !1 | finish | endif

    " No vi compatibility
    " Also needed for cool vim stuff
    if &compatible
        set nocompatible
    endif

    " NeoBundle Setup
    if has('vim_starting')
        set runtimepath+=$XDG_CONFIG_HOME/nvim/bundle/neobundle.vim/
    endif

    call neobundle#begin(expand('$XDG_CONFIG_HOME/nvim/bundle/'))

    NeoBundleFetch 'Shougo/neobundle.vim'

    " Rebind mapleader to something more accessible.
    let mapleader = ','

    " python setup
    let g:python3_host_prog = '/usr/bin/python3'
    "" disable python
    " let g:loaded_python3_provider = 1
    "" skip if_has('python3') check
    " let g:python3_host_skip_check = 1

" SETUP }}}

" BUNDLES {{{

" vimproc - Interactive command execution in Vim {{{

    NeoBundle 'Shougo/vimproc.vim',
            \ {
            \   'build_commands': 'make',
            \   'build': {
            \       'windows' : 'make -f make_mingw32.mak',
            \       'cygwin'  : 'make -f make_cygwin.mak',
            \       'mac'     : 'make -f make_mac.mak',
            \       'unix'    : 'make -f make_unix.mak'
            \   }
            \ }

" vimproc }}}

" Solarized Color Scheme {{{

    NeoBundle 'altercation/vim-colors-solarized'

    let g:solarized_termtrans=1
    let g:solarized_termcolors=256

" Solarized Color Scheme }}}

" vim-rooter - Change vim root directory to project root {{{

    NeoBundle 'airblade/vim-rooter'

" }}}

" delimitMate - Autocompletion for delimiters {{{

    NeoBundle 'Raimondi/delimitMate'

" delimitMate }}}

" NERDCommenter - Easily comment lines or blocks of text {{{

    " Mappings:
    " <leader>c  - Toggle current line comment
    " <leader>cm - Block comment
    " <leader>c$ - Comment from cursor to end of line
    " <leader>cA - Comment from cursor to end of line and go into insert mode

    NeoBundle 'scrooloose/nerdcommenter'

" NERDCommenter }}}

" Syntastic - syntax and error checking {{{

    NeoBundle 'scrooloose/syntastic'
    let syntastic_javascript_checkers = ['jshint', 'jscs']
    let g:syntastic_python_python_exec = '/usr/bin/python3'

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

    NeoBundle 'janko-m/vim-test'

    nnoremap <silent> <leader>t<Space> :TestNearest<CR>
    nnoremap <silent> <leader>tf :TestFile<CR>
    nnoremap <silent> <leader>ts :TestSuite<CR>
    nnoremap <silent> <leader>tl :TestLast<CR>
    nnoremap <silent> <leader>tv :TestVisit<CR>

    let test#strategy = "neovim"

" }}}

" Gundo - Visualize vim undo tree {{{
    
    " Mappings:
    " <leader>g - Toggle Gundo

    NeoBundleLazy 'sjl/gundo.vim', { 'autoload': { 'commands': ['GundoToggle'] }}

    nnoremap <leader>g :GundoToggle<CR>

" Gundo }}}

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

    NeoBundle 'thinca/vim-ref',
                \ {
                \   'depends': 'Shougo/vimproc.vim',
                \ }

    let g:ref_no_default_key_mappings = 1

    let g:ref_pydoc_cmd = "python3 -m pydoc"

    nnoremap <leader>r :call ref#K('normal')<CR>

    " Can use as a unite source
    " :Unite ref/pydoc

" }}}

" vim-fugitive - Vim Git integration {{{

    NeoBundle 'tpope/vim-fugitive', { 'augroup' : 'fugitive'}

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

    NeoBundle 'airblade/vim-gitgutter', { 'disabled': !has('signs') }

    nmap <leader>gg :GitGutterToggle<CR>

    " Hunk management
    nmap <leader>hs :GitGutterStageHunk<CR>
    nmap <leader>hr :GitGutterRevertHunk<CR>

    nmap <leader>hn :GitGutterNextHunk<CR>
    nmap <leader>hp :GitGutterPrevHunk<CR>

" vim-gitgutter }}}

" vim-vinegar - Enhance the default netrw (avoid using NERDTree) {{{

    NeoBundle 'tpope/vim-vinegar'

" vim-vinegar }}}

" deoplete.nvim - neovim autocomplete {{{
    
    NeoBundle 'Shougo/deoplete.nvim'

    let g:deoplete#enable_at_startup = 1

    if !exists('g:deoplete#omni_patterns')
        let g:deoplete#omni_patterns = {}
    endif

    " Custom auto completion trigger patterns
    let g:deoplete#omni_patterns.c = '[^. *\t](\.|->)\w*'
    "let g:deoplete#omni_patterns.cpp = '[^.[:digit:] *\t]\%(\.\|->\)\w*\|\h\w*::\w*'

    " Disable the annoying autocomplete window
    set completeopt-=preview

" }}}

" neosnippet - vim snippets {{{

    NeoBundle 'Shougo/neosnippet'
    NeoBundle 'Shougo/neosnippet-snippets', { 'depends': 'Shougo/neosnippet' }

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

    NeoBundleLazy 'chrisbra/SudoEdit.vim',
                \ { 'autoload': { 'commands': ['SudoWrite', 'SudoRead'] }}

" SudoEdit.vim }}}

" vim-multiple-cursors - Emulate Sublime Text's multiple cursors feature {{{

    " Mappings:
    " Ctrl-n - Select current/next word
    " Ctrl-p - Select previous word
    " Ctrl-x - Skip current word

    NeoBundle 'terryma/vim-multiple-cursors'

" vim-multiple-cursors }}}

" vim-airline - Lightweight yet fancy status line {{{

    NeoBundle 'bling/vim-airline'

    set laststatus=2

    let g:airline_powerline_fonts=1

    "" powerline symbols
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

    NeoBundleLazy 'marijnh/tern_for_vim',
                \ { 
                \   'autoload': { 'filetypes': ['javascript'] },
                \   'build_commands': 'npm',
                \   'build': { 'unix': 'npm install' }
                \ }

    " Display function signatures in the completion menu
    let g:tern_show_signature_in_pum = 1

" }}}

" vim-javascript - Javascript syntax and indent file {{{

    NeoBundleLazy 'pangloss/vim-javascript',
                \ { 'autoload': { 'filetypes': ['javascript'] }}

" }}}

" vim-node - Tools to make Vim superb for developing with Node.js {{{

    " Mappings:
    " gj : Use on paths or requires to open file Node would

    NeoBundleLazy 'moll/vim-node',
                \ { 'autoload': { 'filetypes': ['javascript'] }}

" }}}

" vim-coffee-script - Coffee script syntax highlighting and indenting {{{

    NeoBundleLazy 'kchmck/vim-coffee-script',
                \ { 'autoload': { 'filename_patterns': '\.coffee$' }}

" vim-coffee-script }}}

" vim_cpp_indent - Google C++ indent style {{{

    NeoBundleLazy 'phlip9/google-vim_cpp_indent',
                \ { 'autoload': { 'filetypes': ['cpp'] }}

" vim_cpp_indent }}}

" vim-clang - C/C++ Auto completion {{{

    "NeoBundleLazy 'justmao945/vim-clang',
                "\ { 'autoload': { 'filetypes': ['c', 'cpp'] }}
    NeoBundle 'justmao945/vim-clang'

    " disable vim-clang's auto completion
    let g:clang_auto = 0
    let g:clang_debug = 0
    " remove 'longest' option -- doesn't work with vim-clang
    let g:clang_c_completeopt = 'menuone'
    let g:clang_cpp_completeopt = 'menuone'
    let g:clang_c_options = '-std=gnu11'
    let g:clang_cpp_options = '-std=c++11 -stdlib=libc++'

" vim-clang }}}

" rust.vim - Rust file detection and syntax highlighting {{{

    NeoBundleLazy 'rust-lang/rust.vim',
                \ { 'autoload': { 'filetypes': ['rust'] }}

" }}}

" Racer - code completion for Rust {{{

    NeoBundleLazy 'phildawes/racer',
                \ {
                \   'autoload': { 'filetypes': ['rust'] },
                \   'build_commands': 'cargo',
                \   'build': { 'unix': 'cargo build --release' }
                \ }

    let $RUST_SRC_PATH = $HOME . '/dev/rust/src/'
    let g:racer_cmd = $HOME . '/dev/dotfiles/vim/bundle/racer/target/release/racer'

" }}}

" ghcmod.vim - Haskell linting and syntax checking {{{

    NeoBundleLazy 'eagletmt/ghcmod-vim',
                \ { 'autoload': { 'filetypes': ['haskell'] },
                \   'external_commands': 'ghc-mod' }

" ghcmod.vim }}}

" javacomplete - Java omnicomplete {{{

    NeoBundleLazy 'Shougo/javacomplete',
                \ {
                \   'autoload': { 'filetypes': ['java'] },
                \   'build_commands': 'javac',
                \   'build': {
                \     'unix': 'javac ./autoload/Reflection.java',
                \   }
                \ }

" }}}

" {{{

    NeoBundleLazy 'derekwyatt/vim-scala',
                \ { 'autoload': { 'filetypes': ['scala'] }}

" }}}

" pep8-indent - Python indenting {{{

    NeoBundleLazy 'hynek/vim-python-pep8-indent',
                \ { 'autoload': { 'filetypes': ['python'] }}

" pep8-indent }}}

" Unite.vim - fuzzy file matching and buffer searching {{{
    
    " Mappings:
    " <space>f - find files
    " <space>/ - run ag with pattern (search)
    " <space>y - show yank history
    " <space>b - switch buffer
    " <space>o - file outline

    NeoBundle 'Shougo/unite.vim', { 'depends': 'Shougo/vimproc.vim' }

    " File outline plugin
    NeoBundle 'Shougo/unite-outline', { 'depends': 'Shougo/unite.vim' }

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

    " unite yank history
    let g:unite_source_history_yank_enable = 1
    nmap <space>y :Unite -buffer-name=yank history/yank<CR>

    " Fancy buffer switching
    nmap <space>b :Unite -buffer-name=buffers -quick-match buffer<CR>

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

    NeoBundleLazy 'othree/html5.vim',
                \ { 'autoload': { 'filetypes': ['html'] }}

" }}}

" vim-jade - Jade template engine syntax and highlighting {{{

    NeoBundleLazy 'digitaltoad/vim-jade',
                \ { 'autoload': { 'filetypes': ['jade'] }}

" }}}

" vim-mustace-handlebars - Mustache & Handlebars syntax highlighting {{{

    NeoBundle 'mustache/vim-mustache-handlebars'

" }}}

" scss-syntax.vim - scss syntax and indenting {{{

    NeoBundleLazy 'cakebaker/scss-syntax.vim',
                \ { 'autoload': { 'filetypes': ['scss'] }}

" }}}

" julia-vim - Julia syntax highlighting and ftplugin {{{

    NeoBundle 'JuliaLang/julia-vim'
    
    " Turn off the Latex symbol to unicode key mapping
    let g:latex_to_unicode_tab = 0

" }}}

" goyo.vim - distraction free editing {{{

    " ':Goyo' to toggle distraction free mode
    NeoBundle 'junegunn/goyo.vim'

" }}}

" Recover.vim - Show a diff when recovering swp files {{{

    NeoBundle 'chrisbra/Recover.vim'

" }}}

" vim-bbye - Close a buffer without messing up your layout {{{

    NeoBundle 'moll/vim-bbye'

" }}}

" }}}

" GENERAL {{{

    call neobundle#end()

    filetype plugin indent on       " detect filetypes
    syntax on                       " syntax highlighting

	if !has('vim_starting')
	  " Call on_source hook when reloading .vimrc.
	  call neobundle#call_hook('on_source')
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
    nnoremap <silent> <leader>V :source ~/.nvimrc<CR>:filetype detect<CR>:exe ":echo 'nvimrc reloaded'"<CR>

" KEYBINDINGS }}}

" POSTLUDE {{{

    " If there are uninstalled bundles found on startup,
    " this will conveniently prompt you to install them.
    NeoBundleCheck

" }}}

" vim: foldmethod=marker
