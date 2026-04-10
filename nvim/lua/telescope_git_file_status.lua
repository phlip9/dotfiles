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
---   - when the cache is fresh, markers render synchronously with no
---     subscription or refresh overhead
---   - when the cache is cold (first open), markers are filled in after
---     the finder completes to avoid disrupting the oneshot fd process

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

--- Compose picker attach_mappings to include async marker refresh and
--- optional user mappings.
---
--- When the marker cache is already fresh, lookup_marker works
--- synchronously in the display function and no subscription is needed.
---
--- When the cache is cold (first open), marker data arrives
--- asynchronously. Refreshing the picker while the oneshot finder (fd)
--- is still running would close and re-use it, producing an empty result
--- set. To avoid this, we defer the refresh until the finder's initial
--- completion via `register_completion_callback`.
---
--- @param picker_cwd string
--- @param diff_base string
--- @param user_attach fun(prompt_bufnr: integer, map: function): boolean|nil
--- @return fun(prompt_bufnr: integer, map: function): boolean
function M.make_attach_mappings(picker_cwd, diff_base, user_attach)
    return function(prompt_bufnr, map)
        -- When the cache is fresh, display functions already get correct
        -- markers synchronously. Skip the subscription entirely.
        if not git_file_status.is_cache_fresh(picker_cwd, diff_base) then
            M._attach_async_refresh(prompt_bufnr, picker_cwd, diff_base)
        end

        local user_ok = true
        if type(user_attach) == "function" then
            user_ok = user_attach(prompt_bufnr, map) ~= false
        end
        return user_ok
    end
end

--- Subscribe to async marker updates and wire up a deferred picker
--- refresh. Only called when the marker cache is cold.
---
--- @param prompt_bufnr integer
--- @param picker_cwd string
--- @param diff_base string
function M._attach_async_refresh(prompt_bufnr, picker_cwd, diff_base)
    local finder_complete = false
    local markers_pending = false

    local function redraw_picker()
        local picker = action_state.get_current_picker(prompt_bufnr)
        if picker == nil then
            return
        end
        -- Pass nil for the finder so telescope re-renders entries
        -- through the existing (completed) finder without closing it.
        local ok, err = pcall(picker.refresh, picker, nil, {
            reset_prompt = false,
        })
        if not ok then
            vim.notify(
                "telescope_git_file_status: refresh error: "
                .. tostring(err),
                vim.log.levels.WARN
            )
        end
    end

    -- Detect when the finder's initial result set is ready.
    local picker = action_state.get_current_picker(prompt_bufnr)
    if picker ~= nil then
        picker:register_completion_callback(function()
            finder_complete = true
            if markers_pending then
                markers_pending = false
                -- Schedule after process_complete finishes its own
                -- housekeeping (cursor placement, status, etc.).
                vim.schedule(redraw_picker)
            end
        end)
    end

    local function on_markers_updated()
        if finder_complete then
            redraw_picker()
        else
            markers_pending = true
        end
    end

    local unsubscribe = git_file_status.subscribe(
        picker_cwd,
        diff_base,
        vim.schedule_wrap(on_markers_updated)
    )

    api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = unsubscribe,
    })
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
--- `gen_from_buffer` reads `opts.bufnr_width` at construction time and
--- inside each entry's display function. Normally the builtin computes
--- this, but telescope's `apply_config` shallow-copies opts before the
--- builtin runs, so the builtin's assignment never reaches the table
--- our closure captured. We pre-compute `bufnr_width` here so it's on
--- the original opts and propagates through the copy.
---
--- @param opts? table
function M.buffers(opts)
    opts = opts or {}

    local picker_cwd = vim.fs.normalize(opts.cwd or cwd())
    local diff_base = git_file_status.effective_diff_base()

    -- Pre-compute bufnr_width so gen_from_buffer sees it on the
    -- original opts table (see module comment above).
    if not opts.bufnr_width then
        local bufs = vim.tbl_filter(function(bufnr)
            return vim.fn.buflisted(bufnr) == 1
        end, vim.api.nvim_list_bufs())
        if #bufs > 0 then
            opts.bufnr_width = #tostring(math.max(unpack(bufs)))
        end
    end

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
