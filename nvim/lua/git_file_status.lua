--- Async git changed-file status cache keyed by repo root and diff base.
---
--- Motivation:
---   Telescope file pickers (`O`, `<space>O`, `T`) need file-level git
---   markers for unopened files. gitgutter hunk data is buffer-local, so this
---   module computes repo-wide file status independent of opened buffers.
---
--- Requirements:
---   - never block picker startup
---   - include staged/unstaged/committed-vs-base changes
---   - honor g:gitgutter_diff_base when set
---   - cache and refresh in background for snappy repeated lookups
---   - include untracked files
---
--- Comparison point:
---   - use `g:gitgutter_diff_base` when non-empty
---   - otherwise use `HEAD`
---
--- Marker semantics (file-level):
---   - `+` additions-only or untracked
---   - `-` deletions-only
---   - `~` mixed add+delete, rename/copy, binary, or non-trivial change
---
--- Git sources:
---   - `git diff --numstat -z <diff_base> --`
---   - `git ls-files --others --exclude-standard -z`
---
--- Caching:
---   Cache key is `(repo_root, diff_base)`. Stale entries are refreshed
---   asynchronously; inflight refreshes are deduped.

local M = {}

local uv = vim.uv

--- Milliseconds before a cache entry is considered stale.
M.cache_ttl_ms = 5000

--- cwd => repo_root | false (false means "known non-repo")
M._repo_by_cwd = {}

--- cwd => { callbacks... }
M._repo_discovery_inflight = {}

--- "repo_root\nbase" => entry
M._cache = {}

--- monotonically increasing id for cache subscribers
M._next_subscriber_id = 1

--- @param value string|nil
--- @return string|nil
local function trim(value)
    if type(value) ~= "string" then
        return nil
    end
    local trimmed = value:gsub("%s+$", "")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

--- @return integer
local function now_ms()
    return math.floor(uv.hrtime() / 1000000)
end

--- @param path string
--- @return string
local function normalize_path(path)
    local normalized = vim.fs.normalize(path)
    normalized = normalized:gsub("\\", "/")
    if normalized:sub(-1) == "/" and #normalized > 1 then
        normalized = normalized:sub(1, -2)
    end
    return normalized
end

--- @param path string
--- @return boolean
local function is_absolute_path(path)
    if path:sub(1, 1) == "/" then
        return true
    end
    return path:match("^%a:[/\\]") ~= nil
end

--- @param base string
--- @return string
local function cache_key(repo_root, base)
    return repo_root .. "\n" .. base
end

