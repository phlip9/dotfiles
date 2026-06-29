--- Integration tests for gitgutter_difforig toggle.
---
--- Tests run against an ephemeral git repo using the real
--- :GitGutterDiffOrig command from the vim-gitgutter plugin.

local eq = assert.are.same
local M = require("gitgutter_difforig")

--- Create an ephemeral git repo with a committed file and unstaged edits.
---
--- `committed`/`working` default to a small 3-line file modified to 4
--- lines (first hunk at line 2, second at line 4). Pass custom content
--- for tests that need a different diff shape.
---@param committed string[]|nil committed file contents
---@param working string[]|nil working (unstaged) file contents
---@return string dir repo root
---@return string filepath absolute path to test file
local function make_test_repo(committed, working)
    committed = committed or { "line 1", "line 2", "line 3" }
    working = working or { "line 1", "modified line 2", "line 3", "new line 4" }

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
    vim.fn.writefile(committed, filepath)
    vim.fn.system({ "git", "-C", dir, "add", "." })
    vim.fn.system({ "git", "-C", dir, "commit", "-m", "init" })

    -- Unstaged modification so there's a real diff.
    vim.fn.writefile(working, filepath)

    return dir, filepath
end

--- Force gitgutter to process the current buffer and block until its
--- hunk list is populated.
---
--- gitgutter processes buffers asynchronously. We kick it off with
--- `:GitGutter`, then poll the per-buffer hunk list until it's
--- non-empty (every test file here has real changes). Waiting on the
--- hunks directly is deterministic; the `User GitGutter` autocmd can
--- fire for an unrelated/stale job, leaving this buffer's hunks empty.
local function gitgutter_process_sync()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.cmd("GitGutter")
    local ok = vim.wait(5000, function()
        local hunks = vim.fn["gitgutter#hunk#hunks"](bufnr)
        return hunks ~= nil and not vim.tbl_isempty(hunks)
    end, 50)
    assert.is_true(ok, "gitgutter did not produce hunks in time")
end

