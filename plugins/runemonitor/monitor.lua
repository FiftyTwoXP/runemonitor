-- Pure monitoring logic. Native event adapters live in main.lua so this module
-- can be tested without reading game entities, chat, or ground items itself.
local Monitor = {}
Monitor.__index = Monitor

local MAX_IDLE = 86400
local MAX_ITEM_ID = 2147483647
local MAX_VALUE = 1000000000000
-- Loot counts as a kill drop when it lands on or near an NPC that despawned
-- within KILL_WINDOW seconds, in either order (both can happen in one tick).
local KILL_WINDOW, KILL_MARGIN, MAX_TRACKED = 5, 2, 50

local function whole(value, maximum)
    return type(value) == "number" and value == value and value % 1 == 0
        and value >= 0 and value <= maximum and value or nil
end

local function nowOf(self)
    local value = self.deps.now()
    return type(value) == "number" and value == value and value or 0
end

local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

local function safeText(value, maximum)
    if type(value) ~= "string" then return nil end
    -- Game markup and control bytes do not belong in a phone notification.
    value = value:gsub("<[^>]*>", ""):gsub("[%z\1-\31\127]", " ")
    value = trim(value:gsub("%s+", " "))
    if value == "" then return nil end
    return #value > maximum and value:sub(1, maximum) or value
end

-- Display names appear with spaces, non-breaking spaces, underscores or hyphens.
local function normalName(value)
    value = value:lower():gsub("\194\160", " "):gsub("\160", " "):gsub("[_%-]", " ")
    return trim((value:gsub("%s+", " ")))
end

local function mentions(text, name)
    local wanted = normalName(name)
    if wanted == "" then return false end
    local words = " " .. normalName(text):gsub("[^%w ]", " ") .. " "
    return words:find(" " .. wanted .. " ", 1, true) ~= nil
end

local function tile(value)
    if type(value) ~= "table" then return nil end
    -- Kills and drops are compared tile to tile, inside instances too (up to 32767).
    local x, z, level = whole(value.x, 32767), whole(value.z, 32767), whole(value.level, 3)
    if x and z and level then return x, z, level end
end

local function nearKill(kill, drop)
    local x, z, level = tile(drop)
    return x ~= nil and level == kill.level
        and x >= kill.x - KILL_MARGIN and x <= kill.x + kill.size - 1 + KILL_MARGIN
        and z >= kill.z - KILL_MARGIN and z <= kill.z + kill.size - 1 + KILL_MARGIN
end

function Monitor.new(deps)
    assert(type(deps) == "table" and type(deps.now) == "function", "now dependency is required")
    return setmetatable({
        deps = deps, state = "unknown", focused = false, lastActivityAt = nil,
        sawObservedInput = false, mouseBaseline = nil, dropWarmupUntil = nil,
        profileKey = nil, cache = {}, cacheOrder = {}, cacheGeneration = 0,
        kills = {}, pendingDrops = {},
    }, Monitor)
end

function Monitor:_resetActivity()
    self.lastActivityAt, self.sawObservedInput, self.mouseBaseline = nil, false, nil
end

function Monitor:_clearCache()
    self.cache, self.cacheOrder, self.cacheGeneration = {}, {}, 0
    self.kills, self.pendingDrops = {}, {}
end

function Monitor:setState(state)
    state = type(state) == "string" and state or "unknown"
    if state == self.state then return end
    local wasGame, isGame = self.state == "game", state == "game"
    self.state = state
    if not isGame then
        self:_resetActivity()
        self.dropWarmupUntil = nil
        self:_clearCache()
    elseif not wasGame then
        self:_resetActivity()
        self.dropWarmupUntil = nowOf(self) + 10
    end
end

function Monitor:setProfile(identityKey)
    identityKey = type(identityKey) == "string" and identityKey or nil
    if identityKey == self.profileKey then return end
    self.profileKey = identityKey
    self:_resetActivity()
    self:_clearCache()
    self.dropWarmupUntil = self.state == "game" and nowOf(self) + 10 or nil
