" PRELUDE {{{

    " Note: Skip initialization for vim-tiny or vim-small.
    if !1 | finish | endif

    " No vi compatibility
    " Also needed for cool vim stuff
    if &compatible
        set nocompatible
    endif

    let plugins_home = expand('$XDG_CONFIG_HOME/nvim/plugins')

    " dein install and setup
    if has('vim_starting')
        let dein_home = plugins_home . '/repos/github.com/Shougo/dein.vim'

        " clone dein repo to plugins
        if empty(glob(dein_home))
            let cmd_clone_dein = 'git clone https://github.com/Shougo/dein.vim '.dein_home
            call system(cmd_clone_dein)
            if v:shell_error
                finish
            endif
        endif

        " add dein to rtp
        let &runtimepath = &runtimepath . ',' . dein_home
    endif

    call dein#begin(plugins_home)
    call dein#add('Shougo/dein.vim')

    " Rebind mapleader to something more accessible.
    let mapleader = ','

    " python3 setup
    " Try to use a neovim-specific pyvenv first, otherwise fallback to a global
    " python install.
    let python3_bin_pyenv = expand('$PYTHON3_ENV_DIR/nvim_py/bin/python3')
    let python3_bin_global = expand('$PYTHON3_BIN')
    if executable(python3_bin_pyenv)
        let g:python3_host_prog = python3_bin_pyenv
    elseif executable(python3_bin_global)
        let g:python3_host_prog = python3_bin_global
    endif

    "" disable python
    " let g:loaded_python3_provider = 1
    "" skip if_has('python3') check
    " let g:python3_host_skip_check = 1

" PRELUDE }}}

" BUNDLES {{{

" vimproc - Interactive command execution in Vim {{{

    call dein#add('Shougo/vimproc.vim',
                \ {
                \   'if': executable('make'),
                \   'build': 'make'
                \ })

" vimproc }}}

" crayon - A colorschemee for *Vim {{{

    call dein#add('jansenfuller/crayon')

" }}}

" (disabled) vim-rooter - Change vim root directory to project root {{{

    " call dein#add('airblade/vim-rooter')

" }}}

" delimitMate - Autocompletion for delimiters {{{

    call dein#add('Raimondi/delimitMate')

" delimitMate }}}

" NERDCommenter - Easily comment lines or blocks of text {{{

    " Mappings:
    " <leader>c<space> - Toggle current line comment
    " (disabled) <leader>cm - Block comment
    " (disabled) <leader>c$ - Comment from cursor to end of line
    " (disabled) <leader>cA - Comment from cursor to end of line and go into insert mode

    call dein#add('preservim/nerdcommenter')

    " disable all default key bindings
    let g:NERDCreateDefaultMappings = 0

    " Add spaces after comment delimiters by default
    let g:NERDSpaceDelims = 1

    " Align line-wise comment delimiters flush left instead of following code indentation
    let g:NERDDefaultAlign = 'left'

    " Allow commenting and inverting empty lines (useful when commenting a region)
    let g:NERDCommentEmptyLines = 1

    " custom comment formats
    let g:NERDCustomDelimiters = {
                \ 'dart': { 'left': '//' },
                \ }

    " key bindings
    nnoremap <silent> <leader>c<Space> <Plug>NERDCommenterToggle
    xnoremap <silent> <leader>c<Space> <Plug>NERDCommenterToggle

" NERDCommenter }}}

" (disabled) Syntastic - syntax and error checking {{{

    " call dein#add('vim-syntastic/syntastic')

    " By default, Syntastic doesn't populate the location list unless you
    " explicitly call `:Errors`.
    " let g:syntastic_always_populate_loc_list = 1

    " let syntastic_javascript_checkers = ['jshint', 'jscs']
    " 
    " let g:syntastic_python_python_exec = g:python3_host_prog
    " 
    " let g:syntastic_cpp_compiler = 'g++'
    " let g:syntastic_cpp_compiler_options = ' -std=c++11 -stdlib=libc++'

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
    " <leader>hr - Undo hunk
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
    nmap <leader>hr :GitGutterUndoHunk<CR>

    " Hunk movement
    nmap <leader>hn :GitGutterNextHunk<CR>
    nmap <leader>hp :GitGutterPrevHunk<CR>

" vim-gitgutter }}}

