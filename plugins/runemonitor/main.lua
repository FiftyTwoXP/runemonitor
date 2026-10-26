-- RuneMonitor: local-only, read-only telemetry. No gameplay inputs or actions.
local Wire, Probe = require("wire"), require("probe")
local Controller, Sampler, View = require("controller"), require("sampler"), require("view")
local Monitor = require("monitor")
local configOK, localSettings = pcall(require, "local_settings")
if not configOK or type(localSettings) ~= "table" then localSettings = {} end
-- The in-game panel is on unless a developer's local_settings turns it off.
local enableUI = localSettings.enableUI ~= false
if enableUI and (not prettyui or not prettyui.SimpleView) then
    error("RuneMonitor requires PrettyUI (6398181). Install it in the developer beta first.")
end

local now, stopped, view, settingsView, monitor = 0, false, nil, nil, nil
local renderElapsed = 0
local requests, starting = {}, {}
local settings = PersistentDB:GetStructuredData("runemonitor-v2") or {}
if type(settings) ~= "table" then settings = {} end
-- Resume with the locally saved publisher credential. Re-registering only by
-- display name rotates it and invalidates the phone's existing grant.
if type(settings.characters) ~= "table" then settings.characters = {} end
for key, value in pairs(settings.characters) do
    if type(key) ~= "string" or type(value) ~= "table" then settings.characters[key] = nil end
end
-- Older versions stored a relay installation key; registration no longer needs one.
settings.installationKey = nil
local probePassed, probeRunning, probeRetryAt = false, false, 0
local probeMessage = "Checking the local relay"

local function hasPermission(permission)
    return Plugin.HasPermission(permission)
end

