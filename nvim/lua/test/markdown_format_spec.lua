--- Tests for tree-sitter-aware Markdown `gw` formatting.

local eq = assert.are.same

--- Run a callback in an isolated Markdown buffer and always clean it up.
---
--- @param lines string[]
--- @param textwidth integer
--- @param callback fun(bufnr: integer): any
--- @return any
local function with_markdown_buffer(lines, textwidth, callback)
    local previous_bufnr = vim.api.nvim_get_current_buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)

    local ok, result = xpcall(function()
        vim.bo[bufnr].filetype = "markdown"
        vim.bo[bufnr].textwidth = textwidth
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return callback(bufnr)
    end, debug.traceback)

    if vim.api.nvim_buf_is_valid(previous_bufnr) then
        vim.api.nvim_set_current_buf(previous_bufnr)
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end

    if not ok then
        error(result)
    end
    return result
end

--- Format text through the configured `gw` mapping.
---
--- @param lines string[]
--- @param textwidth integer
--- @param normal_cmd? string
--- @return string[]
local function format_with_gw(lines, textwidth, normal_cmd)
    return with_markdown_buffer(lines, textwidth, function(bufnr)
        vim.api.nvim_feedkeys(normal_cmd or "ggVGgw", "mx", false)
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end)
end

--- Clear undo history while retaining the current buffer contents.
--- @param bufnr integer
local function clear_undo_history(bufnr)
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "temporary" })
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
    vim.bo[bufnr].undolevels = undolevels
end