--- @param value string
--- @return string[]
function M.split_nul(value)
    local out = {}
    if type(value) ~= "string" or value == "" then
        return out
    end

    local start = 1
    while true do
        local stop = value:find("\0", start, true)
        if stop == nil then
            local tail = value:sub(start)
            if tail ~= "" then
                out[#out + 1] = tail
            end
            break
        end

        out[#out + 1] = value:sub(start, stop - 1)
        start = stop + 1
        if start > #value then
            break
        end
    end

    return out
end

--- Parse `git diff --numstat -z` output.
---
--- Returned entries are keyed by repo-relative path and hold raw counters.
--- Counters are nil for binary changes.
---
--- @param stdout string|nil
--- @return table<string, {
---   adds:number?,
---   deletes:number?,
---   binary:boolean,
---   rename:boolean,
--- }>
function M.parse_numstat_z(stdout)
    local rows = M.split_nul(stdout or "")
    local out = {}

    local row_idx = 1
    while row_idx <= #rows do
        local row = rows[row_idx]
        row_idx = row_idx + 1

        if row ~= "" then
            local adds_str, deletes_str, path = row:match(
                "^([^\t]+)\t([^\t]+)\t(.*)$"
            )

            if adds_str ~= nil and deletes_str ~= nil and path ~= nil then
                local rename = false
                if path == "" then
                    -- Rename/copy records carry old/new path in the next 2 NUL
                    -- fields. We only annotate the destination path in file
                    -- pickers.
                    local _old_path = rows[row_idx]
                    local new_path = rows[row_idx + 1]
                    row_idx = row_idx + 2
                    path = new_path or ""
                    rename = true
                end

                if path ~= "" then
                    local adds = tonumber(adds_str)
                    local deletes = tonumber(deletes_str)
                    out[path] = {
                        adds = adds,
                        deletes = deletes,
                        binary = adds == nil or deletes == nil,
                        rename = rename,
                    }
                end
            end
        end
    end

    return out
end

--- Parse `git ls-files --others --exclude-standard -z` output.
---
--- @param stdout string|nil
--- @return table<string, boolean>
function M.parse_untracked_z(stdout)
    local rows = M.split_nul(stdout or "")
    local out = {}
    for _, path in ipairs(rows) do
        if path ~= "" then
            out[path] = true
        end
    end
    return out
end

--- Merge tracked diff stats and untracked paths to file markers.
---
--- Marker semantics:
---   + additions only, or untracked
---   - deletions only
---   ~ mixed add+delete, rename, binary, or otherwise non-trivial change
---
--- @param numstat table<string, {
---   adds:number?,
---   deletes:number?,
---   binary:boolean,
---   rename:boolean,
--- }>
--- @param untracked table<string, boolean>
--- @return table<string, string>
function M.reduce_markers(numstat, untracked)
    local markers = {}

    for path, stat in pairs(numstat or {}) do
        local marker
        if stat.rename or stat.binary then
            marker = "~"
        else
            local adds = stat.adds or 0
            local deletes = stat.deletes or 0
            if adds > 0 and deletes == 0 then
                marker = "+"
            elseif adds == 0 and deletes > 0 then
                marker = "-"
            elseif adds > 0 and deletes > 0 then
                marker = "~"
            end
        end

        if marker ~= nil then
            markers[path] = marker
        end
    end

    for path, is_untracked in pairs(untracked or {}) do
        if is_untracked then
            markers[path] = "+"
        end
    end

    return markers
end

--- @return string
function M.effective_diff_base()
    local base = vim.g.gitgutter_diff_base
    if type(base) == "string" and base ~= "" then
        return base
    end
    return "HEAD"
end

--- @param repo_root string
--- @param base string
--- @return table
local function get_cache_entry(repo_root, base)
    local key = cache_key(repo_root, base)
    if M._cache[key] == nil then
        M._cache[key] = {
            repo_root = repo_root,
            diff_base = base,
            markers = {},
            updated_at_ms = 0,
            inflight = false,
            subscribers = {},
        }
    end
    return M._cache[key]
end

--- @param entry table
local function notify_subscribers(entry)
    for _, callback in pairs(entry.subscribers) do
        pcall(callback)
    end
end

--- @param entry table
--- @return boolean
local function is_stale(entry)
    if entry.updated_at_ms <= 0 then
        return true
    end
    return now_ms() - entry.updated_at_ms > M.cache_ttl_ms
end

--- @param repo_root string
--- @param diff_base string
--- @param done fun(markers:table<string, string>|nil)
function M.collect_markers_async(repo_root, diff_base, done)
    local diff_cmd = {
        "git", "-C", repo_root,
        "diff", "--numstat", "-z", diff_base, "--",
    }

    vim.system(diff_cmd, { text = false }, function(diff_res)
        if diff_res.code ~= 0 then
            done(nil)
            return
        end

        local untracked_cmd = {
            "git", "-C", repo_root,
            "ls-files", "--others", "--exclude-standard", "-z",
        }

        vim.system(untracked_cmd, { text = false }, function(untracked_res)
            if untracked_res.code ~= 0 then
                done(nil)
                return
            end

            local numstat = M.parse_numstat_z(diff_res.stdout)
            local untracked = M.parse_untracked_z(untracked_res.stdout)
            done(M.reduce_markers(numstat, untracked))
        end)
    end)
end

--- @param repo_root string
--- @param diff_base string
function M.refresh_async(repo_root, diff_base)
    local entry = get_cache_entry(repo_root, diff_base)
    if entry.inflight then
        return
    end

    entry.inflight = true
    M.collect_markers_async(repo_root, diff_base, function(markers)
        entry.inflight = false
        if markers ~= nil then
            entry.markers = markers
            entry.updated_at_ms = now_ms()
        end
        notify_subscribers(entry)
    end)
end

--- @param cwd string
--- @param callback fun(repo_root:string|nil)
function M.resolve_repo_root_async(cwd, callback)
    local norm_cwd = normalize_path(cwd)
    local cached = M._repo_by_cwd[norm_cwd]
    if cached ~= nil then
        callback(cached or nil)
        return
    end

    local waiters = M._repo_discovery_inflight[norm_cwd]
    if waiters ~= nil then
        waiters[#waiters + 1] = callback
        return
    end

    M._repo_discovery_inflight[norm_cwd] = { callback }
    vim.system(
        { "git", "-C", norm_cwd, "rev-parse", "--show-toplevel" },
        { text = true },
        function(res)
            local repo_root
            if res.code == 0 then
                repo_root = trim(res.stdout)
            end

            repo_root = repo_root and normalize_path(repo_root) or nil
            M._repo_by_cwd[norm_cwd] = repo_root or false

            local callbacks = M._repo_discovery_inflight[norm_cwd] or {}
            M._repo_discovery_inflight[norm_cwd] = nil
            for _, waiter in ipairs(callbacks) do
                pcall(waiter, repo_root)
            end
        end
    )
end

--- @param cwd string
--- @param diff_base string
--- @param callback fun()
--- @return integer subscriber_id
function M.subscribe(cwd, diff_base, callback)
    local subscriber_id = M._next_subscriber_id
    M._next_subscriber_id = M._next_subscriber_id + 1

    M.resolve_repo_root_async(cwd, function(repo_root)
        if repo_root == nil then
            callback()
            return
        end

        local entry = get_cache_entry(repo_root, diff_base)
        entry.subscribers[subscriber_id] = callback
        callback()

        if is_stale(entry) then
            M.refresh_async(repo_root, diff_base)
        end
    end)

    return subscriber_id
end

--- @param cwd string
--- @param diff_base string
--- @param subscriber_id integer
function M.unsubscribe(cwd, diff_base, subscriber_id)
    local norm_cwd = normalize_path(cwd)
    local repo_root = M._repo_by_cwd[norm_cwd]
    if type(repo_root) ~= "string" then
        return
    end

    local entry = get_cache_entry(repo_root, diff_base)
    entry.subscribers[subscriber_id] = nil
end

--- @param picker_cwd string
--- @param path string
--- @param repo_root string
--- @return string|nil
function M.path_to_repo_rel(picker_cwd, path, repo_root)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    if path == "[No Name]" then
        return nil
    end

    local norm_repo_root = normalize_path(repo_root)
    local absolute

    if is_absolute_path(path) then
        absolute = normalize_path(path)
    else
        absolute = normalize_path(vim.fs.joinpath(picker_cwd, path))
    end

    if absolute == norm_repo_root then
        return nil
    end

    local prefix = norm_repo_root .. "/"
    if absolute:sub(1, #prefix) ~= prefix then
        return nil
    end

    return absolute:sub(#prefix + 1)
end

--- @param cwd string
--- @param diff_base string
--- @param entry_path string
--- @return string|nil
function M.lookup_marker(cwd, diff_base, entry_path)
    local norm_cwd = normalize_path(cwd)
    local repo_root = M._repo_by_cwd[norm_cwd]
    if type(repo_root) ~= "string" then
        return nil
    end

    local entry = get_cache_entry(repo_root, diff_base)
    local relpath = M.path_to_repo_rel(norm_cwd, entry_path, repo_root)
    if relpath == nil then
        return nil
    end

    return entry.markers[relpath]
end

--- @param cwd string
--- @param diff_base string
--- @return table<string, string>
function M.cached_markers(cwd, diff_base)
    local norm_cwd = normalize_path(cwd)
    local repo_root = M._repo_by_cwd[norm_cwd]
    if type(repo_root) ~= "string" then
        return {}
    end

    local entry = get_cache_entry(repo_root, diff_base)
    return entry.markers
end

--- Clear process-global cache for deterministic tests.
function M._reset_for_test()
    M._repo_by_cwd = {}
    M._repo_discovery_inflight = {}
    M._cache = {}
    M._next_subscriber_id = 1
end

return M