" (disabled) deoplete.nvim - neovim autocomplete {{{

    " function! s:deoplete_setup() abort
    "     call deoplete#custom#option('sources',
    "                 \ {
    "                 \   'rust': ['LanguageClient'],
    "                 \   'c': ['clang'],
    "                 \   'cpp': ['clang'],
    "                 \   'go': ['go'],
    "                 \   'python': ['jedi'],
    "                 \   'python3': ['jedi'],
    "                 \   'javascript': ['omni'],
    "                 \   'lean': ['LanguageClient'],
    "                 \ })
    " 
    "     " <TAB>: completion.
    "     inoremap <silent><expr> <TAB>
    "                 \ pumvisible() ? "\<C-n>" :
    "                 \ <SID>check_back_space() ? "\<TAB>" :
    "                 \ deoplete#manual_complete()
    "     function! s:check_back_space() abort
    "         let col = col('.') - 1
    "         return !col || getline('.')[col - 1]  =~ '\s'
    "     endfunction
    " 
    "     " <S-TAB>: completion back.
    "     inoremap <expr><S-TAB>  pumvisible() ? "\<C-p>" : "\<C-h>"
    " 
    "     " <BS>: close popup and delete backword char.
    "     inoremap <expr><BS> deoplete#smart_close_popup()."\<C-h>"
    " 
    "     " <CR>: close popup and save indent.
    "     inoremap <silent> <CR> <C-r>=<SID>my_cr_function()<CR>
    "     function! s:my_cr_function() abort
    "         return deoplete#cancel_popup() . "\<CR>"
    "     endfunction
    " 
    "     inoremap <expr> '  pumvisible() ? deoplete#close_popup() : "'"
    "     
    "     " Disable deoplete while using vim-multiple-cursors
    "     function! g:Multiple_cursors_before()
    "         call deoplete#custom#buffer_option('auto_complete', v:false)
    "     endfunction
    "     function! g:Multiple_cursors_after()
    "         call deoplete#custom#buffer_option('auto_complete', v:true)
    "     endfunction
    " 
    "     " Disable the candidates in Comment/String syntaxes.
    "     call deoplete#custom#source('_',
    "                 \ 'disabled_syntaxes', ['Comment', 'String'])
    " 
    "     " ignore completions from the current buffer
    "     call deoplete#custom#option('ignore_sources', {'_': ['buffer']})
    " 
    "     " Go deoplete configuration
    "     " =========================
    "     call deoplete#custom#source('go', 'gocode_binary', $GOPATH . '/bin/gocode')
    "     call deoplete#custom#source('go', 'sort_class',
    "                 \ ['package', 'func', 'type', 'var', 'const'])
    "     call deoplete#custom#source('go', 'pointer', 1)
    "     " cache the Go stdlib completions
    "     call deoplete#custom#source('go', 'use_cache', 1)
    "     call deoplete#custom#source('go', 'json_directory',
    "                 \ $HOME . '/.cache/deoplete/go/' . $GOOS . '_' . $GOARCH)
    " 
    "     " clang deoplete configuration
    "     " ============================
    "     if executable('llvm-config-4.0')
    "         " `echo -n ...` strips the trailing newline from output
    "         let llvm_libdir = system('echo -n $(llvm-config-4.0 --libdir)')
    "         call deoplete#custom#source('clang', 'libclang_path',
    "                     \ llvm_libdir . '/libclang.so')
    "         call deoplete#custom#source('clang', 'clang_header', '/usr/include/clang')
    "     endif
    " endfunction
    " 
    " "" Custom auto completion trigger patterns
    " "call deoplete#custom#option('omni_patterns', 
    "             "\ {
    "             "\   'c': '[^. *\t](\.|->)\w*',
    "             "\   'cpp': '[^.[:digit:] *\t]\%(\.\|->\)\w*\|\h\w*::\w*',
    "             "\   'ruby': '[^. *\t]\.\w*\|\h\w*::',
    "             "\ })
    "             "\   'lean': '[^. *\t]\.\w*',
    " 
    " call dein#add('Shougo/deoplete.nvim',
    "             \ {
    "             \   'if': has('python3'),
    "             \   'hook_source': function('s:deoplete_setup'),
    "             \ })
    " 
    " let g:deoplete#enable_at_startup = 1
    " 
    " " tab complete
    " "inoremap <expr><tab> pumvisible() ? "\<c-n>" : "\<tab>"
    " 
    " " Do not select a match in the menu, force the user to
    " " select one from the menu.
    " set completeopt+=noselect
    " " Disable the annoying autocomplete window that pops up
    " " on the bottom of the screen.
    " set completeopt-=preview

" }}}

