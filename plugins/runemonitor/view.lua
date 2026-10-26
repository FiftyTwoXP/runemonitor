-- Build only inside the empty component supplied by ContentLayerReady.
-- No game-owned component lookup, separate window, or native input field.
local QR = require("qr")
local View = {}
View.__index = View

function View.new(parent, controller)
    local self = setmetatable({ parent = parent, controller = controller }, View)
    self.host = prettyui.SimpleView.new(parent, { width = parent.width, height = parent.height })
    self.host:AddTitle("RuneMonitor")
    self.message = self.host:AddText("Waiting for local relay")
    self.character = self.host:AddText("Character: waiting")
    self.readings = self.host:AddText("HP -- / --   Prayer -- / --")
    self.host:AddText("Experimental points. Use your phone on the same trusted Wi-Fi.")
    self.host:AddSimpleButton("Link phone", function() controller:linkPhone() end)
    self.host:AddSimpleButton("Revoke link", function() controller:revoke() end, {inline=true})
    self.qrLabel = self.host:AddText("Select Link phone to create a two-minute QR.")
    return self
end

local function points(value) return value == nil and "--" or tostring(value) end

function View:render(status, sample, now)
    self.message.content = status.message or "Waiting"
    self.character.content = "Character: " .. (sample.name or status.characterName or "waiting")
    self.readings.content = "HP " .. points(sample.hpCurrent) .. " / " .. points(sample.hpMax)
        .. "   Prayer " .. points(sample.prayerCurrent) .. " / " .. points(sample.prayerMax)
    local qr = status.qr
    local matrix = qr and qr.matrix or nil
    if matrix ~= self.qrMatrix then
        if self.canvas then self.canvas:Clear() end
        if matrix then
            if not self.canvas then
                self.canvas = ui.Canvas.new(self.parent)
                self.canvas:SetPos(20, 250)
                self.canvas:SetSize(290, 290)
                self.canvas.clickthrough, self.canvas.enabled = true, false
            end
            local ok, width = pcall(QR.draw, self.canvas, matrix, 280)
            if not ok or not width then self.canvas:Clear(); matrix = nil end
        end
        self.qrMatrix = matrix
    end
    if qr and matrix then
        self.qrLabel.content = "Scan and tap Pair character. Expires in "
            .. math.max(0, math.ceil((qr.expiresAt or now) - now)) .. " seconds."
    else
        self.qrLabel.content = "Select Link phone to create a two-minute QR."
    end
end

function View:destroy()
    if self.canvas then self.canvas:Destroy(); self.canvas = nil end
    self.host:Destroy()
end
return View