describe("markdown gw formatting", function()
    describe("mappings and operator ranges", function()
        it("installs buffer-local normal and visual mappings", function()
            with_markdown_buffer({ "text" }, 80, function()
                local operator = vim.fn.maparg("gw", "n", false, true)
                local current_line = vim.fn.maparg("gww", "n", false, true)
                local visual = vim.fn.maparg("gw", "x", false, true)

                eq(1, operator.buffer)
                eq(1, operator.expr)
                eq(1, current_line.buffer)
                eq(1, visual.buffer)
            end)
        end)

        it("formats the current line with gww", function()
            local input = {
                "A long Markdown line should still wrap through the gww alias "
                .. "after installing the tree-sitter-aware operator.",
            }

            eq({
                "A long Markdown line should still wrap through the gww alias "
                .. "after installing",
                "the tree-sitter-aware operator.",
            }, format_with_gw(input, 80, "gggww"))
        end)

        it("formats the current line with gwgw", function()
            local input = {
                "The gwgw alias formats the current line while preserving its "
                .. "original cursor behavior and wrapping words.",
            }

            eq({
                "The gwgw alias formats the current line while",
                "preserving its original cursor behavior and",
                "wrapping words.",
            }, format_with_gw(input, 50, "gggwgw"))
        end)

        it("reflows a paragraph selected with gwip", function()
            local input = {
                "Markdown paragraphs should reflow together even when the "
                .. "first line is short.",
                "Existing continuation lines may exceed the configured text "
                .. "width after more words were added.",
                "Formatting the inner paragraph should update every line.",
            }

            eq({
                "Markdown paragraphs should reflow together even when the "
                .. "first line is short.",
                "Existing continuation lines may exceed the configured text "
                .. "width after more",
                "words were added. Formatting the inner paragraph should "
                .. "update every line.",
            }, format_with_gw(input, 80, "gg0gwip"))
        end)

        it("only formats a visual selection", function()
            local input = {
                "Selected paragraph has enough words to wrap at this narrow "
                .. "configured width.",
                "",
                "Unselected paragraph must remain completely unchanged despite "
                .. "exceeding the configured width.",
            }

            eq({
                "Selected paragraph has enough words to wrap at",
                "this narrow configured width.",
                "",
                input[3],
            }, format_with_gw(input, 50, "ggVgw"))
        end)

        it("formats count-prefixed lines bottom-up", function()
            local input = {
                "- First item has enough words to wrap at this narrow "
                .. "configured width.",
                "- Second item also has enough words to wrap at this narrow "
                .. "configured width.",
                "- Third item must remain completely unchanged despite "
                .. "exceeding the configured width.",
            }

            eq({
                "- First item has enough words to wrap at this",
                "  narrow configured width.",
                "- Second item also has enough words to wrap at",
                "  this narrow configured width.",
                input[3],
            }, format_with_gw(input, 50, "gg2gww"))
        end)

        it("keeps the cursor on the same prose token", function()
            local input = {
                "First paragraph has enough words to wrap at a narrow "
                .. "configured text width and move this target word later.",
            }

            with_markdown_buffer(input, 45, function()
                local target_column = assert(input[1]:find("target", 1, true))
                vim.api.nvim_win_set_cursor(0, { 1, target_column - 1 })
                vim.api.nvim_feedkeys("gww", "mx", false)

                local cursor = vim.api.nvim_win_get_cursor(0)
                local line = vim.api.nvim_get_current_line()
                eq("target", line:sub(cursor[2] + 1, cursor[2] + 6))
            end)
        end)

        it("keeps the pre-motion cursor token with gwip", function()
            local input = {
                "Earlier words on one line appear before the target token in "
                .. "this paragraph.",
                "More paragraph words follow target and force both source "
                .. "lines to reflow at a narrow width.",
            }

            with_markdown_buffer(input, 42, function()
                local target_column = assert(input[2]:find("target", 1, true))
                vim.api.nvim_win_set_cursor(0, { 2, target_column - 1 })
                vim.api.nvim_feedkeys("gwip", "mx", false)

                local cursor = vim.api.nvim_win_get_cursor(0)
                local line = vim.api.nvim_get_current_line()
                eq("target", line:sub(cursor[2] + 1, cursor[2] + 6))
            end)
        end)

        it("joins separated paragraph edits into one undo entry", function()
            local input = {
                "Prose before code has enough words to wrap at this narrow "
                .. "configured text width.",
                "",
                "```lua",
                "local untouched = true",
                "```",
                "",
                "Prose after code also has enough words to wrap at this narrow "
                .. "configured text width.",
            }

            with_markdown_buffer(input, 45, function(bufnr)
                clear_undo_history(bufnr)
                vim.api.nvim_feedkeys("ggVGgw", "mx", false)
                local formatted =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert(#formatted > #input, "expected formatting to add lines")

                vim.api.nvim_feedkeys("u", "nx", false)
                eq(input, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
            end)
        end)

        it("is idempotent", function()
            local input = {
                "A paragraph before the list has enough words to wrap at a "
                .. "narrow configured width.",
                "",
                "- A list item also has enough words to wrap at the same "
                .. "narrow configured width.",
                "",
                "```rust",
                "let exact = vec![\"code remains wider than the text width\"];",
                "```",
            }

            local once = format_with_gw(input, 48)
            eq(once, format_with_gw(once, 48))
        end)
    end)

    describe("fenced code blocks", function()
        local language_cases = {
            {
                name = "an untagged fence",
                opening = "```",
                code = "- code that resembles a very long Markdown list item "
                    .. "must remain on one line",
            },
            {
                name = "bash",
                opening = "```bash",
                code = "printf '%s\\n' \"$value with enough shell text to "
                    .. "exceed textwidth\"",
            },
            {
                name = "rust",
                opening = "```rust",
                code = "let filtered: Vec<_> = values.into_iter()"
                    .. ".filter(|value| value.is_ready()).collect();",
            },
            {
                name = "python",
                opening = "```python",
                code = "filtered = [value for value in values if "
                    .. "value.is_ready() and value.has_metadata()]",
            },
            {
                name = "lua",
                opening = "```lua",
                code = "local filtered = vim.tbl_filter(function(value) return "
                    .. "value.ready end, values)",
            },
            {
                name = "an unknown info string",
                opening = "```custom-language {#sample .numberLines}",
                code = "> code that resembles a very long block quote must "
                    .. "remain byte-for-byte identical",
            },
        }

        ---Register one independently captured fenced-language fixture.
        ---@param case { name: string, opening: string, code: string }
        local function add_language_case(case)
            it("preserves " .. case.name, function()
                local input = { case.opening, case.code, "```" }
                eq(input, format_with_gw(input, 40))
            end)
        end
        for _, case in ipairs(language_cases) do
            add_language_case(case)
        end

        it("preserves tilde and longer backtick fences", function()
            local input = {
                "~~~~bash",
                "echo 'a tilde fence can contain ``` without ending the block'",
                "~~~~",
                "",
                "````markdown",
                "```python",
                "print('a shorter fence is literal content')",
                "```",
                "````",
            }

            eq(input, format_with_gw(input, 32))
        end)

        it("reflows prose around a fence without blank separators", function()
            local input = {
                "Prose before a fence has enough words to wrap at this narrow "
                .. "configured width.",
                "```bash",
                "echo 'this code remains much wider than the configured width'",
                "```",
                "Prose after a fence also has enough words to wrap at this "
                .. "narrow configured width.",
            }

            eq({
                "Prose before a fence has enough words to wrap",
                "at this narrow configured width.",
                input[2],
                input[3],
                input[4],
                "Prose after a fence also has enough words to",
                "wrap at this narrow configured width.",
            }, format_with_gw(input, 45))
        end)

        it("preserves fences nested in list items", function()
            local input = {
                "- A list introduction with enough words to wrap onto a "
                .. "continuation line at this configured width.",
                "",
                "  ```bash",
                "  printf '%s\\n' 'this code line must not wrap despite being "
                .. "substantially longer than textwidth'",
                "  ```",
                "",
                "  List text after the fence has enough words to wrap onto "
                .. "another continuation line at this width.",
            }

            eq({
                "- A list introduction with enough words to wrap onto",
                "  a continuation line at this configured width.",
                "",
                input[3],
                input[4],
                input[5],
                "",
                "  List text after the fence has enough words to wrap",
                "  onto another continuation line at this width.",
            }, format_with_gw(input, 52))
        end)

        it("preserves fences nested in block quotes", function()
            local input = {
                "> Quoted prose before the fence has enough words to wrap onto "
                .. "another quoted line at this width.",
                ">",
                "> ```python",
                "> values = [item for item in source if predicate(item)]"
                .. "  # exact code",
                "> ```",
                ">",
                "> Quoted prose after the fence has enough words to wrap onto "
                .. "another quoted line at this width.",
            }

            eq({
                "> Quoted prose before the fence has enough words to",
                "> wrap onto another quoted line at this width.",
                ">",
                input[3],
                input[4],
                input[5],
                ">",
                "> Quoted prose after the fence has enough words to",
                "> wrap onto another quoted line at this width.",
            }, format_with_gw(input, 52))
        end)

        it("protects an unterminated fence through end-of-buffer", function()
            local input = {
                "Prose before an unterminated fence has enough words to wrap "
                .. "at the configured narrow width.",
                "",
                "```lua",
                "local value = this_code_must_stay_exact_even_with_a_long_name",
                "-- no closing delimiter",
            }

            eq({
                "Prose before an unterminated fence has enough words",
                "to wrap at the configured narrow width.",
                "",
                input[3],
                input[4],
                input[5],
            }, format_with_gw(input, 52))
        end)

        it("does nothing when gww targets code", function()
            local input = {
                "```console",
                "$ a-command --with enough arguments to exceed the "
                .. "configured width",
                "```",
            }

            eq(input, format_with_gw(input, 30, "j0gww"))
        end)
    end)

    describe("other semantic blocks", function()
        it("preserves indented code while reflowing adjacent prose", function()
            local input = {
                "Prose before indented code has enough words to wrap at the "
                .. "configured narrow width.",
                "",
                "    const long_name = 'indented code remains exactly "
                .. "as authored';",
                "    - this is code, not a Markdown list item",
                "",
                "Prose after indented code has enough words to wrap at the "
                .. "configured narrow width.",
            }

            eq({
                "Prose before indented code has enough words to wrap",
                "at the configured narrow width.",
                "",
                input[3],
                input[4],
                "",
                "Prose after indented code has enough words to wrap",
                "at the configured narrow width.",
            }, format_with_gw(input, 52))
        end)

        it("preserves ATX and setext headings", function()
            local input = {
                "# A long heading with enough words to exceed the configured "
                .. "width without losing heading semantics",
                "",
                "A normal paragraph between headings has enough words to wrap "
                .. "at the configured width.",
                "",
                "A setext heading with enough words to exceed the configured "
                .. "width without losing its semantics",
                "============================================================",
            }

            eq({
                input[1],
                "",
                "A normal paragraph between headings has enough",
                "words to wrap at the configured width.",
                "",
                input[5],
                input[6],
            }, format_with_gw(input, 48))
        end)

        it("preserves pipe tables", function()
            local input = {
                "| Column one | Column two |",
                "| --- | ---: |",
                "| a cell containing enough prose to exceed textwidth | "
                .. "another cell |",
            }

            eq(input, format_with_gw(input, 30))
        end)

        it("preserves HTML blocks", function()
            local input = {
                "<div data-description=\"a long attribute value that must "
                .. "stay intact\">",
                "body text that is part of the HTML block",
                "</div>",
            }

            eq(input, format_with_gw(input, 30))
        end)

        it("preserves YAML and TOML front matter", function()
            local yaml = {
                "---",
                "description: a long metadata value that must not become "
                .. "Markdown prose",
                "---",
            }
            local toml = {
                "+++",
                "description = \"a long metadata value that must remain TOML\"",
                "+++",
            }

            eq(yaml, format_with_gw(yaml, 30))
            eq(toml, format_with_gw(toml, 30))
        end)

        it("preserves link reference definitions", function()
            local input = {
                "[reference]: https://example.com/a/very/long/path "
                .. "\"A long title that must remain attached\"",
            }

            eq(input, format_with_gw(input, 40))
        end)

        it("preserves thematic breaks between paragraphs", function()
            local input = {
                "Prose before the break has enough words to wrap at this "
                .. "narrow configured width.",
                "",
                "* * *",
                "",
                "Prose after the break has enough words to wrap at this narrow "
                .. "configured width.",
            }

            eq({
                "Prose before the break has enough words to wrap at",
                "this narrow configured width.",
                "",
                "* * *",
                "",
                "Prose after the break has enough words to wrap at",
                "this narrow configured width.",
            }, format_with_gw(input, 52))
        end)

        it("preserves hard line breaks and reflows following lines", function()
            local input = {
                "The first semantic line is deliberately long and ends in a "
                .. "hard break.  ",
                "The next semantic line must remain separate and also has "
                .. "enough words to wrap independently.",
                "",
                "Backslash hard breaks must remain too.\\",
                "This line must not merge with the previous semantic line when "
                .. "formatted.",
            }

            eq({
                input[1],
                "The next semantic line must remain separate and also",
                "has enough words to wrap independently.",
                "",
                input[4],
                "This line must not merge with the previous semantic",
                "line when formatted.",
            }, format_with_gw(input, 52))
        end)

        it("reflows an even trailing backslash as a soft break", function()
            local input = {
                "An escaped literal backslash ends this soft source line.\\\\",
                "The following source line belongs to the same paragraph and "
                .. "must be joined before wrapping.",
            }

            eq({
                "An escaped literal backslash ends this soft source",
                "line.\\\\ The following source line belongs to the",
                "same paragraph and must be joined before wrapping.",
            }, format_with_gw(input, 52))
        end)
    end)

    describe("prose and inline elements", function()
        it("reflows paragraphs without crossing blank lines", function()
            local input = {
                "First paragraph line has enough words to wrap at this narrow "
                .. "configured width.",
                "Its existing second line should be joined and reflowed with "
                .. "the first line.",
                "",
                "Second paragraph stays separate while also wrapping at this "
                .. "narrow configured width.",
            }

            eq({
                "First paragraph line has enough words to wrap at",
                "this narrow configured width. Its existing second",
                "line should be joined and reflowed with the first",
                "line.",
                "",
                "Second paragraph stays separate while also wrapping",
                "at this narrow configured width.",
            }, format_with_gw(input, 52))
        end)

        it("reflows inline code, emphasis, links, and images", function()
            local input = {
                "A paragraph with **strong words**, _emphasized words_, "
                .. "`inline code with spaces`, [descriptive link text]"
                .. "(https://example.com/path), "
                .. "and ![image alt text](image.png) that needs wrapping.",
            }

            eq({
                "A paragraph with **strong words**, _emphasized",
                "words_, `inline code with spaces`, [descriptive link",
                "text](https://example.com/path), and ![image alt",
                "text](image.png) that needs wrapping.",
            }, format_with_gw(input, 52))
        end)

        it("reflows autolinks without splitting their destinations", function()
            local input = {
                "A paragraph containing <https://example.com/a/very/long/path> "
                .. "and enough trailing prose to wrap cleanly.",
            }

            eq({
                "A paragraph containing",
                "<https://example.com/a/very/long/path> and enough",
                "trailing prose to wrap cleanly.",
            }, format_with_gw(input, 52))
        end)

        it("restores a multibyte cursor token", function()
            local input = {
                "Unicode prose with café naïve résumé 日本語 words and "
                .. "enough ordinary text to wrap at a narrow width.",
            }

            with_markdown_buffer(input, 38, function(bufnr)
                local target_column = assert(input[1]:find("日本語", 1, true))
                vim.api.nvim_win_set_cursor(0, { 1, target_column - 1 })
                vim.api.nvim_feedkeys("gww", "mx", false)

                eq({
                    "Unicode prose with café naïve résumé",
                    "日本語 words and enough ordinary text",
                    "to wrap at a narrow width.",
                }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
                local cursor = vim.api.nvim_win_get_cursor(0)
                local line = vim.api.nvim_get_current_line()
                eq("日本語", line:sub(cursor[2] + 1, cursor[2] + 9))
            end)
        end)

        it("reflows block quotes and retains quote leaders", function()
            local input = {
                "> A quoted paragraph with enough words to wrap across more "
                .. "than one quoted output line at this width.",
            }

            eq({
                "> A quoted paragraph with enough words to wrap",
                "> across more than one quoted output line at this",
                "> width.",
            }, format_with_gw(input, 52))
        end)

        it("reflows nested block quotes", function()
            local input = {
                "> > A doubly nested quote with enough words to wrap across "
                .. "multiple lines while retaining both quote markers.",
            }

            eq({
                "> > A doubly nested quote with enough words to wrap",
                "> > across multiple lines while retaining both quote",
                "> > markers.",
            }, format_with_gw(input, 52))
        end)

        ---Register one independently captured unordered-list fixture.
        ---@param marker string
        local function add_list_marker_case(marker)
            it("aligns " .. marker .. " list continuations", function()
                local input = {
                    marker .. " A list item that is long enough to wrap onto a "
                    .. "properly aligned continuation line at this width.",
                }

                local result = format_with_gw(input, 52)
                assert(#result >= 2, "expected the list item to wrap")
                eq(marker .. " A list item that is long enough to wrap onto a",
                    result[1])
                for line_number = 2, #result do
                    assert(result[line_number]:match("^  %S"),
                        "list continuation " .. line_number .. " is misaligned")
                end
            end)
        end
        for _, marker in ipairs({ "-", "*", "+" }) do
            add_list_marker_case(marker)
        end

        it("aligns task-list continuations after the bullet", function()
            local input = {
                "- [x] A completed task item with enough words to wrap onto a "
                .. "continuation line at this width.",
                "- [ ] An incomplete task item with enough words to wrap onto "
                .. "a continuation line at this width.",
            }

            eq({
                "- [x] A completed task item with enough words to",
                "  wrap onto a continuation line at this width.",
                "- [ ] An incomplete task item with enough words to",
                "  wrap onto a continuation line at this width.",
            }, format_with_gw(input, 52))
        end)

        it("aligns dot and parenthesis ordered-list continuations", function()
            local input = {
                "1. A dot list item with enough words to wrap onto a properly "
                .. "aligned continuation line at this width.",
                "",
                "1) A parenthesized list item with enough words to wrap onto a "
                .. "properly aligned continuation line at this width.",
            }

            eq({
                "1. A dot list item with enough words to wrap onto a",
                "   properly aligned continuation line at this width.",
                "",
                "1) A parenthesized list item with enough words to",
                "   wrap onto a properly aligned continuation line at",
                "   this width.",
            }, format_with_gw(input, 52))
        end)

        it("aligns nested multi-digit ordered lists", function()
            local input = {
                "  10. A nested double-digit list item with enough words to "
                .. "wrap onto a continuation line at this width.",
            }

            eq({
                "  10. A nested double-digit list item with enough",
                "      words to wrap onto a continuation line at this",
                "      width.",
            }, format_with_gw(input, 52))
        end)

        it("handles a list following a quoted paragraph", function()
            local input = {
                "> A quoted paragraph with enough words to wrap across more "
                .. "than one output line at this width.",
                ">",
                "> - A quoted list item with enough words to wrap across more "
                .. "than one output line at this width.",
            }

            eq({
                "> A quoted paragraph with enough words to wrap",
                "> across more than one output line at this width.",
                ">",
                "> - A quoted list item with enough words to wrap",
                ">   across more than one output line at this width.",
            }, format_with_gw(input, 52))
        end)

        it("reflows separate list-item paragraphs", function()
            local input = {
                "- First paragraph in a list item has enough words to wrap "
                .. "across a continuation line at this width.",
                "",
                "  A second paragraph in the same item has enough words to "
                .. "wrap while retaining its content indentation.",
            }

            eq({
                "- First paragraph in a list item has enough words to",
                "  wrap across a continuation line at this width.",
                "",
                "  A second paragraph in the same item has enough",
                "  words to wrap while retaining its content",
                "  indentation.",
            }, format_with_gw(input, 52))
        end)
    end)
end)