describe("gitgutter_difforig", function()
    -- TODO(phlip9): re-enable after vgit transition
    if true then
        return
    end

    local test_dir
    -- Extra repo dir for tests that build their own fixture. Cleaned in
    -- after_each so it's removed even if the test fails mid-way.
    local extra_dir

    before_each(function()
        extra_dir = nil
        local test_file
        test_dir, test_file = make_test_repo()
        vim.cmd.edit(test_file)

        -- gitgutter processes buffers asynchronously. Force it to run
        -- and block until its hunk list is populated, so DiffOrig and
        -- first-hunk jumping have the state they need.
        gitgutter_process_sync()
    end)

    after_each(function()
        vim.cmd("silent! only | silent! %bdelete!")
        vim.fn.delete(test_dir, "rf")
        if extra_dir then
            vim.fn.delete(extra_dir, "rf")
        end
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

    it("keeps folds open but enabled in both diff windows", function()
        local src_bufnr = vim.api.nvim_get_current_buf()

        M.toggle()

        -- Source window: folds open (high foldlevel) but folding still
        -- enabled, so manual zc/zo keep working per-fold.
        eq(true, vim.wo.foldenable)
        assert.is_true(vim.wo.foldlevel >= 99)

        -- Diff window: same.
        local diff_bufnr = vim.b[src_bufnr].gitgutter_difforig_bufnr
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_buf(w) == diff_bufnr then
                eq(true, vim.wo[w].foldenable)
                assert.is_true(vim.wo[w].foldlevel >= 99)
            end
        end
    end)

    it("restores original foldlevel on close", function()
        -- Non-zero, non-99 original so we'd catch either failing to
        -- restore (would read 0, the diff-clobbered value) or leaving
        -- the bumped 99 in place.
        vim.wo.foldlevel = 3

        M.toggle() -- open (raises foldlevel to 99)
        M.toggle() -- close (restores original)

        eq(3, vim.wo.foldlevel)
        eq(nil, vim.b.gitgutter_difforig_foldlevel)
    end)

    it("jumps to the first hunk when cursor is above all hunks", function()
        local src_bufnr = vim.api.nvim_get_current_buf()
        -- At the top, nearest hunk is the first one (line 2).
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        M.toggle()

        -- Focus returns to the source window after open.
        eq(src_bufnr, vim.api.nvim_get_current_buf())
        eq(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("jumps to the hunk nearest the cursor, not the first", function()
        -- Cursor on line 4 (the second hunk); nearest is line 4, not the
        -- first hunk at line 2.
        vim.api.nvim_win_set_cursor(0, { 4, 0 })

        M.toggle()

        eq(4, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("centers the view on the jumped-to hunk", function()
        -- Large file so the window can actually scroll; without zz the
        -- jumped-to line would sit near the bottom of the viewport.
        local committed = {}
        for idx = 1, 200 do
            committed[idx] = "line " .. idx
        end
        local working = vim.deepcopy(committed)
        working[120] = "modified line 120"

        local file
        extra_dir, file = make_test_repo(committed, working)
        vim.cmd.edit(file)
        gitgutter_process_sync()
        -- Start a bit before the change so a jump is needed.
        vim.api.nvim_win_set_cursor(0, { 100, 0 })

        M.toggle()

        eq(120, vim.api.nvim_win_get_cursor(0)[1])

        -- Centered => the line sits in the middle band of the window,
        -- not pinned to the top or bottom edge.
        local winline = vim.fn.winline()
        local height = vim.api.nvim_win_get_height(0)
        assert.is_true(
            winline > height * 0.25 and winline < height * 0.75,
            string.format(
                "expected centered winline, got %d of %d", winline, height
            )
        )
    end)

    it("jumps to a deletion-only hunk at the top of the file", function()
        -- Delete the first two lines. gitgutter reports a deletion hunk
        -- with new_count == 0 and new_start == 0; hunk_line_range must
        -- clamp the jump target to line 1.
        local committed = { "line 1", "line 2", "line 3", "line 4" }
        local working = { "line 3", "line 4" }

        local file
        extra_dir, file = make_test_repo(committed, working)
        vim.cmd.edit(file)
        gitgutter_process_sync()
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        M.toggle()

        eq(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("restores foldlevel when closing from the diff window", function()
        local src_bufnr = vim.api.nvim_get_current_buf()
        vim.wo.foldlevel = 3

        M.toggle() -- open

        -- Move focus into the diff window before closing.
        local diff_bufnr = vim.b[src_bufnr].gitgutter_difforig_bufnr
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_buf(w) == diff_bufnr then
                vim.api.nvim_set_current_win(w)
                break
            end
        end

        M.toggle() -- close from the diff window

        -- Source window's original foldlevel restored, not left at 99.
        eq(src_bufnr, vim.api.nvim_get_current_buf())
        eq(3, vim.wo.foldlevel)
        eq(nil, vim.b[src_bufnr].gitgutter_difforig_foldlevel)
    end)

    it("restores foldlevel to the bumped window when buffer shown twice",
        function()
            local src_bufnr = vim.api.nvim_get_current_buf()
            local win_a = vim.api.nvim_get_current_win()
            vim.wo[win_a].foldlevel = 3

            -- A second window onto the same source buffer, with a
            -- different foldlevel. foldlevel is window-local, so close()
            -- must restore win_a (the one open bumped), not win_b.
            vim.cmd("split")
            local win_b = vim.api.nvim_get_current_win()
            vim.wo[win_b].foldlevel = 7
            assert.are.not_equal(win_a, win_b)
            eq(src_bufnr, vim.api.nvim_win_get_buf(win_b))

            -- Open the diff from window A.
            vim.api.nvim_set_current_win(win_a)
            M.toggle()
            eq(99, vim.wo[win_a].foldlevel)

            M.toggle() -- close

            -- win_a restored to its own original; win_b untouched.
            eq(3, vim.wo[win_a].foldlevel)
            eq(7, vim.wo[win_b].foldlevel)
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
