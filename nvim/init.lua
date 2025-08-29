do -- PRELUDE {{{
    -- enable experimental lua module loader w/ byte-code cache
    vim.loader.enable()

    -- Track the "generation" number for sourcing `init.lua`.
    -- Used to ensure re-sourcing will re-run "one-time" init in various places.
    if _G.my_init_generation == nil then
        _G.my_init_generation = 0
    else
        _G.my_init_generation = _G.my_init_generation + 1
    end

    -- Rebind mapleader to something more accessible.
    vim.g.mapleader = ","

    -- `string` extension methods
    require("util.stringext")
end -- PRELUDE }}}

-- PLUGINS {{{

-- functions visible in whole init.lua go here
local M = {}

do -- lua utils {{{
    -- Pretty-print any lua value and display it in a temp buffer
    function _G.dbg(...)
        return require("util").dbg(...)
    end

    -- Unload and then `require` a module
    ---@param modname string
    function _G.rerequire(modname)
        return require("util").rerequire(modname)
    end

    -- Wrap a function so that it recenters the cursor if it moved after calling
    -- the function.
    function M.recenter_after(fn)
        return function(...)
            local winid = vim.api.nvim_get_current_win()
            local bufid = vim.api.nvim_win_get_buf(winid)
            local cursor = vim.api.nvim_win_get_cursor(winid)

            local status, res = pcall(fn, ...)
            if not status then
                vim.notify("recenter_after: " .. res, vim.log.levels.ERROR)
                return
            end

            -- only recenter view if we actually moved somewhere
            if winid ~= vim.api.nvim_get_current_win()
                or bufid ~= vim.api.nvim_win_get_buf(winid)
                or cursor ~= vim.api.nvim_win_get_cursor(winid)
            then
                -- recenter
                vim.cmd(":normal! zz")
            end

            return res
        end
    end

    function M.with_desc(desc, opts)
        return vim.tbl_extend("force",
            opts or {},
            { silent = true, remap = false, desc = desc }
        )
    end
end -- lua utils }}}

do  -- help split - open vim :help in current window {{{
    local group = vim.api.nvim_create_augroup("HelpSplit", {})
    vim.api.nvim_create_autocmd("BufNew", {
        pattern = "*",
        group = group,
        desc = "Force :help to open in current buffer",
        callback = function(opts) require("helpsplit").on_buf_new(opts) end,
    })
end -- help split }}}

do  -- nvim-treesitter - tree-sitter interface and syntax highlighting {{{
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
        },
    })

    -- -- Use the html treesitter parser for all .xml files, since it works better.
    -- vim.treesitter.language.register("html", "xml")

    -- -- nvim-treesitter-context - show the context that's past the scroll height
    -- require("treesitter-context").setup({
    --     enable = true,
    --     -- max size of the context window
    --     max_lines = 10,
    --     -- don't show on small height windows
    --     min_window_height = 50,
    --     -- max size for any single context in the stack
    --     multiline_threshold = 5,
    --     -- no separator (background color is enough)
    --     separator = "",
    -- })

    -- nvim-treesitter-textobjects - repeatable movements
    --
    -- Press ';' to repeat the last move kind, in forward direction
    -- Press '+' to repeat the last move kind, in reverse direction
    local repeatable_move = require("nvim-treesitter.textobjects.repeatable_move")

    local opts = { silent = true, remap = false }
    vim.keymap.set({ "n", "x", "o" }, ";", M.recenter_after(repeatable_move.repeat_last_move_next), opts)
    vim.keymap.set({ "n", "x", "o" }, "+", M.recenter_after(repeatable_move.repeat_last_move_previous), opts)

    -- Make builtin f, F, t, T also repeatable
    vim.keymap.set({ "n", "x", "o" }, "f", repeatable_move.builtin_f, opts)
    vim.keymap.set({ "n", "x", "o" }, "F", repeatable_move.builtin_F, opts)
    vim.keymap.set({ "n", "x", "o" }, "t", repeatable_move.builtin_t, opts)
    vim.keymap.set({ "n", "x", "o" }, "T", repeatable_move.builtin_T, opts)

    -- Toggle treesitter syntax-based folding
    local function toggle_treesitter_fold()
        local buf = vim.api.nvim_get_current_buf()

        if not vim.b[buf].prev_fold_state then
            -- enable and save current state
            vim.b[buf].prev_fold_state = {
                foldmethod = vim.opt_local.foldmethod:get(),
                foldexpr = vim.opt_local.foldexpr:get(),
            }

            vim.opt_local.foldmethod = "expr"
            vim.opt_local.foldexpr = "nvim_treesitter#foldexpr()"
        else
            -- disable and restore previous state
            local f = vim.b[buf].prev_fold_state
            vim.opt_local.foldmethod = f.foldmethod
            vim.opt_local.foldexpr = f.foldexpr
            vim.b[buf].prev_fold_state = nil
        end
    end
    vim.keymap.set("n", "<leader>tsf", toggle_treesitter_fold,
        M.with_desc("Toggle Treesitter syntax-based folding", opts))
end

-- nvim-treesitter }}}

