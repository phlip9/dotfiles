-- ============================================================================
-- Async "shell -> open/quickfix" helpers for Neovim
--
-- Commands:
-- :Sho  {cmd} - shell -> open, newline-delimited stdout
-- :Shoz {cmd} - shell -> open, NUL-delimited stdout
-- :Shq  {cmd} - shell -> quickfix, newline-delimited stdout
-- :Shqz {cmd} - shell -> quickfix, NUL-delimited stdout
--
-- Examples:
-- :Sho  git diff --name-only | grep Cargo
-- :Shoz git diff --name-only -z
-- :Shq  rg --files | grep Cargo
-- :Shqz fd -0 Cargo
--
-- Notes:
-- - These commands assume stdout is a list of file paths.
-- - :Sho/:Shq parse newline-delimited output.
-- - :Shoz/:Shqz parse NUL-delimited output, which is the robust choice if
--   filenames may contain embedded whitespace or newlines.
-- - Missing/deleted paths are skipped by default.
-- - The shell command is run via the user's configured shell:
--     { vim.o.shell, vim.o.shellcmdflag, <cmd> }
--   so pipes, redirects, quotes, globbing, etc. behave like a normal shell.
-- ============================================================================

local uv = vim.uv or vim.loop

local M = {}

-- ----------------------------------------------------------------------------
-- Small helpers
-- ----------------------------------------------------------------------------

local function notify(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO, { title = "sh-open" })
end

local function shell_argv(cmd)
    -- Build argv for the user's configured shell.
    --
    -- Typical values:
    --   vim.o.shell         = "bash" / "zsh" / "fish"
    --   vim.o.shellcmdflag  = "-c"
    --
    -- We intentionally do not parse the shell command ourselves. We pass the raw
    -- command string to the user's shell so pipelines, quoting, redirects, etc.
    -- work exactly as expected.
    return { vim.o.shell, vim.o.shellcmdflag, cmd }
end

local function path_exists(path)
    ---@diagnostic disable-next-line: undefined-field
    return uv.fs_stat(path) ~= nil
end

local function split_lines(s)
    -- Split on '\n', tolerating a trailing newline.
    -- We do not trim whitespace inside each entry; a leading/trailing space may be
    -- part of a legitimate filename.
    local out = {}

    if s == "" then
        return out
    end

    -- Normalise CRLF -> LF for shell output on some platforms.
    s = s:gsub("\r\n", "\n")

    for item in s:gmatch("([^\n]*)\n?") do
        if item == "" and #out > 0 and s:sub(-1) ~= "\n" then
            -- Avoid an extra empty final capture from the pattern mechanics.
            break
        end
        if item ~= "" then
            table.insert(out, item)
        end
    end

    return out
end

local function split_nul(s)
    -- Split on '\0'. This is the robust path format for arbitrary filenames.
    local out = {}

    if s == "" then
        return out
    end

    local start = 1
    while true do
        local i = s:find("\0", start, true)
        if not i then
            local tail = s:sub(start)
            if tail ~= "" then
                table.insert(out, tail)
            end
            break
        end

        if i > start then
            table.insert(out, s:sub(start, i - 1))
        end

        start = i + 1
    end

    return out
end

local function parse_stdout(stdout, nul_terminated)
    if nul_terminated then
        return split_nul(stdout)
    else
        return split_lines(stdout)
    end
end

local function normalize_and_filter_paths(paths, opts)
    -- Deduplicate while preserving order.
    -- Optionally drop non-existent paths, which is useful for e.g.
    -- `git diff --name-only` when deleted files are present.
    opts = opts or {}

    local seen = {}
    local out = {}

    for _, raw in ipairs(paths) do
        -- Do not trim arbitrary whitespace from filenames.
        local path = raw

        if path ~= "" and not seen[path] then
            seen[path] = true

            if opts.existing_only then
                if path_exists(path) then
                    table.insert(out, path)
                end
            else
                table.insert(out, path)
            end
        end
    end

    return out
end

