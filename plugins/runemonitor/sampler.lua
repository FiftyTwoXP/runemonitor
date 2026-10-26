-- Read only the local player's exposed point counters. Gameplay skill levels
-- are deliberately never used as substitute lifepoints or prayer points.
local Sampler = {}
Sampler.__index = Sampler
local states = { [0] = "unknown", [10] = "loggedout", [20] = "lobby", [30] = "game",
    [35] = "reconnecting", [36] = "reconnecting", [37] = "loading", [40] = "loading" }

local function integer(value)
    return type(value) == "number" and value == value and value >= 0
        and value <= 2147483647 and value % 1 == 0 and value or nil
end

function Sampler.parsePoints(text)
    if type(text) ~= "string" or #text > 256 then return nil end
    text = text:gsub("<[^>]*>", ""):gsub(",", "")
    local current, maximum = text:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
    current, maximum = integer(tonumber(current)), integer(tonumber(maximum))
    if current and maximum and maximum > 0 then return current, maximum end
end

function Sampler.new(api)
    return setmetatable({ api = api, state = "unknown" }, Sampler)
end

function Sampler:setState(value) self.state = states[value] or "unknown" end

function Sampler:pointVar(name)
    local ok, value = pcall(function() return self.api.var.VarPlayer[name].value end)
    return ok and integer(value) or nil
end

function Sampler:prayerMaximum(current)
    -- The normal prayer-point cap is ten times the world-capped base level.
    -- Only the denominator uses this formula; CURRENT points always come from
    -- PRAYER_POINTS, including overboosts. Never inspect a game-owned UI node.
    local ok, level = pcall(function() return self.api.Player.GetLevelCapped(self.api.SkillType.PRAYER) end)
    level = ok and integer(level) or nil
    if level and level > 0 and level <= 1000 then return level * 10 end
end

function Sampler:prayerPoints()
    local raw = self:pointVar("PRAYER_POINTS")
    if raw == nil then return nil end
    -- Observed in the beta client: VarPlayer.PRAYER_POINTS is fixed-point in
    -- tenths (for example 9900 renders as 990/990; 8350 as 835). The monitor
    -- deliberately exposes whole experimental points and floors any fractional
    -- tenth rather than claiming a precision the game UI does not display.
    return math.floor(raw / 10)
end

function Sampler:specialAttackPoints()
    -- VarPlayer.SA_ENERGY is the local special/adrenaline resource. The
    -- fixed-point-tenths conversion is experimental until the first native-bar
    -- comparison; the one-time raw diagnostic below makes that check explicit.
    -- Keep a generous bound for temporary adrenaline extensions, never clip.
    local raw = self:pointVar("SA_ENERGY")
    if raw == nil or raw > 2000 then return nil, raw end
    return math.floor(raw / 10), raw
end

-- Familiar spell (special move) points, which a familiar spends on its special
-- move; a familiar holds at most 60. LORE_SPELL_POINTS holds whole points: the
-- beta client reported 59 while the game showed 59/60.
Sampler.FAMILIAR_MAX = 60

function Sampler:familiarPoints()
    local raw = self:pointVar("LORE_SPELL_POINTS")
    if raw == nil or raw > 10000 then return nil, raw end
    return raw, raw
end

-- Skills in SkillType order: ATTACK is 0 and NECROMANCY is 28.
Sampler.SKILLS = { "ATTACK", "DEFENCE", "STRENGTH", "HITPOINTS", "RANGED", "PRAYER", "MAGIC", "COOKING",
    "WOODCUTTING", "FLETCHING", "FISHING", "FIREMAKING", "CRAFTING", "SMITHING", "MINING", "HERBLORE",
    "AGILITY", "THIEVING", "SLAYER", "FARMING", "RUNECRAFTING", "HUNTER", "CONSTRUCTION", "SUMMONING",
    "DUNGEONEERING", "DIVINATION", "INVENTION", "ARCHAEOLOGY", "NECROMANCY" }

