-- Roost — a 1-bit aerial arcade game for Playdate
-- Original flap-to-fly flying-combat game (procedural 1-bit art).
-- Controls: d-pad left/right to steer, A (or crank) to flap.

import "CoreLibs/graphics"
import "CoreLibs/crank"

local gfx <const> = playdate.graphics
local snd <const> = playdate.sound

local SCREEN_W <const> = 400
local SCREEN_H <const> = 240
local DT <const> = 1 / 30

-- Physics (pixels / second)
local GRAVITY <const> = 300
local MAX_FALL <const> = 230
local FLAP_IMPULSE <const> = 95
local MAX_RISE <const> = 200
local AIR_ACCEL <const> = 240
local GROUND_ACCEL <const> = 420
local PLAYER_MAX_VX <const> = 150
local LAVA_Y <const> = 230
local CLASH_MARGIN <const> = 4 -- y difference below which riders bounce

local AUTOPILOT = false -- smoke-test mode: feeds random input

-- Dither patterns (8 rows each; 1 bits = white)
local PAT_50 <const> = { 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 }
local PAT_75 <const> = { 0xEE, 0xBB, 0xEE, 0xBB, 0xEE, 0xBB, 0xEE, 0xBB }
local PAT_25 <const> = { 0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00 }
local LAVA_PATS <const> = {
    { 0xAA, 0xFF, 0x55, 0xFF, 0xAA, 0xFF, 0x55, 0xFF },
    { 0x55, 0xFF, 0xAA, 0xFF, 0x55, 0xFF, 0xAA, 0xFF },
}

local TIERS <const> = {
    { name = "FLEDGLING",     points = 500,  maxvx = 70,  flapEvery = 0.50, accel = 130 },
    { name = "HARRIER",      points = 750,  maxvx = 105, flapEvery = 0.36, accel = 190 },
    { name = "ROC", points = 1500, maxvx = 150, flapEvery = 0.26, accel = 260 },
}

-- Platforms: x, y of top-left, width, height
local platforms <const> = {
    { x = 0,   y = 216, w = 144, h = 24 },  -- bottom left
    { x = 256, y = 216, w = 144, h = 24 },  -- bottom right
    { x = 160, y = 196, w = 80,  h = 10 },  -- center pedestal (player spawn)
    { x = 0,   y = 148, w = 92,  h = 10 },  -- mid left
    { x = 308, y = 148, w = 92,  h = 10 },  -- mid right
    { x = 148, y = 96,  w = 104, h = 10 },  -- top center
    { x = 0,   y = 64,  w = 56,  h = 10 },  -- top left ledge
    { x = 344, y = 64,  w = 56,  h = 10 },  -- top right ledge
}

local ENEMY_SPAWNS <const> = {
    { x = 200, y = 88 },
    { x = 46,  y = 140 },
    { x = 354, y = 140 },
    { x = 72,  y = 208 },
    { x = 328, y = 208 },
}
local PLAYER_SPAWN <const> = { x = 200, y = 188 }

-- ---------------------------------------------------------------- utilities

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

local function wrapX(x)
    if x < 0 then return x + SCREEN_W elseif x >= SCREEN_W then return x - SCREEN_W end
    return x
end

-- wrap-aware horizontal distance from a to b
local function wrapDX(fromX, toX)
    local dx = toX - fromX
    if dx > SCREEN_W / 2 then dx = dx - SCREEN_W
    elseif dx < -SCREEN_W / 2 then dx = dx + SCREEN_W end
    return dx
end

local function overlap(a, b)
    local dx = math.abs(wrapDX(a.x, b.x))
    return dx < a.hw + b.hw and math.abs(a.y - b.y) < a.hh + b.hh
end