" coc.nvim - Complete engine and Language Server support for neovim {{{

    " Mappings:
    " <leader>gd  - go to definition
    " <leader>gi  - go to implementations
    " <leader>gt  - go to type definition
    " <leader>ren - rename
    " <leader>ref - references
    " <leader>h   - symbol hover
    " <leader>a   - code action
    " (disabled) <leader>al - code lens action
    " <leader>di  - diagnostic info
    " <leader>cm  - select an LSP command
    "
    " Flutter:
    " <leader>fd - flutter devices
    " <leader>fr - flutter run
    " <leader>ft - flutter hot restart
    " <leader>fs - flutter stop
    " <leader>fl - flutter dev log
    "
    " ]c, [c     - next/prev linter errors 
    " <Tab>, <S-Tab> - next/prev completion
    " <C-Space>  - trigger completion
    " <C-f>      - scroll float window up
    " <C-b>      - scroll float window down
    "
    " <verb>if   - <verb> in function
    " <verb>af   - <verb> around function
    " <verb>ic   - <verb> in class
    " <verb>ac   - <verb> around class

    let g:coc_global_extensions = [
                \   'coc-json',
                \   'coc-rust-analyzer',
                \   'coc-flutter',
                \ ]

    function! s:coc_check_back_space() abort
        let col = col('.') - 1
        return !col || getline('.')[col - 1]  =~# '\s'
    endfunction

    function! s:coc_post_source() abort
        " call coc#config('section', {
        "             \ ''
        " })

        " Use tab for trigger completion with characters ahead and navigate.
        inoremap <silent><expr> <TAB>
                    \ coc#pum#visible() ? coc#pum#next(1) :
                    \ <SID>coc_check_back_space() ? "\<TAB>" :
                    \ coc#refresh()
        inoremap <expr><S-TAB> coc#pum#visible() ? coc#pum#prev(1) : "\<S-Tab>"

        " Use <C-Space> to trigger completion.
        inoremap <silent><expr> <C-Space> coc#refresh()

        " Use <cr> for confirm completion, `<C-g>u` means break undo chain at current position.
        " Coc only does snippet and additional edit on confirm.
        inoremap <silent><expr> <cr> pumvisible() ? coc#_select_confirm()
                    \: "\<C-g>u\<CR>\<c-r>=coc#on_enter()\<CR>"

        " Use `[c` and `]c` for navigate diagnostics
        nnoremap <silent> [c :call CocAction('diagnosticPrevious')<CR>
        nnoremap <silent> ]c :call CocAction('diagnosticNext')<CR>

        nnoremap <silent> <leader>gd :call CocAction('jumpDefinition')<CR>
        nnoremap <silent> <leader>gc :call CocAction('jumpDeclaration')<CR>
        nnoremap <silent> <leader>gi :call CocAction('jumpImplementation')<CR>
        nnoremap <silent> <leader>gt :call CocAction('jumpTypeDefinition')<CR>
        nnoremap <silent> <leader>ren :call CocAction('rename')<CR>
        nnoremap <silent> <leader>ref :call CocAction('jumpReferences')<CR>
        nnoremap <silent> <leader>h :call CocAction('doHover')<CR>
        nnoremap <leader>a <Plug>(coc-codeaction-selected)<CR>
        xnoremap <leader>a <Plug>(coc-codeaction-selected)
        nnoremap <silent> <leader>di :call CocAction('diagnosticInfo')<CR>
        nnoremap <silent> <leader>cm :CocCommand<CR>

        " flutter-specific bindings
        " TODO(phlip9): make this bind only in dart/flutter file types
        nnoremap <silent> <leader>fd :CocCommand flutter.devices<CR>
        nnoremap <silent> <leader>fr :CocCommand flutter.run<CR>
        nnoremap <silent> <leader>ft :CocCommand flutter.dev.hotRestart<CR>
        nnoremap <silent> <leader>fs :CocCommand flutter.dev.quit<CR>
        nnoremap <silent> <leader>fl :CocCommand flutter.dev.openDevLog<CR>

        " This lets you select or use vim verbs inside/around functions/"classes".
        " NOTE: Requires 'textDocument.documentSymbol' support from the language server.
        xmap if <Plug>(coc-funcobj-i)
        omap if <Plug>(coc-funcobj-i)
        xmap af <Plug>(coc-funcobj-a)
        omap af <Plug>(coc-funcobj-a)
        xmap ic <Plug>(coc-classobj-i)
        omap ic <Plug>(coc-classobj-i)
        xmap ac <Plug>(coc-classobj-a)
        omap ac <Plug>(coc-classobj-a)

        " Remap <C-f> and <C-b> to scroll float windows/popups.
        nnoremap <silent><nowait><expr> <C-f> coc#float#has_scroll() ? coc#float#scroll(1) : "\<C-f>"
        nnoremap <silent><nowait><expr> <C-b> coc#float#has_scroll() ? coc#float#scroll(0) : "\<C-b>"
        inoremap <silent><nowait><expr> <C-f> coc#float#has_scroll() ? "\<c-r>=coc#float#scroll(1)\<cr>" : "\<Right>"
        inoremap <silent><nowait><expr> <C-b> coc#float#has_scroll() ? "\<c-r>=coc#float#scroll(0)\<cr>" : "\<Left>"
        vnoremap <silent><nowait><expr> <C-f> coc#float#has_scroll() ? coc#float#scroll(1) : "\<C-f>"
        vnoremap <silent><nowait><expr> <C-b> coc#float#has_scroll() ? coc#float#scroll(0) : "\<C-b>"
    endfunction

    call dein#add('neoclide/coc.nvim',
                \ { 
                \   'if': executable('node') && executable('yarn'),
                \   'build': 'yarn install --frozen-lockfile',
                \   'hook_post_source': function('s:coc_post_source'),
                \ })

