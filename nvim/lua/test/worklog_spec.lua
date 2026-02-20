--- Tests for worklog module.
---
--- Run with: nvim --headless -c 'PlenaryBustedFile nvim/lua/test/worklog_spec.lua'

local eq = assert.are.same

--- Create a temp directory for test notes.
---@return string dir path to temp directory
local function make_temp_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

--- Remove a temp directory and all its contents.
---@param dir string
local function rm_temp_dir(dir)
    vim.fn.delete(dir, "rf")
end

--- Helper: set buffer lines and return bufnr.
---@param lines string[]
---@return number bufnr
local function buf_with_lines(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
end

--- Helper: get all lines from buffer.
---@param bufnr number
---@return string[]
local function buf_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Helper: delete a test buffer.
---@param bufnr number
local function buf_delete(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
end

--- A fixed date for deterministic tests: 2026-02-20 (Friday).
---@return osdate
local function test_date()
    return os.date("*t", os.time({
        year = 2026, month = 2, day = 20,
    })) --[[@as osdate]]
end

--- A second fixed date: 2026-02-18 (Wednesday).
---@return osdate
local function test_date_2()
    return os.date("*t", os.time({
        year = 2026, month = 2, day = 18,
    })) --[[@as osdate]]
end

describe("worklog", function()
    ---@module "worklog"
    local worklog

    before_each(function()
        -- Force re-require to reset module state.
        package.loaded["worklog"] = nil
        worklog = require("worklog")
    end)

    describe("day_heading", function()
        it("formats date with weekday abbreviation", function()
            local heading = worklog.day_heading(test_date())
            eq("## 2026-02-20 Fri", heading)
        end)

        it("formats a wednesday", function()
            local heading = worklog.day_heading(test_date_2())
            eq("## 2026-02-18 Wed", heading)
        end)

        it("zero-pads single-digit months and days", function()
            local date = os.date("*t", os.time({
                year = 2026, month = 1, day = 5,
            })) --[[@as osdate]]
            local heading = worklog.day_heading(date)
            eq("## 2026-01-05 Mon", heading)
        end)
    end)

    describe("new_file_contents", function()
        it("generates correct frontmatter and heading", function()
            local contents = worklog.new_file_contents(2026)
            local expected = table.concat({
                "---",
                "publish: false",
                "tags: []",
                "date: 2026-01-01",
                "---",
                "",
                "# log 2026",
                "",
            }, "\n")
            eq(expected, contents)
        end)
    end)

    describe("log_path", function()
        it("builds correct path with default notes_dir", function()
            local path = worklog.log_path("lexe", 2026)
            eq(worklog.notes_dir .. "/lexe/log/2026.md", path)
        end)

        it("respects configured notes_dir", function()
            worklog.setup({ notes_dir = "/tmp/test-notes" })
            local path = worklog.log_path("dotfiles", 2025)
            eq("/tmp/test-notes/dotfiles/log/2025.md", path)
        end)
    end)

    describe("find_year_heading", function()
        it("finds the year heading line", function()
            local bufnr = buf_with_lines({
                "---",
                "publish: false",
                "---",
                "",
                "# log 2026",
                "",
            })
            eq(5, worklog.find_year_heading(bufnr))
            buf_delete(bufnr)
        end)

        it("returns nil when no heading exists", function()
            local bufnr = buf_with_lines({ "some random content" })
            eq(nil, worklog.find_year_heading(bufnr))
            buf_delete(bufnr)
        end)
    end)

    describe("find_first_day_heading", function()
        it("finds the first day heading", function()
            local bufnr = buf_with_lines({
                "# log 2026",
                "",
                "## 2026-02-20 Fri",
                "",
                "stuff",
                "",
                "## 2026-02-18 Wed",
            })
            eq(3, worklog.find_first_day_heading(bufnr))
            buf_delete(bufnr)
        end)

        it("returns nil when no day headings exist", function()
            local bufnr = buf_with_lines({
                "# log 2026",
                "",
            })
            eq(nil, worklog.find_first_day_heading(bufnr))
            buf_delete(bufnr)
        end)
    end)

    describe("has_today_heading", function()
        it("returns true when heading exists", function()
            local date = test_date()
            local bufnr = buf_with_lines({
                "# log 2026",
                "",
                "## 2026-02-20 Fri",
                "",
            })
            eq(true, worklog.has_today_heading(bufnr, date))
            buf_delete(bufnr)
        end)

        it("returns false when heading is missing", function()
            local date = test_date()
            local bufnr = buf_with_lines({
                "# log 2026",
                "",
                "## 2026-02-18 Wed",
                "",
            })
            eq(false, worklog.has_today_heading(bufnr, date))
            buf_delete(bufnr)
        end)
    end)

    describe("insert_today", function()
        it("inserts heading after year heading in empty log", function()
            local date = test_date()
            local bufnr = buf_with_lines({
                "---",
                "publish: false",
                "tags: []",
                "date: 2026-01-01",
                "---",
                "",
                "# log 2026",
                "",
            })

            worklog.insert_today(date)

            eq({
                "---",
                "publish: false",
                "tags: []",
                "date: 2026-01-01",
                "---",
                "",
                "# log 2026",
                "",
                "",
                "## 2026-02-20 Fri",
                "",
                "",
                "",
            }, buf_lines(bufnr))

            -- Cursor should be on blank line after heading.
            local cursor = vim.api.nvim_win_get_cursor(0)
            eq({ 12, 0 }, cursor)

            buf_delete(bufnr)
        end)

        it("inserts before existing day entries", function()
            local date = test_date()
            local bufnr = buf_with_lines({
                "---",
                "publish: false",
                "---",
                "",
                "# log 2026",
                "",
                "",
                "## 2026-02-18 Wed",
                "",
                "Did some stuff.",
            })

            worklog.insert_today(date)

            eq({
                "---",
                "publish: false",
                "---",
                "",
                "# log 2026",
                "",
                "",
                "## 2026-02-20 Fri",
                "",
                "",
                "",
                "",
                "## 2026-02-18 Wed",
                "",
                "Did some stuff.",
            }, buf_lines(bufnr))

            buf_delete(bufnr)
        end)

        it("does not insert duplicate heading", function()
            local date = test_date()
            local lines = {
                "# log 2026",
                "",
                "",
                "## 2026-02-20 Fri",
                "",
                "Already here.",
            }
            local bufnr = buf_with_lines(lines)

            worklog.insert_today(date)

            -- Buffer should be unchanged.
            eq(lines, buf_lines(bufnr))
            buf_delete(bufnr)
        end)
    end)

    describe("open", function()
        local temp_dir

        before_each(function()
            temp_dir = make_temp_dir()
            worklog.setup({ notes_dir = temp_dir })
        end)

        after_each(function()
            -- Close any buffers we opened.
            vim.cmd("silent! %bdelete!")
            rm_temp_dir(temp_dir)
        end)

        it("creates directories and file with frontmatter", function()
            worklog.open("lexe", 2026)

            local path = temp_dir .. "/lexe/log/2026.md"
            eq(1, vim.fn.filereadable(path))

            -- Verify we're editing the right file.
            local buf_path = vim.fn.expand("%:p")
            eq(path, buf_path)

            -- Verify frontmatter was written.
            local lines = buf_lines(vim.api.nvim_get_current_buf())
            eq("---", lines[1])
            eq("# log 2026", lines[7])
        end)

        it("opens existing file without overwriting", function()
            -- Create the file first with some content.
            local dir = temp_dir .. "/lexe/log"
            vim.fn.mkdir(dir, "p")
            local path = dir .. "/2026.md"
            local fd = assert(io.open(path, "w"))
            fd:write("existing content\n")
            fd:close()

            worklog.open("lexe", 2026)

            local lines = buf_lines(vim.api.nvim_get_current_buf())
            eq("existing content", lines[1])
        end)
    end)

    describe("list_worklogs", function()
        local temp_dir

        before_each(function()
            temp_dir = make_temp_dir()
            worklog.setup({ notes_dir = temp_dir })
        end)

        after_each(function()
            rm_temp_dir(temp_dir)
        end)

        it("finds worklog files across projects", function()
            -- Create some test files.
            vim.fn.mkdir(temp_dir .. "/lexe/log", "p")
            vim.fn.mkdir(temp_dir .. "/dotfiles/log", "p")

            local fd1 = assert(io.open(temp_dir .. "/lexe/log/2026.md", "w"))
            fd1:write("a")
            fd1:close()

            local fd2 = assert(io.open(temp_dir .. "/lexe/log/2025.md", "w"))
            fd2:write("b")
            fd2:close()

            local fd3 = assert(io.open(temp_dir .. "/dotfiles/log/2026.md", "w"))
            fd3:write("c")
            fd3:close()

            local files = worklog.list_worklogs()
            eq(3, #files)

            -- Should be reverse-sorted (newest first).
            assert(
                files[1]:find("lexe/log/2026.md$")
                or files[1]:find("dotfiles/log/2026.md$"),
                "first entry should be a 2026 file"
            )
        end)

        it("returns empty list when no worklogs exist", function()
            eq({}, worklog.list_worklogs())
        end)
    end)
end)
