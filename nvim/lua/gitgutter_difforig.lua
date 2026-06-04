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
        vim.b[src_bufnr].gitgutter_difforig_foldlevel = nil
        vim.b[src_bufnr].gitgutter_difforig_src_winid = nil
        return false
    end

    -- Restore foldlevel on the exact window open() bumped, identified by
    -- the stashed winid. foldlevel is window-local, so when the source
    -- buffer is shown in multiple windows we can't re-derive the right
    -- one (find_win_for_buf returns the first by tab order). Fall back to
    -- find_win_for_buf only if the stash is stale (window closed or no
    -- longer showing the source buffer).
    local src_winid = vim.b[src_bufnr].gitgutter_difforig_src_winid
    if not src_winid
        or not vim.api.nvim_win_is_valid(src_winid)
        or vim.api.nvim_win_get_buf(src_winid) ~= src_bufnr
    then
        src_winid = find_win_for_buf(src_bufnr)
    end

    vim.api.nvim_buf_delete(diff_bufnr, { force = true })
    vim.cmd.diffoff()

    -- Restore the source window's pre-diff 'foldlevel'. We raised it on
    -- open to stop diff mode auto-collapsing folds; diffoff doesn't
    -- touch foldlevel, so put it back ourselves.
    local foldlevel = vim.b[src_bufnr].gitgutter_difforig_foldlevel
    if foldlevel ~= nil and src_winid then
        vim.wo[src_winid].foldlevel = foldlevel
    end
    vim.b[src_bufnr].gitgutter_difforig_foldlevel = nil
    vim.b[src_bufnr].gitgutter_difforig_src_winid = nil

    vim.b[src_bufnr].gitgutter_difforig_bufnr = nil
    return true
end

--- Open a difforig split and track the new diff buffer.
---@param src_bufnr number source buffer
function M.open(src_bufnr)
    -- Record the source window so we can stop it auto-folding too.
    -- Capture its foldlevel *before* GitGutterDiffOrig, since entering
    -- diff mode clobbers it to 0; we restore this real value on close.
    local src_winid = vim.api.nvim_get_current_win()
    local src_foldlevel = vim.wo[src_winid].foldlevel

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

            -- Diff mode forces foldmethod=diff w/ foldlevel=0, which
            -- collapses every unchanged region into a closed fold. Raise
            -- foldlevel in both diff windows so all folds start open and
            -- the full file context stays visible. We keep foldenable on
            -- (vs disabling it) so manual `zc`/`zo` still work per-fold;
            -- disabling foldenable would re-collapse every fold on the
            -- first manual fold command. Stash the source window's prior
            -- foldlevel (captured above) so close() can restore it;
            -- diffoff won't, since we overwrote the live value here.
            -- Stash the winid too: foldlevel is window-local, so close()
            -- must restore the exact window we bumped, not just any
            -- window showing this buffer.
            vim.b[src_bufnr].gitgutter_difforig_foldlevel = src_foldlevel
            vim.b[src_bufnr].gitgutter_difforig_src_winid = src_winid
            vim.wo[src_winid].foldlevel = 99
            vim.wo[w].foldlevel = 99
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