"  }}}

" SudoEdit.vim - Easily write to protected files {{{

    call dein#add('chrisbra/SudoEdit.vim', { 'on_cmd': ['SudoWrite', 'SudoRead'] })

    " Use `pkexec` on more recent Ubuntu/Debian/Pop!_OS
    if executable('pkexec')
        let g:sudoAuth='pkexec'
    endif

" SudoEdit.vim }}}

" vim-multiple-cursors - Emulate Sublime Text's multiple cursors feature {{{

    " Mappings:
    " Ctrl-n - Select current/next word
    " Ctrl-p - Select previous word
    " Ctrl-x - Skip current word

    " says it's deprecated and should be replaced w/
    " https://github.com/mg979/vim-visual-multi
    call dein#add('terryma/vim-multiple-cursors')

" vim-multiple-cursors }}}

" vim-airline - Lightweight yet fancy status line {{{

    call dein#add('vim-airline/vim-airline')

    set laststatus=2

    if !exists('g:airline_symbols')
        let g:airline_symbols = {}
    endif

    " Enable Powerline fonts if we're not on WSL
    if !has('wsl')
        " If these look like garbage, then you need to install the patched
        " powerline fonts: https://github.com/powerline/fonts

        let g:airline_powerline_fonts=1

        let g:airline_symbols.branch = ''   
        let g:airline_symbols.readonly = ''
        let g:airline_symbols.linenr = ''
        let g:airline_symbols.maxlinenr = ''

        let g:airline_left_sep = ''
        let g:airline_left_alt_sep = ''
        let g:airline_right_sep = ''
        let g:airline_right_alt_sep = ''
    else
        let g:airline_symbols.space = ' '
        let g:airline_symbols.branch = '[br]'
        let g:airline_symbols.readonly = '[ro]'
        let g:airline_symbols.linenr = '[nr]'
        let g:airline_symbols.maxlinenr = '[mx]'

        let g:airline_left_sep = '>'
        let g:airline_left_alt_sep = '|'
        let g:airline_right_sep = '<'
        let g:airline_right_alt_sep = '|'
    endif

    " airline buffer tab line "
    let g:airline#extensions#tabline#enabled = 1
    
    " straight separators for tabline
    let g:airline#extensions#tabline#left_sep = ''
    let g:airline#extensions#tabline#left_alt_sep = '|'

" vim-airline }}}

" (disabled) LanguageClient-neovim - Language Server Protocol support for neovim {{{

    " " Mappings:
    " " <leader>m  - show the context menu with all available commands
    " " <leader>gd - go to definition of symbol under cursor
    " " <leader>h  - hover info about symbol under cursor
    " " <leader>r  - rename symbol under cursor
    " " <leader>f  - display references to symbol under cursor
    " 
    " call dein#add('autozimu/LanguageClient-neovim',
    "             \ {
    "             \   'rev': 'next',
    "             \   'build': 'bash install.sh',
    "             \ })
    " 
    " let g:LanguageClient_autoStart = 1
    " 
    " let g:LanguageClient_rootMarkers =
    "             \ {
    "             \   'cpp': ['compile_commands.json', 'build'],
    "             \   'c': ['compile_commands.json', 'build'],
    "             \   'rust': ['Cargo.toml', 'build'],
    "             \ }
    " 
    " let g:LanguageClient_serverCommands = {}
    " 
    " if executable('rls')
    "     let g:LanguageClient_serverCommands.rust = ['rls']
    " endif
    " 
    " if executable('npm')
    "     " `echo -n ...` strips the trailing newline from output
    "     let npm_bin = system('echo -n `npm bin --global`')
    "     let g:LanguageClient_serverCommands.lean =
    "                 \ ['node', npm_bin . '/lean-language-server', '--stdio']
    " endif
    " 
    " "autocmd FileType lean setlocal omnifunc=LanguageClient#complete
    " 
    " nnoremap <silent> <leader>m :call LanguageClient_contextMenu()<CR>
    " nnoremap <silent> <leader>gd :call LanguageClient#textDocument_definition()<CR>
    " nnoremap <silent> <leader>h :call LanguageClient#textDocument_hover()<CR>
    " nnoremap <silent> <leader>r :call LanguageClient#textDocument_rename()<CR>
    " nnoremap <silent> <leader>f :call LanguageClient#textDocument_references()<CR>

" }}}

" neoformat - Plugin for formatting code {{{

    call dein#add('sbdchd/neoformat')

    autocmd FileType c,cpp
                \ autocmd BufWritePre <buffer> undojoin | Neoformat

    let g:neoformat_enabled_cpp = ['clangformat']
    let g:neoformat_enabled_c = ['clangformat']

" }}}

