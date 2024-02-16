-- PRELUDE {{{

-- enable experimental lua module loader w/ byte-code cache
vim.loader.enable()

-- Rebind mapleader to something more accessible.
vim.g.mapleader = ","

-- Track the "generation" number for sourcing `init.lua`.
-- Used to ensure re-sourcing will re-run "one-time" init in various places.
if _G.my_init_generation == nil then
    _G.my_init_generation = 0
else
    _G.my_init_generation = _G.my_init_generation + 1
end

-- PRELUDE }}}

-- LUA PLUGINS {{{

-- lua utils {{{

-- Pretty-print any lua value and display it in a temp buffer
_G.dbg = function(...)
    return require("util").dbg(...)
end

-- Unload and then `require` a module
---@param modname string
_G.rerequire = function(modname)
    return require("util").rerequire(modname)
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

    -- nvim-treesitter-textobjects - syntax aware text objs + motions
    textobjects = {
        -- <action><in/around><textobject>
        -- e.g. cif = change in function
        --      vac = visual-select around class
        select = {
            enable = true,
            -- jump for to next textobj if not currently in a matching one
            lookahead = true,
            keymaps = {
                ["af"] = "@function.outer",
                ["if"] = "@function.inner",
                ["ac"] = "@class.outer",
                ["ic"] = "@class.inner",
                ["ap"] = "@parameter.outer",
                ["ip"] = "@parameter.inner",
                ["ai"] = "@call.outer",
                ["ii"] = "@call.inner",
                ["as"] = { query = "@local.scope", query_group = "locals" },
                ["is"] = { query = "@local.scope", query_group = "locals" },
            },
        },

        -- vim motions with treesitter textobjects
        move = {
            enable = true,
            -- add movements to jumplist
            set_jumps = true,

            -- Notes:
            --
            -- `query`: by default, can only use items defined in the
            -- nvim-treesitter-textobjects textobjects.scm query file for each
            -- language.
            -- Ex: <https://github.com/nvim-treesitter/nvim-treesitter-textobjects/blob/master/queries/rust/textobjects.scm>
            --
            -- `query_group`: use a query defined in one of the other *.scm
            -- query files. the parameter is the filename w/o the .scm extension.
            -- Ex (locals): <https://github.com/nvim-treesitter/nvim-treesitter/blob/master/queries/rust/locals.scm>

            goto_next_start = {
                ["]f"] = { query = "@function.outer", desc = "goto next function start" },
                ["]c"] = { query = "@class.outer", desc = "goto next class start" },
                ["]p"] = { query = "@parameter.outer", desc = "goto next parameter start" },
                ["]i"] = { query = "@call.outer", desc = "goto next function invocation start" },
                ["]s"] = { query = "@local.scope", query_group = "locals", desc = "goto next scope start" },
            },
            goto_next_end = {
                ["]F"] = { query = "@function.outer", desc = "goto next function end" },
                ["]C"] = { query = "@class.outer", desc = "goto next class end" },
                ["]P"] = { query = "@parameter.outer", desc = "goto next parameter end" },
                ["]I"] = { query = "@call.outer", desc = "goto next function invocation end" },
                ["]S"] = { query = "@local.scope", query_group = "locals", desc = "goto next scope end" },
            },
            goto_previous_start = {
                ["[f"] = { query = "@function.outer", desc = "goto prev function start" },
                ["[c"] = { query = "@class.outer", desc = "goto prev class start" },
                ["[p"] = { query = "@parameter.outer", desc = "goto prev parameter start" },
                ["[i"] = { query = "@call.outer", desc = "goto prev function invocation start" },
                ["[s"] = { query = "@local.scope", query_group = "locals", desc = "goto prev scope start" },
            },
            goto_previous_end = {
                ["[F"] = { query = "@function.outer", desc = "goto prev function end" },
                ["[C"] = { query = "@class.outer", desc = "goto prev class end" },
                ["[P"] = { query = "@parameter.outer", desc = "goto prev parameter end" },
                ["[I"] = { query = "@call.outer", desc = "goto prev function invocation end" },
                ["[S"] = { query = "@local.scope", query_group = "locals", desc = "goto prev scope end" },
            },
        },

        -- swap textobjects under the cursor
        swap = {
            enable = true,
            swap_next = {
                [">f"] = { query = "@function.outer", desc = "swap w/ next function" },
                [">c"] = { query = "@class.outer", desc = "swap w/ next class" },
                [">p"] = { query = "@parameter.inner", desc = "swap w/ next parameter" },
            },
            swap_previous = {
                ["<f"] = { query = "@function.outer", desc = "swap w/ prev function" },
                ["<c"] = { query = "@class.outer", desc = "swap w/ prev class" },
                ["<p"] = { query = "@parameter.inner", desc = "swap w/ prev parameter" },
            },
        },
    },

    -- nvim-treesitter-endwise - auto-add `end` block to lua, bash, ruby, etc...
    endwise = {
        enable = true,
    }
})

-- Repeatable Move
--
-- Press ';' to repeat the last move kind, in forward direction
-- Press '+' to repeat the last move kind, in reverse direction
local ts_repeat_move = require("nvim-treesitter.textobjects.repeatable_move")

vim.keymap.set({ "n", "x", "o" }, ";", ts_repeat_move.repeat_last_move_next, { remap = true })
vim.keymap.set({ "n", "x", "o" }, "+", ts_repeat_move.repeat_last_move_previous, { remap = true })

-- Make builtin f, F, t, T also repeatable
vim.keymap.set({ "n", "x", "o" }, "f", ts_repeat_move.builtin_f)
vim.keymap.set({ "n", "x", "o" }, "F", ts_repeat_move.builtin_F)
vim.keymap.set({ "n", "x", "o" }, "t", ts_repeat_move.builtin_t)
vim.keymap.set({ "n", "x", "o" }, "T", ts_repeat_move.builtin_T)

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

-- VIM PLUGINS {{{

-- vim-gitgutter - Show git diff in the gutter {{{

-- Mappings:
-- <leader>ggt - Toggle git gutter
-- <leader>ggd - open git diff split pane for current file
-- <leader>hs - Stage hunk
-- <leader>hr - Undo hunk
-- ]h - Move forward one hunk
-- [h - Move backward one hunk
-- <motion>ih - <motion> in hunk
-- <motion>ah - <motion> around hunk (includes trailing empty lines)

-- Don't automatically set mappings.
vim.g.gitgutter_map_keys = false

vim.keymap.set("n", "<leader>ggt", vim.cmd.GitGutterToggle, { remap = false })
vim.keymap.set("n", "<leader>ggd", vim.cmd.GitGutterDiffOrig, { remap = false })
vim.keymap.set("n", "<leader>hs", vim.cmd.GitGutterStageHunk, { remap = false })
vim.keymap.set("n", "<leader>hr", vim.cmd.GitGutterUndoHunk, { remap = false })

-- Make GitGutter(Next|Prev)Hunk repeatable
local move_hunk_next, move_hunk_prev = ts_repeat_move.make_repeatable_move_pair(
    vim.cmd.GitGutterNextHunk,
    vim.cmd.GitGutterPrevHunk
)
vim.keymap.set({ "n", "x", "o" }, "]h", move_hunk_next)
vim.keymap.set({ "n", "x", "o" }, "[h", move_hunk_prev)

vim.keymap.set("o", "ih", "<Plug>(GitGutterTextObjectInnerPending)")
vim.keymap.set("o", "ah", "<Plug>(GitGutterTextObjectOuterPending)")
vim.keymap.set("x", "ih", "<Plug>(GitGutterTextObjectInnerVisual)")
vim.keymap.set("x", "ah", "<Plug>(GitGutterTextObjectOuterVisual)")

-- vim-gitgutter }}}

-- coc.nvim - Complete engine and Language Server support for neovim {{{

-- Mappings:
--         gd  - goto definition
--         gc  - goto declaration
--         gi  - goto implementations
--         gt  - goto type definition
--         gr  - goto references
-- <leader>rn  - rename
-- <leader>rf  - refactor
-- <leader>doc - show docs / symbol hover
-- <leader>a   - code action
-- <leader>di  - diagnostic info
-- <leader>cm  - select an LSP command
-- <space>o    - fuzzy search file outline
-- <space>s    - fuzzy search project symbols
--
-- Flutter:
-- <leader>fd - flutter devices
-- <leader>fr - flutter run
-- <leader>ft - flutter hot restart
-- <leader>fs - flutter stop
-- <leader>fl - flutter dev log
--
-- ]d, [d     - next/prev linter errors
-- <Tab>, <S-Tab> - next/prev completion
-- <C-Space>  - trigger completion
-- <C-f>      - scroll float window up
-- <C-b>      - scroll float window down

---@param cb function(err: string, is_attached: boolean)
local function coc_buf_lsp_is_attached_async(cb)
    local success, result = pcall(vim.fn.CocActionAsync, "ensureDocument", cb)
    if success then return end

    local errmsg
    if type(result) == string then
        errmsg = result
    else
        errmsg = "Error: " .. vim.inspect(result)
    end
    cb(errmsg, nil)
end

-- ---@return boolean
-- local function coc_buf_lsp_is_attached()
--     return vim.fn.CocAction("ensureDocument")
-- end

local function coc_rpc_ready()
    return vim.fn["coc#rpc#ready()"] ~= 0
end

local function coc_pum_visible()
    return vim.fn["coc#pum#visible"]() ~= 0
end

local function coc_pum_confirm()
    return vim.fn["coc#pum#confirm"]()
end

local function coc_pum_next(amount)
    return vim.fn["coc#pum#next"](amount)
end

local function coc_pum_prev(amount)
    return vim.fn["coc#pum#prev"](amount)
end

local function coc_refresh()
    return vim.fn["coc#refresh"]()
end

local function coc_float_has_scroll()
    return vim.fn["coc#float#has_scroll"]() ~= 0
end

local function coc_float_scroll(amount)
    return vim.fn["coc#float#scroll"](amount)
end

local function check_back_space()
    local col = vim.fn.col(".") - 1
    return col == 0 or vim.fn.getline("."):sub(col, col):match("%s") ~= nil
end

-- autocmd group for all coc.nvim autocmds
vim.api.nvim_create_augroup("CocGroup", {})

-- If the autocomplete window is open, use <Tab>/<S-Tab> to goto the next/prev entry.
-- If there's no preceeding whitespace, use <Tab> to start autocomplete.
-- Else normal <Tab>/<S-Tab> behavior.
local opts = { silent = true, noremap = true, expr = true }
vim.keymap.set("i", "<Tab>", function()
    if coc_pum_visible() then
        return coc_pum_next(1)
    elseif check_back_space() then
        return "<Tab>"
    else
        return coc_refresh()
    end
end, opts)
vim.keymap.set("i", "<S-Tab>", function()
    if coc_pum_visible() then
        return coc_pum_prev(1)
    else
        return "<S-Tab>"
    end
end, opts)

-- Use <CR> to confirm completion. `<C-g>u` means break undo chain at current position.
vim.keymap.set("i", "<CR>", function()
    if coc_pum_visible() then
        return coc_pum_confirm()
    else
        return "<C-g>u<CR><c-r>=coc#on_enter()<CR>"
    end
end, opts)

-- Use <C-Space> to trigger autocomplete.
vim.keymap.set("i", "<C-Space>", "coc#refresh()", opts)

-- code navigation
local opts = { silent = true }
vim.keymap.set("n", "gd", "<Plug>(coc-definition)", opts)
vim.keymap.set("n", "gc", "<Plug>(coc-declaration)", opts)
vim.keymap.set("n", "gi", "<Plug>(coc-implementation)", opts)
vim.keymap.set("n", "gt", "<Plug>(coc-type-definition)", opts)
vim.keymap.set("n", "gr", "<Plug>(coc-references)", opts)

-- code actions
vim.keymap.set("n", "<leader>rn", "<Plug>(coc-rename)", opts)
vim.keymap.set("n", "<leader>rf", "<Plug>(coc-refactor)", opts)

-- Use <leader>doc to show docs for current symbol under cursor.
vim.keymap.set("n", "<leader>doc", function()
    local cw = vim.fn.expand("<cword>")
    if vim.fn.index({ "vim", "help" }, vim.bo.filetype) >= 0 then
        vim.api.nvim_command("help " .. cw)
    elseif coc_rpc_ready() then
        vim.fn.CocActionAsync("doHover")
    else
        -- `keywordprg` can be a vim command or a binary
        local cmd = vim.o.keywordprg .. " " .. cw

        -- if it's a binary and not vim command
        if cmd:sub(1, 1) ~= ":" then
            -- do nothing if this `keywordprg` is not installed
            local bin = cmd:match("^%S+")
            if not bin or not vim.fn.executable(bin) then return end

            -- bin exists, just need to prefix w/ "!" to execute as shell cmd
            cmd = "!" .. cmd
        end
        vim.api.nvim_command(cmd)
    end
end, { silent = true })

-- Remap <C-f> and <C-b> to scroll float windows/popups.
local opts = { silent = true, expr = true, nowait = true, remap = false }
vim.keymap.set({ "n", "v" }, "<C-f>", function()
    if coc_float_has_scroll() then
        return coc_float_scroll(1)
    else
        return "<C-f>"
    end
end, opts)
vim.keymap.set("i", "<C-f>", function()
    if coc_float_has_scroll() then
        return "<C-r>=coc#float#scroll(1)<CR>"
    else
        return "<Right>"
    end
end, opts)
vim.keymap.set({ "n", "v" }, "<C-b>", function()
    if coc_float_has_scroll() then
        return coc_float_scroll(0)
    else
        return "<C-b>"
    end
end, opts)
vim.keymap.set("i", "<C-b>", function()
    if coc_float_has_scroll() then
        return "<C-r>=coc#float#scroll(0)<CR>"
    else
        return "<Left>"
    end
end, opts)

-- Use `[d` + `]d` to navigate code "diagnostics", i.e., lint warnings + errors.
local move_diagnostic_next, move_diagnostic_prev = ts_repeat_move.make_repeatable_move_pair(
    function() return vim.fn.CocActionAsync("diagnosticNext") end,
    function() return vim.fn.CocActionAsync("diagnosticPrevious") end
)
local opts = { silent = true, remap = false }
vim.keymap.set("n", "]d", move_diagnostic_next, opts)
vim.keymap.set("n", "[d", move_diagnostic_prev, opts)

-- Run in a buffer when it's safe to assume a coc.nvim LSP is attached.
local function coc_buffer_init()
    -- Early exit if buffer was init'd in this generation
    local gen = vim.b.coc_buffer_init_generation or -1
    if gen >= _G.my_init_generation then return end
    vim.b.coc_buffer_init_generation = _G.my_init_generation

    -- Setup formatexpr for supportted languages
    vim.opt_local.formatexpr = "CocAction('formatSelected')"
end
local function coc_buffer_maybe_init()
    -- Early exit if buffer was init'd in this generation
    local gen = vim.b.coc_buffer_init_generation or -1
    if gen >= _G.my_init_generation then return end
    -- only set buffer generation when we actually init the buffer

    coc_buf_lsp_is_attached_async(function(err, is_attached)
        if err ~= vim.NIL then return end
        if not is_attached then return end
        coc_buffer_init()
    end)
end
vim.api.nvim_create_autocmd("User", {
    group = "CocGroup",
    pattern = "CocNvimInit",
    desc = "Coc LSP post-init setup",
    callback = coc_buffer_maybe_init,
})
vim.api.nvim_create_autocmd("BufEnter", {
    group = "CocGroup",
    pattern = "*",
    desc = "Coc LSP buffer setup",
    callback = coc_buffer_maybe_init,
})
vim.api.nvim_create_autocmd("SourcePost", {
    group = "CocGroup",
    pattern = "*/nvim/init.lua",
    desc = "Coc LSP post-source setup",
    callback = coc_buffer_maybe_init,
})

-- When filling out parameters in a function after autocomplete, this shows the
-- param docs.
vim.api.nvim_create_autocmd("User", {
    group = "CocGroup",
    pattern = "CocJumpPlaceholder",
    desc = "Update signature help on jump placeholder",
    callback = function() vim.fn.CocActionAsync("showSignatureHelp") end,
})

-- coc-fzf
vim.g.coc_fzf_preview = "right:50%"
local opts = { silent = true, remap = false }
vim.keymap.set("n", "<space>o", ":CocFzfList outline<cr>", opts)
vim.keymap.set("n", "<space>s", ":CocFzfList symbols<cr>", opts)
vim.keymap.set("n", "<leader>a", ":CocFzfList actions<cr>", opts)
vim.keymap.set("n", "<leader>di", ":CocFzfList diagnostics<cr>", opts)
vim.keymap.set("n", "<leader>cm", ":CocFzfList commands<cr>", opts)
vim.keymap.set("x", "<leader>a", ":CocFzfList actions", opts)

-- ft: flutter
vim.api.nvim_create_autocmd("FileType", {
    group = "CocGroup",
    pattern = "dart",
    desc = "coc.nvim + dart keybinds",
    callback = function()
        local opts = { buffer = true, silent = true, remap = false }
        vim.keymap.set("n", "<leader>fd", ":CocCommand flutter.devices<CR>", opts)
        vim.keymap.set("n", "<leader>fr", ":CocCommand flutter.run<CR>", opts)
        vim.keymap.set("n", "<leader>ft", ":CocCommand flutter.dev.hotRestart<CR>", opts)
        vim.keymap.set("n", "<leader>fs", ":CocCommand flutter.dev.quit<CR>", opts)
        vim.keymap.set("n", "<leader>fl", ":CocCommand flutter.dev.openDevLog<CR>", opts)
    end
})

-- coc.nvim }}}

vim.cmd([[

" NERDCommenter - Easily comment lines or blocks of text {{{

    " Mappings:
    " <leader>c<space> - Toggle current line comment
    " <leader>cb - Block comment

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

    nnoremap <silent> <leader>cb <Plug>NERDCommenterMinimal
    xnoremap <silent> <leader>cb <Plug>NERDCommenterMinimal

" NERDCommenter }}}

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
    " <space>vh - grep through nvim help
    " <space>vm - grep through nvim mappings

    let g:fzf_command_prefix = 'Fzf'

    nnoremap <silent> T :FzfBuffers<cr>
    nnoremap <silent> <space>cm :FzfCommits<cr>
    nnoremap <silent> <space>cb :FzfBCommits<cr>
    nnoremap <silent> <space>vh :FzfHelptags<cr>
    nnoremap <silent> <space>vm :FzfMaps<cr>

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

    set keywordprg=:Man             " use vim built-in man viewer

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
