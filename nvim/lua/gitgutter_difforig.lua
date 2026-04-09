--- Toggle GitGutterDiffOrig split view.
---
--- Tracks the diff buffer via `b:gitgutter_difforig_bufnr` on the source
--- buffer, and a reverse reference `b:gitgutter_difforig_src_bufnr` on the
--- diff buffer. Opening calls `:GitGutterDiffOrig`. Closing wipes the diff
--- buffer and runs `:diffoff` on the source window.
---
--- Usage:
---   require_local("gitgutter_difforig").toggle()

local M = {}

--- Find a window in the current tab displaying the given buffer.
---@param bufnr number
---@return number|nil winid
local function find_win_for_buf(bufnr)
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(winid) == bufnr then
            return winid
        end
    end
    return nil
end

--- Close an active difforig split. Returns true if one was closed.
---@param src_bufnr number source (original file) buffer
---@return boolean
function M.close(src_bufnr)
    local diff_bufnr = vim.b[src_bufnr].gitgutter_difforig_bufnr
    if not diff_bufnr
        or not vim.api.nvim_buf_is_valid(diff_bufnr)
        or not find_win_for_buf(diff_bufnr)
    then
        vim.b[src_bufnr].gitgutter_difforig_bufnr = nil
        return false
    end

    vim.api.nvim_buf_delete(diff_bufnr, { force = true })
    vim.cmd.diffoff()
    vim.b[src_bufnr].gitgutter_difforig_bufnr = nil
    return true
end

--- Open a difforig split and track the new diff buffer.
---@param src_bufnr number source buffer
function M.open(src_bufnr)
    local wins_before = {}
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        wins_before[w] = true
    end

    vim.cmd.GitGutterDiffOrig()

    -- Find the newly-created window and record its buffer.
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not wins_before[w] then
            local diff_bufnr = vim.api.nvim_win_get_buf(w)
            vim.b[src_bufnr].gitgutter_difforig_bufnr = diff_bufnr
            vim.b[diff_bufnr].gitgutter_difforig_src_bufnr = src_bufnr
            return
        end
    end
end

--- Toggle the GitGutterDiffOrig split for the current buffer.
function M.toggle()
    local bufnr = vim.api.nvim_get_current_buf()

    -- Don't accidentally open a new split if we're in the diff window.
    local src_bufnr = vim.b[bufnr].gitgutter_difforig_src_bufnr
    if src_bufnr then
        if vim.api.nvim_buf_is_valid(src_bufnr) then
            M.close(src_bufnr)
        else
            -- Source buffer is gone. Just wipe the orphaned diff buffer.
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        return
    end

    if not M.close(bufnr) then
        M.open(bufnr)
    end
end

return M