do -- kanagawa - neovim colorscheme {{{
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

        -- add/modify highlights
        ---@type fun(colors: KanagawaColorsSpec): table<string, table>
        ---@diagnostic disable: unused-local
        overrides = function(colors)
            -- local _palette = colors.palette
            -- local _theme = colors.theme
            return {
                -- markdown: remove link underlines
                ["@markup.link"] = {
                    link = "@string.special"
                },
                ["@markup.link.url"] = {
                    link = "@string.special.url"
                },
                ["@string.special.url"] = {
                    link = "Special"
                },
                -- ["@markup.underline"] = {
                --     underline = false
                -- },
                -- AerialArrayIcon = {
                --   link = "Type"
                -- },
            }
        end,

        -- when `background` is set, use corresponding theme
        background = { dark = "dragon", light = "lotus" },
        -- when `background` is not set, use default theme
        theme = "dragon",
        compile = false,
    })

    -- Dump the current kanagawa colors
    -- :lua dbg(kanagawa_dump_colors())
    _G.kanagawa_dump_colors = function()
        local config = require("kanagawa").config
        local colors = require("kanagawa.colors").setup({ theme = config.theme, colors = config.colors })
        return colors
    end

    -- Dump the current kanagawa highlights
    -- :lua dbg(kanagawa_dump_highlights())
    _G.kanagawa_dump_highlights = function()
        local config = require("kanagawa").config
        local colors = kanagawa_dump_colors()
        local highlights = require("kanagawa.highlights").setup(colors, config)
        return highlights
    end
end -- kanagawa }}}

