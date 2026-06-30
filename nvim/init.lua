do -- PRELUDE {{{
    -- enable experimental lua module loader w/ byte-code cache
    vim.loader.enable()

    -- Rebind mapleader to something more accessible.
    vim.g.mapleader = ","

    -- Disable netrw. Its buffers don't close properly with :bd and we
    -- don't use it as a file browser.
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1

    -- Track the "generation" number for sourcing `init.lua`.
    -- Used to ensure re-sourcing will re-run "one-time" init in various places.
    if _G.my_init_generation == nil then
        _G.my_init_generation = 0
    else
        _G.my_init_generation = _G.my_init_generation + 1
    end

    ---require() for local lua modules. It marks the imported module so it is
    ---automatically reloaded when we re-source `nvim/init.lua`.
    ---@param name string
    ---@return table
    function _G.require_local(name)
        local module = require(name)
        rawset(module, "_is_local_module", true)
        return module
    end

    -- `string` extension methods
    require_local("util.stringext")
end -- PRELUDE }}}

-- PLUGINS {{{

-- functions visible in whole init.lua go here
local M = {}

do -- lua utils {{{
    -- Pretty-print any lua value and display it in a temp buffer
    function _G.dbg(...)
        return require_local("util").dbg(...)
    end

    -- Pretty-print all loaded lua packages in a temp buffer
    function _G.print_loaded_packages(...)
        return require_local("util").print_loaded_packages(...)
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
        callback = function(opts) require_local("helpsplit").on_buf_new(opts) end,
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
            -- Disable for markdown: tree-sitter's indentexpr interferes with
            -- gw/gq list continuation formatting. Vim's built-in formatter
            -- uses autoindent+formatlistpat to indent continuation lines, but
            -- when indentexpr is set, this is bypassed.
            -- <https://github.com/nvim-treesitter/nvim-treesitter/issues/7541>
            -- <https://github.com/LazyVim/LazyVim/discussions/2916>
            disable = { "markdown" },
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
                    ["acl"] = "@class.outer",
                    ["icl"] = "@class.inner",
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
                    ["]cl"] = { query = "@class.outer", desc = "goto next class start" },
                    ["]p"] = { query = "@parameter.outer", desc = "goto next parameter start" },
                    ["]i"] = { query = "@call.outer", desc = "goto next function invocation start" },
                    ["]s"] = { query = "@local.scope", query_group = "locals", desc = "goto next scope start" },
                },
                goto_next_end = {
                    ["]F"] = { query = "@function.outer", desc = "goto next function end" },
                    ["]Cl"] = { query = "@class.outer", desc = "goto next class end" },
                    ["]P"] = { query = "@parameter.outer", desc = "goto next parameter end" },
                    ["]I"] = { query = "@call.outer", desc = "goto next function invocation end" },
                    ["]S"] = { query = "@local.scope", query_group = "locals", desc = "goto next scope end" },
                },
                goto_previous_start = {
                    ["[f"] = { query = "@function.outer", desc = "goto prev function start" },
                    ["[cl"] = { query = "@class.outer", desc = "goto prev class start" },
                    ["[p"] = { query = "@parameter.outer", desc = "goto prev parameter start" },
                    ["[i"] = { query = "@call.outer", desc = "goto prev function invocation start" },
                    ["[s"] = { query = "@local.scope", query_group = "locals", desc = "goto prev scope start" },
                },
                goto_previous_end = {
                    ["[F"] = { query = "@function.outer", desc = "goto prev function end" },
                    ["[Cl"] = { query = "@class.outer", desc = "goto prev class end" },
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
                    [">cl"] = { query = "@class.outer", desc = "swap w/ next class" },
                    [">p"] = { query = "@parameter.inner", desc = "swap w/ next parameter" },
                },
                swap_previous = {
                    ["<f"] = { query = "@function.outer", desc = "swap w/ prev function" },
                    ["<cl"] = { query = "@class.outer", desc = "swap w/ prev class" },
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
    local opts = { silent = true, remap = false, expr = true }
    vim.keymap.set({ "n", "x", "o" }, "f", repeatable_move.builtin_f_expr, opts)
    vim.keymap.set({ "n", "x", "o" }, "F", repeatable_move.builtin_F_expr, opts)
    vim.keymap.set({ "n", "x", "o" }, "t", repeatable_move.builtin_t_expr, opts)
    vim.keymap.set({ "n", "x", "o" }, "T", repeatable_move.builtin_T_expr, opts)

    -- Toggle treesitter syntax-based folding
    local function toggle_treesitter_fold()
        local buf = vim.api.nvim_get_current_buf()

        if not vim.b[buf].prev_fold_state then
            -- enable and save current state
            ---@diagnostic disable: undefined-field
            vim.b[buf].prev_fold_state = {
                foldmethod = vim.opt_local.foldmethod:get(),
                foldexpr = vim.opt_local.foldexpr:get(),
            }
            ---@diagnostic enable: undefined-field

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
    local opts = { silent = true, remap = false }
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
    -- TODO(phlip9): re-enable after vgit transition
    -- vim.keymap.set("n", "O", function()
    --     require_local("telescope_git_file_status").find_files({})
    -- end, M.with_desc("search files"))
    -- vim.keymap.set("n", "<space>O", function()
    --         require_local("telescope_git_file_status").find_files({
    --             no_ignore = true,
    --         })
    --     end,
    --     M.with_desc("find files (no gitignore)"))
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
    -- TODO(phlip9): re-enable after vgit transition
    -- vim.keymap.set("n", "T", function()
    --     require_local("telescope_git_file_status").buffers({})
    -- end, M.with_desc("search buffers"))
    vim.keymap.set("n", "T", builtin.buffers, M.with_desc("search buffers"))
    vim.keymap.set("n", "<space>vh", builtin.help_tags, M.with_desc("search nvim help"))
    vim.keymap.set("n", "<space>vm", builtin.keymaps, M.with_desc("search nvim key mappings"))

    -- man
    vim.keymap.set("n", "<space>man", builtin.man_pages, M.with_desc("search man pages"))

    -- LSP
    local function show_outline()
        -- TODO(phlip9): re-enable after vgit transition
        -- local diff_outline = require_local("telescope_diff_outline")

        -- Use coc.nvim LSP document outline if available
        if vim.g.coc_service_initialized == 1 and vim.fn.CocHasProvider("documentSymbol") then
            -- return diff_outline.coc_document_symbols({
            return coc.document_symbols({
                -- don't show path in outline
                path_display = "hidden",
            })
        end

        -- Use treesitter document outline if available
        local parsers = require("nvim-treesitter.parsers")
        if parsers.has_parser(parsers.get_buf_lang()) then
            -- return diff_outline.treesitter_symbols({})
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

do  -- vgit.nvim - visual git plugin for neovim {{{
    local vgit = require("vgit")

    -- Helper functions defined in a table for better organization
    local helpers = {}

    -- Track the window and buffer we came from before opening vgit preview
    local prev_window = nil
    local prev_buffer = nil
    local prev_cursor_pos = nil -- Track cursor position {line, col}

    -- Configuration flags
    -- TODO(max): Remove this later if there are no gutter issues for a while
    local enable_gutter_refresh = false -- Toggle gutter refresh on exit

    -- Track timers for cleanup to prevent leaks
    local pending_timers = {}
    local cursor_restore_timer = nil

    -- Helper to cancel all pending timers and clear the list
    local function cancel_pending_timers()
        for _, timer in ipairs(pending_timers) do
            if timer and not timer:is_closing() then
                timer:stop()
                timer:close()
            end
        end
        pending_timers = {}
        -- Don't cancel cursor_restore_timer - that needs to complete
    end

    -- Wrapper around vim.defer_fn that tracks timers for cleanup
    local function defer_fn_tracked(fn, ms)
        local timer = vim.loop.new_timer()
        if timer == nil then
            return
        end

        table.insert(pending_timers, timer)

        timer:start(ms, 0, function()
            vim.schedule(function()
                -- Remove this timer from pending list when it fires
                for i, t in ipairs(pending_timers) do
                    if t == timer then
                        table.remove(pending_timers, i)
                        break
                    end
                end

                fn()

                if not timer:is_closing() then
                    timer:close()
                end
            end)
        end)
    end

    -- Check if file is untracked
    helpers.is_untracked = function(filepath)
        local relative = vim.fn.fnamemodify(filepath, ':.')
        return vim.fn.system('git ls-files --others --exclude-standard ' ..
            vim.fn.shellescape(relative)):match('%S') ~= nil
    end

    -- Helper to restore syntax highlighting if lost
    helpers.restore_syntax_if_needed = function(bufnr)
        -- Skip during search/command mode to avoid interfering with search
        -- highlights
        local mode = vim.fn.mode()
        if mode:match('[/?]') or mode == 'c' then
            return
        end

        -- Only check normal file buffers
        local buftype = vim.bo[bufnr].buftype
        if buftype ~= '' then
            return
        end

        local filetype = vim.bo[bufnr].filetype
        local syntax = vim.bo[bufnr].syntax
        local filename = vim.api.nvim_buf_get_name(bufnr)

        -- If we have a real file but no filetype, something went wrong
        if filename == '' or vim.fn.filereadable(filename) ~= 1 then
            return
        end

        if filetype == '' then
            -- Re-detect filetype
            vim.cmd('silent! doautocmd BufRead ' ..
                vim.fn.fnameescape(filename))

            -- If still no filetype, try filetype detect
            if vim.bo[bufnr].filetype == '' then
                vim.cmd('silent! filetype detect')
            end
        end

        -- Always re-enable syntax when returning from vgit
        -- Even if syntax option is set, highlighting may not be active
        if vim.bo[bufnr].filetype ~= '' then
            local ft = vim.bo[bufnr].filetype
            -- Force reload syntax by resetting and re-applying filetype
            vim.bo[bufnr].syntax = ''
            vim.bo[bufnr].syntax = ft
            vim.cmd('silent! syntax on')
        end
    end

    -- Helper to save current window and buffer before opening vgit preview
    helpers.save_window = function()
        prev_window = vim.api.nvim_get_current_win()
        prev_buffer = vim.api.nvim_get_current_buf()
        prev_cursor_pos = vim.api.nvim_win_get_cursor(0) -- {line, col}
    end

    -- Helper to restore cursor position for untracked files after opening diff
    helpers.restore_cursor_for_untracked = function(saved_pos)
        if cursor_restore_timer and not cursor_restore_timer:is_closing() then
            cursor_restore_timer:stop()
            cursor_restore_timer:close()
        end
        cursor_restore_timer = vim.loop.new_timer()
        if cursor_restore_timer == nil then
            return
        end
        cursor_restore_timer:start(200, 0, function()
            vim.schedule(function()
                pcall(vim.api.nvim_win_set_cursor, 0, saved_pos)
                vim.cmd('normal! zz')
                if not cursor_restore_timer:is_closing() then
                    cursor_restore_timer:close()
                end
            end)
        end)
    end

    -- Helper to restore previous window and buffer after closing vgit preview
    helpers.restore_window = function()
        -- Cancel cursor restore timer if it's still pending
        if cursor_restore_timer and not cursor_restore_timer:is_closing() then
            cursor_restore_timer:stop()
            cursor_restore_timer:close()
            cursor_restore_timer = nil
        end

        if prev_window and vim.api.nvim_win_is_valid(prev_window) then
            vim.api.nvim_set_current_win(prev_window)

            -- Choose up to 1 of the following behaviors when quitting staging view:

            -- Option 1: Restore original buffer (uncomment to enable)
            -- if prev_buffer and vim.api.nvim_buf_is_valid(prev_buffer) then
            --   vim.api.nvim_win_set_buf(prev_window, prev_buffer)
            -- end

            -- Option 2: Navigate to next hunk (uncomment to enable)
            -- pcall(function()
            --   vgit.hunk_down()
            -- end)

            -- Option 3: Smart behavior based on remaining hunks
            -- (currently active)
            local current_file = vim.fn.expand('%:p')
            local is_untracked = helpers.is_untracked(current_file)

            -- Check if file has unstaged hunks
            local diff_output = vim.fn.systemlist(
                'git diff -U0 ' .. vim.fn.shellescape(current_file))
            local has_hunks = false
            for _, line in ipairs(diff_output) do
                if line:match('^@@') then
                    has_hunks = true
                    break
                end
            end

            if has_hunks or is_untracked then
                -- File still has hunks or is untracked - restore cursor position
                if prev_cursor_pos then
                    pcall(vim.api.nvim_win_set_cursor, 0, prev_cursor_pos)
                    vim.cmd('normal! zz')
                end
            else
                -- No hunks left in file - jump to next file with hunks
                pcall(function()
                    helpers.jump_to_next_unstaged_hunk()
                    -- Restore syntax for the new file we jumped to
                    defer_fn_tracked(function()
                        local new_bufnr = vim.api.nvim_get_current_buf()
                        if vim.api.nvim_buf_is_valid(new_bufnr) then
                            helpers.restore_syntax_if_needed(new_bufnr)
                        end
                    end, 100)
                end)
            end

            prev_window = nil
            prev_buffer = nil
            prev_cursor_pos = nil

            -- Show count of remaining unstaged and untracked files
            local unstaged_count = #vim.fn.systemlist('git diff --name-only')
            local untracked_count = #vim.fn.systemlist(
                'git ls-files --others --exclude-standard')
            local total_count = unstaged_count + untracked_count

            if total_count > 0 then
                local parts = {}
                if unstaged_count > 0 then
                    table.insert(parts, string.format('%d unstaged', unstaged_count))
                end
                if untracked_count > 0 then
                    table.insert(parts, string.format('%d untracked', untracked_count))
                end
                print(string.format('%d file%s remaining (%s)',
                    total_count,
                    total_count == 1 and '' or 's',
                    table.concat(parts, ', ')))
            else
                print('All files staged!')
            end

            -- Refresh quickfix list if it's open
            local qf_winid = vim.fn.getqflist({ winid = 0 }).winid
            if qf_winid ~= 0 then
                require("git_hunks").populate_quickfix(false) -- don't log status
            end
        end
    end

    -- Open diff staging view for first unstaged file
    helpers.open_first_unstaged_diff = function()
        -- Get first file with unstaged changes
        local unstaged_files = vim.fn.systemlist('git diff --name-only')
        if #unstaged_files > 0 then
            -- Save window BEFORE opening the file
            helpers.save_window()
            local first_file = unstaged_files[1]
            -- Open the file
            vim.cmd('edit ' .. vim.fn.fnameescape(first_file))
            -- Open diff preview
            vgit.buffer_diff_preview()
        else
            print('No unstaged changes found')
        end
    end

    -- Jump to unstaged hunk with direction (next/prev)
    helpers.jump_to_unstaged_hunk = function(direction)
        -- Validate direction parameter
        if direction ~= 'next' and direction ~= 'prev' then
            print(string.format(
                "Invalid direction '%s'. Must be 'next' or 'prev'", direction))
            return
        end

        -- Get current file and cursor position
        local current_file = vim.fn.expand('%:p')
        local current_line = vim.fn.line('.')

        -- Get git root to convert relative paths to absolute
        local git_root_output = vim.fn.systemlist(
            'git rev-parse --show-toplevel')
        local git_root = git_root_output[1]
        if not git_root or vim.v.shell_error ~= 0 then
            print('Error: Not in a git repository')
            return
        end

        -- Get all files with unstaged changes and untracked files
        local unstaged_files = vim.fn.systemlist('git diff --name-only')
        local untracked_files = vim.fn.systemlist(
            'git ls-files --others --exclude-standard')

        if #unstaged_files == 0 and #untracked_files == 0 then
            print('No unstaged changes or untracked files found')
            return
        end

        -- Build list of all hunks across all files
        local all_hunks = {}

        -- Add hunks from unstaged files
        for _, file in ipairs(unstaged_files) do
            local diff_output = vim.fn.systemlist(
                'git diff -U0 ' .. vim.fn.shellescape(file)
            )

            for _, line in ipairs(diff_output) do
                -- Parse unified diff header:
                -- @@ -old_start,old_count +new_start,new_count @@
                local new_start, new_count = line:match('^@@.*%+(%d+),?(%d*)')
                if new_start then
                    local start_line = tonumber(new_start)
                    local count = tonumber(new_count) or 1
                    -- For zero-line hunks (pure deletions),
                    -- end_line should equal start_line
                    local end_line = start_line + math.max(0, count - 1)

                    table.insert(all_hunks, {
                        file = file,
                        -- Store absolute path for consistent comparison
                        absolute_file = vim.fn.fnamemodify(
                            git_root .. '/' .. file, ':p'
                        ),
                        start_line = start_line,
                        end_line = end_line,
                        is_untracked = false
                    })
                end
            end
        end

        -- Add untracked files (entire file is a "hunk")
        for _, file in ipairs(untracked_files) do
            table.insert(all_hunks, {
                file = file,
                absolute_file = vim.fn.fnamemodify(git_root .. '/' .. file, ':p'),
                start_line = 1,
                end_line = 1,
                is_untracked = true
            })
        end

        if #all_hunks == 0 then
            print('No hunks found')
            return
        end

        -- Find if we're currently in a hunk
        local current_hunk_index = nil
        local absolute_current_file = vim.fn.fnamemodify(current_file, ':p')

        for i, hunk in ipairs(all_hunks) do
            if hunk.absolute_file == absolute_current_file then
                -- Special case: deletion at beginning of file (start_line = 0)
                -- Consider user "in" this hunk if at line 1
                if hunk.start_line == 0 and current_line == 1 then
                    current_hunk_index = i
                    break
                    -- Normal case: check if line is within hunk range
                elseif current_line >= hunk.start_line and
                    current_line <= hunk.end_line then
                    current_hunk_index = i
                    break
                end
            end
        end

        -- Determine which hunk to jump to
        local target_hunk
        local action_description

        if current_hunk_index then
            -- We're inside a hunk, jump with wraparound
            if direction == 'next' then
                -- Jump to the next hunk (with wraparound)
                -- Note: Lua arrays are 1-indexed, so (index % count) + 1 ensures
                -- we get 1..n, never 0
                local next_index = (current_hunk_index % #all_hunks) + 1
                target_hunk = all_hunks[next_index]
                action_description = 'next'
            elseif direction == 'prev' then
                -- Jump to the previous hunk (with wraparound)
                local prev_index = current_hunk_index - 1
                if prev_index < 1 then
                    prev_index = #all_hunks
                end
                target_hunk = all_hunks[prev_index]
                action_description = 'previous'
            end
        else
            -- Not inside a hunk - check if we're between hunks in
            -- current file

            -- Find all hunks in current file
            local hunks_in_current_file = {}
            for i, hunk in ipairs(all_hunks) do
                if hunk.absolute_file == absolute_current_file then
                    table.insert(hunks_in_current_file, i)
                end
            end

            if #hunks_in_current_file > 0 then
                -- We're in a file with hunks but between them
                local found_index = nil

                if direction == 'next' then
                    -- Find first hunk after current line
                    for _, idx in ipairs(hunks_in_current_file) do
                        if all_hunks[idx].start_line > current_line then
                            found_index = idx
                            break
                        end
                    end

                    if found_index then
                        -- Found a hunk after cursor in same file
                        target_hunk = all_hunks[found_index]
                        action_description = 'next'
                    else
                        -- After all hunks in file, wrap to next file
                        local last_idx = hunks_in_current_file[
                        #hunks_in_current_file]
                        local next_idx = (last_idx % #all_hunks) + 1
                        target_hunk = all_hunks[next_idx]
                        action_description = 'next'
                    end
                elseif direction == 'prev' then
                    -- Find last hunk before current line
                    for i = #hunks_in_current_file, 1, -1 do
                        local idx = hunks_in_current_file[i]
                        if all_hunks[idx].end_line < current_line then
                            found_index = idx
                            break
                        end
                    end

                    if found_index then
                        -- Found a hunk before cursor in same file
                        target_hunk = all_hunks[found_index]
                        action_description = 'previous'
                    else
                        -- Before all hunks in file, wrap to previous file
                        local first_idx = hunks_in_current_file[1]
                        local prev_idx = first_idx - 1
                        if prev_idx < 1 then
                            prev_idx = #all_hunks
                        end
                        target_hunk = all_hunks[prev_idx]
                        action_description = 'previous'
                    end
                end
            else
                -- We're in a file without any hunks
                -- Find the next/previous file alphabetically with hunks

                -- Get unique files from all_hunks
                -- (already in git's alphabetical order)
                local files_with_hunks = {}
                local seen_files = {}
                for _, hunk in ipairs(all_hunks) do
                    if not seen_files[hunk.file] then
                        table.insert(files_with_hunks, hunk.file)
                        seen_files[hunk.file] = true
                    end
                end

                -- Get current file's relative path for comparison
                local escaped_root = vim.fn.escape(git_root, '/\\')
                local pattern = '^' .. escaped_root .. '/?'
                local current_file_relative = vim.fn.fnamemodify(
                    current_file:gsub(pattern, ''), ':.'
                )

                if direction == 'next' then
                    -- Find first file alphabetically after current file
                    local next_file = nil
                    for _, file in ipairs(files_with_hunks) do
                        if file > current_file_relative then
                            next_file = file
                            break
                        end
                    end

                    if next_file then
                        -- Jump to first hunk in the next file alphabetically
                        for i, hunk in ipairs(all_hunks) do
                            if hunk.file == next_file then
                                target_hunk = all_hunks[i]
                                action_description = 'next file'
                                break
                            end
                        end
                    else
                        -- No files after current, wrap to first file
                        target_hunk = all_hunks[1]
                        action_description = 'first file'
                    end
                elseif direction == 'prev' then
                    -- Find last file alphabetically before current file
                    local prev_file = nil
                    for i = #files_with_hunks, 1, -1 do
                        local file = files_with_hunks[i]
                        if file < current_file_relative then
                            prev_file = file
                            break
                        end
                    end

                    if prev_file then
                        -- Jump to last hunk in the previous file alphabetically
                        local last_hunk_in_prev_file = nil
                        for i = #all_hunks, 1, -1 do
                            if all_hunks[i].file == prev_file then
                                last_hunk_in_prev_file = all_hunks[i]
                                target_hunk = last_hunk_in_prev_file
                                action_description = 'previous file'
                                break
                            end
                        end
                    else
                        -- No files before current, wrap to last file's last hunk
                        target_hunk = all_hunks[#all_hunks]
                        action_description = 'last file'
                    end
                end
            end
        end

        -- Jump to the target hunk
        if target_hunk.absolute_file ~= absolute_current_file then
            vim.cmd('edit ' .. vim.fn.fnameescape(target_hunk.absolute_file))
        end
        vim.cmd('normal! ' .. target_hunk.start_line .. 'Gzz')

        -- Update quickfix list highlighting if it's open
        local qf_winid = vim.fn.getqflist({ winid = 0 }).winid
        if qf_winid ~= 0 then
            -- Get the current quickfix list (don't refresh)
            local qf_list = vim.fn.getqflist()

            -- Find the matching quickfix entry to highlight
            for i, item in ipairs(qf_list) do
                -- Get the filename from quickfix entry
                -- It might be stored as filename or via bufnr
                local qf_file
                if item.bufnr and item.bufnr > 0 then
                    qf_file = vim.fn.fnamemodify(
                        vim.fn.bufname(item.bufnr), ':p')
                elseif item.filename then
                    qf_file = vim.fn.fnamemodify(item.filename, ':p')
                end

                -- Check if this entry matches our target hunk
                if qf_file and qf_file == target_hunk.absolute_file and
                    item.lnum == target_hunk.start_line then
                    -- Set the quickfix index to highlight this entry
                    vim.fn.setqflist({}, 'r', { idx = i })
                    break
                end
            end
        end

        -- Report what we did
        -- Use relative file name for cleaner output
        local file_status = target_hunk.is_untracked and 'untracked file' or 'hunk'
        print(string.format('Jumped to %s %s: %s:%d',
            action_description, file_status, target_hunk.file,
            target_hunk.start_line))
    end

    -- Jump to next unstaged hunk (or first if not in a hunk)
    helpers.jump_to_next_unstaged_hunk = function()
        helpers.jump_to_unstaged_hunk('next')
    end

    -- Jump to previous unstaged hunk (or last if not in a hunk)
    helpers.jump_to_prev_unstaged_hunk = function()
        helpers.jump_to_unstaged_hunk('prev')
    end

    -- Open diff preview, jumping to next hunk first if current file has none
    helpers.open_diff_with_jump = function()
        local git_hunks = require("git_hunks")

        -- Check if there are any hunks at all
        local all_hunks = git_hunks.get_all_hunks()
        if #all_hunks == 0 then
            print('No unstaged changes or untracked files found')
            return
        end

        local current_file = vim.fn.expand('%:p')

        -- If current file has no hunks, jump to next file with hunks
        if not git_hunks.has_hunks(current_file) then
            helpers.jump_to_next_unstaged_hunk()
        end

        -- Save window state and open diff preview
        local is_untracked = helpers.is_untracked(vim.fn.expand('%:p'))
        local saved_pos = vim.api.nvim_win_get_cursor(0)
        helpers.save_window()
        vgit.buffer_diff_preview()
        if is_untracked then
            helpers.restore_cursor_for_untracked(saved_pos)
        end
    end

    vgit.setup({
        -- Set below
        keymaps = {},

        settings = {
            -- General settings
            git = {
                cmd = 'git', -- Use system git
                fallback_cwd = vim.fn.getcwd(),
                fallback_args = {
                    '--no-pager',
                    '--literal-pathspecs',
                    '-c', 'gc.auto=0',
                },
            },

            -- Live gutter signs for changes
            live_gutter = {
                enabled = true,
                edge_navigation = false, -- Jump between hunks, not edges
            },

            -- Live blame annotations
            live_blame = {
                enabled = false, -- Toggle with <LocalLeader>gB
                format = function(blame, git_config)
                    local config_author = git_config['user.name']
                    local author = blame.author
                    if config_author == author then
                        author = 'You'
                    end

                    if not blame.committed then
                        author = 'You'
                        return string.format(' %s • Uncommitted changes', author)
                    end

                    local time = os.difftime(os.time(), blame.author_time)
                        / (60 * 60 * 24)
                    local time_str = string.format('%d days ago', math.floor(time))
                    if time < 1 then
                        time_str = 'today'
                    elseif time < 2 then
                        time_str = 'yesterday'
                    elseif time > 365 then
                        time_str = string.format('%d years ago', math.floor(time / 365))
                    elseif time > 30 then
                        time_str = string.format('%d months ago', math.floor(time / 30))
                    end

                    local commit_message = blame.commit_message
                    local max_commit_message_length = 60
                    if #commit_message > max_commit_message_length then
                        commit_message = commit_message:sub(1, max_commit_message_length)
                            .. '...'
                    end

                    return string.format(' %s, %s • %s', author, time_str,
                        commit_message)
                end,
            },

            -- Scene settings
            scene = {
                diff_preference = 'split', -- Prefer split view over unified
                keymaps = {
                    quit = 'q'
                }
            },

            -- Diff preview settings
            -- Note: keymaps must use { key, desc } format (changed in vgit v1.0.x)
            diff_preview = {
                keymaps = vim.tbl_extend('force', {
                        reset = { key = 'R', desc = 'Reset' },
                        buffer_stage = { key = 'S', desc = 'Stage' },
                        buffer_unstage = { key = 'U', desc = 'Unstage' },
                        buffer_hunk_stage = { key = 's', desc = 'Stage hunk' },
                        buffer_hunk_unstage = { key = 'u', desc = 'Unstage hunk' },
                        buffer_hunk_reset = { key = 'r', desc = 'Reset hunk' },
                        -- (v)iew: Changed from 't' to avoid DVORAK conflict
                        toggle_view = { key = 'v', desc = 'Toggle view' },
                        -- Navigate between hunks in diff preview
                        -- Note: These don't work as scene-specific keymaps
                        -- Use global <S-Up>/<S-Down> instead
                        -- previous_hunk = '<Up>',
                        -- next_hunk = '<Down>',
                    },
                    {}
                ),
            },

            -- Project diff preview settings
            project_diff_preview = {
                hunk_alignment = 'center', -- 'top', 'center', or 'bottom'
                keymaps = {
                    stage_hunk = { key = 's', desc = 'Stage hunk' },
                    unstage_hunk = { key = 'u', desc = 'Unstage hunk' },
                    reset_hunk = { key = 'r', desc = 'Reset hunk' },
                    stage_file = { key = 'S', desc = 'Stage file' },
                    unstage_file = { key = 'U', desc = 'Unstage file' },
                    reset_file = { key = 'R', desc = 'Reset file' },
                    next = { key = ';', desc = 'Next' },
                    previous = { key = '+', desc = 'Previous' },
                    jump_section_next = { key = ']H', desc = 'Next section' },
                    jump_section_prev = { key = '[H', desc = 'Previous section' },
                },
            },

            -- Project commits preview settings
            project_commits_preview = {
                keymaps = {
                    next = { key = 'j', desc = 'Next' },
                    previous = { key = 'k', desc = 'Previous' },
                },
            },

            -- Project review by file settings
            project_review_by_file = {
                keymaps = {
                    toggle_focus = { key = '<Tab>', desc = 'Switch focus between file list and diff preview' },
                    mark_hunk = { key = 's', desc = 'Mark hunk seen' },
                    mark_file = { key = 'S', desc = 'Mark file seen' },
                    unmark_hunk = { key = 'u', desc = 'Unmark hunk' },
                    unmark_file = { key = 'U', desc = 'Unmark file' },
                    reset = { key = 'R', desc = 'Reset all marks' },
                    next = { key = ';', desc = 'Next' },
                    previous = { key = '+', desc = 'Previous' },
                    jump_section_next = { key = ']H', desc = 'Next section' },
                    jump_section_prev = { key = '[H', desc = 'Previous section' },
                },
            },

            -- Project review by commit settings
            project_review_by_commit = {
                list_position = 'left',
                keymaps = {
                    toggle_focus = { key = '<Tab>', desc = 'Switch focus between file list and diff preview' },
                    mark_hunk = { key = 's', desc = 'Mark hunk seen' },
                    mark_file = { key = 'S', desc = 'Mark file seen' },
                    unmark_hunk = { key = 'u', desc = 'Unmark hunk' },
                    unmark_file = { key = 'U', desc = 'Unmark file' },
                    reset = { key = 'R', desc = 'Reset all marks' },
                    next = { key = ';', desc = 'Next' },
                    previous = { key = '+', desc = 'Previous' },
                    jump_section_next = { key = ']H', desc = 'Next section' },
                    jump_section_prev = { key = '[H', desc = 'Previous section' },
                },
            },

            -- -- Visual settings inspired by delta configuration
            -- hls = {
            --     -- File paths and decorations
            --     GitTitle = 'Title',
            --     GitHeader = 'DiffText',
            --     GitFooter = 'Normal',
            --     GitBorder = 'LineNr',
            --     GitLineNr = 'LineNr',
            --     GitComment = 'Comment',
            --
            --     -- Signs for changes (inspired by delta colors)
            --     GitSignsAdd = {
            --         fg = '#479B36', -- Green from delta config
            --         bg = nil,
            --     },
            --     GitSignsChange = {
            --         fg = '#D79921', -- Yellow from gruvbox theme
            --         bg = nil,
            --     },
            --     GitSignsDelete = {
            --         fg = '#A02A11', -- Red from delta config
            --         bg = nil,
            --     },
            --
            --     -- Diff highlighting (inspired by delta's gruvbox-dark theme)
            --     GitSignsAddLn = {
            --         bg = '#001a00', -- Dark green background
            --     },
            --     GitSignsDeleteLn = {
            --         bg = '#330011', -- Dark red background
            --     },
            --     GitWordAdd = {
            --         bg = '#003300', -- Dark green from delta config
            --     },
            --     GitWordDelete = {
            --         bg = '#80002a', -- Dark red from delta config
            --     },
            -- },

            -- Signs configuration
            signs = {
                priority = 10,
                definitions = {
                    GitSignsAdd = {
                        texthl = 'GitSignsAdd',
                        text = '+',
                    },
                    GitSignsDelete = {
                        texthl = 'GitSignsDelete',
                        text = '-',
                    },
                    GitSignsChange = {
                        texthl = 'GitSignsChange',
                        text = '~',
                    },
                },
            },

            -- Symbols configuration
            symbols = {
                void = ' ', -- Remove dots filler in empty lines
            },
        }
    })

    --- vgit keymaps ---

    vim.keymap.set("n", "<leader>ggt", vgit.toggle_live_gutter, M.with_desc("toggle showing git hunks"))
    vim.keymap.set("n", "<leader>gp", vgit.project_diff_preview, M.with_desc("project git diff preview"))
    vim.keymap.set("n", "<leader>gq", function() require("git_hunks").populate_quickfix(true) end,
        M.with_desc("fill quickfix with unstaged hunks"))
    vim.keymap.set("n", "<leader>gx", vgit.toggle_diff_preference, M.with_desc("toggle git unified/split diff"))
    -- vim.keymap.set("n", "<leader>gb", vgit.buffer_blame_preview, M.with_desc("open git blame preview"))
    -- vim.keymap.set("n", "<leader>gl", vgit.buffer_history_preview, M.with_desc("open git log preview for file"))
    -- vim.keymap.set("n", "<leader>gL", vgit.project_logs_preview, M.with_desc("open git log preview"))

    vim.keymap.set("n", "<leader>gcr", vgit.project_review_by_commit, M.with_desc("git review by commit"))
    vim.keymap.set("n", "<leader>gpr", vgit.project_review_by_file, M.with_desc("git review by file"))

    vim.keymap.set("n", "<leader>hs", vgit.buffer_hunk_stage, M.with_desc("git stage hunk"))
    vim.keymap.set("n", "<leader>hS", vgit.buffer_stage, M.with_desc("git stage file"))
    vim.keymap.set("n", "<leader>hu", vgit.buffer_hunk_reset, M.with_desc("git unstage hunk"))
    vim.keymap.set("n", "<leader>hU", vgit.buffer_unstage, M.with_desc("git unstage file"))
    vim.keymap.set("n", "<leader>hr", vgit.buffer_hunk_reset, M.with_desc("git reset hunk"))
    vim.keymap.set("n", "<leader>hR", vgit.buffer_reset, M.with_desc("git reset file"))

    vim.keymap.set("n", "<leader>hv", function()
        helpers.save_window()
        vgit.buffer_hunk_preview()
    end, M.with_desc("git hunk preview"))

    vim.keymap.set("n", "<leader>hd", helpers.open_diff_with_jump, M.with_desc("git diff preview of current buffer"))
    -- vim.keymap.set("n", "<leader>hd", function()
    --     require_local("gitgutter_difforig").toggle()
    -- end, M.with_desc("toggle full hunk diff in split window"))

    -- local opts = { silent = true, remap = false }
    -- vim.keymap.set("o", "ih", "<Plug>(GitGutterTextObjectInnerPending)", opts)
    -- vim.keymap.set("o", "ah", "<Plug>(GitGutterTextObjectOuterPending)", opts)
    -- vim.keymap.set("x", "ih", "<Plug>(GitGutterTextObjectInnerVisual)", opts)
    -- vim.keymap.set("x", "ah", "<Plug>(GitGutterTextObjectOuterVisual)", opts)

    local repeatable_move = require("nvim-treesitter.textobjects.repeatable_move")

    -- Make (Next|Prev)Hunk repeatable
    local move_hunk_next, move_hunk_prev = repeatable_move.make_repeatable_move_pair(
        vgit.hunk_down,
        vgit.hunk_up
    )
    vim.keymap.set({ "n", "x", "o" }, "]h", M.recenter_after(move_hunk_next), M.with_desc("goto next git hunk"))
    vim.keymap.set({ "n", "x", "o" }, "[h", M.recenter_after(move_hunk_prev), M.with_desc("goto prev git hunk"))

    -- Make (Next|Prev)GlobalHunk repeatable
    local move_global_hunk_next, move_global_hunk_prev = repeatable_move.make_repeatable_move_pair(
        helpers.jump_to_next_unstaged_hunk,
        helpers.jump_to_prev_unstaged_hunk
    )
    vim.keymap.set("n", "]H", move_global_hunk_next, M.with_desc("goto next git hunk (globally)"))
    vim.keymap.set("n", "[H", move_global_hunk_prev, M.with_desc("goto prev git hunk (globally)"))

    --- vgit autocmds ---

    -- Create augroup for vgit autocmds
    local vgit_group = vim.api.nvim_create_augroup('VgitConfig', { clear = true })

    -- Track when we're coming from a vgit preview buffer
    local coming_from_vgit = false

    -- Detect when entering vgit preview buffers
    vim.api.nvim_create_autocmd('BufEnter', {
        group = vgit_group,
        pattern = '*',
        callback = function()
            local bufnr = vim.api.nvim_get_current_buf()
            local buftype = vim.bo[bufnr].buftype
            local modifiable = vim.bo[bufnr].modifiable
            local buflisted = vim.bo[bufnr].buflisted
            local bufhidden = vim.bo[bufnr].bufhidden

            -- vgit preview buffers: nofile, not modifiable, not listed, bufhidden=wipe
            if buftype == 'nofile' and
                modifiable == false and
                buflisted == false and
                bufhidden == 'wipe' then
                coming_from_vgit = true
                -- Cancel any pending timers from previous preview to avoid races
                cancel_pending_timers()
            end
        end
    })

    -- Capture cursor position when moving in diff view
    vim.api.nvim_create_autocmd('CursorMoved', {
        group = vgit_group,
        pattern = '*',
        callback = function()
            local bufnr = vim.api.nvim_get_current_buf()
            local winnr = vim.api.nvim_get_current_win()

            -- Check if this is a vgit diff buffer (right side - modified file)
            local is_vgit_diff = vim.bo[bufnr].buftype == 'nofile'
                and vim.bo[bufnr].modifiable == false
                and vim.bo[bufnr].buflisted == false
                and vim.bo[bufnr].bufhidden == 'wipe'
                and vim.wo[winnr].cursorbind

            if is_vgit_diff then
                -- Record the cursor position in the diff view
                prev_cursor_pos = vim.api.nvim_win_get_cursor(0)
            end
        end
    })

    -- Force gutter refresh when returning from vgit preview
    vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
        group = vgit_group,
        pattern = '*',
        callback = function()
            local bufnr = vim.api.nvim_get_current_buf()
            local buftype = vim.bo[bufnr].buftype

            -- Check if we're returning to a normal buffer from vgit
            if buftype == '' and coming_from_vgit then
                -- Restore syntax BEFORE resetting flag or jumping to another file
                defer_fn_tracked(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        helpers.restore_syntax_if_needed(bufnr)
                    end
                end, 50)

                coming_from_vgit = false

                -- Restore previous window position
                helpers.restore_window()

                -- VGIT GUTTER REFRESH WORKAROUND
                -- After staging changes in the diff preview, the gutter doesn't
                -- update immediately due to timing issues with vgit's file watcher.
                -- This workaround forces a refresh when returning from the diff
                -- preview. Enable with `enable_gutter_refresh = true`.
                if enable_gutter_refresh then
                    defer_fn_tracked(function()
                        local bufnr = vim.api.nvim_get_current_buf()
                        if not vim.api.nvim_buf_is_valid(bufnr) then
                            return
                        end

                        -- Clear existing signs to force refresh
                        vim.fn.sign_unplace('vgit_signs', { buffer = bufnr })

                        -- Toggle gutter to force vgit to re-detect changes
                        vim.schedule(function()
                            pcall(function()
                                vgit.toggle_live_gutter()

                                -- Toggle back after a brief delay
                                defer_fn_tracked(function()
                                    pcall(function()
                                        vgit.toggle_live_gutter()
                                        -- Restore syntax if it was lost during toggle
                                        helpers.restore_syntax_if_needed(bufnr)
                                    end)
                                end, 100)
                            end)
                        end)
                    end, 100)
                end
            end
        end
    })

    -- Set colorcolumn at 80, 100 chars for vgit diff preview windows
    -- Track which windows we've configured to avoid redundant updates
    local colorcolumn_configured = {}

    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = vgit_group,
        pattern = '*',
        callback = function()
            -- Guard against restricted contexts
            if vim.fn.getcmdwintype() ~= '' then
                return
            end
            local bufnr = vim.api.nvim_get_current_buf()
            local winnr = vim.api.nvim_get_current_win()

            -- Early exit if already configured or not a nofile buffer
            if colorcolumn_configured[winnr] or vim.bo[bufnr].buftype ~= 'nofile' then
                return
            end

            -- Check if this is a vgit diff buffer
            local is_vgit_diff = vim.bo[bufnr].modifiable == false
                and vim.bo[bufnr].buflisted == false
                and vim.bo[bufnr].bufhidden == 'wipe'
                and (vim.wo[winnr].cursorbind
                    or vim.wo[winnr].scrollbind)

            if is_vgit_diff then
                colorcolumn_configured[winnr] = true

                -- Detect line number prefix width and set colorcolumn
                local lines = vim.api.nvim_buf_get_lines(
                    bufnr, 0, math.min(10, vim.api.nvim_buf_line_count(bufnr)), false
                )

                -- Find line number prefix width
                local offset = 0
                for _, line in ipairs(lines) do
                    local prefix = line:match("^(%s*%d+%s)")
                    if prefix then
                        offset = #prefix
                        break
                    end
                end

                -- Apply offset to standard column positions
                local col80 = 80 + offset
                local col100 = 100 + offset
                vim.wo[winnr].colorcolumn = col80 .. ',' .. col100
            end
        end
    })

    -- Clean up colorcolumn tracking when windows close
    vim.api.nvim_create_autocmd('WinClosed', {
        group = vgit_group,
        callback = function(args)
            local winnr = tonumber(args.match)
            if winnr then
                colorcolumn_configured[winnr] = nil
            end
        end
    })
end -- }}}

-- do  -- vim-gitgutter - Show git diff in the gutter {{{
--     -- Mappings:
--     -- <leader>ggt - Toggle git gutter
--     -- <leader>hs - Stage hunk
--     -- <leader>hr - Undo hunk
--     -- <leader>hd - toggle git diff split pane for current file
--     -- <leader>hv - open popup preview for current hunk
--     -- ]h - Move forward one hunk
--     -- [h - Move backward one hunk
--     -- <motion>ih - <motion> in hunk
--     -- <motion>ah - <motion> around hunk (includes trailing empty lines)
--
--     local repeatable_move = require("nvim-treesitter.textobjects.repeatable_move")
--
--     -- Don't automatically set mappings.
--     vim.g.gitgutter_map_keys = false
--
--     vim.keymap.set("n", "<leader>ggt", vim.cmd.GitGutterToggle, M.with_desc("toggle showing git hunks"))
--     vim.keymap.set("n", "<leader>hs", vim.cmd.GitGutterStageHunk, M.with_desc("stage git hunk"))
--     vim.keymap.set("n", "<leader>hr", vim.cmd.GitGutterUndoHunk, M.with_desc("reset git hunk"))
--     vim.keymap.set("n", "<leader>hv", vim.cmd.GitGutterPreviewHunk, M.with_desc("preview git hunk in popup"))
--     vim.keymap.set("n", "<leader>hd", function()
--         require_local("gitgutter_difforig").toggle()
--     end, M.with_desc("toggle full hunk diff in split window"))
--
--     -- Make GitGutter(Next|Prev)Hunk repeatable
--     local move_hunk_next, move_hunk_prev = repeatable_move.make_repeatable_move_pair(
--         vim.cmd.GitGutterNextHunk,
--         vim.cmd.GitGutterPrevHunk
--     )
--     vim.keymap.set({ "n", "x", "o" }, "]h", M.recenter_after(move_hunk_next), M.with_desc("goto next git hunk"))
--     vim.keymap.set({ "n", "x", "o" }, "[h", M.recenter_after(move_hunk_prev), M.with_desc("goto prev git hunk"))
--
--     local opts = { silent = true, remap = false }
--     vim.keymap.set("o", "ih", "<Plug>(GitGutterTextObjectInnerPending)", opts)
--     vim.keymap.set("o", "ah", "<Plug>(GitGutterTextObjectOuterPending)", opts)
--     vim.keymap.set("x", "ih", "<Plug>(GitGutterTextObjectInnerVisual)", opts)
--     vim.keymap.set("x", "ah", "<Plug>(GitGutterTextObjectOuterVisual)", opts)
-- end -- vim-gitgutter }}}

do -- coc.nvim - Complete engine and Language Server support for neovim {{{
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

    -- TODO(phlip9): re-order the filename after the git info. Doing this using
    -- `airline#extensions#default#layout` doesn't work due to `%<`/`%=` marker
    -- location and vim-fugitive interaction.

    -- Drop the lower-value sections before the filename in narrow splits.
    --
    -- Section c (filename) carries vim's `%<` truncation marker and is never
    -- itself width-truncated, so when the other sections fill a narrow window
    -- vim collapses the filename first.
    vim.g["airline#extensions#default#section_truncate_width"] = {
        b = 100,      -- git branch + diff hunks
        x = 100,      -- filetype + LSP client
        y = 80,       -- file encoding/format (airline default)
        z = 45,       -- file position (airline default)
        warning = 80, -- airline default
        error = 80,   -- airline default
    }

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

do  -- worklog - quickly open and manage daily work logs {{{
    -- Mappings:
    --   <space>wo  - telescope picker for all worklog files
    --  <leader>wol - open ~/dev/notes/lexe worklog
    --  <leader>wod - open ~/dev/notes/dotfiles worklog
    --  <leader>wd  - insert today's entry heading
    --
    -- TODO(phlip9): folding does not work well
    -- TODO(phlip9): <leader>wd should work outside log file by detecting the
    --               relevant project from the path

    vim.keymap.set("n", "<space>wo", function() require_local("worklog").pick() end,
        M.with_desc("pick worklog file"))
    vim.keymap.set("n", "<leader>wol", function() require_local("worklog").open("lexe") end,
        M.with_desc("open lexe worklog"))
    vim.keymap.set("n", "<leader>wod", function() require_local("worklog").open("dotfiles") end,
        M.with_desc("open dotfiles worklog"))
    vim.keymap.set("n", "<leader>wd", require_local("worklog").insert_today,
        M.with_desc("insert today's worklog heading"))

    -- Enable treesitter folding for worklog files specifically.
    -- Collapse day entries (## headings) but keep the year heading open.
    local worklog_group = vim.api.nvim_create_augroup("WorklogFolding", {})
    vim.api.nvim_create_autocmd("BufRead", {
        pattern = vim.env.HOME .. "/dev/notes/*/log/*.md",
        group = worklog_group,
        desc = "Enable treesitter folding for worklog files",
        callback = function()
            vim.opt_local.foldmethod = "expr"
            vim.opt_local.foldexpr = "nvim_treesitter#foldexpr()"
            -- Collapse ## day entries but keep # year heading open.
            vim.opt_local.foldlevel = 1
        end,
    })
end -- worklog }}}

do  -- shellopen - shell command -> open files/quickfix {{{
    -- Commands:
    -- :Sho  {cmd} - shell -> open, newline-delimited stdout
    -- :Shoz {cmd} - shell -> open, NUL-delimited stdout
    -- :Shq  {cmd} - shell -> quickfix, newline-delimited stdout
    -- :Shqz {cmd} - shell -> quickfix, NUL-delimited stdout
    --
    -- Examples:
    -- :Sho  git diff --name-only | grep Cargo
    -- :Shoz git diff --name-only -z
    -- :Shq  rg --files | grep Cargo
    -- :Shqz fd -0 Cargo

    vim.api.nvim_create_user_command(
        "Sho",
        function(opts) require_local("shellopen").sho(opts.args) end,
        { nargs = "+", complete = "shellcmdline", desc = "Shell -> open" }
    )
    vim.api.nvim_create_user_command(
        "Shoz",
        function(opts) require_local("shellopen").shoz(opts.args) end,
        { nargs = "+", complete = "shellcmdline", desc = "Shell -> open (NUL-delimited)" }
    )
    vim.api.nvim_create_user_command(
        "Shq",
        function(opts) require_local("shellopen").shq(opts.args) end,
        { nargs = "+", complete = "shellcmdline", desc = "Shell -> quickfix" }
    )
    vim.api.nvim_create_user_command(
        "Shqz",
        function(opts) require_local("shellopen").shqz(opts.args) end,
        { nargs = "+", complete = "shellcmdline", desc = "Shell -> quickfix (NUL-delimited)" }
    )
end -- shellopn }}}

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

    -- In insert mode, expand ex: 'TODO' -> 'TODO(phlip9):'
    vim.cmd([[
        iabbrev TODO TODO(phlip9):
        iabbrev FIXME FIXME(phlip9):
        iabbrev NOTE NOTE(phlip9):
    ]])
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
    vim.keymap.set("v", "K", "<Nop>", M.with_desc("disable K in visual", opts))

    -- map arrow keys to something more useful (indent/unindent)
    vim.keymap.set("n", "<Left>", "<<", M.with_desc("unindent line", opts))
    vim.keymap.set("n", "<Right>", ">>", M.with_desc("indent line", opts))

    vim.keymap.set("v", "<Left>", "<gv", M.with_desc("unindent selection", opts))
    vim.keymap.set("v", "<Right>", ">gv", M.with_desc("indent selection", opts))

    -- up/down adds line above/below
    vim.keymap.set("n", "<Up>", "O<Esc>j", M.with_desc("add blank line above", opts))
    vim.keymap.set("n", "<Down>", "o<Esc>k", M.with_desc("add blank line below", opts))

    -- replace currently selected text w/o clobbering the yank register
    -- note: "_ is the blackhole register
    vim.keymap.set("v", "<leader>p", "\"_dP", M.with_desc("paste without clobbering register", opts))

    -- Reload nvim/init.lua (and all local modules)
    local function reload_nvim_config()
        -- if a module has `_is_local_module` set to true (i.e., it was loaded
        -- with `require_local(..)`), then unload it from the package require()
        -- cache so it gets reloaded on next require().
        for name, pkg in pairs(package.loaded) do
            if type(pkg) == "table" and rawget(pkg, "_is_local_module") then
                package.loaded[name] = nil
                vim.notify("- unloaded: " .. name, vim.log.levels.DEBUG)
            end
        end

        vim.cmd("source $MYVIMRC")
        vim.cmd("filetype detect")
        vim.notify("Reloaded nvim/init.lua", vim.log.levels.INFO)
    end
    vim.keymap.set("n", "<leader>nr", reload_nvim_config, M.with_desc("reload nvim config", opts))

    -- Edit nvim/init.lua
    vim.keymap.set("n", "<leader>ne", ":e $MYVIMRC<CR>", M.with_desc("edit nvim config", opts))

    -- remap Visual Block selection to something that doesn't conflict with
    -- system copy/paste
    vim.keymap.set("n", "<leader>v", "<C-v>", M.with_desc("visual block mode", opts))

    -- map S-J and S-K to next and prev buffer
    vim.keymap.set("n", "J", ":bp<CR>", M.with_desc("prev buffer", opts))
    vim.keymap.set("n", "K", ":bn<CR>", M.with_desc("next buffer", opts))

    -- map S-H and S-L to undo and redo
    vim.keymap.set("n", "H", "u", M.with_desc("undo", opts))
    vim.keymap.set("n", "L", "<C-R>", M.with_desc("redo", opts))

    -- Window movement w/ CTRL + h,j,k,l
    vim.keymap.set("n", "<C-h>", "<C-w>h", M.with_desc("move to left window", opts))
    vim.keymap.set("n", "<C-j>", "<C-w>j", M.with_desc("move to window below", opts))
    vim.keymap.set("n", "<C-k>", "<C-w>k", M.with_desc("move to window above", opts))
    vim.keymap.set("n", "<C-l>", "<C-w>l", M.with_desc("move to right window", opts))

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

    -- quickfix list next/prev with repeatable_move and recenter
    local repeatable_move = require("nvim-treesitter.textobjects.repeatable_move")
    local move_qf_next, move_qf_prev = repeatable_move.make_repeatable_move_pair(
        function() vim.cmd.cnext() end,
        function() vim.cmd.cprev() end
    )
    vim.keymap.set("n", "]q", M.recenter_after(move_qf_next), M.with_desc("goto next quickfix"))
    vim.keymap.set("n", "[q", M.recenter_after(move_qf_prev), M.with_desc("goto prev quickfix"))

    -- location list next/prev with repeatable_move and recenter
    local move_ll_next, move_ll_prev = repeatable_move.make_repeatable_move_pair(
        function() vim.cmd.lnext() end,
        function() vim.cmd.lprev() end
    )
    vim.keymap.set("n", "]l", M.recenter_after(move_ll_next), M.with_desc("goto next location list"))
    vim.keymap.set("n", "[l", M.recenter_after(move_ll_prev), M.with_desc("goto prev location list"))

    -- -- re-center screen on C-d, C-u, search next/prev
    -- vim.keymap.set("n", "<C-d>", "<C-d>zz", opts)
    -- vim.keymap.set("n", "<C-u>", "<C-u>zz", opts)
    -- vim.keymap.set("n", "n", "nzzzv", opts)
    -- vim.keymap.set("n", "N", "Nzzzv", opts)

    --
    -- Terminal Mode
    --

    -- Use escape to go back to normal mode
    vim.keymap.set("t", "<Esc>", "<C-\\><C-n>", M.with_desc("exit terminal mode", opts))

    -- Window movement in terminal mode w/ CTRL + h,j,k,l
    vim.keymap.set("t", "<C-h>", "<C-\\><C-n><C-W>h", M.with_desc("move to left window", opts))
    vim.keymap.set("t", "<C-j>", "<C-\\><C-n><C-W>j", M.with_desc("move to window below", opts))
    vim.keymap.set("t", "<C-k>", "<C-\\><C-n><C-W>k", M.with_desc("move to window above", opts))
    vim.keymap.set("t", "<C-l>", "<C-\\><C-n><C-W>l", M.with_desc("move to right window", opts))

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
