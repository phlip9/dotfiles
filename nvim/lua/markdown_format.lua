--- Smarter markdown formatting
---
--- Neovim's built-in `gw` ignores 'formatexpr' and reflows code, tables,
--- headings, HTML, and other semantic blocks into invalid Markdown. This module
--- replaces `gw` for Markdown buffers and runs the native formatter only on
--- paragraph nodes found by the Markdown tree-sitter parser.

local M = {}

local cursor_namespace = vim.api.nvim_create_namespace("markdown_format_cursor")
--- @type { bufnr: integer, position: integer[] }?
local pending_operator_cursor
local opaque_node_types = {
    atx_heading = true,
    fenced_code_block = true,
    html_block = true,
    indented_code_block = true,
    link_reference_definition = true,
    minus_metadata = true,
    pipe_table = true,
    plus_metadata = true,
    setext_heading = true,
    thematic_break = true,
}

-- The stock Markdown pattern omits CommonMark's `1)` list marker. Keeping the
-- reference-definition branch avoids changing native `gq` behavior.
local markdown_formatlistpat =
[=[^\s*\%(\d\+[.)]\|[-*+]\)\s\+\|^\[^\ze[^\]]\+\]:\&^.\{4\}]=]

--- Add reflowable paragraph ranges below `node` to `ranges`.
--- @param node TSNode
--- @param ranges { first: integer, last: integer }[]
local function collect_reflow_ranges(node, ranges)
    if opaque_node_types[node:type()] then
        return
    end

    if node:type() == "paragraph" then
        local start_row, _, end_row, end_column = node:range()
        local last_line = end_row + (end_column > 0 and 1 or 0)
        table.insert(ranges, { first = start_row + 1, last = last_line })
        return
    end

    for child in node:iter_children() do
        collect_reflow_ranges(child, ranges)
    end
end

--- Return reflowable paragraph ranges from the current Markdown syntax tree.
--- @param bufnr integer
--- @return { first: integer, last: integer }[]
local function get_reflow_ranges(bufnr)
    local parser = assert(vim.treesitter.get_parser(bufnr, "markdown"))
    local tree = parser:parse()[1]
    assert(tree, "Markdown tree-sitter parser returned no syntax tree")

    local ranges = {}
    collect_reflow_ranges(tree:root(), ranges)
    table.sort(ranges, function(left, right)
        return left.first < right.first
    end)
    return ranges
end

--- Whether a source line ends in a Markdown hard line break.
--- @param line string
--- @return boolean
local function has_hard_line_break(line)
    if line:match("  +$") then
        return true
    end

    local trailing_backslashes = line:match("(\\+)$")
    return trailing_backslashes ~= nil and #trailing_backslashes % 2 == 1
end

--- Return paragraph ranges within `[first_line, last_line]`.
---
--- Lines carrying hard-break markers remain unchanged and split a paragraph
--- into independent ranges. Native `gw` otherwise replaces the hard break with
--- a soft space and changes the rendered document.
---
--- @param first_line integer
--- @param last_line integer
--- @param reflow_ranges { first: integer, last: integer }[]
--- @param lines string[]
--- @return { first: integer, last: integer }[]
local function get_format_ranges(first_line, last_line, reflow_ranges, lines)
    local ranges = {}
    for _, reflow in ipairs(reflow_ranges) do
        local range_first = math.max(first_line, reflow.first)
        local range_last = math.min(last_line, reflow.last)
        if range_first <= range_last then
            local next_line = range_first
            for line_number = range_first, range_last do
                if has_hard_line_break(lines[line_number]) then
                    if next_line < line_number then
                        table.insert(ranges, {
                            first = next_line,
                            last = line_number - 1,
                        })
                    end
                    next_line = line_number + 1
                end
            end
            if next_line <= range_last then
                table.insert(ranges, {
                    first = next_line,
                    last = range_last,
                })
            end
        end
    end
    return ranges
end

--- Return a stable token anchor for restoring the cursor after reflow.
---
--- Formatting changes whitespace but not prose tokens. Extmarks alone can
--- drift to a neighboring word when the native formatter replaces a line, so
--- record the occurrence of the token under the cursor as a stronger anchor.
---
--- @param lines string[]
--- @param cursor integer[] 1-indexed row and 0-indexed byte column
--- @return { token: string, occurrence: integer, offset: integer }?
local function get_cursor_token_anchor(lines, cursor)
    local cursor_line = lines[cursor[1]] or ""
    local token_start
    local token
    for start_column, candidate in cursor_line:gmatch("()(%S+)") do
        local end_column = start_column + #candidate - 1
        if cursor[2] + 1 >= start_column and cursor[2] + 1 <= end_column then
            token_start = start_column
            token = candidate
            break
        end
    end
    if not token
        or token == ">"
        or token:match("^[-+*]$")
        or token:match("^%d+[.)]$")
    then
        return nil
    end

    local occurrence = 0
    for line_number = 1, cursor[1] do
        for start_column, candidate in lines[line_number]:gmatch("()(%S+)") do
            if candidate == token then
                occurrence = occurrence + 1
            end
            if line_number == cursor[1] and start_column == token_start then
                return {
                    token = token,
                    occurrence = occurrence,
                    offset = cursor[2] - token_start + 1,
                }
            end
        end
    end
    return nil
end