-- telescope.nvim - fuzzy picker framework {{{
if pcall(require, "telescope") then
    -- TODO(phlip9): why does require("telescope") fail when nvim is used as a
    --               a man page viewer?

    -- Mappings:
    --          O - open files search (ignoring files in .gitignore)
    --   <space>O - open files search (all files)
    --   <space>/ - grep with pattern
    --   <space>' - grep using word under cursor
    --          T - open buffers search
    -- <space>gcm - search git commits
    -- <space>gcb - search git commits for the current buffer
    -- <space>gcs - search git commits for the current selection
    --  <space>gs - open git status (<Tab> to stage/unstage)
    --  <space>vh - search nvim help
    --  <space>vm - search nvim mappings
    -- <space>man - search man page entries

    local telescope = require("telescope")
    telescope.setup({
        defaults = {
            -- default key mappings for all pickers
            mappings = {
                -- insert mode
                i = {
                    -- Show 'elp in insert mode
                    ["<C-e>"] = function(...)
                        require("telescope.actions").which_key(...)
                    end,

                    -- Cycle through history
                    ["<C-Up>"] = function(...)
                        require("telescope.actions").cycle_history_prev(...)
                    end,
                    ["<C-Down>"] = function(...)
                        require("telescope.actions").cycle_history_next(...)
                    end,
                },
                -- normal mode
                n = {
                    -- Cycle through history
                    ["<C-Up>"] = function(...)
                        require("telescope.actions").cycle_history_prev(...)
                    end,
                    ["<C-Down>"] = function(...)
                        require("telescope.actions").cycle_history_next(...)
                    end,
                }
            },

            vimgrep_arguments = {
                "rg",
                "--color=never", "--no-heading", "--with-filename", "--line-number", "--column",
                "--smart-case", "--hidden", "--follow",
                "--glob=!.git/*", "--glob=!target/*", "--glob=!tags",
            }
        },
        pickers = {
            find_files = {
                -- TODO(phlip9): maybe someday telescope will support fd colors
                -- in the find_files picker
                find_command = {
                    "fd",
                    "--type=file", "--color=never", "--strip-cwd-prefix",
                    "--exclude=.git/*", "--exclude=target/*", "--exclude=tags",
                },
                follow = true,
                hidden = true,
            },
            buffers = {
                -- Sorts all buffers after most recent used.
                sort_mru = true,
                -- Don't display the current buffer in the list.
                ignore_current_buffer = true,
            },
            man_pages = {
                -- search all man sections
                sections = { "ALL" },
                -- Filter out ANSI escape codes from man page preview
                PAGER = { "sed", "-e", "s/\\x1b\\[[0-9;]*m//g" },
                -- PAGER = { "col", "-bx" },
                -- PAGER = { "cat" },
            }
        },
        extensions = {
            coc = {
                -- theme = "ivy",
                -- prefer_locations = true,
            }
        }
    })

    -- telescope-fzf-native - use native impl fzf algorithm to speed up matching
    telescope.load_extension('fzf')

    -- telescope-coc.nvim - telescope x coc.nvim integration
    local coc = telescope.load_extension('coc')
    -- require("telescope._extensions.coc")

    -- builtin telescope commands
    local builtin = require("telescope.builtin")
    -- require("telescope.builtin.__files")

    -- files/grep
    vim.keymap.set("n", "O", builtin.find_files, M.with_desc("search files"))
    vim.keymap.set("n", "<space>O", function() builtin.find_files({ no_ignore = true }) end,
        M.with_desc("find files (no gitignore)"))
    vim.keymap.set("n", "<space>/", builtin.live_grep, M.with_desc("repo grep"))
    vim.keymap.set({ "n", "x" }, "<space>'", builtin.grep_string, M.with_desc("repo grep word under cursor"))

    -- git
    vim.keymap.set("n", "<space>gcm", builtin.git_commits, M.with_desc("search git commits"))
    vim.keymap.set("n", "<space>gcb", builtin.git_bcommits, M.with_desc("search git commits for current file"))
    vim.keymap.set({ "n", "x" }, "<space>gcs", builtin.git_bcommits_range,
        M.with_desc("search git commits for current selection"))
    vim.keymap.set("n", "<space>gs", builtin.git_status, M.with_desc("open git status"))
    vim.keymap.set("n", "<space>gb", builtin.git_branches, M.with_desc("open git branches"))

    -- nvim
    vim.keymap.set("n", "T", builtin.buffers, M.with_desc("search buffers"))
    vim.keymap.set("n", "<space>vh", builtin.help_tags, M.with_desc("search nvim help"))
    vim.keymap.set("n", "<space>vm", builtin.keymaps, M.with_desc("search nvim key mappings"))

    -- man
    vim.keymap.set("n", "<space>man", builtin.man_pages, M.with_desc("search man pages"))

    -- LSP
    local function show_outline()
        -- Use coc.nvim LSP document outline if available
        if vim.g.coc_service_initialized == 1 and vim.fn.CocHasProvider("documentSymbol") then
            return coc.document_symbols({
                -- don't show path in output
                path_display = "hidden",
            })
        end

        -- Use treesitter document outline if available
        local parsers = require("nvim-treesitter.parsers")
        if parsers.has_parser(parsers.get_buf_lang()) then
            return builtin.treesitter({})
        end

        print("No coc.nvim LSP or treesitter parser for outline")
    end

    vim.keymap.set("n", "<space>o", show_outline, M.with_desc("document outline"))
    vim.keymap.set("n", "<space>s", function() coc.workspace_symbols({}) end, M.with_desc("workspace symbols"))
    vim.keymap.set("n", "<space>df", function() coc.diagnostics({}) end, M.with_desc("view file lints/errors"))
    vim.keymap.set("n", "<space>da", function() coc.workspace_diagnostics({}) end, M.with_desc("view all lints/errors"))

    vim.keymap.set("n", "<leader>cm", function() coc.commands({}) end, M.with_desc("LSP commands"))

    -- the theme for the "show at cursor" telescope pickers
    -- increase height and width to fit more items and ensure paths are visible
    local show_at_cursor = require("telescope.themes").get_cursor({
        layout_config = {
            height = 32,
            width = 170,
        }
    })
    -- TODO(phlip9): combine cursor, line, and file code actions in one picker
    -- TODO(phlip9): work in visual select mode
    -- vim.keymap.set({ "n", "x" }, "<leader>a", function() coc.code_actions(show_at_cursor) end, opts)
    vim.keymap.set({ "n", "x" }, "<leader>a", ":CocFzfList actions<cr>", M.with_desc("LSP code actions"))

    -- code navigation

    local function goto_definition()
        -- 1. Use coc.nvim LSP goto def if available
        if vim.g.coc_service_initialized == 1 and vim.fn.CocHasProvider("definition") then
            return coc.definitions(show_at_cursor)
        end

        -- 2. Vim help docs have their own goto def
        local cw = vim.fn.expand("<cword>")
        if vim.fn.index({ "vim", "help" }, vim.bo.filetype) >= 0 then
            return vim.api.nvim_command("help " .. cw)
        end

        -- 3. Else fallback to `keywordprg`
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
        return vim.api.nvim_command(cmd)
    end
    vim.keymap.set("n", "gd", goto_definition, M.with_desc("goto definition"))

    vim.keymap.set("n", "gc", function() coc.declarations(show_at_cursor) end, M.with_desc("goto declaration"))
    vim.keymap.set("n", "gi", function() coc.implementations(show_at_cursor) end, M.with_desc("goto implementations"))
    vim.keymap.set("n", "gt", function() coc.type_definitions(show_at_cursor) end, M.with_desc("goto type definitions"))
    vim.keymap.set("n", "gr", function() coc.references_used(show_at_cursor) end, M.with_desc("goto references"))
end -- }}}

