--- Tests for telescope_git_file_status picker integration helpers.

local eq = assert.are.same
local M = require("telescope_git_file_status")

local git_file_status = require("git_file_status")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

describe("telescope_git_file_status", function()
    local orig_lookup = git_file_status.lookup_marker
    local orig_create = entry_display.create
    local orig_subscribe = git_file_status.subscribe
    local orig_get_current_picker = action_state.get_current_picker
    local temp_bufs = {}

    before_each(function()
        git_file_status._reset_for_test()
    end)

    after_each(function()
        git_file_status.lookup_marker = orig_lookup
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

    it(
        "refresh callback redraws picker and unsubscribes on prompt wipe",
        function()
            ---@type {cwd:string, diff_base:string}?
            local subscribe_args = nil
            local unsubscribe_called = false
            ---@type function?
            local subscribed_cb = nil

            ---@diagnostic disable-next-line: duplicate-set-field
            git_file_status.subscribe = function(cwd, diff_base, cb)
                subscribe_args = { cwd = cwd, diff_base = diff_base }
                subscribed_cb = cb
                return function()
                    unsubscribe_called = true
                end
            end

            local refresh_count = 0
            ---@diagnostic disable-next-line: duplicate-set-field
            action_state.get_current_picker = function()
                return {
                    finder = {},
                    refresh = function(_, _, _)
                        refresh_count = refresh_count + 1
                    end,
                }
            end

            local attach = M.make_attach_mappings("/repo", "HEAD", nil)
            local prompt_bufnr = vim.api.nvim_create_buf(false, true)
            temp_bufs[#temp_bufs + 1] = prompt_bufnr
            attach(prompt_bufnr, function(_, _, _) end)

            local got_subscribe = assert(subscribe_args)
            eq("/repo", got_subscribe.cwd)
            eq("HEAD", got_subscribe.diff_base)

            assert(subscribed_cb)()
            local ok = vim.wait(
                1000,
                function() return refresh_count == 1 end,
                20
            )
            assert.is_true(
                ok,
                "expected picker redraw from subscription callback"
            )

            vim.api.nvim_buf_delete(prompt_bufnr, { force = true })

            ok = vim.wait(
                1000,
                function() return unsubscribe_called end,
                20
            )
            assert.is_true(ok, "expected unsubscribe on prompt buffer wipe")
        end
    )
end)