" (disabled) vim-go - Go linting, highlighting, building, formatting {{{

    " call dein#add('fatih/vim-go')

    " don't use <shift>-k to show go docs, since we use it for buffer switching
    " let g:go_doc_keywordprg_enabled = 0

" }}}

" (disabled) deoplete-go - Go Autocompletion {{{

    " call dein#add('zchee/deoplete-go', { 'build': 'make' })

" }}}

" (disabled) deoplete-jedi - Python autocompletion {{{

    " call dein#add('zchee/deoplete-jedi')

" }}}

" (disabled) vim-tern - Javascript autocompletion {{{

    " " ## Commands ##
    " " TernDef: Jump to the definition of the thing under the cursor.
    " " TernDoc: Look up the documentation of something.
    " " TernType: Find the type of the thing under the cursor.
    " " TernRefs: Show all references to the variable or property under the cursor.
    " " TernRename: Rename the variable under the cursor.
    " 
    " call dein#add('marijnh/tern_for_vim',
    "             \ { 
    "             \   'if': executable('npm'),
    "             \   'lazy': 1,
    "             \   'build': 'npm install',
    "             \   'on_ft': ['javascript'],
    "             \ })
    " 
    " " Display function signatures in the completion menu
    " let g:tern_show_signature_in_pum = 1

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

" (disabled) vim_cpp_indent - Google C++ indent style {{{

    " call dein#add('phlip9/google-vim_cpp_indent',
    "             \ {
    "             \   'lazy': 1,
    "             \   'on_ft': ['cpp']
    "             \ })

" vim_cpp_indent }}}

" (disabled) deoplete-clang - C/C++ Autocomplete integrated with deoplete {{{

    " call dein#add('zchee/deoplete-clang',
    "             \ {
    "             \   'if': executable('clang'),
    "             \   'depends': 'deoplete.nvim',
    "             \   'lazy': 1,
    "             \   'on_ft': ['c', 'cpp']
    "             \ })

" }}}

" rust.vim - Rust file detection and syntax highlighting {{{

    call dein#add('rust-lang/rust.vim',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['rust']
                \ })

    let g:rustfmt_autosave = 0

" }}}

" (disabled) vim-racer - code completion for Rust {{{

    " call dein#add('racer-rust/vim-racer',
    "             \ {
    "             \   'if': executable('racer'),
    "             \   'lazy': 1,
    "             \   'on_ft': ['rust']
    "             \ })
    " 
    " let g:racer_experimental_completer = 1
    " let g:racer_no_default_keymappings = 1

" }}}

" lean.vim - Lean syntax plugin {{{
    
    call dein#add('leanprover/lean.vim')

" }}}

" ghcmod.vim - Haskell linting and syntax checking {{{

    call dein#add('eagletmt/ghcmod-vim',
                \ {
                \   'if': executable('ghc-mod'),
                \   'lazy': 1,
                \   'on_ft': ['haskell']
                \ })

" ghcmod.vim }}}

" (disabled) javacomplete - Java omnicomplete {{{

    "NeoBundleLazy 'Shougo/javacomplete',
                "\ {
                "\   'autoload': { 'filetypes': ['java'] },
                "\   'build_commands': 'javac',
                "\   'build': {
                "\     'unix': 'javac ./autoload/Reflection.java',
                "\   }
                "\ }

" }}}

" (disabled) vim-monster - Ruby omnicomplete {{{

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

" vim-opencl - OpenCL syntax plugin {{{

    call dein#add('petRUShka/vim-opencl')

" }}}

" pep8-indent - Python indenting {{{

    call dein#add('hynek/vim-python-pep8-indent',
                \ {
                \   'lazy': 1,
                \   'on_ft': ['python']
                \ })

" pep8-indent }}}

" (disabled) Unite.vim - fuzzy file matching and buffer searching {{{
    
    " Mappings:
    " <space>f - find files
    " <space>/ - grep with pattern (search)
    " <space>o - file outline

    " call dein#add('Shougo/unite.vim', { 'depends': 'vimproc.vim' })
    " 
    " " File outline plugin
    " call dein#add('Shougo/unite-outline', { 'depends': 'unite.vim' })
    " 
    " " use ripgrep or ag to for searching
    " if executable('rg')
    "     let g:unite_source_grep_command = 'rg'
    "     let g:unite_source_grep_default_opts = '--ignore-case --vimgrep'
    "     let g:unite_source_grep_recursive_opt = ''
    "     " TODO: use rg?
    "     let g:unite_source_file_rec_command = 'ag --files-with-matches --follow --nocolor --noheading --column'
	"     let g:unite_source_rec_async_command = 'ag --files-with-matches --follow --nocolor --nogroup --column -g ""'
    " elseif executable('ag')
    "     let g:unite_source_grep_command = 'ag'
    "     let g:unite_source_grep_default_opts = '--follow --noheading --nocolor --column'
    "     let g:unite_source_grep_recursive_opt = ''
    "     let g:unite_source_file_rec_command = 'ag --files-with-matches --follow --nocolor --noheading --column'
	"     let g:unite_source_rec_async_command = 'ag --files-with-matches --follow --nocolor --nogroup --column -g ""'
    " endif
    " 
    " " ctrlp-like functionality: fuzzy file searching
    " nmap <space>f :Unite -buffer-name=files file_rec/async<CR>
    " 
    " nmap <space>/ :Unite -buffer-name=search grep:.<CR>
    " 
    " " Show file outline
    " nmap <space>o :Unite -buffer-name=outline outline<CR>
    " 
    " " Start in insert mode
    " let g:unite_enable_start_insert = 1
    " 
    " " mru (most-recently-used) file list limit
    " let g:unite_source_file_mru_long_limit = 1000
    " 
    " let g:unite_winheight = 10
    " let g:unite_split_rule = 'botright'

