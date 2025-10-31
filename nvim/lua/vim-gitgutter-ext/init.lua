-- vim-gitgutter extensions
-- * cross-buffer `GitGutter{Next,Prev}Hunk` motions
local M = {}

-- Gather hunks from all listed buffers plus the current buffer (even if
-- unlisted) so we have a deterministic iteration order.
local function collect_gitgutter_state()
    local sequence = {}
    local hunks_by_buf = {}
    local has_hunks = false

    for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
        if info.loaded == 1 then
            table.insert(sequence, info.bufnr)
            local hunks = vim.fn["gitgutter#hunk#hunks"](info.bufnr)
            if type(hunks) ~= "table" then
                hunks = {}
            end
            if #hunks > 0 then
                hunks_by_buf[info.bufnr] = hunks
                has_hunks = true
            end
        end
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local found_current = false
    for _, bufnr in ipairs(sequence) do
        if bufnr == current_buf then
            found_current = true
            break
        end
    end
    if not found_current then
        -- Ensure the current buffer is considered first for forward motion.
        table.insert(sequence, 1, current_buf)
        if hunks_by_buf[current_buf] == nil then
            local hunks = vim.fn["gitgutter#hunk#hunks"](current_buf)
            if type(hunks) ~= "table" then
                hunks = {}
            end
            if #hunks > 0 then
                hunks_by_buf[current_buf] = hunks
                has_hunks = true
            end
        end
    end

    return sequence, hunks_by_buf, has_hunks
end

local function find_next_hunk_target(bufnr, line, count, sequence, hunks_by_buf)
    local remaining = count
    local past_current = false

    for _, listed_bufnr in ipairs(sequence) do
        local hunks = hunks_by_buf[listed_bufnr]
        if listed_bufnr == bufnr then
            past_current = true
            if hunks then
                for index, hunk in ipairs(hunks) do
                    local start_line = hunk[3] or 0
                    if start_line > line then
                        remaining = remaining - 1
                        if remaining == 0 then
                            -- Within the current buffer and past the cursor.
                            return {
                                bufnr = listed_bufnr,
                                hunk = hunk,
                                index = index,
                                total = #hunks,
                            }
                        end
                    end
                end
            end
        elseif past_current and hunks then
            for index, hunk in ipairs(hunks) do
                remaining = remaining - 1
                if remaining == 0 then
                    -- First hunk in any subsequent buffer.
                    return {
                        bufnr = listed_bufnr,
                        hunk = hunk,
                        index = index,
                        total = #hunks,
                    }
                end
            end
        end
    end
end

local function find_prev_hunk_target(bufnr, line, count, sequence, hunks_by_buf)
    local remaining = count
    local before_current = false

    for idx = #sequence, 1, -1 do
        local listed_bufnr = sequence[idx]
        local hunks = hunks_by_buf[listed_bufnr]
        if listed_bufnr == bufnr then
            before_current = true
            if hunks then
                for index = #hunks, 1, -1 do
                    local hunk = hunks[index]
                    local start_line = hunk[3] or 0
                    local cmp_line = line
                    if start_line == 0 then
                        start_line = 1
                    end
                    if cmp_line == 0 then
                        cmp_line = 1
                    end
                    if start_line < cmp_line then
                        remaining = remaining - 1
                        if remaining == 0 then
                            -- Within the current buffer and before the cursor.
                            return {
                                bufnr = listed_bufnr,
                                hunk = hunk,
                                index = index,
                                total = #hunks,
                            }
                        end
                    end
                end
            end
        elseif before_current and hunks then
            for index = #hunks, 1, -1 do
                remaining = remaining - 1
                if remaining == 0 then
                    -- First hunk encountered while iterating backwards.
                    return {
                        bufnr = listed_bufnr,
                        hunk = hunks[index],
                        index = index,
                        total = #hunks,
                    }
                end
            end
        end
    end
end

local function jump_to_hunk_target(target)
    local bufnr = target.bufnr
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
        vim.fn.win_gotoid(winid)
    else
        vim.api.nvim_set_current_buf(bufnr)
    end

    local start_line = target.hunk[3] or 0
    -- GitGutter encodes deleted-leading-lines as starting at 0; jump to line 1.
    if start_line == 0 then
        start_line = 1
    end
    vim.api.nvim_win_set_cursor(0, { start_line, 0 })

    if string.find("," .. vim.o.foldopen .. ",", ",block,") then
        vim.cmd("normal! zv")
    end

    local show_msg = vim.g.gitgutter_show_msg_on_hunk_jumping
    if show_msg == nil or show_msg ~= 0 then
        vim.cmd("redraw")
        vim.api.nvim_echo({ { string.format("Hunk %d of %d", target.index, target.total), "" } }, false, {})
    end

    if vim.fn["gitgutter#hunk#is_preview_window_open"]() == 1 then
        vim.fn["gitgutter#hunk#preview"]()
    end
end

-- Top-level fn for next/prev navigation; honors counts and stops when out.
local function move_hunk_all_bufs(direction, count)
    count = tonumber(count) or 1
    if count < 1 then
        count = 1
    end

    local sequence, hunks_by_buf, has_hunks = collect_gitgutter_state()
    if not has_hunks then
        vim.fn["gitgutter#utility#warn"]("No hunks")
        return
    end

    local current_buf = vim.api.nvim_get_current_buf()
    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local target

    if direction == "next" then
        target = find_next_hunk_target(current_buf, current_line, count, sequence, hunks_by_buf)
        if not target then
            vim.fn["gitgutter#utility#warn"]("No more next hunks")
            return
        end
    else
        target = find_prev_hunk_target(current_buf, current_line, count, sequence, hunks_by_buf)
        if not target then
            vim.fn["gitgutter#utility#warn"]("No more prev hunks")
            return
        end
    end

    jump_to_hunk_target(target)
end

function M.next_hunk_all_bufs(count)
    move_hunk_all_bufs("next", count or vim.v.count1)
end

function M.prev_hunk_all_bufs(count)
    move_hunk_all_bufs("prev", count or vim.v.count1)
end

return M
