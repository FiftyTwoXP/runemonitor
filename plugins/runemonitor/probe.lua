-- Pure protocol gate. A mock can test this, but only the real client can prove
-- that its HTTP permission and loopback URL policy admit the requests.
local Probe = {}

function Probe.run(request, done)
    request("GET", "/health", nil, function(ok, code, body)
        if not ok or code ~= 200 or body ~= "RUNEMONITOR_HEALTH_V1" then
            done(false, "Loopback GET failed (HTTP " .. tostring(code) .. ").")
            return
        end
        request("POST", "/api/probe", "runemonitor-loopback-v1", function(postOK, postCode, reply)
            if postOK and postCode == 200 and reply == "RUNEMONITOR_PROBE_OK_V1" then
                done(true, "Loopback GET and POST passed.")
            else
                done(false, "Loopback POST failed (HTTP " .. tostring(postCode) .. ").")
            end
        end)
    end)
end

return Probe