do  -- baleia.nvim - colorize ANSI escape sequences {{{
    vim.api.nvim_create_user_command("AnsiColorize", function()
        require("baleia")
            .setup({
                colors = require("baleia.styles.themes").NR_16,
            })
            .once(vim.api.nvim_get_current_buf())
    end, { bang = true })
end -- baleia.nvim }}}

do  -- vim-gitgutter - Show git diff in the gutter {{{
    -- Mappings:
    -- <leader>ggt - Toggle git gutter
    -- <leader>hd - open git diff split pane for current file
    -- <leader>hs - Stage hunk
    -- <leader>hr - Undo hunk
    -- ]h - Move forward one hunk
    -- [h - Move backward one hunk
    -- <motion>ih - <motion> in hunk
    -- <motion>ah - <motion> around hunk (includes trailing empty lines)

    local repeatable_move = require("nvim-treesitter.textobjects.repeatable_move")

    -- Don't automatically set mappings.
    vim.g.gitgutter_map_keys = false

    vim.keymap.set("n", "<leader>ggt", vim.cmd.GitGutterToggle, M.with_desc("toggle showing git hunks"))
    vim.keymap.set("n", "<leader>hs", vim.cmd.GitGutterStageHunk, M.with_desc("stage git hunk"))
    vim.keymap.set("n", "<leader>hr", vim.cmd.GitGutterUndoHunk, M.with_desc("reset git hunk"))
    vim.keymap.set("n", "<leader>hv", vim.cmd.GitGutterPreviewHunk, M.with_desc("preview git hunk in popup"))
    vim.keymap.set("n", "<leader>hd", vim.cmd.GitGutterDiffOrig, M.with_desc("show full hunk diff in split window"))

    -- Make GitGutter(Next|Prev)Hunk repeatable
    local move_hunk_next, move_hunk_prev = repeatable_move.make_repeatable_move_pair(
        vim.cmd.GitGutterNextHunk,
        vim.cmd.GitGutterPrevHunk
    )
    vim.keymap.set({ "n", "x", "o" }, "]h", M.recenter_after(move_hunk_next), M.with_desc("goto next git hunk"))
    vim.keymap.set({ "n", "x", "o" }, "[h", M.recenter_after(move_hunk_prev), M.with_desc("goto prev git hunk"))

    local opts = { silent = true, remap = false }
    vim.keymap.set("o", "ih", "<Plug>(GitGutterTextObjectInnerPending)", opts)
    vim.keymap.set("o", "ah", "<Plug>(GitGutterTextObjectOuterPending)", opts)
    vim.keymap.set("x", "ih", "<Plug>(GitGutterTextObjectInnerVisual)", opts)
    vim.keymap.set("x", "ah", "<Plug>(GitGutterTextObjectOuterVisual)", opts)
end -- vim-gitgutter }}}

