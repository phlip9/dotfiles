-- Git hunk utilities - reusable for quickfix, telescope, fzf, etc.

local M = {}

-- Get all unstaged hunks across all files
-- Returns: array of { file, lnum, text, is_untracked }
function M.get_all_hunks()
    local items = {}

    -- Get unstaged files and their hunks
    local unstaged_files = vim.fn.systemlist('git diff --name-only')
    for _, file in ipairs(unstaged_files) do
        -- Fetch file diff
        local diff_output = vim.fn.systemlist(
            'git diff -U0 ' .. vim.fn.shellescape(file)
        )

        local hunk_num = 0
        for _, line in ipairs(diff_output) do
            -- Parse unified diff header: @@ -l,s +l,s @@
            local new_line = line:match('^@@.*%+(%d+)')
            if new_line then
                hunk_num = hunk_num + 1
                table.insert(items, {
                    file = file,
                    lnum = tonumber(new_line),
                    text = string.format('Hunk %d: Unstaged changes', hunk_num),
                    is_untracked = false,
                })
            end
        end

        -- If no hunks found (shouldn't happen), add file with line 1
        if hunk_num == 0 then
            table.insert(items, {
                file = file,
                lnum = 1,
                text = 'Unstaged changes',
                is_untracked = false,
            })
        end
    end

    -- Get untracked files (not in git tree)
    local untracked_files = vim.fn.systemlist(
        'git ls-files --others --exclude-standard'
    )
    for _, file in ipairs(untracked_files) do
        table.insert(items, {
            file = file,
            lnum = 1,
            text = 'Untracked file',
            is_untracked = true,
        })
    end

    return items
end

-- Get files with unstaged changes or untracked files
-- Returns: array of { file, text, is_untracked }
function M.get_files_with_changes()
    local items = {}

    -- Get unstaged files
    local unstaged_files = vim.fn.systemlist('git diff --name-only')
    for _, file in ipairs(unstaged_files) do
        table.insert(items, {
            file = file,
            text = 'Unstaged changes',
            is_untracked = false,
        })
    end

    -- Get untracked files (not in git tree)
    local untracked_files = vim.fn.systemlist(
        'git ls-files --others --exclude-standard'
    )
    for _, file in ipairs(untracked_files) do
        table.insert(items, {
            file = file,
            text = 'Untracked file',
            is_untracked = true,
        })
    end

    return items
end

-- Check if a file has unstaged hunks or is untracked
-- Returns: boolean
function M.has_hunks(filepath)
    -- Check if file is untracked
    local relative = vim.fn.fnamemodify(filepath, ':.')
    local ls_files_cmd = 'git ls-files --others --exclude-standard '
        .. vim.fn.shellescape(relative)
    local is_untracked = vim.fn.system(ls_files_cmd):match('%S') ~= nil

    if is_untracked then
        return true
    end

    -- Check if file has unstaged hunks
    local diff_output = vim.fn.systemlist(
        'git diff -U0 ' .. vim.fn.shellescape(filepath))
    for _, line in ipairs(diff_output) do
        if line:match('^@@') then
            return true
        end
    end

    return false
end

-- Populate quickfix list with unstaged hunks
function M.populate_quickfix(log_status)
    local hunks = M.get_all_hunks()

    if #hunks == 0 then
        -- Close quickfix window if open
        vim.cmd('cclose')
        if log_status then
            print('No unstaged changes or untracked files found')
        end
        return
    end

    -- Convert to quickfix format
    local qf_items = {}
    for _, hunk in ipairs(hunks) do
        table.insert(qf_items, {
            filename = hunk.file,
            lnum = hunk.lnum,
            text = hunk.text,
        })
    end

    vim.fn.setqflist(qf_items, 'r')
    vim.cmd('copen')
    if log_status then
        print(string.format('Found %d unstaged hunks', #hunks))
    end
end

return M
