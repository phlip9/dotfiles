local M = {}

---@param modname string
function M.rerequire(modname)
    package.loaded[modname] = nil
    return require(modname)
end

---open a new temporary, unnamed buffer filled with `contents`
---@param contents string
function M.nvim_open_tmp_buf(contents)
    local lines = vim.split(contents, "\n", { plain = true })

    vim.cmd("enew")
    local bufnr = vim.api.nvim_get_current_buf()
    -- don't list this buffer in the buffer list
    vim.api.nvim_buf_set_option(bufnr, "buflisted", false)
    -- unload this buffer when it's no longer displayed in a window
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "unload")
    -- not a real file, don't try to write or swap
    vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(bufnr, "filetype", "lua")

    -- note: we can't set the buffer contents to a string with newlines, so we
    -- have to split first.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
end

---@return string
function M.get_loc()
    local me = debug.getinfo(1, "S")
    local level = 2
    local info = debug.getinfo(level, "S")
    while info and (info.source == me.source or info.source == "@" .. vim.env.MYVIMRC or info.what ~= "Lua") do
        level = level + 1
        info = debug.getinfo(level, "S")
    end
    info = info or me
    local source = info.source:sub(2)
    source = vim.loop.fs_realpath(source) or source
    return source .. ":" .. info.linedefined
end

---@param value any
---@param opts? {loc:string, bt?:boolean}
function M._dbg(value, opts)
    opts = opts or {}
    opts.loc = opts.loc or M.get_loc()
    if vim.in_fast_event() then
        return vim.schedule(function()
            M._dump(value, opts)
        end)
    end
    ---@diagnostic disable-next-line: assign-type-mismatch
    opts.loc = vim.fn.fnamemodify(opts.loc, ":~:.")
    local msg = "Debug: " .. opts.loc .. "\n\n"
    msg = msg .. vim.inspect(value)
    if opts.bt then
        msg = msg .. "\n\n" .. debug.traceback("", 2)
    end
    M.nvim_open_tmp_buf(msg)
end

---pretty-print the args and display them in a new temporary buffer in the
---current window.
function M.dbg(...)
    local value = { ... }
    if vim.tbl_isempty(value) then
        ---@diagnostic disable-next-line: cast-local-type
        value = nil
    else
        value = vim.tbl_islist(value) and vim.tbl_count(value) <= 1 and value[1] or value
    end
    M._dbg(value)
    return value
end

return M
