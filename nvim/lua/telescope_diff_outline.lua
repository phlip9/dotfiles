--- Telescope document outline with git diff markers.
---
--- Wraps telescope-coc and builtin.treesitter pickers to add git diff markers
--- (+/~/−) to the results list and preview pane.
---
--- Usage:
---   local diff_outline = require_local("telescope_diff_outline")
---   diff_outline.coc_document_symbols({})
---   diff_outline.treesitter_symbols({})

local conf = require("telescope.config").values
local finders = require("telescope.finders")
local make_entry = require("telescope.make_entry")
local pickers = require("telescope.pickers")
local previewers = require("telescope.previewers")
local entry_display = require("telescope.pickers.entry_display")

local M = {}

--------------------------------------------------------------------------------
-- Git hunk utilities
--------------------------------------------------------------------------------

--- Get hunks for a buffer from vim-gitgutter.
--- @param bufnr number Buffer number
--- @return table[] hunks List of hunks: [old_start, old_count, new_start, new_count]
function M.get_hunks(bufnr)
    local ok, hunks = pcall(vim.fn["gitgutter#hunk#hunks"], bufnr)
    if not ok or hunks == nil then
        return {}
    end
    return hunks
end

--- Check if a line is within a hunk's range.
--- @param lnum number Line number (1-indexed)
--- @param hunk table Hunk: [old_start, old_count, new_start, new_count]
--- @return boolean
local function line_in_hunk(lnum, hunk)
    local new_start = hunk[3]
    local new_count = hunk[4]

    -- For deleted hunks (new_count=0), they appear at a single line
    if new_count == 0 then
        return lnum == new_start
    end

    -- For added/modified hunks
    return lnum >= new_start and lnum < new_start + new_count
end

--- Get the hunk that contains a given line.
--- @param lnum number Line number (1-indexed)
--- @param hunks table[]|nil List of hunks
--- @return table|nil hunk The hunk or nil
function M.get_hunk_for_line(lnum, hunks)
    if hunks == nil then
        return nil
    end
    for _, hunk in ipairs(hunks) do
        if line_in_hunk(lnum, hunk) then
            return hunk
        end
    end
    return nil
end

--- Get the diff status for a line.
--- @param lnum number Line number (1-indexed)
--- @param hunks table[]|nil List of hunks
--- @return string|nil status "+", "~", "-", or nil
function M.get_line_diff_status(lnum, hunks)
    local hunk = M.get_hunk_for_line(lnum, hunks)
    if hunk == nil then
        return nil
    end

    local old_count = hunk[2]
    local new_count = hunk[4]

    if new_count == 0 then
        -- Deleted: old_count > 0, new_count = 0
        return "-"
    elseif old_count == 0 then
        -- Added: old_count = 0, new_count > 0
        return "+"
    else
        -- Modified: old_count > 0, new_count > 0
        return "~"
    end
end

--------------------------------------------------------------------------------
-- Custom entry maker with diff markers
--------------------------------------------------------------------------------

--- Create an entry maker that adds diff markers to symbol entries.
--- @param hunks table[] Hunks for the buffer
--- @param opts table Options for the picker
--- @return function entry_maker
---@diagnostic disable-next-line: unused-local
function M.make_diff_entry_maker(_bufnr, hunks, opts)
    local base_maker = make_entry.gen_from_lsp_symbols(opts)

    local displayer = entry_display.create({
        separator = " ",
        items = {
            { width = 1 }, -- diff marker
            { remaining = true },
        },
    })

    return function(symbol)
        local entry = base_maker(symbol)
        if entry == nil then
            return nil
        end

        local lnum = symbol.lnum
        local status = M.get_line_diff_status(lnum, hunks)

        -- Wrap the display function to prepend diff marker
        local orig_display = entry.display
        entry.display = function(e)
            local marker = status or " "
            local hl_group = nil
            if status == "+" then
                hl_group = "GitGutterAdd"
            elseif status == "~" then
                hl_group = "GitGutterChange"
            elseif status == "-" then
                hl_group = "GitGutterDelete"
            end

            -- Get original display
            local display_text
            if type(orig_display) == "function" then
                display_text = orig_display(e)
            else
                display_text = orig_display
            end

            return displayer({
                { marker, hl_group },
                display_text,
            })
        end

        return entry
    end
end

--------------------------------------------------------------------------------
-- Custom previewer with diff markers in sign column
--------------------------------------------------------------------------------

--- Create a previewer that shows diff markers in the sign column.
--- @param opts table Options
--- @param hunks table[] Hunks for the buffer
--- @return table previewer
function M.make_diff_previewer(opts, hunks)
    local ns = vim.api.nvim_create_namespace("telescope_diff_outline_preview")

    return previewers.new_buffer_previewer({
        title = "Preview",
        get_buffer_by_name = function(_, entry)
            return entry.filename
        end,

        ---@diagnostic disable-next-line: unused-local
        define_preview = function(self, entry, _status)
            -- Use the built-in buffer previewer behavior
            conf.buffer_previewer_maker(entry.filename, self.state.bufnr, {
                bufname = self.state.bufname,
                winid = self.state.winid,
                preview = opts.preview,
                callback = function(bufnr)
                    -- Jump to the entry's line
                    if entry.lnum then
                        pcall(vim.api.nvim_win_set_cursor, self.state.winid, {
                            entry.lnum, 0
                        })
                    end

                    -- Add diff markers as extmarks in sign column
                    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
                    for _, hunk in ipairs(hunks) do
                        local old_count = hunk[2]
                        local new_start = hunk[3]
                        local new_count = hunk[4]

                        local marker, hl_group
                        if new_count == 0 then
                            -- Deleted: show at deletion point
                            marker = "-"
                            hl_group = "GitGutterDelete"
                            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns,
                                new_start - 1, 0, {
                                    sign_text = marker,
                                    sign_hl_group = hl_group,
                                })
                        else
                            if old_count == 0 then
                                marker = "+"
                                hl_group = "GitGutterAdd"
                            else
                                marker = "~"
                                hl_group = "GitGutterChange"
                            end
                            -- Mark each line in the hunk
                            for lnum = new_start, new_start + new_count - 1 do
                                pcall(vim.api.nvim_buf_set_extmark, bufnr, ns,
                                    lnum - 1, 0, {
                                        sign_text = marker,
                                        sign_hl_group = hl_group,
                                    })
                            end
                        end
                    end
                end,
            })
        end,
    })
