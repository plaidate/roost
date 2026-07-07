-- Smoke-test harness. The Makefile stages smokeflag.lua: SMOKE_BUILD is false
-- for the release build (every hook below is a no-op) and true for the
-- instrumented `make smoke` build, which pcall-wraps the frame, writes a
-- 90-frame heartbeat plus any error to the datastore, and saves a periodic
-- screenshot. The game's built-in AUTOPILOT is driven by the same flag.

import "smokeflag"

Harness = {
    enabled = SMOKE_BUILD,
    counters = {},
    extra = nil,
    shotPath = nil,
}

function Harness.count(key, n)
    if not Harness.enabled then return end
    Harness.counters[key] = (Harness.counters[key] or 0) + (n or 1)
end

function Harness.set(key, val)
    if not Harness.enabled then return end
    Harness.counters[key] = val
end

function Harness.frame(frame, updateFn)
    if not Harness.enabled then
        updateFn()
        return
    end
    local ok, err = pcall(updateFn)
    if not ok then
        playdate.datastore.write({ err = tostring(err) }, "err")
    end
    if frame % 90 == 0 then
        local t = {}
        for k, v in pairs(Harness.counters) do t[k] = v end
        t.frame = frame
        if Harness.extra then pcall(Harness.extra, t) end
        playdate.datastore.write(t, "smoke")
    end
    if Harness.shotPath and frame % 300 == 0 and playdate.simulator then
        playdate.simulator.writeToFile(playdate.graphics.getDisplayImage(), Harness.shotPath)
    end
end