do  -- coc.nvim - Complete engine and Language Server support for neovim {{{
    -- Mappings:
    --         gd  - goto definition
    --         gc  - goto declaration
    --         gi  - goto implementations
    --         gt  - goto type definition
    --         gr  - goto references
    --  <space>df  - view file errors/lints/diagnostics
    --  <space>da  - view all errors/lints/diagnostics
    --  <space>o   - fuzzy search file outline
    --  <space>s   - fuzzy search project symbols
    -- <leader>rn  - rename
    -- <leader>rf  - refactor
    -- <leader>doc - show docs / symbol hover
    -- <leader>a   - code action
    -- <leader>cm  - select an LSP command
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
    --
    -- :CocStop   - disable and stop coc.nvim

    local repeatable_move = require("nvim-treesitter.textobjects.repeatable_move")

    -- local function coc_rpc_ready()
    --     return vim.fn["coc#rpc#ready()"] ~= 0
    -- end

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

    local function check_back_space()
        local col = vim.fn.col(".") - 1
        return col == 0 or vim.fn.getline("."):sub(col, col):match("%s") ~= nil
    end


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

    -- code actions
    vim.keymap.set("n", "<leader>rn", "<Plug>(coc-rename)", M.with_desc("LSP rename symbol"))
    vim.keymap.set("n", "<leader>rf", "<Plug>(coc-refactor)", M.with_desc("LSP refactor symbol"))

    -- Use <leader>doc to show docs for current symbol under cursor.
    vim.keymap.set("n", "<leader>doc", function() vim.fn.CocActionAsync("doHover") end,
        M.with_desc("show symbol documentation"))

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
    local move_diagnostic_next, move_diagnostic_prev = repeatable_move.make_repeatable_move_pair(
        function() return vim.fn.CocActionAsync("diagnosticNext") end,
        function() return vim.fn.CocActionAsync("diagnosticPrevious") end
    )
    vim.keymap.set("n", "]d", M.recenter_after(move_diagnostic_next), M.with_desc("goto next LSP lint/error"))
    vim.keymap.set("n", "[d", M.recenter_after(move_diagnostic_prev), M.with_desc("goto prev LSP lint/error"))

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
    local group = vim.api.nvim_create_augroup("CocGroup", {})
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "CocNvimInit",
        desc = "Coc LSP post-init setup",
        callback = coc_buffer_maybe_init,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group,
        pattern = "*",
        desc = "Coc LSP buffer setup",
        callback = coc_buffer_maybe_init,
    })
    vim.api.nvim_create_autocmd("SourcePost", {
        group = group,
        pattern = "*/nvim/init.lua",
        desc = "Coc LSP post-source setup",
        callback = coc_buffer_maybe_init,
    })

    -- When filling out parameters in a function after autocomplete, this shows the
    -- param docs.
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "CocJumpPlaceholder",
        desc = "Update signature help on jump placeholder",
        callback = function() vim.fn.CocActionAsync("showSignatureHelp") end,
    })

    -- coc-settings.json supports comments
    vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
        group = group,
        pattern = "coc-settings.json",
        command = "set filetype=jsonc",
    })

    -- coc-fzf
    vim.g.coc_fzf_preview = "right:50%"

    -- ft: flutter
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
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

    -- :CocStop
    vim.api.nvim_create_user_command("CocStop", function(opts)
        -- An amalgamation of `:CocDisable` and `coc#rpc#restart()` that *should*
        -- cleanly shutdown coc.nvim.
        vim.cmd([[
            if !coc#rpc#ready()
                echohl MoreMsg | echom '[coc.nvim] already not running' | echohl None
            else
                call coc#highlight#clear_all()
                call coc#ui#sign_unplace()
                call coc#float#close_all()

                autocmd! coc_dynamic_autocmd
                autocmd! coc_dynamic_content
                autocmd! coc_dynamic_option
                autocmd! coc_nvim

                call coc#rpc#request('detach', [])

                if !empty(get(g:, 'coc_status', ''))
                    unlet g:coc_status
                endif
                let g:coc_service_initialized = 0

                sleep 100m

                call coc#rpc#stop()
                let g:coc_enabled = 0

                echohl MoreMsg | echom '[coc.nvim] Stopped' | echohl None
            endif
        ]])
    end, { desc = "Stop coc.nvim" })
