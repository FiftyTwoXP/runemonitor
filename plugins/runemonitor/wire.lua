-- Small, dependency-free form codec used by the RuneMonitor relay protocol.
local Wire = {}

Wire.MAX_RESPONSE_BYTES = 64 * 1024

local function encodePart(value)
    local text = tostring(value)
    -- Lua's %w is locale-sensitive; protocol unreserved bytes are ASCII only.
    return (text:gsub("([^A-Za-z0-9%-%.%_~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function decodePart(value)
    local position = 1
    while true do
        local percent = value:find("%", position, true)
        if not percent then break end
        if not value:sub(percent + 1, percent + 2):match("^%x%x$") then
            return nil, "malformed percent escape"
        end
        position = percent + 3
    end
    value = value:gsub("+", " ")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function Wire.encode(fields)
    assert(type(fields) == "table", "fields must be a table")
    local keys = {}
    for key, value in pairs(fields) do
        if value ~= nil then
            keys[#keys + 1] = tostring(key)
        end
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = encodePart(key) .. "=" .. encodePart(fields[key])
    end
    return table.concat(parts, "&")
end

function Wire.decode(body)
    if type(body) ~= "string" then
        return nil, "response is not a string"
    end
    if #body > Wire.MAX_RESPONSE_BYTES then
        return nil, "response exceeds 64 KiB"
    end
    if body == "" then
        return {}
    end

    local fields = {}
    for part in body:gmatch("[^&]+") do
        local equals = part:find("=", 1, true)
        if not equals then
            return nil, "form field has no equals sign"
        end
        local rawKey, rawValue = part:sub(1, equals - 1), part:sub(equals + 1)
        local key, keyError = decodePart(rawKey)
        local value, valueError = decodePart(rawValue)
        if not key or not value then
            return nil, keyError or valueError
        end
        if key == "" then
            return nil, "empty form key"
        end
        if fields[key] ~= nil then
            return nil, "duplicate form key"
        end
        fields[key] = value
    end
    if body:sub(-1) == "&" or body:find("&&", 1, true) then
        return nil, "empty form field"
    end
    return fields
end

return Wire
