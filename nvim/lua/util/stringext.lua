-- Lua `string` extensions

---Only append `value` to the string `s` if `s` doesn't already contain `value`.
---@param s string
---@param value string
---@param delim? string
---@return string
---@nodiscard
function string.append_once(s, value, delim)
    local delim = delim or ""
    if not s:find(value, 0, true) then
        return s .. delim .. value
    else
        return s
    end
end
