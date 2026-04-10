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

local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config").values
local entry_display = require("telescope.pickers.entry_display")
local finders = require("telescope.finders")
local make_entry = require("telescope.make_entry")
local pickers = require("telescope.pickers")

local git_file_status = require_local("git_file_status")

local M = {}

--- Keep compatibility with Telescope's historical `only_cwd` option alias.
--- @param opts table
--- @return table
local function apply_cwd_only_aliases(opts)
    local has_cwd_only = opts.cwd_only ~= nil
    local has_only_cwd = opts.only_cwd ~= nil
    if has_only_cwd and not has_cwd_only then
        opts.cwd_only = opts.only_cwd
        opts.only_cwd = nil
    end
    return opts
end

--- @param bufname string
--- @param cwd string
--- @return boolean
local function buf_in_cwd(bufname, cwd)
    local norm_buf = vim.fs.normalize(bufname)
    local norm_cwd = vim.fs.normalize(cwd)
    if norm_cwd:sub(-1) ~= "/" then
        norm_cwd = norm_cwd .. "/"
    end
    return norm_buf:sub(1, #norm_cwd) == norm_cwd
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
            local display_text
            if type(orig_display) == "function" then
                display_text = orig_display(e)
            else
                display_text = orig_display
            end

            return displayer({
                { marker or " ", marker_hl_group(marker) },
                display_text,
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

        local subscriber_id = git_file_status.subscribe(
            picker_cwd,
            diff_base,
            vim.schedule_wrap(redraw_picker)
        )

        api.nvim_create_autocmd("BufWipeout", {
            buffer = prompt_bufnr,
            once = true,
            callback = function()
                git_file_status.unsubscribe(
                    picker_cwd,
                    diff_base,
                    subscriber_id
                )
            end,
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

    local picker_cwd = vim.fs.normalize(opts.cwd or vim.uv.cwd())
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
--- This is implemented locally instead of calling builtin.buffers directly so
--- we can compose our async refresh attach_mappings with buffer-specific
--- mappings (like `<M-d>` delete buffer).
---
--- @param opts? table
function M.buffers(opts)
    opts = opts or {}
    opts = apply_cwd_only_aliases(opts)

    local picker_cwd = vim.fs.normalize(opts.cwd or vim.uv.cwd())
    local diff_base = git_file_status.effective_diff_base()

    local bufnrs = vim.tbl_filter(function(bufnr)
        if vim.fn.buflisted(bufnr) ~= 1 then
            return false
        end
        if opts.show_all_buffers == false
            and not api.nvim_buf_is_loaded(bufnr)
        then
            return false
        end
        if opts.ignore_current_buffer
            and bufnr == api.nvim_get_current_buf()
        then
            return false
        end

        local bufname = api.nvim_buf_get_name(bufnr)
        if opts.cwd_only and not buf_in_cwd(bufname, vim.uv.cwd()) then
            return false
        end

        if not opts.cwd_only
            and opts.cwd
            and not buf_in_cwd(bufname, opts.cwd)
        then
            return false
        end
        return true
    end, api.nvim_list_bufs())

    if not next(bufnrs) then
        return
    end

    if opts.sort_mru then
        table.sort(bufnrs, function(a, b)
            local a_last = vim.fn.getbufinfo(a)[1].lastused
            local b_last = vim.fn.getbufinfo(b)[1].lastused
            return a_last > b_last
        end)
    end

    if type(opts.sort_buffers) == "function" then
        table.sort(bufnrs, opts.sort_buffers)
    end

    local buffers = {}
    local default_selection_idx = 1
    for i, bufnr in ipairs(bufnrs) do
        local flag = bufnr == vim.fn.bufnr("") and "%"
            or (bufnr == vim.fn.bufnr("#") and "#" or " ")

        if opts.sort_lastused
            and not opts.ignore_current_buffer
            and flag == "#"
        then
            default_selection_idx = 2
        end

        local element = {
            bufnr = bufnr,
            flag = flag,
            info = vim.fn.getbufinfo(bufnr)[1],
        }

        if opts.sort_lastused and (flag == "#" or flag == "%") then
            local insert_idx =
                ((buffers[1] ~= nil and buffers[1].flag == "%") and 2 or 1)
            table.insert(buffers, insert_idx, element)
        else
            if opts.select_current and flag == "%" then
                default_selection_idx = i
            end
            table.insert(buffers, element)
        end
    end

    if not opts.bufnr_width then
        local max_bufnr = math.max(unpack(bufnrs))
        opts.bufnr_width = #tostring(max_bufnr)
    end

    local base_entry_maker = opts.entry_maker
        or make_entry.gen_from_buffer(opts)
    local marked_entry_maker = M.make_marked_entry_maker(
        base_entry_maker,
        picker_cwd,
        diff_base
    )

    local refresh_attach = M.make_attach_mappings(
        picker_cwd,
        diff_base,
        opts.attach_mappings
    )

    pickers.new(opts, {
        prompt_title = "Buffers",
        finder = finders.new_table({
            results = buffers,
            entry_maker = marked_entry_maker,
        }),
        previewer = conf.grep_previewer(opts),
        sorter = conf.generic_sorter(opts),
        default_selection_index = default_selection_idx,
        attach_mappings = function(prompt_bufnr, map)
            map({ "i", "n" }, "<M-d>", actions.delete_buffer)
            return refresh_attach(prompt_bufnr, map)
        end,
    }):find()
end

return M
