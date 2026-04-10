# Audit: git_file_status

Date: 2026-04-10

## Files reviewed

- `nvim/lua/git_file_status.lua`
- `nvim/lua/test/git_file_status_spec.lua`
- `nvim/lua/telescope_git_file_status.lua`
- `nvim/lua/test/telescope_git_file_status_spec.lua`

## Findings

### 1. High — Subscriber leak on early unsubscribe

`subscribe()` returns a `subscriber_id` immediately but registers the callback
_asynchronously_ inside `resolve_repo_root_async`. `unsubscribe()` is
synchronous — it checks `_repo_by_cwd[cwd]` and bails if the repo root isn't
cached yet.

Race sequence:
1. `subscribe()` called — `resolve_repo_root_async` starts `git rev-parse`
2. User closes picker before `git rev-parse` finishes — `BufWipeout` fires
3. `unsubscribe()` finds `_repo_by_cwd[cwd] == nil` — returns early (no-op)
4. `resolve_repo_root_async` callback fires — registers the subscriber
5. Leaked subscriber — callback fires on every future refresh

Practical impact is low (the leaked callback is a scheduled no-op since the
picker buffer is gone), but it accumulates over many open/close cycles.

**Fixed:** `subscribe` now returns an unsubscribe closure that captures a
`cancelled` flag. The async callback checks this flag before registering.
`M.unsubscribe` removed as a public API — callers just call the returned
function. New test exercises the race (unsubscribe before repo root resolves).

### 2. Medium — Sequential git commands (easy parallelism)

`collect_markers_async` runs `git diff --numstat` and waits for completion
before launching `git ls-files --others`. These are independent — running
them in parallel halves wall-clock latency on the first render.

### 3. Medium — `adds=0, deletes=0` produces no marker

`git diff --numstat` reports `0\t0\tfile` for mode-only changes (permission
bits) and submodule pointer changes. `reduce_markers` has no branch for this
case, so these files get no marker and appear unchanged in the picker.

Fix: add a fallback `else marker = "~"` after the existing conditions.

### 4. Medium — `notify_subscribers` iterates table that callbacks could mutate

`notify_subscribers` uses `pairs()` over `entry.subscribers`. Modifying a
table during `pairs()` is undefined in Lua. Currently safe by accident —
the subscriber callback is `vim.schedule_wrap(...)` so actual unsubscription
happens on a later event-loop tick. A future synchronous callback would break.

Fix: snapshot the subscribers table before iterating.

### 5. Medium — `buffers()` `cwd_only` filter uses runtime `cwd()` not `picker_cwd`

In `telescope_git_file_status.lua`, when both `opts.cwd` and `opts.cwd_only`
are set, the buffer filter checks against the runtime `cwd()` (line 236)
instead of `picker_cwd` (derived from `opts.cwd`). This may be intentional
(matching upstream Telescope behavior) but is inconsistent with the picker's
configured cwd used for git markers.

### 6. Medium — Cache over-engineered for actual usage

`_cache` is a dict keyed by `(repo_root, diff_base)`. In practice only one
pair is active at a time (pickers are modal, diff_base rarely changes).
The dict adds complexity (composite key construction, unbounded growth,
multi-entry eviction concerns) for no practical benefit.

Fix: replace with a single MRU entry.

### 7. Low — `cached_markers()` is dead code

No callers exist in the codebase. Remove it.

### 8. Low — Silent error swallowing

When `git diff` or `git ls-files` fails, `done(nil)` is called with no
logging. Makes debugging hard in misconfigured repos.

Fix: `vim.notify()` at DEBUG level with stderr.

### 9. Low — `trim()` only strips trailing whitespace

`vim.trim()` exists and handles both sides. Leading whitespace from
`git rev-parse` would cause cache-key mismatches.

### 10. Low — Test temp dirs leak on assertion failure

The integration test calls `vim.fn.delete(repo, "rf")` at the end of the
test body. If an assertion fails before that line, cleanup never runs.

Fix: use `after_each` or `finally` for cleanup.

### 11. Low — Test monkey-patches not restored on failure

Tests that stub `M.collect_markers_async` or `M.resolve_repo_root_async`
restore the original at the end of the test body. If an assertion fails
mid-test, the stub leaks into subsequent tests.

### 12. Low — `path_to_repo_rel` doesn't resolve symlinks

`vim.fs.normalize` does not resolve symlinks. Files accessed via symlinked
paths won't match the repo root prefix and will get no marker.

## Changes applied

### Cache simplification (finding 6, 7)

Replaced `M._cache` dict with a single `M._entry` field. Removed `cache_key`,
`cached_markers`, and `get_cache_entry`. Added `get_entry` (returns nil on
mismatch) and `get_or_create_entry` (replaces stale entry). This eliminates
unbounded cache growth and composite-key construction.