local function request(method, path, fields, credential, done)
    local entry = { startedAt = now, finished = false }
    requests[entry] = true
    local function complete(response)
        if entry.finished then return end
        entry.finished = true
        requests[entry] = nil
        if not stopped then done(response) end
    end
    entry.start = function()
        local ok, err = pcall(function()
            entry.native = HTTPRequest.new(Plugin.urls.relay, path)
            entry.native:AddHeader("Content-Type", "application/x-www-form-urlencoded")
            entry.native:AddHeader("X-RuneMonitor-Source", "official-client-api")
            if credential then entry.native:AddHeader("Authorization", "Bearer " .. credential) end
            local function callback(result)
                local parsed, parseError = {}, nil
                local raw, code = result.data or "", tonumber(result.responseCode) or 0
                if path ~= "/health" and path ~= "/api/probe" then parsed, parseError = Wire.decode(raw) end
                local successful = result.successful and code >= 200 and code < 300 and not parseError
                local info = tostring(result.errorInfo or "")
                complete({ ok = successful, code = code, fields = parsed or {}, raw = raw,
                    error = parseError or (parsed and parsed.error)
                        or (info ~= "" and info or (not successful and "Relay HTTP " .. tostring(code) or nil)) })
            end
            if method == "GET" then entry.native:Get(callback)
            else
                local body = type(fields) == "string" and fields or Wire.encode(fields or {})
                -- The beta client's empty Post body arrived at the relay as GET.
                -- Pairing/revocation have no other fields; keep their body nonempty.
                if body == "" then body = "protocol=1" end
                entry.native:Post(body, callback)
            end
        end)
        if not ok then complete({ ok = false, code = 0, fields = {}, error = tostring(err) }) end
    end
    -- Native requests start from the Logic tick, never inside another request's
    -- completion callback: other developers saw that pattern crash the client.
    starting[#starting + 1] = entry
    entry.cancel = function()
        if entry.finished then return end
        entry.finished = true
        requests[entry] = nil
        if entry.native then pcall(function() entry.native:Cancel() end) end
    end
    entry.timeout = function()
        if entry.finished then return end
        complete({ ok = false, code = 0, fields = {}, error = "Local relay request timed out" })
        if entry.native then pcall(function() entry.native:Cancel() end) end
    end
    return entry.cancel
end

local function startQueuedRequests()
    local queued = starting
    starting = {}
    for _, entry in ipairs(queued) do
        if not entry.finished then entry.start() end
    end
end

local sampler = Sampler.new({ Player = Player, World = World, var = var, SkillType = SkillType, CoordGrid = CoordGrid })
local latestSample = { readingSource = "unavailable" }
local nextSampleAt = 0
local lastLocationProblem = nil
local lastProbeLine = nil
local function readSnapshot()
    if now >= nextSampleAt then
        latestSample = sampler:read()
        -- Say why the map has no position, once each time the reason changes.
        if sampler.locationProblem ~= lastLocationProblem then
            lastLocationProblem = sampler.locationProblem
            print("[runemonitor] Map position: " .. (lastLocationProblem or "OK again"))
        end
        if monitor then
            monitor:setState(latestSample.state or "unknown")
            monitor:setProfile(latestSample.identityKey)
            for key, value in pairs(monitor:activitySnapshot()) do latestSample[key] = value end
            -- Skip XP until login readings settle, so the tracker never starts
            -- from a not-yet-loaded zero.
            if not monitor:isWarm() then latestSample.skillXp = nil end
        end
        nextSampleAt = now + 1
    end
    return latestSample
end
local controller = Controller.new({
    request = request, now = function() return now end,
    readSnapshot = readSnapshot,
    settings = settings,
    hasHttp = function() return probePassed and hasPermission(PluginPermissions.httpAccess) end,
    save = function(value)
        local ok, err = pcall(function() PersistentDB:SetStructuredData("runemonitor-v2", value) end)
        if not ok then print("[runemonitor] Settings could not be saved: " .. tostring(err)) end
    end,
})

monitor = Monitor.new({
    now = function() return now end,
    onEvent = function(event)
        local current = readSnapshot()
        if current.available and current.identityKey then controller:queueEvent(event, current.identityKey) end
    end,
    mousePosition = function()
        if not Mouse then return nil end
        local ok, x, y = pcall(function()
            if not Mouse.IsAvailable() then return nil end
            return Mouse.GetX(), Mouse.GetY()
        end)
        if ok then return x, y end
    end,
})

-- Only system/broadcast announcement channels are forwarded. Player chat,
-- private messages, clan/friends conversations, and sender fields are omitted.
local announcementTypes = {}
if ChatType then
    for _, name in ipairs({"SYSTEM_BROADCAST", "BROADCAST", "WORLD_EVENT", "MISC_BROADCAST",
        "LATEST_NEWSPOST", "MOTD", "BROADCAST_GLOBAL", "BROADCAST_WORLD", "BROADCAST_FRIENDS", "TIMED_EVENT"}) do
        if ChatType[name] ~= nil then announcementTypes[ChatType[name]] = true end
    end
end

-- Game messages carry no sender; only these types can hold the loot beam and
-- collection log lines, so player, clan and plugin chat can never imitate them.
local gameMessageTypes = {}
if ChatType then
    for _, name in ipairs({"GENERAL", "ENGINE", "SPAM", "GENERAL_LINKABLE"}) do
        if ChatType[name] ~= nil then gameMessageTypes[ChatType[name]] = true end
    end
end

local function runProbe()
    if probePassed or probeRunning or now < probeRetryAt or not hasPermission(PluginPermissions.httpAccess) then return end
    probeRunning, probeMessage = true, "Checking loopback GET and POST"
    Probe.run(function(method, path, body, done)
        request(method, path, body, nil, function(result) done(result.ok, result.code, result.raw) end)
    end, function(ok, message)
        probeRunning, probePassed, probeMessage = false, ok, message
        probeRetryAt = now + 5
        -- Only say something when it changes: connected, or why not.
        local line = ok and "Connected to the RuneMonitor Relay" or ("Can't reach the RuneMonitor Relay: " .. message)
        if line ~= lastProbeLine then lastProbeLine = line; print("[runemonitor] " .. line) end
    end)
end

local function status()
    local value = controller:status()
    if not hasPermission(PluginPermissions.httpAccess) then
        value.message = "Grant HTTP: plugins_permissions_enable runemonitor httpAccess"
    elseif not probePassed then value.message = probeMessage
    end
    return value
end

local function destroyView()
    local old = view
    view = nil
    if old then pcall(function() old:destroy() end) end
end

local function destroySettingsView()
    local old = settingsView
    settingsView = nil
    if old then pcall(function() old:destroy() end) end
end

Event.Logic.Subscribe("runemonitor-tick", function()
    if stopped then return end
    now, renderElapsed = now + 0.02, renderElapsed + 0.02
    for entry in pairs(requests) do
        if now - entry.startedAt >= 5 then entry.timeout() end
    end
    runProbe()
    controller:tick()
    startQueuedRequests()
    if renderElapsed >= 0.5 then
        renderElapsed = 0
        if enableUI then
            local current = (view or settingsView) and readSnapshot() or nil
            if view then view:render(status(), current, now) end
            if settingsView then settingsView:render(status(), current, now) end
        end
    end
end)

Event.GameStateChanged.Subscribe("runemonitor-state", function(event)
    sampler:setState(event.newState)
    monitor:setState(sampler.state)
    latestSample = { available = false, state = sampler.state, readingSource = "unavailable" }
    nextSampleAt = now + (event.newState == 30 and 0 or 1)
    destroyView()
    destroySettingsView()
    controller:tick()
    startQueuedRequests()
end)
Event.OptionalPermissionChanged.Subscribe("runemonitor-permission", function(event)
    print("[runemonitor] Permission event: " .. tostring(event.permissionName) .. " enabled=" .. tostring(event.enabled))
    if event.permissionName == "httpAccess" and not event.enabled then probePassed = false end
    controller:tick()
    startQueuedRequests()
end)
Event.ContentLayerReady.Subscribe("runemonitor-content", function(event)
    if not enableUI then return end
    destroyView()
    view = View.new(event.component, controller)
end)
Event.SettingsLayerReady.Subscribe("runemonitor-settings", function(event)
    if not enableUI then return end
    destroySettingsView()
    settingsView = View.new(event.component, controller)
end)

Event.KeyDown.Subscribe("runemonitor-activity-key", function() monitor:keyDown() end)
Event.WindowFocusChanged.Subscribe("runemonitor-focus", function(event) monitor:setFocus(event.hasFocus == true) end)
Event.ChatMessage.Subscribe("runemonitor-announcement", function(event)
    if not hasPermission(PluginPermissions.chatAccess) then return end
    if announcementTypes[event.chatType] then
        monitor:observeAnnouncement(event.chatMessage, readSnapshot().name)
    elseif gameMessageTypes[event.chatType] and (event.senderNameUnfiltered or "") == "" then
        local matched = monitor:observeGameMessage(event.chatMessage)
        -- RS3's collection log wording is undocumented: a collection message
        -- that did not alert is shown, so a wording change can be spotted.
        local text = type(event.chatMessage) == "string" and event.chatMessage or ""
        if not matched and text:lower():find("collection log", 1, true) then
            print("[runemonitor] Collection log message not recognised: " .. text:sub(1, 300))
        end
    end
end)
local function tileOf(entity)
    local grid = entity.coordGrid
    return grid.x, grid.z, grid.level
end
local npcTileWarned = false
Event.NPCEntityRemoved.Subscribe("runemonitor-npc-removed", function(event)
    local ok, npc = pcall(function()
        local config = event.npcEntity.config
        if config and config.isFamiliar then return nil end
        local x, z, level = tileOf(event.npcEntity)
        return { x = x, z = z, level = level, size = config and config.gridSize or 1 }
    end)
    if ok and npc then monitor:observeNpcRemoved(npc)
    elseif not ok and not npcTileWarned then
        npcTileWarned = true
        print("[runemonitor] A despawned NPC's tile could not be read, so its loot cannot be matched: " .. tostring(npc))
    end
end)
local function observeDrop(event, changed)
    if event.isOwner ~= true then return end
    -- objType is the event's documented immutable item config. Do not inspect
    -- game-owned UI or unrelated players' entities to infer ownership.
    local ok, item = pcall(function()
        if not event.objType then return nil end
        local x, z, level = tileOf(event.objStackEntity)
        return {itemId=event.objType.id, itemName=event.objType.name, configuredCost=event.objType.cost,
            count=changed and event.newCount or event.count, oldCount=changed and event.oldCount or nil, isOwner=true,
            x=x, z=z, level=level}
    end)
    if ok and item then monitor:observeDrop(item) end
end
Event.ObjStackEntityAdded.Subscribe("runemonitor-owned-drop", function(event) observeDrop(event, false) end)
Event.ObjStackEntityChanged.Subscribe("runemonitor-owned-stack", function(event) observeDrop(event, true) end)

function PluginShutdown()
    stopped = true
    controller:shutdown()
    for entry in pairs(requests) do entry.cancel() end
    starting = {}
    for eventName, reference in pairs({ Logic = "runemonitor-tick", GameStateChanged = "runemonitor-state",
        OptionalPermissionChanged = "runemonitor-permission", ContentLayerReady = "runemonitor-content",
        SettingsLayerReady = "runemonitor-settings", KeyDown = "runemonitor-activity-key",
        WindowFocusChanged = "runemonitor-focus", ChatMessage = "runemonitor-announcement",
        ObjStackEntityAdded = "runemonitor-owned-drop", ObjStackEntityChanged = "runemonitor-owned-stack",
        NPCEntityRemoved = "runemonitor-npc-removed" }) do
        Event[eventName].Unsubscribe(reference)
    end
    destroyView()
    destroySettingsView()
end

print("[runemonitor] Loaded v1.0.0. Choose Link phone in its panel to pair a phone; loot beam and collection log alerts need Chat access.")

