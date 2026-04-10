--- Tests for telescope_git_file_status picker integration helpers.

local eq = assert.are.same
local M = require("telescope_git_file_status")

local git_file_status = require("git_file_status")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

describe("telescope_git_file_status", function()
    before_each(function()
        git_file_status._reset_for_test()
    end)

    it("extracts entry path from path/filename/value fields", function()
        eq("a.lua", M.get_entry_path({ path = "a.lua", filename = "b.lua" }))
        eq("b.lua", M.get_entry_path({ filename = "b.lua", value = "c.lua" }))
        eq("c.lua", M.get_entry_path({ value = "c.lua" }))
        eq(nil, M.get_entry_path({}))
    end)

    it("prepends marker column to entry display", function()
        local orig_lookup = git_file_status.lookup_marker
        local orig_create = entry_display.create
        git_file_status.lookup_marker = function()
            return "+"
        end
        entry_display.create = function(_)
            return function(columns)
                return columns[1][1] .. " " .. columns[2]
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

        git_file_status.lookup_marker = orig_lookup
        entry_display.create = orig_create
    end)

    it(
        "refresh callback redraws picker and unsubscribes on prompt wipe",
        function()
            local subscribe_args = nil
            local unsubscribe_args = nil
            local subscribed_cb = nil

            local orig_subscribe = git_file_status.subscribe
            local orig_unsubscribe = git_file_status.unsubscribe
            local orig_get_current_picker = action_state.get_current_picker

            git_file_status.subscribe = function(cwd, diff_base, cb)
                subscribe_args = { cwd = cwd, diff_base = diff_base }
                subscribed_cb = cb
                return 42
            end

            git_file_status.unsubscribe = function(cwd, diff_base, id)
                unsubscribe_args = {
                    cwd = cwd,
                    diff_base = diff_base,
                    id = id,
                }
            end

            local refresh_count = 0
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
            attach(prompt_bufnr, function(_, _, _) end)

            assert.is_truthy(subscribe_args ~= nil)
            eq("/repo", subscribe_args.cwd)
            eq("HEAD", subscribe_args.diff_base)

            subscribed_cb()
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
                function() return unsubscribe_args ~= nil end,
                20
            )
            assert.is_true(ok, "expected unsubscribe on prompt buffer wipe")
            eq(42, unsubscribe_args.id)
            eq("/repo", unsubscribe_args.cwd)
            eq("HEAD", unsubscribe_args.diff_base)

            git_file_status.subscribe = orig_subscribe
            git_file_status.unsubscribe = orig_unsubscribe
            action_state.get_current_picker = orig_get_current_picker
        end
    )
end)