--- Restore the cursor to a token anchor in the formatted buffer.
---
--- @param bufnr integer
--- @param anchor { token: string, occurrence: integer, offset: integer }
--- @return boolean restored
local function restore_cursor_token_anchor(bufnr, anchor)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local occurrence = 0
    for line_number, line in ipairs(lines) do
        for start_column, candidate in line:gmatch("()(%S+)") do
            if candidate == anchor.token then
                occurrence = occurrence + 1
                if occurrence == anchor.occurrence then
                    vim.api.nvim_win_set_cursor(0, {
                        line_number,
                        start_column - 1 + math.min(anchor.offset,
                            #candidate - 1),
                    })
                    return true
                end
            end
        end
    end
    return false
end

--- Format a line range with Neovim's built-in `gw`, bypassing mappings.
---
--- @param first_line integer
--- @param last_line integer
local function format_native(first_line, last_line)
    vim.api.nvim_win_set_cursor(0, { first_line, 0 })
    local line_motion = last_line > first_line
        and tostring(last_line - first_line) .. "j"
        or ""
    vim.cmd.normal({ args = { "V" .. line_motion .. "gw" }, bang = true })
end

--- Format selected Markdown paragraph lines while preserving semantic blocks.
---
--- Ranges are processed bottom-up so line-count changes cannot invalidate the
--- source positions of ranges that have not been formatted yet.
---
--- @param first_line integer
--- @param last_line integer
--- @param source_cursor? integer[] Cursor position from before an operator motion.
local function format_lines(first_line, last_line, source_cursor)
    local bufnr = vim.api.nvim_get_current_buf()
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    first_line = math.max(1, math.min(first_line, line_count))
    last_line = math.max(first_line, math.min(last_line, line_count))

    local cursor = source_cursor or vim.api.nvim_win_get_cursor(0)
    local source_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cursor_anchor = get_cursor_token_anchor(source_lines, cursor)
    local cursor_mark = vim.api.nvim_buf_set_extmark(
        bufnr,
        cursor_namespace,
        cursor[1] - 1,
        cursor[2],
        { right_gravity = false }
    )

    local ok, err = xpcall(function()
        local reflow_ranges = get_reflow_ranges(bufnr)
        local format_ranges = get_format_ranges(
            first_line,
            last_line,
            reflow_ranges,
            source_lines
        )
        local changed = false

        for index = #format_ranges, 1, -1 do
            if changed then
                vim.cmd("silent! undojoin")
            end

            local changedtick = vim.b.changedtick
            local range = format_ranges[index]
            format_native(range.first, range.last)
            changed = changed or vim.b.changedtick ~= changedtick
        end
    end, debug.traceback)

    local mark = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        cursor_namespace,
        cursor_mark,
        {}
    )
    vim.api.nvim_buf_del_extmark(bufnr, cursor_namespace, cursor_mark)
    local restored_to_token = cursor_anchor
        and restore_cursor_token_anchor(bufnr, cursor_anchor)
    if not restored_to_token and #mark == 2 then
        local line = vim.api.nvim_buf_get_lines(
            bufnr,
            mark[1],
            mark[1] + 1,
            false
        )[1] or ""
        vim.api.nvim_win_set_cursor(0, {
            mark[1] + 1,
            math.min(mark[2], #line),
        })
    end

    if not ok then
        error(err)
    end
end

--- Run Markdown formatting and report failures without breaking operator state.
---
--- @param first_line integer
--- @param last_line integer
--- @param source_cursor? integer[] Cursor position from before an operator motion.
local function format_lines_safe(first_line, last_line, source_cursor)
    local ok, err = xpcall(function()
        format_lines(first_line, last_line, source_cursor)
    end, debug.traceback)
    if not ok then
        vim.notify(
            "Markdown gw failed: " .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

--- Start a Markdown-aware `gw{motion}` operator.
--- @return string operator-pending keys
function M.begin_operator()
    pending_operator_cursor = {
        bufnr = vim.api.nvim_get_current_buf(),
        position = vim.api.nvim_win_get_cursor(0),
    }
    vim.go.operatorfunc = "v:lua.require'markdown_format'.format_operator"
    return "g@"
end

--- Format the lines selected by the pending operator motion.
--- @param _ string operator motion type
function M.format_operator(_)
    local first_line = vim.api.nvim_buf_get_mark(0, "[")[1]
    local last_line = vim.api.nvim_buf_get_mark(0, "]")[1]
    local bufnr = vim.api.nvim_get_current_buf()
    local source_cursor = pending_operator_cursor
        and pending_operator_cursor.bufnr == bufnr
        and pending_operator_cursor.position
        or nil
    pending_operator_cursor = nil
    format_lines_safe(first_line, last_line, source_cursor)
end

--- Format the previous visual selection.
function M.format_visual()
    local first_line = vim.api.nvim_buf_get_mark(0, "<")[1]
    local last_line = vim.api.nvim_buf_get_mark(0, ">")[1]
    format_lines_safe(
        math.min(first_line, last_line),
        math.max(first_line, last_line)
    )
end

--- Format the current line and any count-prefixed following lines.
function M.format_current_lines()
    local first_line = vim.api.nvim_win_get_cursor(0)[1]
    format_lines_safe(first_line, first_line + vim.v.count1 - 1)
end

--- Install Markdown-aware `gw` mappings for one buffer.
--- @param bufnr integer
function M.setup(bufnr)
    vim.bo[bufnr].formatlistpat = markdown_formatlistpat

    local opts = { buffer = bufnr, silent = true }
    vim.keymap.set("n", "gw", M.begin_operator,
        vim.tbl_extend("force", opts, {
            expr = true,
            desc = "format Markdown paragraphs safely",
        }))
    for _, lhs in ipairs({ "gww", "gwgw" }) do
        vim.keymap.set("n", lhs, M.format_current_lines,
            vim.tbl_extend("force", opts, {
                desc = "format Markdown paragraph lines safely",
            }))
    end
    vim.keymap.set("x", "gw",
        ":<C-U>lua require('markdown_format').format_visual()<CR>",
        vim.tbl_extend("force", opts, {
            desc = "format Markdown paragraph selection safely",
        }))
end

return M
