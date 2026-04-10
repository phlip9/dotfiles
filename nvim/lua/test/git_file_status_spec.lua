--- Tests for git_file_status changed-file cache and parsing.

local eq = assert.are.same
local M = require("git_file_status")

--- Create a git repo with a baseline commit.
---@return string repo_root
local function make_repo()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")

    vim.fn.system({ "git", "-C", dir, "init" })
    vim.fn.system({ "git", "-C", dir, "config", "user.email", "test@test.com" })
    vim.fn.system({ "git", "-C", dir, "config", "user.name", "Test" })

    vim.fn.writefile({ "line 1", "line 2" }, dir .. "/keep.txt")
    vim.fn.writefile({ "remove me" }, dir .. "/delete_me.txt")
    vim.fn.system({ "git", "-C", dir, "add", "." })
    vim.fn.system({ "git", "-C", dir, "commit", "-m", "init" })

    return dir
end

--- Wait for async callback completion and fail test on timeout.
---@param pred fun():boolean
local function wait_for(pred)
    local ok = vim.wait(5000, pred, 20)
    assert.is_true(ok, "timed out waiting for async status callback")
end

describe("git_file_status", function()
    before_each(function()
        M._reset_for_test()
        vim.g.gitgutter_diff_base = nil
    end)

    it("parses numstat -z rows including rename records", function()
        local stdout = table.concat({
            "2\t0\tadded.txt",
            "1\t1\tmodified.txt",
            "0\t3\tremoved.txt",
            "-\t-\tbinary.bin",
            "5\t0\t",
            "old_name.txt",
            "new_name.txt",
            "",
        }, "\0")

        local parsed = M.parse_numstat_z(stdout)

        eq(2, parsed["added.txt"].adds)
        eq(0, parsed["added.txt"].deletes)

        eq(true, parsed["binary.bin"].binary)
        eq(true, parsed["new_name.txt"].rename)
        eq(5, parsed["new_name.txt"].adds)
    end)

    it("parses untracked -z rows", function()
        local stdout = "a.txt\0dir/b.txt\0"
        eq({
            ["a.txt"] = true,
            ["dir/b.txt"] = true,
        }, M.parse_untracked_z(stdout))
    end)

    it("reduces parsed stats to +, -, and ~ markers", function()
        local markers = M.reduce_markers({
            ["added.txt"] = {
                adds = 4,
                deletes = 0,
                binary = false,
                rename = false,
            },
            ["removed.txt"] = {
                adds = 0,
                deletes = 2,
                binary = false,
                rename = false,
            },
            ["changed.txt"] = {
                adds = 3,
                deletes = 1,
                binary = false,
                rename = false,
            },
            ["renamed.txt"] = {
                adds = 1,
                deletes = 0,
                binary = false,
                rename = true,
            },
            ["binary.dat"] = {
                adds = nil,
                deletes = nil,
                binary = true,
                rename = false,
            },
        }, {
            ["new_untracked.txt"] = true,
        })

        eq("+", markers["added.txt"])
        eq("-", markers["removed.txt"])
        eq("~", markers["changed.txt"])
        eq("~", markers["renamed.txt"])
        eq("~", markers["binary.dat"])
        eq("+", markers["new_untracked.txt"])
    end)

    it("uses g:gitgutter_diff_base when configured", function()
        eq("HEAD", M.effective_diff_base())

        vim.g.gitgutter_diff_base = "origin/main"
        eq("origin/main", M.effective_diff_base())

        vim.g.gitgutter_diff_base = ""
        eq("HEAD", M.effective_diff_base())
    end)

    it("normalizes picker paths to repo-relative paths", function()
        local repo = "/tmp/repo"
        local cwd = "/tmp/repo/subdir"

        eq("subdir/a.lua", M.path_to_repo_rel(cwd, "a.lua", repo))
        eq("x/y.lua", M.path_to_repo_rel(cwd, "/tmp/repo/x/y.lua", repo))
        eq(nil, M.path_to_repo_rel(cwd, "/tmp/other/file.lua", repo))
        eq(nil, M.path_to_repo_rel(cwd, "[No Name]", repo))
    end)

    it("dedupes concurrent refreshes while one refresh is inflight", function()
        local calls = 0
        local done_fn

        local original_collect = M.collect_markers_async
        M.collect_markers_async = function(_, _, done)
            calls = calls + 1
            done_fn = done
        end

        M.refresh_async("/repo", "HEAD")
        M.refresh_async("/repo", "HEAD")
        eq(1, calls)

        done_fn({ ["f.txt"] = "+" })
        wait_for(function()
            return M._entry ~= nil and M._entry.markers["f.txt"] == "+"
        end)

        M.collect_markers_async = original_collect
    end)

    it(
        "does not invoke subscriber callback until async refresh completes",
        function()
            local callback_calls = 0

            local original_resolve = M.resolve_repo_root_async
            local original_collect = M.collect_markers_async

            M.resolve_repo_root_async = function(_, cb)
                cb("/repo")
            end

            local done_fn
            M.collect_markers_async = function(_, _, done)
                done_fn = done
            end

            M.subscribe("/repo", "HEAD", function()
                callback_calls = callback_calls + 1
            end)

            eq(0, callback_calls)
            done_fn({ ["f.lua"] = "~" })

            wait_for(function() return callback_calls == 1 end)

            M.resolve_repo_root_async = original_resolve
            M.collect_markers_async = original_collect
        end
    )

    it("unsubscribe before repo root resolves prevents leaked subscriber", function()
        local callback_calls = 0

        local original_resolve = M.resolve_repo_root_async
        local original_collect = M.collect_markers_async

        -- Capture the resolve callback so we can fire it after unsubscribe.
        local resolve_cb
        M.resolve_repo_root_async = function(_, cb)
            resolve_cb = cb
        end

        local done_fn
        M.collect_markers_async = function(_, _, done)
            done_fn = done
        end

        local unsubscribe = M.subscribe("/repo", "HEAD", function()
            callback_calls = callback_calls + 1
        end)

        -- Unsubscribe before repo root resolves (simulates fast picker close).
        unsubscribe()

        -- Now the repo root resolves — the cancelled subscriber must not be
        -- registered.
        resolve_cb("/repo")

        -- If a refresh happened to fire, it should not call the subscriber.
        if done_fn then
            done_fn({ ["f.lua"] = "~" })
        end

        -- Give any scheduled callbacks a chance to run.
        vim.wait(100, function() return false end, 10)
        eq(0, callback_calls)

        M.resolve_repo_root_async = original_resolve
        M.collect_markers_async = original_collect
    end)

    it("collects staged, unstaged, deleted, and untracked markers", function()
        local repo = make_repo()

        -- Modified (mixed add/delete) -> ~
        vim.fn.writefile({ "line 1", "line two changed" }, repo .. "/keep.txt")

        -- Added and staged -> +
        vim.fn.writefile({ "new file" }, repo .. "/staged_add.txt")
        vim.fn.system({ "git", "-C", repo, "add", "staged_add.txt" })

        -- Deleted and staged -> -
        vim.fn.system({ "git", "-C", repo, "rm", "delete_me.txt" })

        -- Untracked -> +
        vim.fn.writefile({ "scratch" }, repo .. "/scratch.txt")

        local done = false
        local markers = nil
        M.collect_markers_async(repo, "HEAD", function(result)
            markers = result
            done = true
        end)

        wait_for(function() return done end)
        local got = assert(markers, "expected marker map")
        eq("~", got["keep.txt"])
        eq("+", got["staged_add.txt"])
        eq("-", got["delete_me.txt"])
        eq("+", got["scratch.txt"])

        vim.fn.delete(repo, "rf")
    end)
end)
