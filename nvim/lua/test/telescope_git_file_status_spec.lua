--- Tests for telescope_git_file_status picker integration helpers.

local eq = assert.are.same
local M = require("telescope_git_file_status")

local git_file_status = require("git_file_status")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

--- Stub picker returned by get_current_picker in async-refresh tests.
--- @return table picker, fun():integer get_refresh_count, fun():function? get_completion_cb
local function make_stub_picker()
    local refresh_count = 0
    local completion_cb = nil
    local picker = {
        refresh = function(_, _, _)
            refresh_count = refresh_count + 1
        end,
        register_completion_callback = function(_, cb)
            completion_cb = cb
        end,
    }
    return picker,
        function() return refresh_count end,
        function() return completion_cb end
end

describe("telescope_git_file_status", function()
    local orig_lookup = git_file_status.lookup_marker
    local orig_is_cache_fresh = git_file_status.is_cache_fresh
    local orig_create = entry_display.create
    local orig_subscribe = git_file_status.subscribe
    local orig_get_current_picker = action_state.get_current_picker
    local temp_bufs = {}

    before_each(function()
        git_file_status._reset_for_test()
    end)

    after_each(function()
        git_file_status.lookup_marker = orig_lookup
        git_file_status.is_cache_fresh = orig_is_cache_fresh
        entry_display.create = orig_create
        git_file_status.subscribe = orig_subscribe
        action_state.get_current_picker = orig_get_current_picker
        for _, bufnr in ipairs(temp_bufs) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        end
        temp_bufs = {}
    end)

    it("extracts entry path from path/filename/value fields", function()
        eq("a.lua", M.get_entry_path({ path = "a.lua", filename = "b.lua" }))
        eq("b.lua", M.get_entry_path({ filename = "b.lua", value = "c.lua" }))
        eq("c.lua", M.get_entry_path({ value = "c.lua" }))
        eq(nil, M.get_entry_path({}))
    end)

    it("prepends marker column to entry display", function()
        git_file_status.lookup_marker = function()
            return "+"
        end
        ---@diagnostic disable-next-line: duplicate-set-field
        entry_display.create = function(_)
            return function(columns)
                local text = columns[2]
                if type(text) == "table" then
                    text = text[1]
                end
                return columns[1][1] .. " " .. text
            end
        end

        local base_entry_maker = function(item)
            return {
                value = item,
                path = item,
                display = function()
                    return item
                end,
            }
        end

        local maker = M.make_marked_entry_maker(
            base_entry_maker,
            "/repo",
            "HEAD"
        )
        local entry = maker("tracked.lua")
        local rendered = entry.display(entry)

        assert.is_truthy(type(rendered) == "string")
        assert.is_truthy(rendered:find("+", 1, true) ~= nil)
        assert.is_truthy(rendered:find("tracked.lua", 1, true) ~= nil)
    end)

    it("skips subscription when marker cache is fresh", function()
        ---@diagnostic disable-next-line: duplicate-set-field
        git_file_status.is_cache_fresh = function()
            return true
        end

        local subscribe_called = false
        ---@diagnostic disable-next-line: duplicate-set-field
        git_file_status.subscribe = function()
            subscribe_called = true
            return function() end
        end

        ---@diagnostic disable-next-line: duplicate-set-field
        action_state.get_current_picker = function()
            return { register_completion_callback = function() end }
        end

        local attach = M.make_attach_mappings("/repo", "HEAD", nil)
        local prompt_bufnr = vim.api.nvim_create_buf(false, true)
        temp_bufs[#temp_bufs + 1] = prompt_bufnr
        attach(prompt_bufnr, function(_, _, _) end)

        eq(false, subscribe_called, "must not subscribe with fresh cache")
    end)

    it("defers refresh until finder completes, then unsubscribes", function()
        local unsubscribe_called = false
        ---@type function?
        local subscribed_cb = nil

        ---@diagnostic disable-next-line: duplicate-set-field
        git_file_status.subscribe = function(_, _, cb)
            subscribed_cb = cb
            return function()
                unsubscribe_called = true
            end
        end

        local picker, get_refresh_count, get_completion_cb =
            make_stub_picker()

        ---@diagnostic disable-next-line: duplicate-set-field
        action_state.get_current_picker = function()
            return picker
        end

        local attach = M.make_attach_mappings("/repo", "HEAD", nil)
        local prompt_bufnr = vim.api.nvim_create_buf(false, true)
        temp_bufs[#temp_bufs + 1] = prompt_bufnr
        attach(prompt_bufnr, function(_, _, _) end)

        -- Markers arrive while the finder is still running.
        assert(subscribed_cb)()
        vim.wait(100, function() return false end, 10)
        eq(0, get_refresh_count(), "must not refresh before finder completes")

        -- Finder completes, deferred refresh fires.
        assert(get_completion_cb())(picker)
        local ok = vim.wait(
            1000,
            function() return get_refresh_count() == 1 end,
            20
        )
        assert.is_true(ok, "expected deferred refresh after finder completes")

        -- Prompt buffer wipe triggers unsubscribe.
        vim.api.nvim_buf_delete(prompt_bufnr, { force = true })
        ok = vim.wait(
            1000,
            function() return unsubscribe_called end,
            20
        )
        assert.is_true(ok, "expected unsubscribe on prompt buffer wipe")
    end)

    -- Reproduce: telescope's `apply_config` shallow-copies opts before
    -- passing to the builtin. The builtin sets `bufnr_width` on the
    -- copy. Without pre-computation, our entry maker closure captures
    -- the original opts, so `gen_from_buffer(opts)` never sees
    -- `bufnr_width` and crashes with "attempt to perform arithmetic
    -- on field 'bufnr_width'".
    --
    -- The fix: M.buffers pre-computes bufnr_width on the original
    -- opts before gen_from_buffer captures them.
    it("buffers pre-computes bufnr_width for gen_from_buffer", function()
        local make_entry_mod = require("telescope.make_entry")
        local orig_gen = make_entry_mod.gen_from_buffer

        -- Intercept gen_from_buffer to capture the opts it receives.
        local captured_opts
        ---@diagnostic disable-next-line: duplicate-set-field
        make_entry_mod.gen_from_buffer = function(opts)
            captured_opts = opts
            -- Return a dummy entry maker; we only care about opts.
            return function()
                return nil
            end
        end

        local builtin = require("telescope.builtin")
        local orig_builtin_buffers = builtin.buffers
        ---@diagnostic disable-next-line: duplicate-set-field
        builtin.buffers = function() end

        M.buffers({})

        make_entry_mod.gen_from_buffer = orig_gen
        builtin.buffers = orig_builtin_buffers

        assert(captured_opts, "gen_from_buffer should be called")
        assert(
            captured_opts.bufnr_width,
            "opts.bufnr_width must be set before gen_from_buffer"
        )
    end)

    it("refreshes immediately when markers arrive after finder", function()
        ---@type function?
        local subscribed_cb = nil

        ---@diagnostic disable-next-line: duplicate-set-field
        git_file_status.subscribe = function(_, _, cb)
            subscribed_cb = cb
            return function() end
        end

        local picker, get_refresh_count, get_completion_cb =
            make_stub_picker()

        ---@diagnostic disable-next-line: duplicate-set-field
        action_state.get_current_picker = function()
            return picker
        end

        local attach = M.make_attach_mappings("/repo", "HEAD", nil)
        local prompt_bufnr = vim.api.nvim_create_buf(false, true)
        temp_bufs[#temp_bufs + 1] = prompt_bufnr
        attach(prompt_bufnr, function(_, _, _) end)

        -- Finder completes first (no pending markers).
        assert(get_completion_cb())(picker)
        vim.wait(100, function() return false end, 10)
        eq(0, get_refresh_count(), "no refresh when no markers pending")

        -- Markers arrive after finder -- refresh is immediate.
        assert(subscribed_cb)()
        local ok = vim.wait(
            1000,
            function() return get_refresh_count() == 1 end,
            20
        )
        assert.is_true(ok, "expected immediate refresh after finder done")
    end)
end)