end

--------------------------------------------------------------------------------
-- Public API: Document symbol pickers with diff markers
--------------------------------------------------------------------------------

--- coc.nvim async action helper
local function CocActionWithTimeout(action_type, ...)
    local result = nil
    local completed = false

    local args = { ... }
    table.insert(args, 1, action_type)
    table.insert(args, function(_, res)
        result = res
        completed = true
    end)

    vim.fn.CocActionAsync(unpack(args))

    local timeout = 3000
    vim.wait(timeout, function()
        return completed
    end, 50)

    return result
end

--- Open coc.nvim document symbols picker with diff markers.
--- @param opts? table Options passed to telescope
function M.coc_document_symbols(opts)
    opts = opts or {}

    if vim.g.coc_service_initialized ~= 1 then
        print("Coc is not ready!")
        return
    end

    if not vim.fn.CocHasProvider("documentSymbol") then
        print("Coc: server does not support documentSymbol")
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local hunks = M.get_hunks(bufnr)

    local symbols = CocActionWithTimeout("documentSymbols", bufnr)
    if type(symbols) ~= "table" or vim.tbl_isempty(symbols) then
        print("No document symbols found")
        return
    end

    -- Convert to quickfix-style entries
    local results = {}
    local filename = vim.api.nvim_buf_get_name(bufnr)
    for _, s in ipairs(symbols) do
        results[#results + 1] = {
            filename = filename,
            lnum = s.lnum,
            col = s.col,
            kind = s.kind,
            text = string.format("[%s] %s", s.kind, s.text),
        }
    end

    opts.ignore_filename = true
    opts.path_display = { "hidden" }

    pickers.new(opts, {
        prompt_title = "Document Symbols",
        previewer = M.make_diff_previewer(opts, hunks),
        finder = finders.new_table({
            results = results,
            entry_maker = M.make_diff_entry_maker(bufnr, hunks, opts),
        }),
        sorter = conf.prefilter_sorter({
            tag = "symbol_type",
            sorter = conf.generic_sorter(opts),
        }),
    }):find()
end

--- Open treesitter symbols picker with diff markers.
--- @param opts? table Options passed to telescope
function M.treesitter_symbols(opts)
    opts = opts or {}

    local bufnr = vim.api.nvim_get_current_buf()
    local hunks = M.get_hunks(bufnr)

    -- Use builtin.treesitter's entry maker and finder, but wrap with our
    -- diff marker logic
    local builtin = require("telescope.builtin")

    local parsers = require("nvim-treesitter.parsers")
    if not parsers.has_parser(parsers.get_buf_lang()) then
        print("No treesitter parser for this buffer")
        return
    end

    -- Get treesitter entries
    local ts_entries = {}
    local filename = vim.api.nvim_buf_get_name(bufnr)

    local ts = vim.treesitter
    local lang = parsers.get_buf_lang()
    local parser = parsers.get_parser(bufnr, lang)
    if not parser then
        print("Could not get treesitter parser")
        return
    end

    local tree = parser:parse()[1]
    if not tree then
        print("Could not parse treesitter tree")
        return
    end

    -- Query for definitions/symbols
    local query_name = "locals"
    local query_ok, query = pcall(ts.query.get, lang, query_name)
    if not query_ok or not query then
        -- Try highlights as fallback
        query_ok, query = pcall(ts.query.get, lang, "highlights")
        if not query_ok or not query then
            print("No treesitter query available")
            return
        end
    end

    -- Collect definition nodes
    local seen = {}
    for id, node, _ in query:iter_captures(tree:root(), bufnr, 0, -1) do
        local name = query.captures[id]
        if name:match("^definition") or name:match("^scope") then
            local text = ts.get_node_text(node, bufnr)
            local start_row, start_col = node:start()
            local key = string.format("%d:%d:%s", start_row, start_col, text)
            if not seen[key] then
                seen[key] = true
                local kind = name:gsub("^definition%.", ""):gsub("^scope$", "scope")
                ts_entries[#ts_entries + 1] = {
                    filename = filename,
                    lnum = start_row + 1,
                    col = start_col + 1,
                    kind = kind,
                    text = string.format("[%s] %s", kind, text),
                }
            end
        end
    end

    if #ts_entries == 0 then
        -- Fall back to builtin treesitter picker if our query didn't work
        builtin.treesitter(opts)
        return
    end

    opts.ignore_filename = true
    opts.path_display = { "hidden" }

    pickers.new(opts, {
        prompt_title = "Treesitter Symbols",
        previewer = M.make_diff_previewer(opts, hunks),
        finder = finders.new_table({
            results = ts_entries,
            entry_maker = M.make_diff_entry_maker(bufnr, hunks, opts),
        }),
        sorter = conf.generic_sorter(opts),
    }):find()
end

return M