-- tiny scheduler for delayed one-shots (chained sound notes etc.)
local pending = {}
local function after(delay, fn)
    pending[#pending + 1] = { t = delay, fn = fn }
end
local function runPending()
    for i = #pending, 1, -1 do
        local p = pending[i]
        p.t = p.t - DT
        if p.t <= 0 then
            table.remove(pending, i)
            p.fn()
        end
    end
end

local function textWhite(s, x, y, align)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    if align then
        gfx.drawTextAligned(s, x, y, align)
    else
        gfx.drawText(s, x, y)
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

-- ------------------------------------------------------------------- sounds

local sqSynth = snd.synth.new(snd.kWaveSquare)
local triSynth = snd.synth.new(snd.kWaveTriangle)
local sawSynth = snd.synth.new(snd.kWaveSawtooth)
local noiseSynth = snd.synth.new(snd.kWaveNoise)

local function sfxFlap()
    noiseSynth:playNote(500 + math.random(200), 0.18, 0.05)
end
local function sfxBounce()
    sqSynth:playNote(110, 0.3, 0.06)
end
local function sfxKill()
    sqSynth:playNote(660, 0.35, 0.07)
    after(0.08, function() sqSynth:playNote(880, 0.35, 0.1) end)
end
local function sfxEgg()
    triSynth:playNote(523, 0.35, 0.06)
    after(0.07, function() triSynth:playNote(784, 0.35, 0.1) end)
end
local function sfxDie()
    sawSynth:playNote(440, 0.4, 0.1)
    after(0.11, function() sawSynth:playNote(330, 0.4, 0.1) end)
    after(0.22, function() sawSynth:playNote(220, 0.4, 0.18) end)
end
local function sfxHatch()
    triSynth:playNote(196, 0.3, 0.08)
    after(0.1, function() triSynth:playNote(262, 0.3, 0.1) end)
end
local function sfxWave()
    sqSynth:playNote(392, 0.3, 0.09)
    after(0.1, function() sqSynth:playNote(523, 0.3, 0.09) end)
    after(0.2, function() sqSynth:playNote(659, 0.3, 0.14) end)
end
local function sfxScreech()
    noiseSynth:playNote(1400, 0.35, 0.25)
end
local function sfxExtraLife()
    for i = 0, 3 do
        after(i * 0.09, function() triSynth:playNote(523 * (1 + i * 0.25), 0.35, 0.08) end)
    end
end

-- ------------------------------------------------------------------ sprites
-- All art is generated at startup with drawing primitives (1-bit, white on
-- transparent; the playfield background is black).

-- kind: "player" | tier 1..3, wingUp: boolean
local function buildBird(kind, wingUp)
    local img = gfx.image.new(26, 24)
    gfx.lockFocus(img)
    gfx.setColor(gfx.kColorWhite)
    gfx.setLineWidth(2)

    -- mount body --------------------------------------------------------
    -- tail
    gfx.fillTriangle(7, 14, 0, 11, 7, 18)
    -- body (pattern marks the enemy tier)
    if kind == 1 then
        gfx.setPattern(PAT_50)
    elseif kind == 2 then
        gfx.setPattern(PAT_75)
    end
    gfx.fillEllipseInRect(5, 12, 13, 8)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawEllipseInRect(5, 12, 13, 8)

    if kind == "player" then
        -- heron: long upright neck
        gfx.drawLine(16, 14, 20, 9)
        gfx.fillCircleAtPoint(20.5, 8, 2.5)
        gfx.fillTriangle(22, 7, 26, 8, 22, 9)
    else
        -- raptor: hunched neck, hooked beak
        gfx.drawLine(16, 14, 19, 11)
        gfx.fillCircleAtPoint(19.5, 10, 2.5)
        gfx.fillTriangle(21, 9, 25, 12, 21, 12)
    end

    -- wing
    if wingUp then
        gfx.fillTriangle(6, 14, 12, 14, 8, 6)
    else
        gfx.fillTriangle(6, 15, 12, 15, 9, 23)
    end

    -- legs
    gfx.setLineWidth(1)
    if wingUp then
        gfx.drawLine(10, 19, 8, 22)
        gfx.drawLine(14, 19, 12, 22)
    else
        gfx.drawLine(10, 19, 10, 23)
        gfx.drawLine(14, 19, 14, 23)
    end

    -- rider --------------------------------------------------------------
    gfx.fillRect(13, 6, 3, 6)                 -- torso
    gfx.fillCircleAtPoint(14.5, 4, 2)         -- head
    if kind == "player" then
        gfx.fillRect(12, 2, 5, 2)             -- plumed helmet
        gfx.drawLine(11, 1, 13, 2)
    elseif kind == 3 then
        gfx.fillRect(12, 2, 5, 2)             -- horned helm
        gfx.drawLine(12, 0, 12, 2)
        gfx.drawLine(17, 0, 17, 2)
    end
    -- lance
    gfx.setLineWidth(2)
    gfx.drawLine(15, 7, 25, 4)
    gfx.setLineWidth(1)

    -- roc gets a dark slash across the body
    if kind == 3 then
        gfx.setColor(gfx.kColorBlack)
        gfx.drawLine(7, 16, 16, 14)
        gfx.setColor(gfx.kColorWhite)
    end

    gfx.unlockFocus()
    return img
end

local function buildPtero(wingUp)
    local img = gfx.image.new(32, 18)
    gfx.lockFocus(img)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillEllipseInRect(8, 7, 14, 6)                 -- body
    gfx.setLineWidth(2)
    gfx.drawLine(20, 10, 26, 8)                        -- neck
    gfx.fillTriangle(24, 6, 29, 3, 28, 8)              -- crest
    gfx.fillTriangle(26, 7, 32, 8, 26, 10)             -- beak
    if wingUp then
        gfx.fillTriangle(6, 1, 10, 10, 18, 10)
    else
        gfx.fillTriangle(6, 17, 10, 8, 18, 8)
    end
    gfx.fillTriangle(8, 9, 0, 7, 8, 12)                -- tail
    gfx.setColor(gfx.kColorBlack)
    gfx.drawPixel(26, 7)                               -- eye
    gfx.unlockFocus()
    return img
end

local function buildEgg()
    local img = gfx.image.new(9, 11)
    gfx.lockFocus(img)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillEllipseInRect(0, 1, 9, 10)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawPixel(3, 4)
    gfx.drawPixel(5, 7)
    gfx.drawPixel(6, 4)
    gfx.unlockFocus()
    return img
end

local sprites = {}
local function buildSprites()
    sprites.player = { buildBird("player", false), buildBird("player", true) }
    sprites.tier = {}
    for t = 1, 3 do
        sprites.tier[t] = { buildBird(t, false), buildBird(t, true) }
    end
    sprites.ptero = { buildPtero(false), buildPtero(true) }
    sprites.egg = buildEgg()

    local w, h = gfx.getTextSize("*ROOST*")
    local timg = gfx.image.new(w, h)
    gfx.lockFocus(timg)
    gfx.drawText("*ROOST*", 0, 0)
    gfx.unlockFocus()
    sprites.title = timg
end

-- draw an image centered at x,y with horizontal screen wrap
local function drawCentered(img, x, y, flipped)
    local w, h = img:getSize()
    local flip = flipped and gfx.kImageFlippedX or gfx.kImageUnflipped
    img:draw(x - w / 2, y - h / 2, flip)
    if x < w then img:draw(x + SCREEN_W - w / 2, y - h / 2, flip) end
    if x > SCREEN_W - w then img:draw(x - SCREEN_W - w / 2, y - h / 2, flip) end
end

-- --------------------------------------------------------------- game state

local state = "title" -- "title" | "play" | "gameover"
local frame = 0
local score, highScore, lives, wave
local nextLifeAt
local player
local enemies, eggs, particles, popups, spawnQueue
local ptero, pteroTimer
local waveTimer, waveIntroTimer, waveIntroText
local deathsThisWave, eggChain
local gameOverTimer

local saved = playdate.datastore.read()
highScore = (saved and saved.highScore) or 0

local function saveHigh()
    playdate.datastore.write({ highScore = highScore })
end

local function addPopup(x, y, text)
    popups[#popups + 1] = { x = x, y = y, text = text, life = 1.0 }
end

local function addScore(n)
    score = score + n
    if score >= nextLifeAt then
        lives = lives + 1
        nextLifeAt = nextLifeAt + 20000
        sfxExtraLife()
        addPopup(player.x, player.y - 20, "EXTRA LIFE")
    end
end

local function burst(x, y, n)
    for _ = 1, n do
        local a = math.random() * math.pi * 2
        local s = 40 + math.random(80)
        particles[#particles + 1] = {
            x = x, y = y,
            vx = math.cos(a) * s, vy = math.sin(a) * s - 30,
            life = 0.4 + math.random() * 0.4,
        }
    end
end

-- ------------------------------------------------------------------ birds

local function newEnemy(tier, x, y)
    return {
        kind = "enemy", tier = tier,
        x = x, y = y, vx = 0, vy = 0,
        hw = 9, hh = 9, facing = math.random() < 0.5 and 1 or -1,
        onGround = false, anim = 0,
        spawn = 1.3, -- materialize time; no collisions while > 0
        flapTimer = math.random() * 0.5,
        aiTimer = 0, targetX = x, targetY = y,
    }
end

local function newPlayer()
    return {
        kind = "player",
        x = PLAYER_SPAWN.x, y = PLAYER_SPAWN.y, vx = 0, vy = 0,
        hw = 8, hh = 9, facing = 1,
        onGround = false, anim = 0,
        dead = false, respawnTimer = 0, invuln = 2,
    }
end

local function collidePlatforms(e)
    e.onGround = false
    for _, p in ipairs(platforms) do
        local left, right = e.x - e.hw, e.x + e.hw
        local top, bot = e.y - e.hh, e.y + e.hh
        if right > p.x and left < p.x + p.w and bot > p.y and top < p.y + p.h then
            local pushUp = bot - p.y
            local pushDown = (p.y + p.h) - top
            local pushLeft = right - p.x
            local pushRight = (p.x + p.w) - left
            local m = math.min(pushUp, pushDown, pushLeft, pushRight)
            if m == pushUp and e.vy >= 0 then
                e.y = p.y - e.hh
                e.vy = 0
                e.onGround = true
            elseif m == pushDown and e.vy < 0 then
                e.y = p.y + p.h + e.hh
                e.vy = math.abs(e.vy) * 0.4
                sfxBounce()
            elseif m == pushLeft then
                e.x = p.x - e.hw
                e.vx = -math.abs(e.vx) * 0.6
            elseif m == pushRight then
                e.x = p.x + p.w + e.hw
                e.vx = math.abs(e.vx) * 0.6
            end
        end
    end
end

local function applyGravityAndMove(e)
    e.vy = math.min(e.vy + GRAVITY * DT, MAX_FALL)
    e.x = wrapX(e.x + e.vx * DT)
    e.y = e.y + e.vy * DT
    if e.y < 8 then
        e.y = 8
        e.vy = math.abs(e.vy) * 0.3
    end
    collidePlatforms(e)
    if e.anim > 0 then e.anim = e.anim - DT end
end

local function inLava(e)
    return e.y + e.hh >= LAVA_Y
end

-- ---------------------------------------------------------------- spawning

local function queueEnemy(delay, tier)
    spawnQueue[#spawnQueue + 1] = { t = delay, tier = tier }
end

local function startWave(w)
    wave = w
    waveTimer = 0
    deathsThisWave = 0
    eggChain = 0
    pteroTimer = 45
    waveIntroText = "WAVE " .. w
    waveIntroTimer = 2.2
    sfxWave()

    local count = math.min(2 + w, 8)
    for i = 1, count do
        local tier = 1
        local r = math.random()
        if w >= 6 and r < 0.25 + (w - 6) * 0.05 then
            tier = 3
        elseif w >= 3 and r < 0.6 then
            tier = 2
        elseif w >= 2 and r < 0.3 then
            tier = 2
        end
        queueEnemy(0.8 + (i - 1) * 1.6, tier)
    end
end

local function updateSpawnQueue()
    for i = #spawnQueue, 1, -1 do
        local s = spawnQueue[i]
        s.t = s.t - DT
        if s.t <= 0 then
            table.remove(spawnQueue, i)
            local sp = ENEMY_SPAWNS[math.random(#ENEMY_SPAWNS)]
            enemies[#enemies + 1] = newEnemy(s.tier, sp.x, sp.y)
        end
    end
end

local function startGame()
    score = 0
    lives = 3
    nextLifeAt = 20000
    player = newPlayer()
    enemies, eggs, particles, popups, spawnQueue = {}, {}, {}, {}, {}
    ptero = nil
    gameOverTimer = 0
    state = "play"
    startWave(1)
end

local function gameOver()
    state = "gameover"
    if score > highScore then
        highScore = score
        saveHigh()
    end
end

-- ------------------------------------------------------------------ deaths

local function killPlayer()
    if player.dead or player.invuln > 0 then return end
    player.dead = true
    player.respawnTimer = 2
    deathsThisWave = deathsThisWave + 1
    lives = lives - 1
    burst(player.x, player.y, 14)
    sfxDie()
end

local function killEnemy(e, idx)
    table.remove(enemies, idx)
    local t = TIERS[e.tier]
    addScore(t.points)
    addPopup(e.x, e.y - 14, tostring(t.points))
    burst(e.x, e.y, 8)
    sfxKill()
    eggs[#eggs + 1] = {
        x = e.x, y = e.y, vx = e.vx * 0.5, vy = -60,
        hw = 4, hh = 5, tier = e.tier,
        resting = false, hatchTimer = 9,
    }
end

-- --------------------------------------------------------------------- AI

local function enemyAI(e)
    local t = TIERS[e.tier]
    e.aiTimer = e.aiTimer - DT
    if e.aiTimer <= 0 then
        e.aiTimer = 0.8 + math.random() * 1.2
        if e.tier == 1 or player.dead then
            e.targetX = math.random(20, SCREEN_W - 20)
            e.targetY = math.random(40, 185)
        else
            -- harriers and rocs try to get above the player
            e.targetX = player.x + math.random(-40, 40)
            e.targetY = player.y - 14 + math.random(-10, 6)
        end
    end

    local dx = wrapDX(e.x, e.targetX)
    local dir = dx > 0 and 1 or -1
    if math.abs(dx) > 8 then
        e.vx = clamp(e.vx + dir * t.accel * DT, -t.maxvx, t.maxvx)
    end
    if math.abs(e.vx) > 5 then e.facing = e.vx > 0 and 1 or -1 end

    e.flapTimer = e.flapTimer - DT
    local nearLava = e.y + e.hh > 195
    if nearLava then e.flapTimer = math.min(e.flapTimer, 0.12) end
    local wantUp = e.y > e.targetY or nearLava
    if wantUp and e.flapTimer <= 0 then
        e.flapTimer = t.flapEvery * (0.7 + math.random() * 0.6)
        e.vy = math.max(e.vy - FLAP_IMPULSE, -MAX_RISE)
        e.anim = 0.15
    end
end

-- ------------------------------------------------------------------- input

local auto = { t = 0, dir = 1, started = false }
local function gatherInput()
    if AUTOPILOT then
        auto.t = auto.t + DT
        if auto.t > 1 then
            auto.t = 0
            auto.dir = math.random() < 0.5 and -1 or 1
        end
        local flap = math.random() < 0.18
        local start = true
        return auto.dir < 0, auto.dir > 0, flap, start
    end
    local left = playdate.buttonIsPressed(playdate.kButtonLeft)
    local right = playdate.buttonIsPressed(playdate.kButtonRight)
    local flap = playdate.buttonJustPressed(playdate.kButtonA)
    if playdate.getCrankTicks(8) ~= 0 then flap = true end
    local start = playdate.buttonJustPressed(playdate.kButtonA)
    return left, right, flap, start
end

-- ----------------------------------------------------------------- updates

local function updatePlayer(left, right, flap)
    if player.dead then
        player.respawnTimer = player.respawnTimer - DT
        if player.respawnTimer <= 0 then
            if lives <= 0 then
                gameOver()
            else
                player = newPlayer()
            end
        end
        return
    end

    if player.invuln > 0 then player.invuln = player.invuln - DT end

    local accel = player.onGround and GROUND_ACCEL or AIR_ACCEL
    if left then
        player.vx = clamp(player.vx - accel * DT, -PLAYER_MAX_VX, PLAYER_MAX_VX)
        player.facing = -1
    elseif right then
        player.vx = clamp(player.vx + accel * DT, -PLAYER_MAX_VX, PLAYER_MAX_VX)
        player.facing = 1
    elseif player.onGround then
        player.vx = player.vx * 0.92
        if math.abs(player.vx) < 4 then player.vx = 0 end
    end

    if flap then
        player.vy = math.max(player.vy - FLAP_IMPULSE, -MAX_RISE)
        player.anim = 0.15
        sfxFlap()
    end

    applyGravityAndMove(player)

    if inLava(player) and player.invuln <= 0 then
        killPlayer()
    elseif inLava(player) then
        -- invulnerable players still shouldn't sink into lava
        player.y = LAVA_Y - player.hh
        player.vy = -120
    end
end

local function updateEnemies()
    for i = #enemies, 1, -1 do
        local e = enemies[i]
        if e.spawn > 0 then
            e.spawn = e.spawn - DT
        else
            enemyAI(e)
            applyGravityAndMove(e)
            if inLava(e) then
                table.remove(enemies, i)
                burst(e.x, LAVA_Y, 8)
                sfxDie()
            end
        end
    end

    -- enemy vs enemy: simple bounce
    for i = 1, #enemies - 1 do
        for j = i + 1, #enemies do
            local a, b = enemies[i], enemies[j]
            if a.spawn <= 0 and b.spawn <= 0 and overlap(a, b) then
                local dx = wrapDX(a.x, b.x)
                local push = dx >= 0 and 1 or -1
                a.x = wrapX(a.x - push * 2)
                b.x = wrapX(b.x + push * 2)
                a.vx, b.vx = -math.abs(a.vx) * push, math.abs(b.vx) * push
            end
        end
    end

    -- lance clash
    if not player.dead then
        for i = #enemies, 1, -1 do
            local e = enemies[i]
            if e.spawn <= 0 and overlap(player, e) then
                local dy = player.y - e.y
                if dy < -CLASH_MARGIN then
                    killEnemy(e, i)
                    player.vy = math.max(player.vy, 40) -- slight recoil downward halt
                elseif dy > CLASH_MARGIN then
                    if player.invuln <= 0 then
                        killPlayer()
                        break
                    end
                else
                    -- equal height: bounce apart
                    local push = wrapDX(e.x, player.x) >= 0 and 1 or -1
                    player.vx = push * math.max(math.abs(player.vx), 60)
                    e.vx = -push * math.max(math.abs(e.vx), 60)
                    player.x = wrapX(player.x + push * 3)
                    e.x = wrapX(e.x - push * 3)
                    sfxBounce()
                end
            end
        end
    end
end

local function updateEggs()
    for i = #eggs, 1, -1 do
        local egg = eggs[i]
        if not egg.resting then
            egg.vy = math.min(egg.vy + GRAVITY * DT, MAX_FALL)
            egg.x = wrapX(egg.x + egg.vx * DT)
            egg.y = egg.y + egg.vy * DT
            for _, p in ipairs(platforms) do
                if egg.x > p.x - egg.hw and egg.x < p.x + p.w + egg.hw
                    and egg.y + egg.hh > p.y and egg.y + egg.hh < p.y + p.h + 8
                    and egg.vy >= 0 then
                    egg.y = p.y - egg.hh
                    if math.abs(egg.vy) > 40 then
                        egg.vy = -egg.vy * 0.35
                        egg.vx = egg.vx * 0.6
                    else
                        egg.resting = true
                        egg.vx, egg.vy = 0, 0
                    end
                end
            end
        end

        if egg.y - egg.hh > LAVA_Y then
            table.remove(eggs, i)
        elseif not player.dead and overlap(player, egg) then
            table.remove(eggs, i)
            eggChain = eggChain + 1
            local pts = 250 * math.min(eggChain, 4)
            if not egg.resting then pts = pts + 250 end -- mid-air catch bonus
            addScore(pts)
            addPopup(egg.x, egg.y - 10, tostring(pts))
            sfxEgg()
        else
            egg.hatchTimer = egg.hatchTimer - DT
            if egg.hatchTimer <= 0 then
                table.remove(eggs, i)
                local tier = math.min(egg.tier + 1, 3)
                enemies[#enemies + 1] = newEnemy(tier, egg.x, egg.y - 4)
                sfxHatch()
            end
        end
    end
end

local function updatePtero()
    if ptero then
        ptero.t = ptero.t + DT
        ptero.x = ptero.x + ptero.vx * DT
        local targetY = player.dead and 60 or player.y
        ptero.y = ptero.y + clamp(targetY - ptero.y, -50, 50) * DT
            + math.sin(ptero.t * 4) * 0.8
        ptero.y = clamp(ptero.y, 16, 200)

        if ptero.x < -40 or ptero.x > SCREEN_W + 40 then
            ptero = nil
            pteroTimer = 20
            return
        end

        if not player.dead and overlap(player, ptero) then
            local facingIt = (player.facing == 1) == (wrapDX(player.x, ptero.x) > 0)
            if facingIt and math.abs(player.y - ptero.y) < 4 then
                -- lance straight into the open beak
                burst(ptero.x, ptero.y, 16)
                addScore(1000)
                addPopup(ptero.x, ptero.y - 14, "1000")
                sfxKill()
                ptero = nil
                pteroTimer = 30
            elseif player.invuln <= 0 then
                killPlayer()
            end
        end
    else
        pteroTimer = pteroTimer - DT
        if pteroTimer <= 0 then
            local fromLeft = math.random() < 0.5
            ptero = {
                x = fromLeft and -30 or SCREEN_W + 30,
                y = 60,
                vx = fromLeft and 110 or -110,
                hw = 13, hh = 7, t = 0,
            }
            sfxScreech()
        end
    end
end

local function updateParticles()
    for i = #particles, 1, -1 do
        local p = particles[i]
        p.life = p.life - DT
        if p.life <= 0 then
            table.remove(particles, i)
        else
            p.vy = p.vy + 150 * DT
            p.x = p.x + p.vx * DT
            p.y = p.y + p.vy * DT
        end
    end
    for i = #popups, 1, -1 do
        local p = popups[i]
        p.life = p.life - DT
        p.y = p.y - 20 * DT
        if p.life <= 0 then table.remove(popups, i) end
    end
end

local function updatePlay()
    local left, right, flap = gatherInput()
    waveTimer = waveTimer + DT
    if waveIntroTimer > 0 then waveIntroTimer = waveIntroTimer - DT end

    updateSpawnQueue()
    updatePlayer(left, right, flap)
    if state ~= "play" then return end -- gameOver may fire inside updatePlayer
    updateEnemies()
    updateEggs()
    updatePtero()
    updateParticles()

    -- wave complete?
    if #enemies == 0 and #eggs == 0 and #spawnQueue == 0 and not player.dead then
        if ptero then ptero = nil end
        if deathsThisWave == 0 and waveTimer > 3 then
            addScore(3000)
            addPopup(player.x, player.y - 20, "SURVIVAL BONUS 3000")
        end
        startWave(wave + 1)
    end
end

-- ----------------------------------------------------------------- drawing

local function drawLava()
    gfx.setPattern(LAVA_PATS[1 + (frame // 6) % 2])
    gfx.fillRect(0, LAVA_Y + 2, SCREEN_W, SCREEN_H - LAVA_Y - 2)
    gfx.setColor(gfx.kColorWhite)
    -- bubbling surface
    for x = 0, SCREEN_W, 16 do
        local bob = math.sin((x + frame * 3) * 0.08) * 2
        gfx.fillCircleAtPoint(x + 8, LAVA_Y + 4 + bob, 2)
    end
end

local function drawPlatforms()
    for _, p in ipairs(platforms) do
        gfx.setPattern(PAT_25)
        gfx.fillRect(p.x, p.y, p.w, p.h)
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(p.x, p.y, p.w, 3)
        gfx.drawRect(p.x, p.y, p.w, p.h)
    end
end

local function birdFrame(e)
    if e.anim and e.anim > 0 then return 2 end
    if e.onGround and math.abs(e.vx) > 20 then
        return 1 + (frame // 4) % 2 -- running gallop
    end
    return 1
end

local function drawBird(e, imgs)
    drawCentered(imgs[birdFrame(e)], e.x, e.y, e.facing < 0)
end

local function drawHUD()
    textWhite("SCORE " .. score, 4, 2)
    textWhite("WAVE " .. wave, SCREEN_W / 2, 2, kTextAlignment.center)
    -- lives as small marks
    for i = 1, math.min(lives, 6) do
        local x = SCREEN_W - 10 - (i - 1) * 12
        gfx.setColor(gfx.kColorWhite)
        gfx.fillTriangle(x, 4, x + 8, 4, x + 4, 12)
    end
end

local function drawPlay()
    drawLava()
    drawPlatforms()

    for _, egg in ipairs(eggs) do
        local wob = 0
        if egg.hatchTimer < 2.5 then
            wob = math.sin(frame * 0.8) * 1.5
        end
        drawCentered(sprites.egg, egg.x + wob, egg.y, false)
    end

    for _, e in ipairs(enemies) do
        if e.spawn > 0 then
            -- materialize: flashing outline
            if frame % 6 < 3 then
                gfx.setColor(gfx.kColorWhite)
                gfx.drawRect(e.x - e.hw, e.y - e.hh, e.hw * 2, e.hh * 2)
            end
        else
            drawBird(e, sprites.tier[e.tier])
        end
    end

    if ptero then
        local f = 1 + (frame // 5) % 2
        drawCentered(sprites.ptero[f], ptero.x, ptero.y, ptero.vx < 0)
    end

    if not player.dead then
        -- flash while invulnerable
        if player.invuln <= 0 or frame % 4 < 2 then
            drawBird(player, sprites.player)
        end
    end

    gfx.setColor(gfx.kColorWhite)
    for _, p in ipairs(particles) do
        gfx.fillRect(p.x - 1, p.y - 1, 2, 2)
    end

    for _, p in ipairs(popups) do
        textWhite(p.text, p.x, p.y, kTextAlignment.center)
    end

    drawHUD()

    if waveIntroTimer > 0 then
        textWhite("*" .. waveIntroText .. "*", SCREEN_W / 2, 60, kTextAlignment.center)
    end
end

local function drawTitle()
    drawLava()
    drawPlatforms()
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    local tw, th = sprites.title:getSize()
    sprites.title:drawScaled(SCREEN_W / 2 - tw * 2, 28, 4)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)

    -- decorative riders
    drawCentered(sprites.player[1 + (frame // 8) % 2], 110, 120, false)
    drawCentered(sprites.tier[2][1 + ((frame + 4) // 8) % 2], 290, 120, true)

    textWhite("d-pad: steer    A or crank: flap", SCREEN_W / 2, 142, kTextAlignment.center)
    textWhite("unseat riders from above - collect the eggs", SCREEN_W / 2, 158, kTextAlignment.center)
    if frame % 30 < 20 then
        textWhite("*PRESS A TO START*", SCREEN_W / 2, 180, kTextAlignment.center)
    end
    textWhite("HIGH SCORE " .. highScore, SCREEN_W / 2, 222, kTextAlignment.center)
end

local function drawGameOver()
    drawLava()
    drawPlatforms()
    textWhite("*GAME OVER*", SCREEN_W / 2, 70, kTextAlignment.center)
    textWhite("SCORE " .. score, SCREEN_W / 2, 100, kTextAlignment.center)
    if score >= highScore and score > 0 then
        textWhite("*NEW HIGH SCORE!*", SCREEN_W / 2, 120, kTextAlignment.center)
    else
        textWhite("HIGH SCORE " .. highScore, SCREEN_W / 2, 120, kTextAlignment.center)
    end
    if frame % 30 < 20 then
        textWhite("PRESS A TO PLAY AGAIN", SCREEN_W / 2, 160, kTextAlignment.center)
    end
end

-- -------------------------------------------------------------- main loop

function playdate.update()
    frame = frame + 1
    runPending()

    gfx.clear(gfx.kColorBlack)

    if state == "title" then
        drawTitle()
        local _, _, _, start = gatherInput()
        if start then startGame() end
    elseif state == "play" then
        updatePlay()
        if state == "play" then
            drawPlay()
        end
    elseif state == "gameover" then
        gameOverTimer = gameOverTimer + DT
        drawGameOver()
        local _, _, _, start = gatherInput()
        if start and gameOverTimer > 1 then
            startGame()
        end
    end
end

playdate.getSystemMenu():addMenuItem("restart", function()
    state = "title"
end)

-- ---------------------------------------------------------------- startup

math.randomseed(playdate.getSecondsSinceEpoch())
playdate.display.setRefreshRate(30)
buildSprites()