end

-- True once the character has been in game for the warm-up period, when
-- login-time readings (drops, XP) have settled.
function Monitor:isWarm()
    return self.state == "game" and self.dropWarmupUntil ~= nil and nowOf(self) >= self.dropWarmupUntil
end

function Monitor:setFocus(value)
    value = value == true
    if self.focused ~= value then self.mouseBaseline = nil end
    self.focused = value
end

function Monitor:_activity()
    self.lastActivityAt, self.sawObservedInput = nowOf(self), true
end

function Monitor:keyDown()
    if self.state == "game" then
        -- Some client reloads do not send a focus callback before the first key.
        self.focused = true
        self:_activity()
    end
end

function Monitor:_observeMouse()
    if self.state ~= "game" or not self.focused or type(self.deps.mousePosition) ~= "function" then return end
    local ok, x, y = pcall(self.deps.mousePosition)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then return end
    if not self.mouseBaseline then
        self.mouseBaseline = { x = x, y = y }
    elseif self.mouseBaseline.x ~= x or self.mouseBaseline.y ~= y then
        self.mouseBaseline = { x = x, y = y }
        self:_activity()
    end
end

function Monitor:activitySnapshot()
    self:_observeMouse()
    if self.state ~= "game" or not self.sawObservedInput or not self.lastActivityAt then
        return { afkSource = "unavailable" }
    end
    local elapsed = math.floor(math.max(0, math.min(MAX_IDLE, nowOf(self) - self.lastActivityAt)))
    return { activityIdleSeconds = elapsed, afkSource = "observed-input" }
end