" unite.vim }}}

" fzf.vim - fuzzy file matching, grepping, and tag searching using fzf {{{

    " Mappings:
    "         O - open files search (ignoring files in .gitignore)
    "  <space>O - open files search (all files)
    "  <space>o - file ctags outline
    "  <space>t - project ctags search
    "         T - open buffers search
    "  <space>/ - grep with pattern
    "  <space>' - grep using word under cursor
    " <space>cm - grep through commits
    " <space>cb - grep through commits for the current buffer
    "  <space>h - grep through vim help

    let fzf_home = expand('$FZF_HOME')
    let fzf_enabled = isdirectory(fzf_home) && executable('fzf')
    let g:fzf_command_prefix = 'Fzf'

    call dein#add(fzf_home,
                \ {
                \   'if': fzf_enabled,
                \   'build': 'bash install --all',
                \ })
    call dein#add('junegunn/fzf.vim', { 'if': fzf_enabled })

    nnoremap <silent> T :FzfBuffers<cr>
    nnoremap <silent> <space>o :FzfBTags<cr>
    nnoremap <silent> <space>t :FzfTags<cr>
    nnoremap <silent> <space>cm :FzfCommits<cr>
    nnoremap <silent> <space>cb :FzfBCommits<cr>
    nnoremap <silent> <space>h :FzfHelptags<cr>

    " build command!'s and mappings for fzf file searching using some external
    " file listing command `cmd`. creates two variants: (1) search files,
    " excluding those in .gitignore files and (2) search _all_ files
    function! s:FzfFilesCommand(cmd, no_ignore_opt)
        " command! seems to evaluate lazily, so we need to pre-render these
        let g:phlip9_fzf_files_cmd_ignore = a:cmd
        let g:phlip9_fzf_files_cmd_noignore = a:cmd . ' ' . a:no_ignore_opt

        " Searching across files, ignoring those in .gitignore.
        " Unlike stock FzfGFiles, this must work outside git repos (important!).
        command! -bang -nargs=? -complete=dir FzfGFiles2
                    \ let $FZF_DEFAULT_COMMAND = g:phlip9_fzf_files_cmd_ignore |
                    \ call fzf#vim#files(<q-args>, fzf#vim#with_preview('right:50%'), <bang>0)

        " Searching across _all_ files (with some basic ignores)
        command! -bang -nargs=? -complete=dir FzfFiles2
                    \ let $FZF_DEFAULT_COMMAND = g:phlip9_fzf_files_cmd_noignore |
                    \ call fzf#vim#files(<q-args>, fzf#vim#with_preview('right:50%'), <bang>0)

        nnoremap <silent>        O :FzfGFiles2<cr>
        nnoremap <silent> <space>O :FzfFiles2<cr>
    endfunction

    " fzf file searching using `fd` or `rg`, preferring `fd` cus it has nicer colors : p
    if executable('fd')
        " fd's `--color` option emits ANSI color codes; tell fzf to show them
        " properly.
        let g:fzf_files_options = ['--ansi']
        let fd_command = 'fd ' .
                    \ '--type f --hidden --follow --color "always" --strip-cwd-prefix ' .
                    \ '--exclude ".git/*" --exclude "target/*" --exclude "tags" '
        call s:FzfFilesCommand(fd_command, '--no-ignore')
    elseif executable('rg')
        " --color 'never': rg doesn't support meaningful colors when listing
        "                  files, so let's just turn them off.
        let rg_command = 'rg ' .
                    \ '--hidden --follow --color "never" --files ' .
                    \ '--glob "!.git/*" --glob "!target/*" --glob "!tags" '
        call s:FzfFilesCommand(rg_command, '--no-ignore')
    else
        nnoremap <silent>        O :echoerr "Error: neither `fd` nor `rg` installed"<cr>
        nnoremap <silent> <space>O :echoerr "Error: neither `fd` nor `rg` installed"<cr>
    endif

    " fzf grep search using `rg`
    if executable('rg')
        let has_column = 1
        command! -bang -nargs=* RgFzfFind call fzf#vim#grep(
                    \ 'rg --column --line-number --no-heading --fixed-strings ' .
                    \ '--ignore-case --hidden --follow --color "always" ' .
                    \ '--glob "!.git/*" --glob "!target/*" --glob "!tags" ' .
                    \ shellescape(<q-args>),
                    \ 1,
                    \ fzf#vim#with_preview('right:50%'),
                    \ <bang>0)

        command! -bang -nargs=* RgFzfFindAll call fzf#vim#grep(
                    \ 'rg --column --line-number --no-heading --fixed-strings ' .
                    \ '--ignore-case --hidden --follow --color "always" ' .
                    \ '--no-ignore ' .
                    \ '--glob "!.git/*" --glob "!target/*" --glob "!tags" ' .
                    \ shellescape(<q-args>),
                    \ 1,
                    \ fzf#vim#with_preview('right:50%'),
                    \ <bang>0)

        nnoremap <space>/ :RgFzfFind<space>
        nnoremap <silent> <space>' :RgFzfFind <C-R><C-W><cr>
    endif

