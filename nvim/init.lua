-- PRELUDE {{{

-- enable experimental lua module loader w/ byte-code cache
vim.loader.enable()

-- Rebind mapleader to something more accessible.
vim.g.mapleader = ","

-- PRELUDE }}}

-- LUA PLUGINS {{{

-- lua utils {{{

-- Pretty-print any lua value and display it in a temp buffer
_G.dbg = function(...)
    return require("util").dbg(...)
end

-- lua utils }}}

-- nvim-treesitter - tree-sitter interface and syntax highlighting {{{

---@diagnostic disable-next-line: missing-fields
require("nvim-treesitter.configs").setup({
    -- we're managing parser installation via nix, so don't auto install
    auto_install = false,
    ensure_installed = {},

    highlight = {
        -- enable tree-sitter highlighting
        enable = true,
        -- don't use tree-sitter highlighting and vim regex highlighting at
        -- the same time
        additional_vim_regex_highlighting = false,
    },
    indent = {
        enable = true,
    },
})

-- nvim-treesitter }}}

-- kanagawa - neovim colorscheme {{{

require("kanagawa").setup({
    -- enable terminal text undercurls (underlines, dotted underlines, etc)
    undercurl = true,
    commentStyle = { italic = false },
    functionStyle = {},
    keywordStyle = { italic = false },
    statementStyle = { bold = false },
    typeStyle = {},
    -- don't set background color
    transparent = false,
    -- dim normal text in other, inactive windows
    dimInactive = false,
    -- define g:terminal_color_{0,17}
    terminalColors = true,
    -- add/modify theme palette colors
    -- palette colors: <https://github.com/rebelot/kanagawa.nvim/blob/master/lua/kanagawa/colors.lua>
    colors = {
        palette = {
            fujiWhite = "#deddd3", -- desaturated and lightened

            -- darken the darker dragonBlack's
            dragonBlack0 = "#0d0c0c",
            dragonBlack1 = "#0d0c0c",
            dragonBlack2 = "#12120f",
            dragonBlack3 = "#12120f",
        },
        theme = {
            wave = {},
            lotus = {},
            dragon = {},
            all = {
                ui = {
                    -- Remove the background highlight for gutter
                    bg_gutter = "none",
                },
            },
        },
    },

    -- -- add/modify highlights
    -- ---@type fun(colors: KanagawaColorsSpec): table<string, table>
    -- overrides = function(colors)
    --     local _palette = colors.palette
    --     local _theme = colors.theme
    --     return {}
    -- end,

    -- when `background` is set, use corresponding theme
    background = { dark = "dragon", light = "lotus" },
    -- when `background` is not set, use default theme
    theme = "dragon",
    compile = false,
})

-- Uncomment these to inspect kanagawa's exact generated colors/highlights
--
-- -- Dump the current kanagawa colors
-- -- :lua dbg(kanagawa_dump_colors())
-- _G.kanagawa_dump_colors = function()
--     local config = require("kanagawa").config
--     local colors = require("kanagawa.colors").setup({ theme = config.theme, colors = config.colors })
--     return colors
-- end
--
-- -- Dump the current kanagawa highlights
-- -- :lua dbg(kanagawa_dump_highlights())
-- _G.kanagawa_dump_highlights = function()
--     local config = require("kanagawa").config
--     local colors = kanagawa_dump_colors()
--     local highlights = require("kanagawa.highlights").setup(colors, config)
--     return highlights
-- end

-- kanagawa }}}

-- LUA PLUGINS }}}

