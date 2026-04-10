--- Telescope file pickers with async git file-status markers.
---
--- This module is the UI layer for `git_file_status.lua`.
---
--- It decorates file-oriented Telescope entries with a leading marker column:
---   + added/untracked
---   - deleted
---   ~ modified/mixed/rename/binary
---
--- Pickers wrapped here:
---   - `find_files` (`O`, `<space>O`)
---   - `buffers` (`T`)
---
--- UX guarantees:
---   - marker data fetch is asynchronous and off the critical path
---   - pickers open immediately even when git status is slow (large repos)
---   - cached marker snapshots render first; background refresh repaints later

local api = vim.api
local uv = vim.uv

local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")
local make_entry = require("telescope.make_entry")

local git_file_status = require_local("git_file_status")

local M = {}

--- @return string
local function cwd()
    return uv.cwd() or vim.fn.getcwd()
end

--- @param marker string|nil
--- @return string|nil
local function marker_hl_group(marker)
    if marker == "+" then
        return "GitGutterAdd"
    elseif marker == "~" then
        return "GitGutterChange"
    elseif marker == "-" then
        return "GitGutterDelete"
    end
    return nil
end

--- @param entry table
--- @return string|nil
function M.get_entry_path(entry)
    if type(entry.path) == "string" and entry.path ~= "" then
        return entry.path
    end
    if type(entry.filename) == "string" and entry.filename ~= "" then
        return entry.filename
    end
    if type(entry.value) == "string" and entry.value ~= "" then
        return entry.value
    end
    return nil
end

--- @param base_entry_maker function
--- @param picker_cwd string
--- @param diff_base string
--- @return function
function M.make_marked_entry_maker(base_entry_maker, picker_cwd, diff_base)
    local displayer = entry_display.create({
        separator = " ",
        items = {
            { width = 1 },
            { remaining = true },
        },
    })

    return function(item)
        local entry = base_entry_maker(item)
        if entry == nil then
            return nil
        end

        local orig_display = entry.display
        entry.display = function(e)
            local marker = git_file_status.lookup_marker(
                picker_cwd,
                diff_base,
                M.get_entry_path(e)
            )
            local display_text, orig_hl
            if type(orig_display) == "function" then
                display_text, orig_hl = orig_display(e)
            else
                display_text = orig_display
            end

            return displayer({
                { marker or " ", marker_hl_group(marker) },
                {
                    display_text,
                    function()
                        return orig_hl or {}
                    end,
                },
            })
        end

        return entry
    end
end

--- Compose picker attach_mappings to include async marker refresh and optional
--- user mappings.
---
--- @param picker_cwd string
--- @param diff_base string
--- @param user_attach fun(prompt_bufnr: integer, map: function): boolean|nil
--- @return fun(prompt_bufnr: integer, map: function): boolean
function M.make_attach_mappings(picker_cwd, diff_base, user_attach)
    return function(prompt_bufnr, map)
        local function redraw_picker()
            local picker = action_state.get_current_picker(prompt_bufnr)
            if picker == nil then
                return
            end
            pcall(picker.refresh, picker, picker.finder, {
                reset_prompt = false,
            })
        end

        local unsubscribe = git_file_status.subscribe(
            picker_cwd,
            diff_base,
            vim.schedule_wrap(redraw_picker)
        )

        api.nvim_create_autocmd("BufWipeout", {
            buffer = prompt_bufnr,
            once = true,
            callback = unsubscribe,
        })

        local user_ok = true
        if type(user_attach) == "function" then
            user_ok = user_attach(prompt_bufnr, map) ~= false
        end
        return user_ok
    end
end

--- Wrapper around builtin.find_files with git marker column.
---
--- @param opts? table
function M.find_files(opts)
    opts = opts or {}

    local picker_cwd = vim.fs.normalize(opts.cwd or cwd())
    local diff_base = git_file_status.effective_diff_base()

    local user_attach = opts.attach_mappings
    local base_entry_maker = opts.entry_maker or make_entry.gen_from_file(opts)

    opts.entry_maker = M.make_marked_entry_maker(
        base_entry_maker,
        picker_cwd,
        diff_base
    )
    opts.attach_mappings = M.make_attach_mappings(
        picker_cwd,
        diff_base,
        user_attach
    )

    require("telescope.builtin").find_files(opts)
end

--- Wrapper around builtin.buffers with git marker column.
---
--- Delegates to `builtin.buffers` and injects `entry_maker` +
--- `attach_mappings`, same strategy as `find_files` above. Telescope's
--- `pickers.new` automatically composes our `attach_mappings` with the
--- builtin's (which adds `<M-d>` delete-buffer and returns `true`).
---
--- @param opts? table
function M.buffers(opts)
    opts = opts or {}

    local picker_cwd = vim.fs.normalize(opts.cwd or cwd())
    local diff_base = git_file_status.effective_diff_base()

    local user_attach = opts.attach_mappings
    local base_entry_maker = opts.entry_maker
        or make_entry.gen_from_buffer(opts)

    opts.entry_maker = M.make_marked_entry_maker(
        base_entry_maker,
        picker_cwd,
        diff_base
    )
    opts.attach_mappings = M.make_attach_mappings(
        picker_cwd,
        diff_base,
        user_attach
    )

    require("telescope.builtin").buffers(opts)
end

return M
