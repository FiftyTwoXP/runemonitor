-- Rendering only: the relay creates QR matrices; the client draws them.
local QR = {}

local function rowsFrom(matrix)
    if type(matrix) == "table" then
        return matrix
    end
    if type(matrix) ~= "string" or matrix == "" then
        return nil, "matrix must be a non-empty string or table"
    end
    local rows = {}
    for row in (matrix .. "/"):gmatch("(.-)/") do
        rows[#rows + 1] = row
    end
    return rows
end

function QR.validate(matrix)
    local rows, errorMessage = rowsFrom(matrix)
    if not rows then return nil, errorMessage end
    local size = #rows
    if size < 21 or size > 177 or (size - 21) % 4 ~= 0 then
        return nil, "invalid QR matrix size"
    end
    for _, row in ipairs(rows) do
        if type(row) ~= "string" or #row ~= size or row:find("[^01]") then
            return nil, "matrix rows must contain exactly size bits"
        end
    end
    return rows, size
end

function QR.draw(canvas, matrix, maxPixels)
    -- The game supplies ui.Canvas as userdata, while tests commonly use tables.
    -- Probe the method instead of rejecting a valid native canvas by Lua type.
    local readable, addRectangle = pcall(function() return canvas and canvas.AddRectangle end)
    if not readable or type(addRectangle) ~= "function" then
        return nil, "canvas must provide AddRectangle"
    end
    local rows, sizeOrError = QR.validate(matrix)
    if not rows then return nil, sizeOrError end
    local size = sizeOrError
    maxPixels = maxPixels or 280
    if type(maxPixels) ~= "number" or maxPixels < 1 then
        return nil, "maxPixels must be positive"
    end

    local modules = size + 8 -- ISO quiet zone: four modules on all sides.
    local pixelsPerModule = math.floor(maxPixels / modules)
    if pixelsPerModule < 1 then
        return nil, "canvas is too small for this QR matrix"
    end
    local width = modules * pixelsPerModule
    canvas:AddRectangle(0, 0, width, width, 0xFFFFFFFF)

    for y, row in ipairs(rows) do
        local x = 1
        while x <= size do
            if row:sub(x, x) == "1" then
                local finish = x
                while finish < size and row:sub(finish + 1, finish + 1) == "1" do
                    finish = finish + 1
                end
                canvas:AddRectangle((x + 3) * pixelsPerModule, (y + 3) * pixelsPerModule,
                    (finish - x + 1) * pixelsPerModule, pixelsPerModule, 0x000000FF)
                x = finish + 1
            else
                x = x + 1
            end
        end
    end
    return width
end

return QR