end -- coc.nvim }}}

do  -- copilot.vim - Github Copilot {{{
    -- Mappings:
    -- <C-Enter> - Trigger Copilot completion
    vim.g.copilot_no_tab_map = true
    vim.keymap.set("i", "<C-CR>", 'copilot#Accept("\\<CR>")', {
        expr = true,
        replace_keycodes = false,
        remap = false,
        script = true,
    })
end -- copilot.vim }}}

do  -- fzf.vim - fuzzy file matching, grepping, and tag searching using fzf {{{
    vim.g.fzf_command_prefix = "Fzf"
    vim.g.fzf_files_options = { "--ansi" }
end -- fzf.vim }}}

do  -- NERDCommenter - Easily comment lines or blocks of text {{{
    -- Mappings:
    -- <leader>c<space> - Toggle current line comment
    -- <leader>cb - Block comment

    -- disable all default key bindings
    vim.g.NERDCreateDefaultMappings = 0

    -- Add spaces after comment delimiters by default
    vim.g.NERDSpaceDelims = 1

    -- Align line-wise comment delimiters flush left instead of following code indentation
    vim.g.NERDDefaultAlign = "left"

    -- Allow commenting and inverting empty lines (useful when commenting a region)
    vim.g.NERDCommentEmptyLines = 1

    -- custom comment formats
    vim.g.NERDCustomDelimiters = {
        c = { left = "//", leftAlt = "/*", rightAlt = "*/", },
        dart = { left = '//', },
        dtrace = { left = '//', },
    }

    -- key bindings
    vim.keymap.set({ "n", "x" }, "<leader>c<Space>", "<Plug>NERDCommenterToggle", M.with_desc("toggle line comment"))
    vim.keymap.set({ "n", "x" }, "<leader>cb", "<Plug>NERDCommenterMinimal", M.with_desc("toggle block comment"))
end -- NERDCommenter }}}

do  -- SudoEdit.vim - Easily write to protected files {{{
    -- Use `pkexec` on more recent Ubuntu/Debian/Pop!_OS
    if vim.fn.executable("pkexec") then
        vim.g.sudoAuth = "pkexec"
    end
end -- SudoEdit.vim }}}

do  -- vim-airline - Lightweight yet fancy status line {{{
    vim.o.laststatus = 2

    -- enable powerline font symbols
    vim.g.airline_powerline_fonts = 1

    vim.g.airline_symbols = vim.tbl_deep_extend("force", vim.g.airline_symbols or {}, {
        branch = "",
        readonly = "",
        linenr = "",
        maxlinenr = "",
    })

    vim.g.airline_left_sep = ""
    vim.g.airline_left_alt_sep = ""
    vim.g.airline_right_sep = ""
    vim.g.airline_right_alt_sep = ""

    -- airline buffer tab line "
    vim.g["airline#extensions#tabline#enabled"] = 1

    -- straight separators for tabline
    vim.g["airline#extensions#tabline#left_sep"] = ""
    vim.g["airline#extensions#tabline#left_alt_sep"] = "|"

    -- Minimalistic Airline theme with fixed backgrounds for terminal transparency
    vim.g.airline_theme = "crayon3"
end -- vim-airline }}}

do  -- Recover.vim - Show a diff when recovering swp files {{{
    -- Keep swap file
    -- :FinishRecovery
end -- Recover.vim }}}

-- PLUGINS }}}

do -- GENERAL {{{
    -- don't pass messages to |ins-completion-menu|.
    vim.o.shortmess = vim.o.shortmess:append_once("c")
end -- GENERAL }}}

do  -- VISUAL {{{
    -- Show line numbers
    vim.o.number = true
    -- Display the current vim mode
    vim.o.showmode = true
    -- use RGB colors
    vim.o.termguicolors = true
    -- Highlight the 80+1'th column to help keep text under 80 characters per line
    vim.o.colorcolumn = "81"
    -- Always display the sign column to avoid flickering w/ gitgutter
    vim.o.signcolumn = "yes"
    -- show matching delimiters
    vim.o.showmatch = true
    -- -- uber ruler
    -- vim.o.rulerformat = "%30(%=\:b%n%y%m%r%w\ %l,%c%V\ %P%)"

    -- colorscheme
    vim.o.background = "dark"
    vim.cmd("colorscheme kanagawa")
end -- VISUAL }}}