" }}}

" (disabled) html5.vim - html5 autocompletion, syntax, and indentation {{{

    " call dein#add('othree/html5.vim',
    "             \ {
    "             \   'lazy': 1,
    "             \   'on_ft': ['html']
    "             \ })

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

" idris2-vim - Idris2 syntax highlighting, checking, and interactive editing {{{

    " Mappings:
    " \t - show type
    " \r - reload file?
    " \h - show function documentation
    " \c - case split
    " \e - evaluate an expression
    " \f - refine item
    " \o - obvious proof search
    " \p - proof search
    " \i - open idris response window
    call dein#add('edwinb/idris2-vim')

    " TODO: check https://github.com/idris-community/idris2-lsp maybe it will
    " eventually support autocompletion?

" }}}

" ats-vim - ATS2 syntax highlighting and checking {{{

    call dein#add('phlip9/ats-vim')
    " call dein#add(expand('$HOME/dev/ats-vim'))

    let g:ats_use_ctags = 1
    let g:ats_autoformat = 0

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

    " Keep swap file
    " :FinishRecovery
    call dein#add('chrisbra/Recover.vim')

" }}}

" vim-bbye - Close a buffer without messing up your layout {{{

    call dein#add('moll/vim-bbye',
                \ {
                \   'lazy': 1,
                \   'on_cmd': ['Bdelete']
                \ })

" }}}

" cup.vim - JavaCUP syntax {{{

    call dein#add('vim-scripts/cup.vim')
    au BufNewFile,BufRead *.cup set filetype=cup

" }}}

" vim-just - Justfile syntax {{{

    call dein#add('NoahTheDuke/vim-just')

" }}}

" earthly.vim - Earthfile syntax {{{

    call dein#add('https://github.com/earthly/earthly.vim')

" }}}

" BUNDLES }}}

" GENERAL {{{

    " Required after all plugins have been declared
    call dein#end()

    filetype plugin indent on       " detect filetypes
    syntax on                       " syntax highlighting

    " Call source and post_source hooks
    call dein#call_hook('source')
    call dein#call_hook('post_source')

    set history=1000                " make the history larger
    set hidden                      " change buffers w/o having to write first
    set mouse=a                     " enable mouse for all modes
    scriptencoding=utf-8            " set encoding to utf-8
    set shortmess+=c                " don't pass messages to |ins-completion-menu|.
    "set shortmess+=filmnrxoOtT      " abbreviate annoying messages


" GENERAL }}}

