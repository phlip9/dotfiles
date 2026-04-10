--- Tests for telescope_diff_outline module.

local eq = assert.are.same
local M = require("telescope_diff_outline")

local entry_display = require("telescope.pickers.entry_display")
local make_entry = require("telescope.make_entry")

describe("telescope_diff_outline", function()
    describe("get_line_diff_status", function()
        it("returns + for added lines", function()
            -- Hunk format: [old_start, old_count, new_start, new_count]
            -- Added: old_count=0, new_count>0
            local hunks = { { 10, 0, 10, 5 } } -- lines 10-14 added
            eq("+", M.get_line_diff_status(10, hunks))
            eq("+", M.get_line_diff_status(12, hunks))
            eq("+", M.get_line_diff_status(14, hunks))
        end)

        it("returns ~ for modified lines", function()
            -- Modified: old_count>0, new_count>0
            local hunks = { { 20, 3, 20, 3 } } -- lines 20-22 modified
            eq("~", M.get_line_diff_status(20, hunks))
            eq("~", M.get_line_diff_status(21, hunks))
            eq("~", M.get_line_diff_status(22, hunks))
        end)

        it("returns - at deletion point for deleted lines", function()
            -- Deleted hunks (old_count>0, new_count=0) appear at a single line
            local hunks = { { 15, 3, 15, 0 } } -- 3 lines deleted at line 15
            eq("-", M.get_line_diff_status(15, hunks))
            eq(nil, M.get_line_diff_status(16, hunks))
        end)

        it("returns nil for unchanged lines", function()
            local hunks = { { 10, 0, 10, 5 } }
            eq(nil, M.get_line_diff_status(5, hunks))
            eq(nil, M.get_line_diff_status(15, hunks))
        end)

        it("handles multiple hunks", function()
            local hunks = {
                { 5,  0, 5,  2 }, -- lines 5-6 added
                { 15, 2, 15, 3 }, -- lines 15-17 modified
                { 25, 0, 28, 1 }, -- line 28 added
            }
            eq("+", M.get_line_diff_status(5, hunks))
            eq("+", M.get_line_diff_status(6, hunks))
            eq(nil, M.get_line_diff_status(7, hunks))
            eq("~", M.get_line_diff_status(15, hunks))
            eq("~", M.get_line_diff_status(17, hunks))
            eq(nil, M.get_line_diff_status(18, hunks))
            eq("+", M.get_line_diff_status(28, hunks))
        end)

        it("handles empty hunks list", function()
            eq(nil, M.get_line_diff_status(10, {}))
        end)

        it("handles nil hunks", function()
            eq(nil, M.get_line_diff_status(10, nil))
        end)

        -- Deletion at file start: gitgutter uses new_start=0. No
        -- real 1-indexed line number should match. lnum=0 technically
        -- matches but never occurs in practice.
        it("returns nil for line 1 when deletion is at file start", function()
            local hunks = { { 1, 3, 0, 0 } }
            eq(nil, M.get_line_diff_status(1, hunks))
        end)
    end)

    describe("get_hunk_for_line", function()
        it("returns the hunk containing the line", function()
            local hunks = {
                { 5,  0, 5,  2 },
                { 15, 2, 15, 3 },
            }
            eq({ 5, 0, 5, 2 }, M.get_hunk_for_line(5, hunks))
            eq({ 15, 2, 15, 3 }, M.get_hunk_for_line(16, hunks))
        end)

        it("returns nil if line is not in any hunk", function()
            local hunks = { { 5, 0, 5, 2 } }
            eq(nil, M.get_hunk_for_line(10, hunks))
        end)
    end)

    describe("make_diff_entry_maker", function()
        local orig_create = entry_display.create
        local orig_gen = make_entry.gen_from_lsp_symbols

        after_each(function()
            entry_display.create = orig_create
            make_entry.gen_from_lsp_symbols = orig_gen
        end)

        --- Stub entry_display.create to capture columns passed to
        --- the displayer and return a simple concatenation.
        --- Returns the displayer and a function to get the last
        --- columns argument.
        local function stub_displayer()
            local last_columns = nil
            ---@diagnostic disable-next-line: duplicate-set-field
            entry_display.create = function(_)
                return function(columns)
                    last_columns = columns
                    local text = columns[2]
                    if type(text) == "table" then
                        text = text[1]
                    end
                    return columns[1][1] .. " " .. text
                end
            end
            return function()
                return last_columns
            end
        end

        --- Return non-nil first displayer column.
        local function get_marker_col(cols)
            local marker_col = cols[1]
            if marker_col == nil then
                error("missing marker column")
            end
            return marker_col
        end

        --- Return non-nil highlight fn stored in second displayer column.
        local function get_highlight_fn(cols)
            local text_col = cols[2]
            if type(text_col) ~= "table" then
                error("missing text column table")
            end

            local hl_fn = text_col[2]
            if type(hl_fn) ~= "function" then
                error("missing highlight function")
            end
            return hl_fn
        end

        --- Stub gen_from_lsp_symbols to return a simple entry maker
        --- that optionally returns highlight info.
        local function stub_base_maker(orig_hl)
            ---@diagnostic disable-next-line: duplicate-set-field
            make_entry.gen_from_lsp_symbols = function(_)
                return function(symbol)
                    return {
                        value = symbol.text,
                        ordinal = symbol.text,
                        filename = symbol.filename,
                        lnum = symbol.lnum,
                        col = symbol.col,
                        display = function()
                            return symbol.text, orig_hl
                        end,
                    }
                end
            end
        end

        it("prepends + marker for added lines", function()
            local get_columns = stub_displayer()
            stub_base_maker(nil)

            local hunks = { { 10, 0, 10, 5 } }
            local maker = M.make_diff_entry_maker(0, hunks, {})
            local entry = maker({
                filename = "test.lua",
                lnum = 12,
                col = 1,
                kind = "Function",
                text = "[Function] foo",
            })

            local rendered = entry.display(entry)
            assert.is_truthy(rendered:find("+", 1, true))
            assert.is_truthy(rendered:find("[Function] foo", 1, true))

            local cols = get_columns()
            local marker_col = get_marker_col(cols)
            eq("+", marker_col[1])
            eq("GitGutterAdd", marker_col[2])
        end)

        it("prepends ~ marker for modified lines", function()
            local get_columns = stub_displayer()
            stub_base_maker(nil)

            local hunks = { { 5, 3, 5, 3 } }
            local maker = M.make_diff_entry_maker(0, hunks, {})
            local entry = maker({
                filename = "test.lua",
                lnum = 6,
                col = 1,
                kind = "Variable",
                text = "[Variable] x",
            })

            entry.display(entry)
            local cols = get_columns()
            local marker_col = get_marker_col(cols)
            eq("~", marker_col[1])
            eq("GitGutterChange", marker_col[2])
        end)

        it("prepends space for unchanged lines", function()
            local get_columns = stub_displayer()
            stub_base_maker(nil)

            local hunks = { { 10, 0, 10, 5 } }
            local maker = M.make_diff_entry_maker(0, hunks, {})
            local entry = maker({
                filename = "test.lua",
                lnum = 1,
                col = 1,
                kind = "Function",
                text = "[Function] bar",
            })

            entry.display(entry)
            local cols = get_columns()
            local marker_col = get_marker_col(cols)
            eq(" ", marker_col[1])
            eq(nil, marker_col[2])
        end)

        it("forwards highlight table from base display function", function()
            local fake_hl = { { 0, 5, "Type" }, { 6, 10, "Function" } }
            local get_columns = stub_displayer()
            stub_base_maker(fake_hl)

            local hunks = {}
            local maker = M.make_diff_entry_maker(0, hunks, {})
            local entry = maker({
                filename = "test.lua",
                lnum = 1,
                col = 1,
                kind = "Function",
                text = "[Function] baz",
            })

            entry.display(entry)
            local cols = get_columns()

            -- Second column should be a table with a highlight function
            local hl_fn = get_highlight_fn(cols)
            eq(fake_hl, hl_fn())
        end)

        it("returns empty table when base display has no highlights", function()
            local get_columns = stub_displayer()
            stub_base_maker(nil)

            local hunks = {}
            local maker = M.make_diff_entry_maker(0, hunks, {})
            local entry = maker({
                filename = "test.lua",
                lnum = 1,
                col = 1,
                kind = "Function",
                text = "[Function] qux",
            })

            entry.display(entry)
            local cols = get_columns()

            local hl_fn = get_highlight_fn(cols)
            eq({}, hl_fn())
        end)

        it("returns nil when base maker returns nil", function()
            ---@diagnostic disable-next-line: duplicate-set-field
            make_entry.gen_from_lsp_symbols = function(_)
                return function(_)
                    return nil
                end
            end
            stub_displayer()

            local maker = M.make_diff_entry_maker(0, {}, {})
            eq(nil, maker({
                filename = "test.lua",
                lnum = 1,
                col = 1,
                kind = "Function",
                text = "[Function] nil_entry",
            }))
        end)
    end)

    describe("place_hunk_signs", function()
        local temp_bufs = {}

        --- Create a scratch buffer with the given number of lines.
        local function make_buf(num_lines)
            local bufnr = vim.api.nvim_create_buf(false, true)
            temp_bufs[#temp_bufs + 1] = bufnr
            local lines = {}
            for idx = 1, num_lines do
                lines[idx] = "line " .. idx
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            return bufnr
        end

        --- Get all extmarks in a namespace as a simplified list of
        --- { line (0-indexed), sign_text, sign_hl_group }.
        local function get_signs(bufnr, ns)
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr, ns, 0, -1, { details = true }
            )
            local out = {}
            for _, mark in ipairs(marks) do
                local details = mark[4]
                if details == nil then
                    error("missing extmark details")
                end
                out[#out + 1] = {
                    line = mark[2],
                    -- neovim pads sign_text to 2 chars; trim it
                    sign_text = vim.trim(details.sign_text),
                    sign_hl_group = details.sign_hl_group,
                }
            end
            return out
        end

        after_each(function()
            for _, bufnr in ipairs(temp_bufs) do
                if vim.api.nvim_buf_is_valid(bufnr) then
                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            end
            temp_bufs = {}
        end)

        it("places + signs for added hunks", function()
            local bufnr = make_buf(10)
            local ns = vim.api.nvim_create_namespace("test_signs_add")
            -- Lines 3-5 added (1-indexed)
            M.place_hunk_signs(bufnr, ns, { { 3, 0, 3, 3 } })

            local signs = get_signs(bufnr, ns)
            eq(3, #signs)
            for _, sign in ipairs(signs) do
                eq("+", sign.sign_text)
                eq("GitGutterAdd", sign.sign_hl_group)
            end
            -- 0-indexed lines: 2, 3, 4
            eq(2, signs[1].line)
            eq(3, signs[2].line)
            eq(4, signs[3].line)
        end)

        it("places ~ signs for modified hunks", function()
            local bufnr = make_buf(10)
            local ns = vim.api.nvim_create_namespace("test_signs_mod")
            -- Lines 1-2 modified (1-indexed)
            M.place_hunk_signs(bufnr, ns, { { 1, 2, 1, 2 } })

            local signs = get_signs(bufnr, ns)
            eq(2, #signs)
            eq("~", signs[1].sign_text)
            eq("GitGutterChange", signs[1].sign_hl_group)
        end)

        it("places - sign for deleted hunk", function()
            local bufnr = make_buf(10)
            local ns = vim.api.nvim_create_namespace("test_signs_del")
            -- 3 lines deleted at line 5
            M.place_hunk_signs(bufnr, ns, { { 5, 3, 5, 0 } })

            local signs = get_signs(bufnr, ns)
            eq(1, #signs)
            eq("-", signs[1].sign_text)
            eq("GitGutterDelete", signs[1].sign_hl_group)
            eq(4, signs[1].line) -- 0-indexed: line 5 -> index 4
        end)

        it("clamps deletion at file start to line 0", function()
            local bufnr = make_buf(5)
            local ns = vim.api.nvim_create_namespace("test_signs_del0")
            -- Deletion at file start: new_start=0
            M.place_hunk_signs(bufnr, ns, { { 1, 3, 0, 0 } })

            local signs = get_signs(bufnr, ns)
            eq(1, #signs)
            eq("-", signs[1].sign_text)
            eq(0, signs[1].line) -- clamped to 0, not -1
        end)

        it("places mixed signs for multiple hunks", function()
            local bufnr = make_buf(20)
            local ns = vim.api.nvim_create_namespace("test_signs_mix")
            M.place_hunk_signs(bufnr, ns, {
                { 1,  0, 1,  2 }, -- lines 1-2 added
                { 8,  2, 8,  2 }, -- lines 8-9 modified
                { 15, 5, 15, 0 }, -- deleted at line 15
            })

            local signs = get_signs(bufnr, ns)
            eq(5, #signs)
            -- Added: lines 1-2 (0-indexed: 0, 1)
            eq("+", signs[1].sign_text)
            eq(0, signs[1].line)
            eq("+", signs[2].sign_text)
            eq(1, signs[2].line)
            -- Modified: lines 8-9 (0-indexed: 7, 8)
            eq("~", signs[3].sign_text)
            eq(7, signs[3].line)
            eq("~", signs[4].sign_text)
            eq(8, signs[4].line)
            -- Deleted: line 15 (0-indexed: 14)
            eq("-", signs[5].sign_text)
            eq(14, signs[5].line)
        end)

        it("clears previous signs before placing new ones", function()
            local bufnr = make_buf(10)
            local ns = vim.api.nvim_create_namespace("test_signs_clear")

            -- Place initial signs
            M.place_hunk_signs(bufnr, ns, { { 1, 0, 1, 3 } })
            eq(3, #get_signs(bufnr, ns))

            -- Replace with different hunks
            M.place_hunk_signs(bufnr, ns, { { 5, 2, 5, 0 } })
            local signs = get_signs(bufnr, ns)
            eq(1, #signs)
            eq("-", signs[1].sign_text)
        end)

        it("handles empty hunk list", function()
            local bufnr = make_buf(5)
            local ns = vim.api.nvim_create_namespace("test_signs_empty")
            M.place_hunk_signs(bufnr, ns, {})
            eq(0, #get_signs(bufnr, ns))
        end)
    end)
end)