do  -- BEHAVIOR {{{
    -- ignore case by default when searching
    vim.o.ignorecase = true
    -- case sensitive when search includes uppercase characters
    vim.o.smartcase = true
    -- command completion mode
    vim.o.wildmode = "list:longest,full"
    -- don't wrap lines by default
    vim.o.wrap = false
    -- backspace and cursor keys also wrap
    vim.o.whichwrap = "b,s,h,l,<,>,[,]"
    -- lines to scroll when cursor leaves screen
    vim.o.scrolljump = 5
    -- min # of lines to keep below cursor
    vim.o.scrolloff = 3
    -- always use /g on :s substitution
    vim.o.gdefault = true
    -- place yanked text into the clipboard
    vim.o.clipboard = vim.o.clipboard:append_once("unnamedplus")
    -- use nvim built-in man viewer
    vim.o.keywordprg = ":Man"

    -- " Remove trailing whitespaces and ^M chars
    -- autocmd FileType c,cpp,java,php,js,python,twig,xml,yml,vim,nix,dart
    --             \ autocmd BufWritePre <buffer>
    --             \     :call setline(1,map(getline(1,"$"),
    --             \         'substitute(v:val,"\\s\\+$","","")'))

    ---@diagnostic disable-next-line: unused-local
    function _G.MyFoldText(foldstart, foldend, foldlevel)
        local line = vim.api.nvim_buf_get_lines(0, foldstart - 1, foldstart, true)[1]
        return line .. " "
    end

    vim.o.foldtext = "v:lua.MyFoldText(v:foldstart, v:foldend, v:foldlevel)"

    -- custom math digraphs
    -- Directions: type <C-K><digraph-code> to write digraph
    -- Example: <C-K>na => ℕ
    vim.fn.digraph_setlist({
        -- natural numbers
        { "na", "ℕ" },
        -- integers
        { "IN", "ℤ" },
        -- small black right-pointing triangle
        { "tr", "▸" },
        -- vector left bracket
        { "bl", "⟨" },
        -- vector right bracket
        { "br", "⟩" },
        -- french quote left
        { "<<", "‹" },
        -- french quote right
        { ">>", "›" },
        -- forall
        { "fa", "∀" },
        -- there exists
        { "te", "∃" },
        -- not
        { "no", "¬" },
        -- not equal
        { "ne", "≠" },
        -- not in set
        { "ni", "∉" },
        -- in set
        { "in", "∈" },
        -- set union
        { ")U", "∪" },
        -- set intersection
        { "(U", "∩" },
        -- and
        { "an", "∧" },
        -- or
        { "or", "∨" },
        -- multiplication
        { "xx", "×" },
        -- o-plus
        { "op", "⊕" },
        -- superscript minus
        { "s-", "⁻" },
        -- superscript one
        { "s1", "¹" },
        -- divides
        { "di", "∣" },
        -- curly bracket left
        { "cl", "⦃" },
        -- curly bracket right
        { "cl", "⦄" },
        -- equivalence
        { "eq", "≡" },
        -- approx
        { "ap", "≈" },
        -- up arrow
        { "up", "↑" },
        -- sum, sigma (upper)
        { "su", "∑" },
    })
end -- BEHAVIOR }}}

do  -- TAB SETTINGS {{{
    -- spaces not tabs
    vim.o.expandtab = true
    -- 4 spaces per tab
    vim.o.shiftwidth = 4
    -- backspace deletes pseudo-tab
    vim.o.softtabstop = 4
    -- tab characters display as 4 spaces
    vim.o.tabstop = 4
end -- TAB SETTINGS }}}

