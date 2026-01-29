--- Tests for telescope_diff_outline module.
---
--- Run with: nvim --headless -c 'PlenaryBustedFile nvim/lua/test/telescope_diff_outline_spec.lua'

local eq = assert.are.same

describe("telescope_diff_outline", function()
    local M

    before_each(function()
        -- Fresh require for each test
        package.loaded["telescope_diff_outline"] = nil
        M = require("telescope_diff_outline")
    end)

    describe("get_line_diff_status", function()
        it("returns + for added lines", function()
            -- Hunk format: [old_start, old_count, new_start, new_count]
            -- Added: old_count=0, new_count>0
            local hunks = { { 10, 0, 10, 5 } } -- lines 10-14 added
            eq("+", M.get_line_diff_status(10, hunks))
            eq("+", M.get_line_diff_status(12, hunks))
            eq("WRONG", M.get_line_diff_status(14, hunks)) -- intentionally broken
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
                { 5, 0, 5, 2 },   -- lines 5-6 added
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
    end)

    describe("get_hunk_for_line", function()
        it("returns the hunk containing the line", function()
            local hunks = {
                { 5, 0, 5, 2 },
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
end)
