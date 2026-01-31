--- Tests for markdown formatting (gw/gq) behavior.
---
--- These tests verify that continuation lines in markdown lists are properly
--- indented to align with text after the list marker (bullet or number).
---
--- Run with: nvim --headless -c 'PlenaryBustedFile nvim/lua/test/markdown_format_spec.lua'

local eq = assert.are.same

--- Format text using gw operator, returning the result.
---@param lines string[] input lines
---@param textwidth number
---@return string[] formatted lines
local function format_with_gw(lines, textwidth)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)

    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].textwidth = textwidth

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.cmd("normal! ggVGgw")

    local result = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.api.nvim_buf_delete(bufnr, { force = true })

    return result
end

--- Check that continuation lines have the expected indent prefix.
---@param lines string[] lines to check
---@param first_line_pattern string pattern the first line should match
---@param continuation_indent string expected indent for continuation lines
local function assert_continuation_indent(lines, first_line_pattern, continuation_indent)
    assert(#lines >= 2, "Expected at least 2 lines after formatting")
    assert(lines[1]:match(first_line_pattern), "First line should match: " .. first_line_pattern)

    for i = 2, #lines do
        local line = lines[i]
        -- Skip empty lines
        if line ~= "" then
            local prefix = line:sub(1, #continuation_indent)
            local after_indent = line:sub(#continuation_indent + 1, #continuation_indent + 1)
            assert(
                prefix == continuation_indent and after_indent ~= " ",
                string.format(
                    "Line %d should start with %q indent, got: %q",
                    i, continuation_indent, line:sub(1, #continuation_indent + 3)
                )
            )
        end
    end
end

describe("markdown gw formatting", function()
    describe("bullet list continuation", function()
        it("indents continuation lines with 2 spaces for '- ' bullets", function()
            local input = {
                "- Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
            }
            local result = format_with_gw(input, 80)
            assert_continuation_indent(result, "^%- Lorem", "  ")
        end)

        it("indents continuation lines with 2 spaces for '* ' bullets", function()
            local input = {
                "* Asterisk bullet that is long enough to wrap onto another line when formatted at eighty character width limit.",
            }
            local result = format_with_gw(input, 80)
            assert_continuation_indent(result, "^%* Asterisk", "  ")
        end)

        it("indents continuation lines with 2 spaces for '+ ' bullets", function()
            local input = {
                "+ Plus bullet that is long enough to wrap onto another line when formatted at eighty character width limit here.",
            }
            local result = format_with_gw(input, 80)
            assert_continuation_indent(result, "^%+ Plus", "  ")
        end)

        it("preserves indentation of nested bullets", function()
            local input = {
                "  - Nested indented bullet that is long enough to wrap onto another line when formatted at eighty chars.",
            }
            local result = format_with_gw(input, 80)
            -- Nested bullet at 2-space indent should have 4-space continuation
            assert_continuation_indent(result, "^  %- Nested", "    ")
        end)

        it("handles multiple bullet items correctly", function()
            local input = {
                "- First item that is long enough to wrap onto another line when formatted at eighty character width.",
                "- Second item that is also long enough to wrap onto multiple lines when the width is eighty.",
            }
            local result = format_with_gw(input, 80)

            -- Find where second item starts
            local second_item_idx = nil
            for i, line in ipairs(result) do
                if line:match("^%- Second") then
                    second_item_idx = i
                    break
                end
            end
            assert(second_item_idx, "Should find second bullet item")

            -- Check first item's continuations (lines 2 to second_item_idx-1)
            for i = 2, second_item_idx - 1 do
                local line = result[i]
                if line ~= "" then
                    eq("  ", line:sub(1, 2), "First item continuation should have 2-space indent")
                end
            end

            -- Check second item's continuations
            for i = second_item_idx + 1, #result do
                local line = result[i]
                if line ~= "" then
                    eq("  ", line:sub(1, 2), "Second item continuation should have 2-space indent")
                end
            end
        end)
    end)

    describe("numbered list continuation", function()
        it("indents continuation lines with 3 spaces for '1. ' numbers", function()
            local input = {
                "1. Numbered item that is long enough to wrap onto another line when formatted at eighty character width limit.",
            }
            local result = format_with_gw(input, 80)
            -- "1. " is 3 chars, so continuation should be 3 spaces
            assert_continuation_indent(result, "^1%. Numbered", "   ")
        end)

        it("indents continuation lines correctly for '10. ' numbers", function()
            local input = {
                "10. Double digit numbered item that is long enough to wrap onto another line when formatted properly.",
            }
            local result = format_with_gw(input, 80)
            -- "10. " is 4 chars, so continuation should be 4 spaces
            assert_continuation_indent(result, "^10%. Double", "    ")
        end)
    end)
end)