function Monitor:_recent(key, seconds)
    local now = nowOf(self)
    local previous = self.cache[key]
    if previous and now - previous.at < seconds then return true end
    self.cacheGeneration = self.cacheGeneration + 1
    local entry = { at = now, generation = self.cacheGeneration }
    self.cache[key] = entry
    self.cacheOrder[#self.cacheOrder + 1] = { key = key, generation = entry.generation }
    while #self.cacheOrder > 100 do
        local oldest = table.remove(self.cacheOrder, 1)
        local current = self.cache[oldest.key]
        -- A key may have been renewed after this queued record was added.
        if current and current.generation == oldest.generation then self.cache[oldest.key] = nil end
    end
    return false
end

function Monitor:_emit(event)
    if type(self.deps.onEvent) == "function" then self.deps.onEvent(event) end
end

-- Only announcements that name this character are forwarded. Others would
-- export other players' names, which the plugin guidelines prohibit.
function Monitor:observeAnnouncement(text, playerName)
    if self.state ~= "game" or type(playerName) ~= "string" then return false end
    text = safeText(text, 500)
    if not text or not mentions(text, playerName) then return false end
    if self:_recent("announcement:" .. text, 10) then return false end
    self:_emit({ kind = "announcement", title = "Game announcement", message = text, valueSource = "unknown" })
    return true
end

-- Game messages (no sender) about the player's own loot. A loot beam reads
-- "A golden beam shines over one of your items. You receive: 2 x Dragon bones";
-- cosmetic beams change the first words and the verb ("A flower blooms over
-- one of your items", seen in game), so only the shared part is matched. The collection log wording is
-- not documented, so a game message that calls a collection log entry new,
-- added or unlocked counts, and the alert repeats the game's own words.
local function word(text, value)
    return text:find("%f[%a]" .. value .. "%f[%A]") ~= nil
end

function Monitor:observeGameMessage(text)
    if self.state ~= "game" then return false end
    text = safeText(text, 300)
    if not text then return false end
    local lower, event = text:lower(), nil
    if lower:find("over one of your items", 1, true) then
        local received = text:match("[Yy]ou receive:%s*(.+)$")
        event = { kind = "lootbeam", title = "Loot beam", message = received and ("You receive: " .. received) or text }
    elseif lower:find("collection log", 1, true) and not word(lower, "already")
        and (word(lower, "new") or word(lower, "added") or word(lower, "unlocked")) then
        event = { kind = "collection", title = "Collection log", message = text }
    else
        return false
    end
    if self:_recent(event.kind .. ":" .. text, 5) then return false end
    event.valueSource = "unknown"
    self:_emit(event)
    return true
end

function Monitor:_prune(now)
    for _, list in ipairs({ self.kills, self.pendingDrops }) do
        for index = #list, 1, -1 do
            if now - list[index].at > KILL_WINDOW then table.remove(list, index) end
        end
    end
end

-- An NPC (not a familiar) despawned at tile {x, z, level} with footprint size.
function Monitor:observeNpcRemoved(npc)
    if self.state ~= "game" then return end
    local x, z, level = tile(npc)
    if not x then return end
    local now = nowOf(self)
    self:_prune(now)
    local kill = { at = now, x = x, z = z, level = level, size = math.max(1, whole(npc.size, 32) or 1) }
    self.kills[#self.kills + 1] = kill
    if #self.kills > MAX_TRACKED then table.remove(self.kills, 1) end
    for index = #self.pendingDrops, 1, -1 do
        local pending = self.pendingDrops[index]
        if nearKill(kill, pending.drop) then
            table.remove(self.pendingDrops, index)
            self:_emitDrop(pending.drop)
        end
    end
end

-- Owned loot is logged only when it lands near a recent kill, so items the
-- player dropped earlier and walks past are ignored.
-- lastDropReason says why the last item on the ground was or was not logged.
function Monitor:observeDrop(drop)
    if self.state ~= "game" or type(drop) ~= "table" then self.lastDropReason = "not in game"; return false end
    if drop.isOwner ~= true then self.lastDropReason = "not yours"; return false end
    if not tile(drop) then self.lastDropReason = "no tile position"; return false end
    local now = nowOf(self)
    if not self.dropWarmupUntil or now < self.dropWarmupUntil then self.lastDropReason = "warming up after login"; return false end
    self:_prune(now)
    for _, kill in ipairs(self.kills) do
        if nearKill(kill, drop) then
            local logged = self:_emitDrop(drop)
            self.lastDropReason = logged and "logged (kill nearby)" or "kill nearby, but a repeat or zero count"
            return logged
        end
    end
    self.lastDropReason = "waiting for a kill nearby (" .. #self.kills .. " recent kills)"
    self.pendingDrops[#self.pendingDrops + 1] = { at = now, drop = drop }
    if #self.pendingDrops > MAX_TRACKED then table.remove(self.pendingDrops, 1) end
    return false
end

function Monitor:_emitDrop(drop)
    local itemId = whole(drop.itemId, MAX_ITEM_ID)
    local count = whole(drop.count, MAX_ITEM_ID)
    if not itemId or itemId <= 0 or not count or count <= 0 then return false end
    local delta = count
    if drop.oldCount ~= nil then
        local oldCount = whole(drop.oldCount, MAX_ITEM_ID)
        if oldCount == nil then return false end
        delta = count - oldCount
    end
    if delta <= 0 then return false end
    local name = safeText(drop.itemName, 470) or ("Item " .. tostring(itemId))
    local fingerprint = "drop:" .. itemId .. ":" .. count .. ":" .. delta
    if self:_recent(fingerprint, 3) then return false end
    local configuredCost = whole(drop.configuredCost, MAX_VALUE)
    local event = {
        kind = "drop", title = "Kill drop",
        message = safeText(tostring(delta) .. " x " .. name, 500),
        itemId = itemId, quantity = delta,
        valueSource = configuredCost and "configured" or "unknown",
    }
    if configuredCost then
        event.unitValue = configuredCost
        -- A cap would invent a value. Only send a total when the exact
        -- configured calculation fits the relay's bounded integer contract.
        if configuredCost == 0 or delta <= math.floor(MAX_VALUE / configuredCost) then
            event.totalValue = configuredCost * delta
        end
    end
    self:_emit(event)
    return true
end

return Monitor
