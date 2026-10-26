-- Transport-independent RuneMonitor state machine. Game API calls live in main.lua.
local Controller = {}
Controller.__index = Controller

local RETRIES = { 1, 2, 4, 8, 15 }
-- Registration needs no secret: the relay only accepts this PC, and this fixed
-- Authorization value only keeps web pages out (see the relay's server.mjs).
local LOCAL_REGISTRATION = "runemonitor-local-v1"

local function copySnapshot(snapshot)
    local copy = {}
    for key, value in pairs(snapshot or {}) do copy[key] = value end
    return copy
end

local function hasValue(value)
    return value ~= nil and tostring(value) ~= ""
end

local function pointFields(snapshot)
    local fields = {
        state = snapshot.state or "unknown",
        displayName = snapshot.name or "Unknown",
        readingSource = snapshot.readingSource or "unavailable",
    }
    for _, name in ipairs({ "hpCurrent", "hpMax", "prayerCurrent", "prayerMax", "runEnergy",
        "specialAttackCurrent", "familiarCurrent", "familiarMax", "sampledAt",
        "activityIdleSeconds", "afkTimeoutSeconds", "afkSource", "skillXp", "membersWorld" }) do
        if snapshot[name] ~= nil then fields[name] = snapshot[name] end
    end
    local location = snapshot.location
    if type(location) == "table" and location.x ~= nil and location.z ~= nil and location.level ~= nil
        and location.facing ~= nil and type(location.isRegion) == "boolean" then
        fields.locationX, fields.locationZ, fields.locationLevel, fields.locationFacing =
            location.x, location.z, location.level, location.facing
        fields.locationIsRegion = location.isRegion and "1" or "0"
    end
    return fields
end

function Controller.new(deps)
    assert(type(deps) == "table" and type(deps.request) == "function", "request dependency is required")
    local settings = deps.settings or {}
    settings.characters = settings.characters or {}
    return setmetatable({
        deps = deps, settings = settings, activeId = nil, activeSnapshot = nil,
        inflight = nil, clearingId = nil, latestSnapshot = nil, generation = 0,
        nextAttemptAt = 0, retryIndex = 1, nextPublishAt = 0,
        connected = false, message = "Waiting for character", qr = nil,
        wantPairing = false, stopped = false, transitioning = false, unavailable = false,
        eventQueue = {},
    }, Controller)
end

function Controller:_save()
    if self.deps.save then self.deps.save(self.settings) end
end

function Controller:_clearQr()
    self.qr = nil
end

function Controller:_ready()
    return not self.stopped and self.deps.hasHttp()
end

function Controller:_begin(kind, path, fields, credential, done)
    if self.inflight or not self:_ready() then return false end
    local operation = { kind = kind, generation = self.generation,
        eventId = type(fields) == "table" and fields.eventId or nil }
    self.inflight = operation
    local cancelled = self.deps.request("POST", path, fields, credential, function(response)
        if self.inflight ~= operation or self.stopped then return end
        self.inflight = nil
        done(response or { ok = false, error = "empty response" }, operation)
    end)
    operation.cancel = cancelled
    return true
end

function Controller:_retry(reason)
    local now = self.deps.now()
    local seconds = RETRIES[self.retryIndex] or RETRIES[#RETRIES]
    self.retryIndex = math.min(self.retryIndex + 1, #RETRIES)
    self.nextAttemptAt = now + seconds
    self.connected = false
    self.message = reason or ("Relay unavailable; retrying in " .. tostring(seconds) .. "s")
end

function Controller:_publisherRejected(id, response)
    if response.code ~= 401 and response.code ~= 403 then return false end
    local entry = self.settings.characters[id]
    if entry then
        entry.publisherToken, entry.characterId, entry.blocked = nil, nil, true
        self:_save()
    end
    self.wantPairing = false
    self:_clearQr()
    self.connected = false
    self.message = "Character link expired or was revoked; choose Link phone to pair again"
    return true
end

function Controller:_registered(snapshot)
    local entry = self.settings.characters[self.activeId]
    return entry and entry.publisherToken and entry or nil
end

function Controller:queueEvent(event, profileKey)
    if self.stopped or type(event) ~= "table" or not hasValue(profileKey) then return false end
    local known = { drop = true, announcement = true, afk = true, lootbeam = true, collection = true }
    if not known[event.kind] then return false end
    local sequence = math.floor(tonumber(self.settings.eventSequence) or 0) + 1
    self.settings.eventSequence = sequence
    local fields = { eventId = "rm-" .. tostring(sequence) }
    for _, key in ipairs({"kind", "title", "message", "itemId", "quantity", "unitValue", "totalValue", "valueSource", "occurredAt"}) do
        if event[key] ~= nil then fields[key] = event[key] end
    end
    self.eventQueue[#self.eventQueue + 1] = {profileKey=tostring(profileKey),fields=fields,queuedAt=self.deps.now()}
    if #self.eventQueue > 40 then table.remove(self.eventQueue, 1) end
    self:_save()
    return true
end

function Controller:_sendEvent(entry)
    local selected
    for index = #self.eventQueue, 1, -1 do
        if self.deps.now() - self.eventQueue[index].queuedAt > 120 then table.remove(self.eventQueue, index) end
    end
    for _, item in ipairs(self.eventQueue) do
        if item.profileKey == self.activeId and self.deps.now() >= (item.retryAt or 0) then selected = item; break end
    end
    if not selected then return false end
    local id, generation = self.activeId, self.generation
    return self:_begin("event", "/api/events", selected.fields, entry.publisherToken, function(response)
        if self.generation ~= generation or self.activeId ~= id then return end
        -- Invalid input is not retried; other failures retain the same event ID.
        if response.ok or response.code == 400 or response.code == 413 then
            for index, item in ipairs(self.eventQueue) do
                if item == selected then table.remove(self.eventQueue, index); break end
            end
        elseif not self:_publisherRejected(id, response) then
            local attempt = selected.retryIndex or 1
            selected.retryAt = self.deps.now() + (RETRIES[attempt] or RETRIES[#RETRIES])
            selected.retryIndex = math.min(attempt + 1, #RETRIES)
        end
    end)
end

function Controller:_preemptAlert()
    local operation = self.inflight
    if not operation or operation.kind ~= "event" then return end
    self.inflight = nil
    if operation.cancel then pcall(operation.cancel) end
    -- An accepted-but-unacknowledged event may be retried with the same ID;
    -- the relay deduplicates it. Keep the next vital publish on schedule.
    for _, item in ipairs(self.eventQueue) do
        if item.fields.eventId == operation.eventId then item.retryAt = self.deps.now() + 0.2; break end
    end
end

function Controller:_register(snapshot)
    local id, generation = self.activeId, self.generation
    self:_begin("register", "/api/register", { profileKey = id, displayName = snapshot.name or "Unknown" },
        LOCAL_REGISTRATION, function(response)
            if self.generation ~= generation or self.activeId ~= id then return end
            if not response.ok or not response.fields or not hasValue(response.fields.publisherToken) then
                self:_retry(response.error or "Registration failed")
                return
            end
            local entry = self.settings.characters[id] or {}
            entry.publisherToken = response.fields.publisherToken
            entry.characterId = response.fields.characterId
            entry.blocked = nil
            self.settings.characters[id] = entry
            self:_save()
            self.retryIndex, self.nextAttemptAt = 1, self.deps.now()
            self.message = "Connected to local relay"
        end)
end

function Controller:_publish(snapshot, entry)
    local id, generation = self.activeId, self.generation
    self:_begin("publish", "/api/publish", pointFields(snapshot), entry.publisherToken, function(response)
        if self.generation ~= generation or self.activeId ~= id then return end
        if not response.ok then
            if not self:_publisherRejected(id, response) then self:_retry(response.error or "Publish failed") end
            return
        end
        self.connected, self.retryIndex = true, 1
        self.nextPublishAt, self.nextAttemptAt = self.deps.now() + 1, self.deps.now()
        self.message = "Live telemetry connected"
    end)
end

function Controller:_clearOld(id, snapshot, nextState)
    if self.clearingId or self.inflight then return end
    self.clearingId = id
    self:_clearQr()
    local entry = self.settings.characters[id]
    if not entry or not hasValue(entry.publisherToken) or not self:_ready() then
        self.clearingId = nil
        return
    end
    local clear = { state = nextState or "loggedout", displayName = (snapshot and snapshot.name) or "Unknown", readingSource = "unavailable" }
    self:_begin("clear", "/api/publish", clear, entry.publisherToken, function(response)
        -- An old clear must always release the single pipeline, even after identity changes.
        self.clearingId = nil
        if not response.ok then self:_publisherRejected(id, response) end
        if not response.ok then self.message = "Previous character may remain visible until stale" end
    end)
end

function Controller:_activate(snapshot)
    self.activeId = tostring(snapshot.identityKey)
    self.activeSnapshot = snapshot
    self.connected = false
    self.nextAttemptAt = self.deps.now()
    self.nextPublishAt = self.deps.now()
    self.retryIndex = 1
    self:_clearQr()
end

function Controller:_requestPairing(entry)
    local id, generation = self.activeId, self.generation
    self:_begin("pairing", "/api/pairing", {}, entry.publisherToken, function(response)
        if self.generation ~= generation or self.activeId ~= id then return end
        if not response.ok or not response.fields or not hasValue(response.fields.url) then
            -- Pairing is user initiated. Do not let a failed QR request occupy
            -- the publish lane forever; another explicit Link phone retries it.
            self.wantPairing = false
            if not self:_publisherRejected(id, response) then self:_retry(response.error or "Could not create pairing code") end
            return
        end
        local expires = tonumber(response.fields.expiresIn) or 120
        self.qr = { url = response.fields.url, matrix = response.fields.matrix,
            size = tonumber(response.fields.size), expiresAt = self.deps.now() + math.min(expires, 120) }
        self.wantPairing = false
        self.message = "Scan the pairing code within two minutes"
    end)
end

function Controller:tick()
    if self.stopped then return end
    local now = self.deps.now()
    if self.qr and now >= self.qr.expiresAt then self:_clearQr() end
    if not self:_ready() then
        -- Permission/key loss is a boundary: no late callback may restore a QR
        -- or connection indicator while the transport is unavailable.
        if not self.unavailable then
            self.unavailable = true
            self.generation = self.generation + 1
            if self.inflight and self.inflight.cancel then self.inflight.cancel() end
            self.inflight, self.clearingId = nil, nil
        end
        self:_clearQr()
        self.connected = false
        self.message = "HTTP permission is required"
        return
    end
    self.unavailable = false

    local snapshot = copySnapshot(self.deps.readSnapshot() or {})
    self.latestSnapshot = snapshot
    local usable = snapshot.available and hasValue(snapshot.identityKey)
    local desiredId = usable and tostring(snapshot.identityKey) or nil

    if self.inflight and self.inflight.kind == "event"
        and (desiredId ~= self.activeId or now >= self.nextPublishAt) then
        self:_preemptAlert()
    end

    if self.clearingId then return end
    if self.transitioning and desiredId == self.activeId then
        -- The identity recovered before the old request completed. Its callback
        -- is still generation-stale; resume from the latest snapshot afterward.
        self.transitioning = false
    end
    if self.activeId and self.activeId ~= desiredId then
        -- Keep the old identity until an in-flight registration/publish settles so
        -- its credential can be used for exactly one transition clear.
        if not self.transitioning then
            self.transitioning = true
            self.generation = self.generation + 1
            self:_clearQr()
            self.connected = false
            self.wantPairing = false
        end
        if self.inflight then return end
        local oldId, oldSnapshot = self.activeId, self.activeSnapshot
        self.activeId, self.activeSnapshot, self.connected = nil, nil, false
        self.transitioning = false
        local nextState = not desiredId and snapshot.state or "loggedout"
        if nextState == "game" then nextState = "unknown" end
        self:_clearOld(oldId, oldSnapshot, nextState)
        return
    end
    if not desiredId then
        self:_clearQr()
        self.message = snapshot.available and "Waiting for character identity"
            or (snapshot.state == "loggedout" and "Logged out; phone link saved"
                or "Waiting for the character to return; phone link saved")
        return
    end
    if not self.activeId then self:_activate(snapshot) else self.activeSnapshot = snapshot end
    if self.inflight or now < self.nextAttemptAt then return end

    local entry = self.settings.characters[self.activeId]
    if entry and entry.blocked then
        self.message = "Character link unavailable; choose Link phone to pair again"
        return
    end
    if not entry or not hasValue(entry.publisherToken) then
        self:_register(snapshot)
        return
    end
    if self.wantPairing then self:_requestPairing(entry); return end
    if now >= self.nextPublishAt then self:_publish(snapshot, entry); return end
    self:_sendEvent(entry)
end

function Controller:linkPhone()
    self.wantPairing = true
    self.nextAttemptAt = self.deps.now()
    self:_clearQr()
    if self.activeId then
        local entry = self.settings.characters[self.activeId] or {}
        entry.blocked = nil
        self.settings.characters[self.activeId] = entry
        self:_save()
    end
end

function Controller:revoke()
    if not self:_ready() or self.inflight or not self.activeId then return false end
    local id, entry = self.activeId, self.settings.characters[self.activeId]
    if not entry or not hasValue(entry.publisherToken) then return false end
    return self:_begin("revoke", "/api/revoke", {}, entry.publisherToken, function(response)
        if not response.ok then self:_retry(response.error or "Revoke failed"); return end
        local current = self.settings.characters[id] or {}
        current.publisherToken, current.characterId, current.blocked = nil, nil, true
        self.settings.characters[id] = current
        self:_save()
        self:_clearQr()
        self.connected = false
        self.message = "Character access revoked"
    end)
end

function Controller:shutdown()
    self.stopped, self.generation = true, self.generation + 1
    if self.inflight and self.inflight.cancel then self.inflight.cancel() end
    self.inflight = nil
    self:_clearQr()
end

function Controller:status()
    local snapshot = self.activeSnapshot or self.latestSnapshot or {}
    return { message = self.message, characterName = snapshot.name, qr = self.qr,
        pairedQR = self.qr ~= nil, connected = self.connected, activeId = self.activeId }
end

return Controller