local function set_arglist(files)
    -- Replace the current arglist.
    --
    -- We use fnameescape because these are passed through Ex command parsing.
    local escaped = vim.tbl_map(vim.fn.fnameescape, files)
    vim.cmd("args " .. table.concat(escaped, " "))
end

local function open_files(files)
    -- "Open" semantics:
    --   1. replace arglist with the file list
    --   2. edit the first file in the current window
    --   3. add the remaining files as listed buffers without switching to each
    --
    -- This is usually the least disruptive behavior.
    set_arglist(files)

    if #files == 0 then
        return
    end

    vim.cmd("edit " .. vim.fn.fnameescape(files[1]))

    for i = 2, #files do
        vim.cmd("badd " .. vim.fn.fnameescape(files[i]))
    end
end

local function populate_quickfix(files, title)
    local items = {}

    for _, path in ipairs(files) do
        table.insert(items, {
            filename = path,
            lnum = 1,
            col = 1,
            text = title,
        })
    end

    vim.fn.setqflist({}, " ", {
        title = title,
        items = items,
    })

    vim.cmd("copen")
end

-- ----------------------------------------------------------------------------
-- Core async runner
-- ----------------------------------------------------------------------------

local function run_shell_to_paths(cmd, opts, on_success)
    opts = vim.tbl_extend("force", {
        nul_terminated = false,
        existing_only = true,
        mode_name = "sho",
    }, opts or {})

    if not cmd or cmd == "" then
        notify("missing shell command", vim.log.levels.ERROR)
        return
    end

    vim.system(shell_argv(cmd), { text = false }, function(obj)
        -- obj = { code, signal, stdout, stderr }
        --
        -- text=false is important:
        -- - preserves raw stdout exactly
        -- - supports NUL bytes for *z variants
        local stdout = obj.stdout or ""
        local stderr = obj.stderr or ""

        local function handle()
            if obj.code ~= 0 then
                local msg = string.format(
                    "%s: shell exited with code %d%s",
                    opts.mode_name,
                    obj.code,
                    (stderr ~= "" and ("\n" .. stderr)) or ""
                )
                notify(msg, vim.log.levels.ERROR)
                return
            end

            local parsed = parse_stdout(stdout, opts.nul_terminated)
            local files = normalize_and_filter_paths(parsed, {
                existing_only = opts.existing_only,
            })

            if #parsed == 0 then
                notify(string.format("%s: command returned no paths", opts.mode_name), vim.log.levels.WARN)
                return
            end

            if #files == 0 then
                notify(
                    string.format("%s: no existing paths found in command output", opts.mode_name),
                    vim.log.levels.WARN
                )
                return
            end

            on_success(files)
        end

        -- Always hop back to the main thread before touching the editor UI/state.
        vim.schedule(handle)
    end)
end

-- ----------------------------------------------------------------------------
-- Public operations
-- ----------------------------------------------------------------------------

function M.sho(cmd)
    run_shell_to_paths(cmd, {
        nul_terminated = false,
        existing_only = true,
        mode_name = "sho",
    }, function(files)
        open_files(files)
        notify(string.format("sho: opened %d file(s)", #files))
    end)
end

function M.shoz(cmd)
    run_shell_to_paths(cmd, {
        nul_terminated = true,
        existing_only = true,
        mode_name = "shoz",
    }, function(files)
        open_files(files)
        notify(string.format("shoz: opened %d file(s)", #files))
    end)
end

function M.shq(cmd)
    run_shell_to_paths(cmd, {
        nul_terminated = false,
        existing_only = true,
        mode_name = "shq",
    }, function(files)
        populate_quickfix(files, "shq: " .. cmd)
        notify(string.format("shq: opened quickfix with %d file(s)", #files))
    end)
end

function M.shqz(cmd)
    run_shell_to_paths(cmd, {
        nul_terminated = true,
        existing_only = true,
        mode_name = "shqz",
    }, function(files)
        populate_quickfix(files, "shqz: " .. cmd)
        notify(string.format("shqz: opened quickfix with %d file(s)", #files))
    end)
end

return M
