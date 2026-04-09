--- Integration tests for gitgutter_difforig toggle.
---
--- Tests run against an ephemeral git repo using the real
--- :GitGutterDiffOrig command from the vim-gitgutter plugin.

local eq = assert.are.same

--- Create an ephemeral git repo with a committed file and unstaged edits.
---@return string dir repo root
---@return string filepath absolute path to test file
local function make_test_repo()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.system({ "git", "-C", dir, "init" })
    vim.fn.system({
        "git", "-C", dir, "config", "user.email", "test@test.com",
    })
    vim.fn.system({
        "git", "-C", dir, "config", "user.name", "Test",
    })

    local filepath = dir .. "/test.txt"
    vim.fn.writefile({ "line 1", "line 2", "line 3" }, filepath)
    vim.fn.system({ "git", "-C", dir, "add", "." })
    vim.fn.system({ "git", "-C", dir, "commit", "-m", "init" })

    -- Unstaged modification so there's a real diff.
    vim.fn.writefile(
        { "line 1", "modified line 2", "line 3", "new line 4" },
        filepath
    )

    return dir, filepath
end

--- Force gitgutter to process the current buffer and block until done.
---
--- Listens for the `User GitGutter` autocmd that gitgutter fires after
--- it finishes updating signs, then kicks off processing with
--- `:GitGutter`. Fails the test if the event doesn't arrive.
local function gitgutter_process_sync()
    local done = false
    local au = vim.api.nvim_create_autocmd("User", {
        pattern = "GitGutter",
        once = true,
        callback = function() done = true end,
    })
    vim.cmd("GitGutter")
    local ok = vim.wait(5000, function() return done end, 50)
    pcall(vim.api.nvim_del_autocmd, au)
    assert.is_true(ok, "gitgutter did not finish processing in time")
end

describe("gitgutter_difforig", function()
    local M
    local test_dir

    before_each(function()
        package.loaded["gitgutter_difforig"] = nil
        M = require("gitgutter_difforig")

        local test_file
        test_dir, test_file = make_test_repo()
        vim.cmd.edit(test_file)

        -- gitgutter processes buffers asynchronously. Force it to
        -- run and wait for the `User GitGutter` event, so its
        -- internal state (repo path, diff base) is populated for
        -- DiffOrig.
        gitgutter_process_sync()
    end)

    after_each(function()
        vim.cmd("silent! only | silent! %bdelete!")
        vim.fn.delete(test_dir, "rf")
    end)

    it("opens diff split on first toggle", function()
        local src_bufnr = vim.api.nvim_get_current_buf()
        local win_count = #vim.api.nvim_tabpage_list_wins(0)

        M.toggle()

        eq(win_count + 1, #vim.api.nvim_tabpage_list_wins(0))
        eq(true, vim.wo.diff)

        local diff_bufnr = vim.b[src_bufnr].gitgutter_difforig_bufnr
        assert.is_truthy(diff_bufnr)
        eq("nofile", vim.bo[diff_bufnr].buftype)
    end)

    it("diff buffer records reverse reference to source", function()
        local src_bufnr = vim.api.nvim_get_current_buf()
        M.toggle()

        local diff_bufnr = vim.b[src_bufnr].gitgutter_difforig_bufnr
        assert.is_truthy(diff_bufnr)
        eq(src_bufnr, vim.b[diff_bufnr].gitgutter_difforig_src_bufnr)
    end)

    it("closes diff split on second toggle", function()
        M.toggle() -- open
        local win_count = #vim.api.nvim_tabpage_list_wins(0)

        M.toggle() -- close

        eq(win_count - 1, #vim.api.nvim_tabpage_list_wins(0))
        eq(false, vim.wo.diff)
        eq(nil, vim.b.gitgutter_difforig_bufnr)
    end)

    it("closes diff split when toggled from the diff window", function()
        local src_bufnr = vim.api.nvim_get_current_buf()
        M.toggle() -- open

        local diff_bufnr = vim.b[src_bufnr].gitgutter_difforig_bufnr
        assert.is_truthy(diff_bufnr)

        -- Move focus to the diff window.
        ---@type integer?
        local diff_win = nil
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_buf(w) == diff_bufnr then
                diff_win = w
                break
            end
        end
        assert(diff_win ~= nil, "expected diff window to exist")
        vim.api.nvim_set_current_win(diff_win)
        eq(diff_bufnr, vim.api.nvim_get_current_buf())

        local win_count = #vim.api.nvim_tabpage_list_wins(0)

        M.toggle() -- close from diff window

        eq(win_count - 1, #vim.api.nvim_tabpage_list_wins(0))
        eq(src_bufnr, vim.api.nvim_get_current_buf())
        eq(false, vim.wo.diff)
        eq(nil, vim.b[src_bufnr].gitgutter_difforig_bufnr)
    end)

    it("re-opens after diff buffer is manually closed", function()
        M.toggle() -- open
        local first_diff = vim.b.gitgutter_difforig_bufnr

        -- Simulate user doing :bd on the diff window.
        vim.api.nvim_buf_delete(first_diff, { force = true })

        M.toggle() -- should detect stale state and re-open

        local second_diff = vim.b.gitgutter_difforig_bufnr
        assert.is_truthy(second_diff)
        assert.are.not_equal(first_diff, second_diff)
        eq(true, vim.wo.diff)
    end)

    it("diff buffer contains the committed version", function()
        M.toggle()

        local diff_bufnr = vim.b.gitgutter_difforig_bufnr
        local lines = vim.api.nvim_buf_get_lines(
            diff_bufnr, 0, -1, false
        )
        eq({ "line 1", "line 2", "line 3" }, lines)
    end)
end)
