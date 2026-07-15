--- Tests for cursor-anchored Telescope picker config.

local eq = assert.are.same

describe("telescope cursor picker", function()
    local coc = require("telescope").extensions.coc
    local original_references_used = coc.references_used

    after_each(function()
        coc.references_used = original_references_used
    end)

    it("caps height at half the screen", function()
        local captured_opts
        coc.references_used = function(opts)
            captured_opts = opts
        end

        local mapping = vim.fn.maparg("gr", "n", false, true)
        mapping.callback()

        eq({ 0.5, max = 32 }, captured_opts.layout_config.height)

        local resolve_height = require("telescope.config.resolve").resolve_height
        local height = resolve_height(captured_opts.layout_config.height)
        eq(20, height(nil, 170, 40))
        eq(32, height(nil, 170, 80))
    end)
end)
