-- Problem: `:help` always opens in a horizontal split window, which I hate.
-- Solution: open `:help` in the current window
-- How: set some autocmds that hook the `:help` window open and make it replace
-- the current window's buffer with the `:help` buffer.

local M = {}

---@return integer
local function nvim_get_prev_win()
    ---@diagnostic disable-next-line: return-type-mismatch
    return vim.fn.win_getid(vim.fn.winnr("#"))
end

local function on_buf_enter(opts)
    -- :help open appears to work in two stages; we need to run in the first
    -- stage, before the `filetype` is assigned (?).
    if not (vim.bo.buftype == "help" and vim.bo.filetype == "") then
        return
    end

    -- replace buffer in original window with help buffer, then close new help
    -- window.

    -- get handle to original window/buffer that we're going to replace
    local orig_win = nvim_get_prev_win()

    -- the newly opened help split window
    local help_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_buf(orig_win, opts.buf)
    vim.api.nvim_win_close(help_win, false)
end

function M.on_buf_new(opts)
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = opts.buf,
        group = opts.group,
        once = true,
        callback = on_buf_enter,
    })
end

return M