vim.cmd([[

" VIM PLUGINS {{{

" NERDCommenter - Easily comment lines or blocks of text {{{

    " Mappings:
    " <leader>c<space> - Toggle current line comment
    " <leader>cm - Block comment
    " (disabled) <leader>c$ - Comment from cursor to end of line
    " (disabled) <leader>cA - Comment from cursor to end of line and go into insert mode

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
                \ 'c': { 'left': '//', 'leftAlt': '/*', 'rightAlt': '*/' },
                \ 'dart': { 'left': '//' },
                \ 'dtrace': { 'left': '//' },
                \ }

    " key bindings
    nnoremap <silent> <leader>c<Space> <Plug>NERDCommenterToggle
    xnoremap <silent> <leader>c<Space> <Plug>NERDCommenterToggle

    nnoremap <silent> <leader>cm <Plug>NERDCommenterMinimal
    xnoremap <silent> <leader>cm <Plug>NERDCommenterMinimal

" NERDCommenter }}}

" vim-gitgutter - Show git diff in the gutter {{{

    " Mappings:
    " <leader>ggt - Toggle git gutter
    " <leader>ggd - open git diff split pane for current file
    " <leader>hs - Stage hunk
    " <leader>hr - Undo hunk
    " <leader>hf - Move forward one hunk
    " <leader>hb - Move backward one hunk

    " Don't automatically set mappings.
    let g:gitgutter_map_keys = 0

    nmap <leader>ggt :GitGutterToggle<CR>
    nmap <leader>ggd :GitGutterDiffOrig<CR>

    " Hunk management
    nmap <leader>hs :GitGutterStageHunk<CR>
    nmap <leader>hr :GitGutterUndoHunk<CR>

    " Hunk movement
    nmap <leader>hf :GitGutterNextHunk<CR>
    nmap <leader>hb :GitGutterPrevHunk<CR>

" vim-gitgutter }}}

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
    " <space>o    - fuzzy search file outline
    " <space>s    - fuzzy search project symbols
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

    function! s:coc_check_back_space() abort
        let col = col('.') - 1
        return !col || getline('.')[col - 1]  =~# '\s'
    endfunction

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
    inoremap <silent><expr> <CR> pumvisible() ? coc#_select_confirm()
                \: "\<C-g>u\<CR>\<c-r>=coc#on_enter()\<CR>"

    " Use `[c` and `]c` for navigate diagnostics
    nnoremap <silent> [c :call CocAction('diagnosticPrevious')<CR>
    nnoremap <silent> ]c :call CocAction('diagnosticNext')<CR>

    nnoremap <silent> <leader>gd :call CocAction('jumpDefinition')<CR>
    nnoremap <silent> <leader>gc :call CocAction('jumpDeclaration')<CR>
    nnoremap <silent> <leader>gi :call CocAction('jumpImplementation')<CR>
    nnoremap <silent> <leader>gt :call CocAction('jumpTypeDefinition')<CR>
    nnoremap <silent> <leader>ren :call CocActionAsync('rename')<CR>
    nnoremap <silent> <leader>ref :call CocAction('jumpReferences')<CR>
    nnoremap <silent> <leader>h :call CocAction('doHover')<CR>
    " nnoremap <leader>a <Plug>(coc-codeaction-selected)<CR>
    " xnoremap <leader>a <Plug>(coc-codeaction-selected)
    " nnoremap <silent> <leader>di :call CocAction('diagnosticInfo')<CR>
    " nnoremap <silent> <leader>cm :CocCommand<CR>

    " flutter-specific bindings
    autocmd FileType dart
                \ nnoremap <buffer> <silent> <leader>fd :CocCommand flutter.devices<CR> |
                \ nnoremap <buffer> <silent> <leader>fr :CocCommand flutter.run<CR> |
                \ nnoremap <buffer> <silent> <leader>ft :CocCommand flutter.dev.hotRestart<CR> |
                \ nnoremap <buffer> <silent> <leader>fs :CocCommand flutter.dev.quit<CR> |
                \ nnoremap <buffer> <silent> <leader>fl :CocCommand flutter.dev.openDevLog<CR>

    " " This lets you select or use vim verbs inside/around functions/"classes".
    " " NOTE: Requires 'textDocument.documentSymbol' support from the language server.
    " xmap if <Plug>(coc-funcobj-i)
    " omap if <Plug>(coc-funcobj-i)
    " xmap af <Plug>(coc-funcobj-a)
    " omap af <Plug>(coc-funcobj-a)
    " xmap ic <Plug>(coc-classobj-i)
    " omap ic <Plug>(coc-classobj-i)
    " xmap ac <Plug>(coc-classobj-a)
    " omap ac <Plug>(coc-classobj-a)

    " Remap <C-f> and <C-b> to scroll float windows/popups.
    nnoremap <silent><nowait><expr> <C-f> coc#float#has_scroll() ? coc#float#scroll(1) : "\<C-f>"
    nnoremap <silent><nowait><expr> <C-b> coc#float#has_scroll() ? coc#float#scroll(0) : "\<C-b>"
    inoremap <silent><nowait><expr> <C-f> coc#float#has_scroll() ? "\<c-r>=coc#float#scroll(1)\<cr>" : "\<Right>"
    inoremap <silent><nowait><expr> <C-b> coc#float#has_scroll() ? "\<c-r>=coc#float#scroll(0)\<cr>" : "\<Left>"
    vnoremap <silent><nowait><expr> <C-f> coc#float#has_scroll() ? coc#float#scroll(1) : "\<C-f>"
    vnoremap <silent><nowait><expr> <C-b> coc#float#has_scroll() ? coc#float#scroll(0) : "\<C-b>"

    "
    " coc-fzf
    "
    let g:coc_fzf_preview='right:50%'
    nnoremap <silent> <space>o :CocFzfList outline<cr>
    nnoremap <silent> <space>s :CocFzfList symbols<cr>
    nnoremap <silent> <leader>a :CocFzfList actions<cr>
    xnoremap <silent> <leader>a :CocFzfList actions
    nnoremap <silent> <leader>di :CocFzfList diagnostics<cr>
    nnoremap <silent> <leader>cm :CocFzfList commands<cr>

"  }}}

" SudoEdit.vim - Easily write to protected files {{{

    " Use `pkexec` on more recent Ubuntu/Debian/Pop!_OS
    if executable('pkexec')
        let g:sudoAuth='pkexec'
    endif

" SudoEdit.vim }}}

" vim-airline - Lightweight yet fancy status line {{{

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

" fzf.vim - fuzzy file matching, grepping, and tag searching using fzf {{{

    " Mappings:
    "         O - open files search (ignoring files in .gitignore)
    "  <space>O - open files search (all files)
    "         T - open buffers search
    "  <space>/ - grep with pattern
    "  <space>' - grep using word under cursor
    " <space>cm - grep through commits
    " <space>cb - grep through commits for the current buffer
    "  <space>h - grep through vim help

    let g:fzf_command_prefix = 'Fzf'

    nnoremap <silent> T :FzfBuffers<cr>
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

    " fzf file searching using `fd`
    if executable('fd')
        " fd's `--color` option emits ANSI color codes; tell fzf to show them.
        let g:fzf_files_options = ['--ansi']
        let fd_command = 'fd ' .
                    \ '--type f --hidden --follow --color "always" --strip-cwd-prefix ' .
                    \ '--exclude ".git/*" --exclude "target/*" --exclude "tags" '
        call s:FzfFilesCommand(fd_command, '--no-ignore')
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

" Recover.vim - Show a diff when recovering swp files {{{

    " Keep swap file
    " :FinishRecovery

" }}}

" VIM PLUGINS }}}

" GENERAL {{{

    filetype plugin indent on       " detect filetypes
    syntax on                       " syntax highlighting

    set history=1000                " make the history larger
    set hidden                      " change buffers w/o having to write first
    set mouse=a                     " enable mouse for all modes
    set shortmess+=c                " don't pass messages to |ins-completion-menu|.

" GENERAL }}}

" VISUAL {{{

    set nu                          " set line numbers
    set showmode                    " show current display mode
    set termguicolors               " use RGB colors

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

    " Colorscheme
    set background=dark
    colorscheme kanagawa

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
    autocmd FileType c,cpp,java,php,js,python,twig,xml,yml,vim,nix,dart
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

    " re-center screen on C-d, C-u, search next/prev
    nnoremap <C-d> <C-d>zz
    nnoremap <C-u> <C-u>zz
    nnoremap n nzzzv
    nnoremap N Nzzzv

    " Reload nvimrc
    nnoremap <silent> <leader>V :source $MYVIMRC<CR>:filetype detect<CR>:echo 'nvim config reloaded'<CR>

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

]])

--  vim: foldmethod=marker