-- Every skill's current XP as "index:xp,...", or nil if any skill is unreadable.
function Sampler:skillXp()
    local parts = {}
    for index, name in ipairs(Sampler.SKILLS) do
        local ok, xp = pcall(function() return self.api.Player.GetXPUncapped(self.api.SkillType[name]) end)
        xp = ok and integer(xp) or nil
        if xp == nil then return nil end
        parts[#parts + 1] = (index - 1) .. ":" .. xp
    end
    return table.concat(parts, ",")
end

local function coordinate(value, maximum)
    return type(value) == "number" and value == value and value % 1 == 0
        and value >= 0 and value <= maximum and value or nil
end

-- "1" on a members world, "0" on a free one. Only members can be on a members
-- world, which adds 5 minutes to the idle logout; the relay works out the rest.
function Sampler:membersWorld()
    local ok, isAvailable, members = pcall(function()
        if not self.api.World or not self.api.World.IsAvailable or not self.api.World.IsMembers then return nil end
        if not self.api.World.IsAvailable() then return nil end
        return true, self.api.World.IsMembers()
    end)
    if not ok or isAvailable ~= true or type(members) ~= "boolean" then return nil end
    return members and "1" or "0"
end

function Sampler:location(entity)
    -- Only expose the current local entity after the name/identity check above.
    -- If the world API cannot establish whether this is an instanced region,
    -- omit the location rather than rendering a potentially wrong world map.
    local worldOK, isAvailable, isRegion = pcall(function()
        if not self.api.World or not self.api.World.IsAvailable or not self.api.World.IsRegion then return nil end
        if not self.api.World.IsAvailable() then return nil end
        return true, self.api.World.IsRegion()
    end)
    -- Why the last position was left out, for the console (nil when it worked).
    self.locationProblem = nil
    if not worldOK or isAvailable ~= true or type(isRegion) ~= "boolean" then
        self.locationProblem = "world API unavailable (available=" .. tostring(isAvailable)
            .. ", region=" .. tostring(isRegion) .. ")"
        return nil
    end
    local coordsOK, xValue, zValue, levelValue, facingValue = pcall(function()
        local grid = entity.coordGrid
        return grid.x, grid.z, grid.level, entity.facing
    end)
    -- Instances sit beyond the 12799-tile world map (up to 32767); they are
    -- converted to world tiles below, and only world tiles are published.
    local x, z, level, facing = coordinate(xValue, 32767), coordinate(zValue, 32767),
        coordinate(levelValue, 3), coordinate(facingValue, 359)
    if not coordsOK or not x or not z or level == nil or facing == nil then
        self.locationProblem = "position out of range or unreadable (x=" .. tostring(xValue) .. ", z=" .. tostring(zValue)
            .. ", level=" .. tostring(levelValue) .. ", facing=" .. tostring(facingValue) .. ", region=" .. tostring(isRegion) .. ")"
        return nil
    end
    if isRegion then
        local sourceX, sourceZ, sourceLevel = self:regionSource(x, z, level)
        if sourceX then return { x = sourceX, z = sourceZ, level = sourceLevel, facing = facing, isRegion = false } end
    end
    if x > 12799 or z > 12799 then
        self.locationProblem = "instance tile " .. x .. "," .. z .. " has no world source to map it to"
        return nil
    end
    return { x = x, z = z, level = level, facing = facing, isRegion = isRegion }
end

-- Inside a region (an instance), find the world tile it was copied from so the
-- map can show that terrain. The API returns the bottom-left of the copied
-- block: an 8x8 zone or a 64x64 map square. Only a whole-square copy gives a
-- neighbouring zone the same source, and that source is square-aligned.
-- Rotated zones are not exposed, so positions inside them may be a few tiles off.
function Sampler:regionSource(x, z, level)
    local ok, sourceX, sourceZ, sourceLevel, wholeSquare = pcall(function()
        local function source(tileX, tileZ)
            local coord = self.api.CoordGrid.new(level, tileX // 64, tileZ // 64, tileX % 64, tileZ % 64)
            local found = self.api.World.GetRegionSourceForCoordGrid(coord)
            if found then return found.x, found.z, found.level end
        end
        local bottomX, bottomZ, bottomLevel = source(x, z)
        if bottomX == nil then return nil end
        local neighbourX, neighbourZ, neighbourLevel = source((x % 64) < 56 and x + 8 or x - 8, z)
        return bottomX, bottomZ, bottomLevel, neighbourX == bottomX and neighbourZ == bottomZ
            and neighbourLevel == bottomLevel and bottomX % 64 == 0 and bottomZ % 64 == 0
    end)
    if not ok or sourceX == nil then return nil end
    local size = wholeSquare and 64 or 8
    local tileX, tileZ = coordinate(sourceX + x % size, 12799), coordinate(sourceZ + z % size, 12799)
    local tileLevel = coordinate(sourceLevel, 3)
    if tileX and tileZ and tileLevel then return tileX, tileZ, tileLevel end
end

function Sampler:read()
    if self.state ~= "game" and self.state ~= "unknown" then
        return { available = false, state = self.state, readingSource = "unavailable" }
    end
    local availableOK, available = pcall(self.api.Player.IsAvailable)
    if not availableOK or not available then
        return { available = false, state = self.state == "game" and "unknown" or self.state, readingSource = "unavailable" }
    end
    local result = { available = true, state = "game", readingSource = "unavailable" }
    -- Native tracking access caused a client crash during this POC. Use only
    -- the current local player's documented display name. Renames require a
    -- fresh local profile/pairing; this is not a Jagex ownership credential.
    local entity, nameOK, name
    nameOK, name = pcall(function()
        entity = self.api.Player.GetEntity()
        if not entity or not entity.isValid then return nil end
        return entity.displayName
    end)
    if nameOK and type(name) == "string" and name ~= "" and #name <= 150 then
        result.name = name
        result.identityKey = "name:" .. name
        result.location = self:location(entity)
    end
    result.hpCurrent = self:pointVar("LIFEPOINTS")
    result.hpMax = self:pointVar("MAXLIFEPOINTS")
    if result.hpMax == 0 then result.hpMax = nil end
    result.prayerCurrent = self:prayerPoints()
    if result.prayerCurrent then result.prayerMax = self:prayerMaximum(result.prayerCurrent) end
    result.specialAttackCurrent, result.specialAttackRaw = self:specialAttackPoints()
    result.familiarCurrent, result.familiarRaw = self:familiarPoints()
    if result.familiarCurrent then result.familiarMax = Sampler.FAMILIAR_MAX end
    result.skillXp = self:skillXp()
    result.membersWorld = self:membersWorld()
    local energyOK, runEnergy = pcall(function() return self.api.Player.GetRunEnergy() end)
    result.runEnergy = energyOK and coordinate(runEnergy, 100) or nil
    if result.hpCurrent and result.hpMax and result.prayerCurrent then result.readingSource = "var" end
    if self.api.timestamp then result.sampledAt = self.api.timestamp() end
    return result
end

return Sampler