" VISUAL {{{

    set nu                          " set line numbers
    set showmode                    " show current display mode
    set t_Co=256                    " number of available terminal colors
    "set cursorline                  " show a line under the cursor

    " Highlight the 80+1'th column to help keep text under 80 characters per
    " line
    set cc=81

    if has('cmdline_info')
        set ruler                                           " show ruler
        set rulerformat=%30(%=\:b%n%y%m%r%w\ %l,%c%V\ %P%)  " uber ruler
        set showcmd                                         " show partial commands in status line
    endif

    " Always display the sign column to avoid flickering with syntastic and
    " vim-gitgutter
    set signcolumn=yes

    " Colorscheme highlight overrides
    function! CustomColors()
        hi ColorColumn ctermbg=8 ctermfg=15
        
        " Make sure text doesn't fill ctermbg so terminal transparency works
        hi Normal ctermbg=NONE ctermfg=15 cterm=NONE
        hi Comment ctermbg=NONE ctermfg=12 cterm=NONE

        " Reduce popup menu brightness
        hi Pmenu ctermbg=8

        " make tabline background clear so terminal transparency isn't blocked
        " out
        "hi airline_tabsel cterm=bold ctermfg=7 ctermbg=NONE

        " Highlight CursorLine as lighter background color
        hi CursorLine ctermbg=10 ctermfg=None cterm=NONE

        " Make matching text readable
        hi MatchParen ctermbg=8 ctermfg=NONE cterm=NONE

        " Sign column color should be the same as the line number column
        hi SignColumn ctermbg=NONE

        " Make line number column same as background color
        hi LineNr ctermbg=NONE

        " Don't underline the fold lines
        hi Folded ctermbg=NONE ctermfg=12 term=bold cterm=bold 

        " Make LSP inlay hints more subtle vs Comment
        hi CocInlayHint ctermbg=NONE ctermfg=59 cterm=NONE
        hi CocRustTypeHint ctermbg=NONE ctermfg=59 cterm=NONE
        hi CocRustChainingHint ctermbg=NONE ctermfg=59 cterm=NONE
    endfunction

    " override colors on colorscheme change
    autocmd ColorScheme * :call CustomColors()

    " Colorscheme
    set background=dark
    colorscheme crayon

    "" Light colorscheme
    "set background=light
    "colorscheme morning

    " Minimalistic Airline theme with fixed backgrounds for terminal
    " transparency
    let g:airline_theme = 'crayon3'

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

    set nowrap                      " don't wrap long lines
    
    set clipboard+=unnamedplus      " place yanked text into the clipboard

    " Remove trailing whitespaces and ^M chars
    autocmd FileType c,cpp,java,php,js,python,twig,xml,yml 
                \ autocmd BufWritePre <buffer>
                \     :call setline(1,map(getline(1,"$"),
                \         'substitute(v:val,"\\s\\+$","","")'))

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

    " WSL clipboard hack
    if has('wsl')
        let g:clipboard = {
                    \   'name': 'wsl-clipboard',
                    \   'copy': {
                    \      '+': 'clip.exe',
                    \      '*': 'clip.exe',
                    \    },
                    \   'paste': {
                    \      '+': "sh -c \"powershell.exe Get-Clipboard\" | sed 's/\\r$//'",
                    \      '*': "sh -c \"powershell.exe Get-Clipboard\" | sed 's/\\r$//'",
                    \   },
                    \   'cache_enabled': 1,
                    \ }
    endif

    " custom math digraphs
    " Directions: type <C-K><digraph-code> to write digraph
    " Example: <C-K>na => ℕ

    " N natural numbers
    digraphs na 8469
    " Z integers
    digraphs IN 8484
    " ▸ small black right-pointing triangle
    digraphs tr 9656
    " ⟩ vector right bracket
    digraphs br 10217
    " ⟨ vector left bracket
    digraphs bl 10216
    " ‹ french quote left
    digraphs << 8249
    " › french quote left
    digraphs >> 8250
    " ∀ for all
    digraphs fa 8704
    " ∃ there exists
    digraphs te 8707
    " ¬ not
    digraphs no 172
    " ≠ not equal
    digraphs ne 8800
    " ∉ not in
    digraphs ni 8713
    " ∈ in
    digraphs in 8712
    " ∧ and
    digraphs an 8743
    " ∨ or
    digraphs or 8744
    " × multiplication
    digraphs xx 215
    " ⊕ o-plus
    digraphs op 8853
    " ⁻ superscript minus
    digraphs s- 8315
    " ¹ superscript one
    digraphs s1 185
    " ∣ divides
    digraphs di 8739
    " ⦃ left curly bracket
    digraphs cl 10627
    " ⦄ right curly bracket
    digraphs cr 10628
    " ≡ equivalence
    digraphs eq 8801
    " ↑ up arrow
    digraphs up 8593
    " ≈ approx
    digraphs ap 8776
    " ∑ sum, sigma (upper)
    digraphs su 8721

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

    " replace currently selected text w/o clobbering the yank register
    " note: "_ is the blackhole register
    vnoremap <silent><leader>p "_dP

    " Bind Up and Down keys to add line above and below
    nnoremap <silent><Up> O<Esc>j
    nnoremap <silent><Down> o<Esc>k

    " remap Visual Block selection to something that doesn't conflict with
    " system copy/paste
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

    " Terminal Mode
    " Use escape to go back to normal mode
    tnoremap <Esc> <C-\><C-n>
    " Window movement in terminal mode w/ CTRL + h,j,k,l
    tnoremap <C-h> <C-\><C-n><C-W>h
    tnoremap <C-j> <C-\><C-n><C-W>j
    tnoremap <C-k> <C-\><C-n><C-W>k
    tnoremap <C-l> <C-\><C-n><C-W>l

    " Go to the next/previous error (in the same buffer)
    nnoremap <silent> <leader>en :lnext<CR>
    nnoremap <silent> <leader>ep :lprevious<CR>

" KEYBINDINGS }}}

" POSTLUDE {{{

    " If there are uninstalled bundles found on startup,
    " this will conveniently prompt you to install them.
    if !has('vim_starting') && dein#check_install()
        call dein#install()
    endif

" POSTLUDE }}}

" vim: foldmethod=marker