do  -- KEYBINDINGS {{{
    local opts = { silent = true, remap = false }

    -- Delete `keyworkprg`/man-page keybind
    vim.keymap.set("v", "K", "<Nop>", opts)

    -- map arrow keys to something more useful (indent/unindent)
    vim.keymap.set("n", "<Left>", "<<", opts)
    vim.keymap.set("n", "<Right>", ">>", opts)

    vim.keymap.set("v", "<Left>", "<gv", opts)
    vim.keymap.set("v", "<Right>", ">gv", opts)

    -- up/down adds line above/below
    vim.keymap.set("n", "<Up>", "O<Esc>j", opts)
    vim.keymap.set("n", "<Down>", "o<Esc>k", opts)

    -- replace currently selected text w/o clobbering the yank register
    -- note: "_ is the blackhole register
    vim.keymap.set("v", "<leader>p", "\"_dP", opts)

    -- Reload nvimrc
    vim.keymap.set("n", "<leader>V", ":source $MYVIMRC<CR>:filetype detect<CR>:echo 'nvim config reloaded'<CR>", opts)

    -- remap Visual Block selection to something that doesn't conflict with
    -- system copy/paste
    vim.keymap.set("n", "<leader>v", "<C-v>", opts)

    -- map S-J and S-K to next and prev buffer
    vim.keymap.set("n", "J", ":bp<CR>", opts)
    vim.keymap.set("n", "K", ":bn<CR>", opts)

    -- map S-H and S-L to undo and redo
    vim.keymap.set("n", "H", "u", opts)
    vim.keymap.set("n", "L", "<C-R>", opts)

    -- Window movement w/ CTRL + h,j,k,l
    vim.keymap.set("n", "<C-h>", "<C-w>h", opts)
    vim.keymap.set("n", "<C-j>", "<C-w>j", opts)
    vim.keymap.set("n", "<C-k>", "<C-w>k", opts)
    vim.keymap.set("n", "<C-l>", "<C-w>l", opts)

    -- copy path and copy relative path (yp, yrp)
    local function copy_absolute_path()
        local path = vim.fn.expand("%:p")
        vim.fn.setreg("+", path)
        print("Copied: " .. path)
    end
    local function copy_relative_path()
        local path = vim.fn.expand("%:~:.")
        vim.fn.setreg("+", path)
        print("Copied: " .. path)
    end
    vim.keymap.set("n", "yp", copy_absolute_path, M.with_desc("copy absolute file path"))
    vim.keymap.set("n", "yrp", copy_relative_path, M.with_desc("copy relative file path"))
    vim.api.nvim_create_user_command("CopyPath", copy_absolute_path, { desc = "Copy absolute file path to clipboard" })
    vim.api.nvim_create_user_command("CopyPathRel", copy_relative_path, { desc = "Copy relative file path to clipboard" })

    -- -- re-center screen on C-d, C-u, search next/prev
    -- vim.keymap.set("n", "<C-d>", "<C-d>zz", opts)
    -- vim.keymap.set("n", "<C-u>", "<C-u>zz", opts)
    -- vim.keymap.set("n", "n", "nzzzv", opts)
    -- vim.keymap.set("n", "N", "Nzzzv", opts)

    --
    -- Terminal Mode
    --

    -- Use escape to go back to normal mode
    vim.keymap.set("t", "<Esc>", "<C-\\><C-n>", opts)

    -- Window movement in terminal mode w/ CTRL + h,j,k,l
    vim.keymap.set("t", "<C-h>", "<C-\\><C-n><C-W>h", opts)
    vim.keymap.set("t", "<C-j>", "<C-\\><C-n><C-W>j", opts)
    vim.keymap.set("t", "<C-k>", "<C-\\><C-n><C-W>k", opts)
    vim.keymap.set("t", "<C-l>", "<C-\\><C-n><C-W>l", opts)

    --
    -- "lazy-shift" aliases
    --
    vim.cmd([[
        command! -bar -nargs=* -complete=file -range=% -bang W         <line1>,<line2>write<bang> <args>
        command! -bar -nargs=* -complete=file -range=% -bang Write     <line1>,<line2>write<bang> <args>
        command! -bar -nargs=* -complete=file -range=% -bang Wq        <line1>,<line2>wq<bang> <args>
        command! -bar                                  -bang Wqall     wqa<bang>
        command! -bar -nargs=* -complete=file          -bang E         edit<bang> <args>
        command! -bar -nargs=* -complete=file          -bang Edit      edit<bang> <args>
        command! -bar                                  -bang Q         quit<bang>
        command! -bar                                  -bang Quit      quit<bang>
        command! -bar                                  -bang Qall      qall<bang>
        command! -bar -nargs=? -complete=help                Help      help <args>
        command! -bar                                        Messages  messages
        command! -bar -nargs=+ -complete=file          -bang Source    source<bang> <args>
    ]])
end -- KEYBINDINGS }}}

--  vim: foldmethod=marker
