--- Worklog module -- quickly open and manage daily engineering work logs.
---
--- Work logs live in `<notes_dir>/<project>/log/<year>.md` as a single
--- file per year, with reverse-chronological day entries.
---
--- Format:
--- ```
--- ---
--- publish: false
--- tags: []
--- date: <year>-01-01
--- ---
---
--- # log <year>
---
---
--- ## <year>-<month>-<day> <weekday>
---
--- ...
--- ```

local M = {}

--- Default root directory for notes.
M.DEFAULT_NOTES_DIR = vim.env.HOME .. "/dev/notes"

--- Configured notes root directory.
---@type string
M.notes_dir = M.DEFAULT_NOTES_DIR

--- Set the notes root directory.
---@param opts? { notes_dir?: string }
function M.setup(opts)
    opts = opts or {}
    if opts.notes_dir then
        M.notes_dir = opts.notes_dir
    end
end

--- Build the path to a project's current year log file.
---@param project string e.g. "lexe", "dotfiles"
---@param year? number override year (default: current year)
---@return string path
function M.log_path(project, year)
    year = year or tonumber(os.date("%Y"))
    return M.notes_dir .. "/" .. project .. "/log/" .. year .. ".md"
end

--- Generate the YAML frontmatter + top heading for a new year log file.
---@param year number
---@return string
function M.new_file_contents(year)
    return table.concat({
        "---",
        "publish: false",
        "tags: []",
        "date: " .. year .. "-01-01",
        "---",
        "",
        "# log " .. year,
        "",
    }, "\n")
end

--- Generate today's day heading string.
---@param date? osdate override (table with year/month/day/wday fields)
---@return string heading e.g. "## 2026-02-20 Thu"
function M.day_heading(date)
    date = date or os.date("*t") --[[@as osdate]]
    local wday_names = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
    local wday = wday_names[date.wday]
    return string.format(
        "## %04d-%02d-%02d %s",
        date.year, date.month, date.day, wday
    )
end

--- Find the line number of the first `## ` day heading in a buffer.
--- Returns nil if no day heading is found.
---@param bufnr number
---@return number? line 1-indexed line number
function M.find_first_day_heading(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for idx, line in ipairs(lines) do
        if line:match("^## %d%d%d%d%-%d%d%-%d%d ") then
            return idx
        end
    end
    return nil
end

--- Find the line number of the `# log <year>` heading in a buffer.
--- Returns nil if not found.
---@param bufnr number
---@return number? line 1-indexed line number
function M.find_year_heading(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for idx, line in ipairs(lines) do
        if line:match("^# log %d%d%d%d$") then
            return idx
        end
    end
    return nil
end

--- Check if today's heading already exists in the buffer.
---@param bufnr number
---@param date? osdate
---@return boolean
function M.has_today_heading(bufnr, date)
    local heading = M.day_heading(date)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for _, line in ipairs(lines) do
        if line == heading then
            return true
        end
    end
    return false
end

--- Insert today's day heading into the current buffer.
---
--- Inserts after the `# log <year>` heading, before any existing day
--- entries. Positions cursor on the blank line after the new heading.
---
--- Does nothing if today's heading already exists.
---@param date? osdate override for testing
function M.insert_today(date)
    local bufnr = vim.api.nvim_get_current_buf()

    -- Don't insert if already present.
    if M.has_today_heading(bufnr, date) then
        vim.notify("Today's heading already exists", vim.log.levels.INFO)
        return
    end

    local heading = M.day_heading(date)

    -- Find insertion point: after `# log <year>` heading.
    local year_line = M.find_year_heading(bufnr)
    if not year_line then
        vim.notify(
            "No '# log <year>' heading found in buffer",
            vim.log.levels.ERROR
        )
        return
    end

    -- Insert: blank line, heading, two blank lines (cursor goes here).
    -- The two trailing blank lines give space to start writing.
    local insert_at = year_line -- 0-indexed line after year heading
    vim.api.nvim_buf_set_lines(
        bufnr, insert_at, insert_at, false,
        { "", "", heading, "", "" }
    )

    -- Position cursor on the blank line after the heading (ready to type).
    local cursor_line = insert_at + 4 -- 0-indexed
    vim.api.nvim_win_set_cursor(0, { cursor_line + 1, 0 })
end

--- Open a project's worklog for the current year.
---
--- Creates the file with frontmatter if it doesn't exist. Creates
--- intermediate directories as needed.
---@param project string
---@param year? number override year for testing
function M.open(project, year)
    year = year or tonumber(os.date("%Y")) --[[@as number]]
    local path = M.log_path(project, year)

    -- Create parent dirs if needed.
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    -- Create file with frontmatter if it doesn't exist.
    ---@diagnostic disable-next-line: undefined-field
    if not vim.uv.fs_stat(path) then
        local fd = io.open(path, "w")
        if fd then
            fd:write(M.new_file_contents(year))
            fd:close()
        end
    end

    vim.cmd("edit " .. vim.fn.fnameescape(path))
end

--- List all worklog files matching `<notes_dir>/*/log/<year>.md`.
---@return string[] paths
function M.list_worklogs()
    local pattern = M.notes_dir .. "/*/log/*.md"
    local files = vim.fn.glob(pattern, false, true)
    -- Sort reverse so newest year files come first.
    table.sort(files, function(a, b) return a > b end)
    return files
end

--- Open a telescope picker for all worklog files.
function M.pick()
    local ok, pickers = pcall(require, "telescope.pickers")
    if not ok then
        vim.notify("telescope.nvim required for worklog picker", vim.log.levels.ERROR)
        return
    end
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local files = M.list_worklogs()

    -- Build display entries: "project/log/YYYY.md"
    local entries = {}
    local prefix_len = #M.notes_dir + 2 -- strip notes_dir + "/"
    for _, file in ipairs(files) do
        table.insert(entries, {
            display = file:sub(prefix_len),
            path = file,
        })
    end

    pickers.new({}, {
        prompt_title = "Worklogs",
        finder = finders.new_table({
            results = entries,
            entry_maker = function(entry)
                return {
                    value = entry.path,
                    display = entry.display,
                    ordinal = entry.display,
                    path = entry.path,
                }
            end,
        }),
        sorter = conf.generic_sorter({}),
        previewer = conf.file_previewer({}),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    vim.cmd("edit " .. vim.fn.fnameescape(selection.value))
                end
            end)
            return true
        end,
    }):find()
end

return M
