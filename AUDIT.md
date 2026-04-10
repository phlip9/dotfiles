# Audit: `telescope_git_file_status` + `git_file_status`

## High

### 1. ~~Wrapped display function drops original entry highlights~~

**FIXED.** `orig_display(e)` now captures both return values
`(display_text, orig_hl)` and forwards `orig_hl` via a highlight function
closure. The displayer's hl-function path (lines 112-115 in
`entry_display.lua`) offsets each range by the column's start position.

---

### 2. `pcall` swallows errors silently in two places

**File:** `git_file_status.lua:289`, `telescope_git_file_status.lua:149`

```lua
-- git_file_status.lua:289
pcall(callback)

-- telescope_git_file_status.lua:149
pcall(picker.refresh, picker, picker.finder, { ... })
```

Both discard the error return. If a subscriber throws or `picker:refresh`
fails, the failure is invisible. This makes debugging painful — marker updates
silently stop working with no log output.

Fix: log on failure.

```lua
local ok, err = pcall(callback)
if not ok then
    vim.notify("git_file_status: subscriber error: " .. tostring(err),
        vim.log.levels.WARN)
end
```

---

## Medium

### 3. ~~Vendored `buffers()` is a near-verbatim copy of telescope internals~~

**FIXED.** `buffers()` now delegates to `builtin.buffers(opts)`, same strategy
as `find_files`. `pickers.new` (line 1548 of telescope's `pickers.lua`)
auto-composes `attach_mappings` when both `opts` and defaults provide one, so
the builtin's `<M-d>` mapping and our git-status refresh subscription both
apply. Removed ~100 lines of vendored buffer logic, 4 imports, and 2 helper
functions (`apply_cwd_only_aliases`, `buf_in_cwd`).

---

### 4. Notify subscribers even on git command failure

**File:** `git_file_status.lua:374-381`

```lua
entry.inflight = false
if markers ~= nil then
    entry.markers = markers
    entry.updated_at_ms = now_ms()
end
notify_subscribers(entry)  -- always fires
```

When both git commands fail (`markers == nil`), subscribers are still notified,
triggering a `picker:refresh` that re-renders all entries — with no data
change. Harmless but wasteful.

Fix: only notify when markers actually changed.

```lua
if markers ~= nil then
    entry.markers = markers
    entry.updated_at_ms = now_ms()
    notify_subscribers(entry)
end
```

But note: the current behavior has a subtle upside — it lets subscribers know
"the refresh attempt finished" even if it failed. If that semantic is wanted,
keep the current code but document it.

---

### 5. `vim.system` callback context may be unsafe for `vim.notify`

**File:** `git_file_status.lua:318-330`

`vim.system` callbacks run from libuv's event loop. `vim.notify` (which
ultimately calls `nvim_echo`) may not be safe from that context without
`vim.schedule`. In practice this seems to work because neovim's `vim.system`
implementation schedule-wraps the exit callback, but this is an implementation
detail not guaranteed by the API.

The `vim.notify` calls here are `DEBUG` level (rarely shown), so the blast
radius is small. But if neovim ever changes callback dispatch, these could
crash.

Fix: wrap the entire `done` callback chain in `vim.schedule`, or at minimum
wrap the `vim.notify` calls.

---

## Low

### 6. ~~`math.max(unpack(bufnrs))` can exceed Lua stack limit~~

**FIXED** (consequence of #3). The vendored code is gone; this upstream bug
(`__internal.lua:993`) is no longer our problem.

---

### 7. `_repo_by_cwd` cache never invalidates

**File:** `git_file_status.lua:39`

Once a directory is resolved as non-repo (`false`), it stays cached forever.
`git init` in that directory won't be picked up until neovim restarts.

Similarly, repo root changes (e.g., `.git` deleted, or nested repo added)
aren't detected.

Acceptable for the current use case (pickers are short-lived), but worth
documenting.

---

### 8. Filenames containing tab characters break `parse_numstat_z`

**File:** `git_file_status.lua:143`

The pattern `^([^\t]+)\t([^\t]+)\t(.*)$` splits on tabs. A filename containing
a literal tab would be misparsed — the tab would be treated as a field
separator. Git does support tab-in-filename, though it's extremely rare.

Git itself has `-z` precisely because NUL-delimited output avoids this — but
the per-line format within `--numstat` still uses tabs for field separation
(the `-z` only changes record separation to NUL). So there's no clean
git-level fix; this is an inherent limitation of `--numstat` format.

---

### 9. ~~`select_current` index bug when `sort_lastused` is also true~~

**FIXED** (consequence of #3). The vendored code is gone; this upstream bug
(`__internal.lua:986`) is no longer our problem.

---

## Test coverage gaps

**File:** `telescope_git_file_status_spec.lua`

Missing tests (in rough priority order):

1. **Display highlight preservation** — would have caught issue #1. Stub
   `entry_display.create` to return a displayer that captures column highlight
   args; verify orig highlights are forwarded.
2. **`make_marked_entry_maker` when `base_entry_maker` returns nil** — the
   early `return nil` path (line 108) is untested.
3. **`make_marked_entry_maker` with string `orig_display`** — the non-function
   branch (line 122) is untested.
4. **`make_attach_mappings` when `user_attach` returns false** — should
   propagate `false` to telescope.
5. **`buf_in_cwd`** — basic prefix matching with trailing-slash edge cases.
6. **`marker_hl_group`** — trivial but documents the mapping.
7. **`apply_cwd_only_aliases`** — trivial but documents the alias.
