local heli3d = {}

local rad = math.rad
local sin = math.sin
local cos = math.cos
local floor = math.floor
local min = math.min
local max = math.max
local t_sort = table.sort

local BASE_VIEW_PITCH_R = rad(-90)
local BASE_VIEW_YAW_R = rad(90)
local CAMERA_DIST = 7.0
local CAMERA_NEAR_EPS = 0.25

local function clamp(v, lo, hi)
    if v < lo then
        return lo
    end
    if v > hi then
        return hi
    end
    return v
end

local function toInt(v)
    return floor(v + 0.5)
end

local function normalizeAngle(angle)
    while angle > math.pi do
        angle = angle - (2 * math.pi)
    end
    while angle < -math.pi do
        angle = angle + (2 * math.pi)
    end
    return angle
end

local function setColor(r, g, b)
    if not (lcd and lcd.color and lcd.RGB) then
        return
    end
    pcall(lcd.color, lcd.RGB(r, g, b))
end

local function setColorV(rgb)
    setColor(rgb[1], rgb[2], rgb[3])
end

-- Adapted from Rotorflight alignment visualizer:
-- world transform is Rz(roll) -> Rx(pitch) -> Ry(yaw),
-- with a rear-view baseline rotation applied first.
local function rotatePoint(x, y, z, pitchR, yawR, rollR)
    local cbp = cos(BASE_VIEW_PITCH_R)
    local sbp = sin(BASE_VIEW_PITCH_R)
    local px = x
    local py = y * cbp - z * sbp
    local pz = y * sbp + z * cbp

    local cby = cos(BASE_VIEW_YAW_R)
    local sby = sin(BASE_VIEW_YAW_R)
    local bx = px * cby + pz * sby
    local by = py
    local bz = -px * sby + pz * cby

    local cz = cos(rollR)
    local sz = sin(rollR)
    local cx = cos(pitchR)
    local sx = sin(pitchR)
    local cy = cos(yawR)
    local sy = sin(yawR)

    local x1 = bx * cz - by * sz
    local y1 = bx * sz + by * cz
    local z1 = bz

    local x2 = x1
    local y2 = y1 * cx - z1 * sx
    local z2 = y1 * sx + z1 * cx

    local x3 = x2 * cy + z2 * sy
    local y3 = y2
    local z3 = -x2 * sy + z2 * cy

    return x3, y3, z3
end

local function projectPoint(px, py, pz, cx, cy, scale)
    local denom = CAMERA_DIST - pz
    if denom <= CAMERA_NEAR_EPS then
        return nil, nil
    end
    local f = CAMERA_DIST / denom
    local sx = cx + (px * f * scale)
    local sy = cy - (py * f * scale)
    return sx, sy
end

local function drawLine3D(a, b, cx, cy, scale, pitchR, yawR, rollR)
    local ax, ay, az = rotatePoint(a[1], a[2], a[3], pitchR, yawR, rollR)
    local bx, by, bz = rotatePoint(b[1], b[2], b[3], pitchR, yawR, rollR)
    if (CAMERA_DIST - az) <= CAMERA_NEAR_EPS or (CAMERA_DIST - bz) <= CAMERA_NEAR_EPS then
        return
    end
    local x1, y1 = projectPoint(ax, ay, az, cx, cy, scale)
    local x2, y2 = projectPoint(bx, by, bz, cx, cy, scale)
    if x1 == nil or x2 == nil then
        return
    end
    lcd.drawLine(toInt(x1), toInt(y1), toInt(x2), toInt(y2))
end

local function drawFilledTriangle3D(a, b, c, cx, cy, scale, pitchR, yawR, rollR)
    if not (lcd and lcd.drawFilledTriangle) then
        return
    end

    local ax, ay, az = rotatePoint(a[1], a[2], a[3], pitchR, yawR, rollR)
    local bx, by, bz = rotatePoint(b[1], b[2], b[3], pitchR, yawR, rollR)
    local cx3, cy3, cz3 = rotatePoint(c[1], c[2], c[3], pitchR, yawR, rollR)
    if (CAMERA_DIST - az) <= CAMERA_NEAR_EPS or (CAMERA_DIST - bz) <= CAMERA_NEAR_EPS or (CAMERA_DIST - cz3) <= CAMERA_NEAR_EPS then
        return
    end

    local x1, y1 = projectPoint(ax, ay, az, cx, cy, scale)
    local x2, y2 = projectPoint(bx, by, bz, cx, cy, scale)
    local x3, y3 = projectPoint(cx3, cy3, cz3, cx, cy, scale)
    if x1 == nil or x2 == nil or x3 == nil then
        return
    end

    lcd.drawFilledTriangle(toInt(x1), toInt(y1), toInt(x2), toInt(y2), toInt(x3), toInt(y3))
end

local function collectTriangle3D(list, a, b, c, cx, cy, scale, pitchR, yawR, rollR, color)
    local ax, ay, az = rotatePoint(a[1], a[2], a[3], pitchR, yawR, rollR)
    local bx, by, bz = rotatePoint(b[1], b[2], b[3], pitchR, yawR, rollR)
    local cx3, cy3, cz3 = rotatePoint(c[1], c[2], c[3], pitchR, yawR, rollR)
    if (CAMERA_DIST - az) <= CAMERA_NEAR_EPS or (CAMERA_DIST - bz) <= CAMERA_NEAR_EPS or (CAMERA_DIST - cz3) <= CAMERA_NEAR_EPS then
        return
    end

    local x1, y1 = projectPoint(ax, ay, az, cx, cy, scale)
    local x2, y2 = projectPoint(bx, by, bz, cx, cy, scale)
    local x3, y3 = projectPoint(cx3, cy3, cz3, cx, cy, scale)
    if x1 == nil or x2 == nil or x3 == nil then
        return
    end

    list[#list + 1] = {
        x1 = toInt(x1), y1 = toInt(y1),
        x2 = toInt(x2), y2 = toInt(y2),
        x3 = toInt(x3), y3 = toInt(y3),
        z = (az + bz + cz3) / 3,
        color = color
    }
end

local function drawTriangleList(list)
    if #list == 0 or not (lcd and lcd.drawFilledTriangle) then
        return
    end
    t_sort(list, function(a, b)
        return a.z < b.z
    end)
    for i = 1, #list do
        local tri = list[i]
        setColorV(tri.color)
        lcd.drawFilledTriangle(tri.x1, tri.y1, tri.x2, tri.y2, tri.x3, tri.y3)
    end
end

local P = {
    nose = {2.35, 0.00, -0.02},
    lf = {1.10, -0.62, 0.02},
    rf = {1.10, 0.62, 0.02},
    lb = {-0.55, -0.46, 0.05},
    rb = {-0.55, 0.46, 0.05},
    top = {0.05, 0.00, 0.84},
    podAftTop = {-0.66, 0.00, 0.56},
    podAftBot = {-0.66, 0.00, -0.12},
    podAftL = {-0.66, -0.30, 0.14},
    podAftR = {-0.66, 0.30, 0.14},
    mast = {0.00, 0.00, 1.02},
    finU = {-2.25, 0.00, 0.45},
    finD = {-2.25, 0.00, -0.18},
    boomSU = {-0.88, 0.00, 0.18},
    boomSL = {-0.88, -0.10, 0.11},
    boomSR = {-0.88, 0.10, 0.11},
    boomSD = {-0.88, 0.00, 0.06},
    boomEU = {-2.35, 0.00, 0.12},
    boomEL = {-2.35, -0.06, 0.08},
    boomER = {-2.35, 0.06, 0.08},
    boomED = {-2.35, 0.00, 0.05},
    skidL1 = {1.12, -0.66, -0.69},
    skidL2 = {0.76, -0.66, -0.64},
    skidL3 = {0.00, -0.66, -0.62},
    skidL4 = {-0.96, -0.66, -0.63},
    skidL5 = {-1.24, -0.66, -0.67},
    skidR1 = {1.12, 0.66, -0.69},
    skidR2 = {0.76, 0.66, -0.64},
    skidR3 = {0.00, 0.66, -0.62},
    skidR4 = {-0.96, 0.66, -0.63},
    skidR5 = {-1.24, 0.66, -0.67},
    strutLFTop = {0.52, -0.50, -0.12},
    strutLFBot = {0.48, -0.66, -0.63},
    strutLBTop = {-0.52, -0.44, -0.10},
    strutLBBot = {-0.58, -0.66, -0.63},
    strutRFTop = {0.52, 0.50, -0.12},
    strutRFBot = {0.48, 0.66, -0.63},
    strutRBTop = {-0.52, 0.44, -0.10},
    strutRBBot = {-0.58, 0.66, -0.63},
    rotorA = {0.0, -1.9, 1.02},
    rotorB = {0.0, 1.9, 1.02},
    rotorC = {-1.9, 0.0, 1.02},
    rotorD = {1.9, 0.0, 1.02}
}

local MAIN_EDGES_HIGH = {
    {P.lb, P.lf}, {P.rb, P.rf}, {P.lf, P.nose}, {P.rf, P.nose}, {P.top, P.nose},
    {P.boomSU, P.boomEU}, {P.boomSL, P.boomEL}, {P.boomSR, P.boomER}, {P.boomSD, P.boomED},
    {P.skidL1, P.skidL2}, {P.skidL2, P.skidL3}, {P.skidL3, P.skidL4}, {P.skidL4, P.skidL5},
    {P.skidR1, P.skidR2}, {P.skidR2, P.skidR3}, {P.skidR3, P.skidR4}, {P.skidR4, P.skidR5},
    {P.strutLFTop, P.strutLFBot}, {P.strutLBTop, P.strutLBBot}, {P.strutRFTop, P.strutRFBot}, {P.strutRBTop, P.strutRBBot},
    {P.strutLFBot, P.strutRFBot}, {P.strutLBBot, P.strutRBBot}, {P.strutLFTop, P.strutRFTop}, {P.strutLBTop, P.strutRBTop}
}

local MAIN_EDGES_LOW = {
    {P.lb, P.lf}, {P.rb, P.rf}, {P.lf, P.nose}, {P.rf, P.nose}, {P.top, P.nose},
    {P.boomSU, P.boomEU}, {P.boomSL, P.boomEL}, {P.boomSR, P.boomER},
    {P.skidL1, P.skidL3}, {P.skidL3, P.skidL5}, {P.skidR1, P.skidR3}, {P.skidR3, P.skidR5}
}

local ACCENT_EDGES_HIGH = {
    {P.finU, P.finD}, {P.boomSU, P.boomSL}, {P.boomSL, P.boomSD}, {P.boomSD, P.boomSR}, {P.boomSR, P.boomSU}
}

local ACCENT_EDGES_LOW = {
    {P.finU, P.finD}, {P.boomSU, P.boomSL}
}

local COL = {
    skyTop = {10, 21, 37},
    skyMid = {17, 34, 56},
    ground = {23, 32, 33},
    frameOuter = {86, 126, 170},
    frameInner = {44, 70, 99},
    rotor = {148, 165, 188},
    bodyLight = {232, 237, 246},
    bodyMid = {191, 200, 218},
    bodyDark = {144, 156, 178},
    canopy = {255, 199, 94},
    lineMain = {241, 247, 255},
    lineAccent = {98, 192, 255}
}

local function drawBackground(x, y, w, h, horizonY)
    local skySplit = y + floor((horizonY - y) * 0.62)

    setColorV(COL.skyTop)
    lcd.drawFilledRectangle(x, y, w, max(1, skySplit - y))

    setColorV(COL.skyMid)
    lcd.drawFilledRectangle(x, skySplit, w, max(1, horizonY - skySplit))

    setColorV(COL.ground)
    lcd.drawFilledRectangle(x, horizonY, w, max(1, (y + h) - horizonY))

    if lcd.drawRectangle then
        setColorV(COL.frameOuter)
        lcd.drawRectangle(x, y, w, h)
        if w > 4 and h > 4 then
            setColorV(COL.frameInner)
            lcd.drawRectangle(x + 1, y + 1, w - 2, h - 2)
        end
    end
end

function heli3d.draw(state, opts)
    if not (state and lcd and lcd.drawFilledRectangle and lcd.drawLine) then
        return false
    end

    opts = opts or {}
    local windowW = toInt(tonumber(opts.windowW) or 784)
    local windowH = toInt(tonumber(opts.windowH) or 406)
    if windowW < 100 or windowH < 70 then
        return false
    end

    local rectX = toInt(tonumber(opts.rectX) or 0)
    local rectY = toInt(tonumber(opts.rectY) or 0)
    rectX = clamp(rectX, 0, max(0, windowW - 20))
    rectY = clamp(rectY, 0, max(0, windowH - 20))

    local rectW = toInt(tonumber(opts.rectW) or (windowW - rectX))
    local rectH = toInt(tonumber(opts.rectH) or (windowH - rectY))
    rectW = clamp(rectW, 80, max(80, windowW - rectX))
    rectH = clamp(rectH, 70, max(70, windowH - rectY))

    local dt = clamp(tonumber(opts.dt) or 0.016, 0.001, 0.10)
    local detail = clamp(math.floor(tonumber(opts.detail) or 1), 0, 2)

    local rollInput = clamp(tonumber(opts.rollInput) or 0, -1, 1)
    local pitchInput = clamp(tonumber(opts.pitchInput) or 0, -1, 1)
    local yawInput = clamp(tonumber(opts.yawInput) or 0, -1, 1)
    local collectiveInput = clamp(tonumber(opts.collectiveInput) or 0, -1, 1)

    local yawGain = clamp(tonumber(opts.yawGain) or 5.8, 0.5, 12.0)
    local rollGain = clamp(tonumber(opts.rollGain) or 6.4, 0.5, 12.0)
    local pitchGain = clamp(tonumber(opts.pitchGain) or 5.8, 0.5, 12.0)
    local levelAssist = clamp(tonumber(opts.levelAssist) or 0.0, 0.0, 4.0)

    local yawRate = tonumber(opts.yawRate)
    if type(yawRate) ~= "number" then
        yawRate = yawInput * yawGain
    end
    yawRate = yawRate + (tonumber(opts.autoSpin) or 0)

    local rollRate = tonumber(opts.rollRate)
    if type(rollRate) ~= "number" then
        rollRate = rollInput * rollGain
    end

    local pitchRate = tonumber(opts.pitchRate)
    if type(pitchRate) ~= "number" then
        pitchRate = pitchInput * pitchGain
    end

    local cache = state._heli3dScene
    if type(cache) ~= "table" then
        cache = {yaw = 0, pitch = 0, roll = 0, bobPhase = 0}
        state._heli3dScene = cache
    end

    if opts.resetAttitude then
        cache.yaw = 0
        cache.pitch = 0
        cache.roll = 0
    end

    cache.yaw = normalizeAngle(cache.yaw + (yawRate * dt))
    cache.roll = normalizeAngle(cache.roll + (rollRate * dt))
    cache.pitch = normalizeAngle(cache.pitch + (pitchRate * dt))

    if levelAssist > 0 then
        local pull = clamp(1.0 - (levelAssist * dt), 0, 1)
        cache.roll = cache.roll * pull
        cache.pitch = cache.pitch * pull
    end

    cache.bobPhase = cache.bobPhase + ((0.75 + math.abs(collectiveInput) * 2.0) * dt)

    local sceneScale = min(rectW, rectH)
    local bobOffset = (sin(cache.bobPhase) * 2.8 + (collectiveInput * 5.0)) * (sceneScale / 160.0)
    local horizonY = clamp(
        toInt(rectY + (rectH * 0.58) + (pitchInput * rectH * 0.11)),
        rectY + 16,
        rectY + rectH - 14
    )

    drawBackground(rectX, rectY, rectW, rectH, horizonY)

    local scaleMul = clamp(tonumber(opts.scaleMul) or 1.0, 0.50, 1.35)
    local scale = tonumber(opts.scale) or (sceneScale * 0.17 * scaleMul)
    scale = clamp(scale, sceneScale * 0.08, sceneScale * 0.24)

    local cx = toInt((tonumber(opts.centerX) or (rectX + rectW * 0.54)) + (yawInput * rectW * 0.05))
    local cy = toInt((tonumber(opts.centerY) or (rectY + rectH * 0.64)) + bobOffset)
    cx = clamp(cx, rectX + 14, rectX + rectW - 14)
    cy = clamp(cy, rectY + 14, rectY + rectH - 10)

    local pitchR = cache.pitch
    local yawR = cache.yaw
    local rollR = -cache.roll

    if detail >= 2 then
        local fuselage = {}
        collectTriangle3D(fuselage, P.nose, P.lf, P.top, cx, cy, scale, pitchR, yawR, rollR, COL.bodyLight)
        collectTriangle3D(fuselage, P.nose, P.top, P.rf, cx, cy, scale, pitchR, yawR, rollR, COL.bodyLight)
        collectTriangle3D(fuselage, P.lf, P.lb, P.top, cx, cy, scale, pitchR, yawR, rollR, COL.bodyMid)
        collectTriangle3D(fuselage, P.rf, P.top, P.rb, cx, cy, scale, pitchR, yawR, rollR, COL.bodyMid)
        collectTriangle3D(fuselage, P.lb, P.podAftTop, P.top, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.rb, P.top, P.podAftTop, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.lf, P.lb, P.rb, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.lf, P.rb, P.rf, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.lb, P.podAftL, P.podAftTop, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.rb, P.podAftTop, P.podAftR, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.lb, P.podAftBot, P.podAftL, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.rb, P.podAftR, P.podAftBot, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.boomSU, P.boomSL, P.boomEU, cx, cy, scale, pitchR, yawR, rollR, COL.bodyMid)
        collectTriangle3D(fuselage, P.boomSL, P.boomEL, P.boomEU, cx, cy, scale, pitchR, yawR, rollR, COL.bodyMid)
        collectTriangle3D(fuselage, P.boomSU, P.boomEU, P.boomSR, cx, cy, scale, pitchR, yawR, rollR, COL.bodyMid)
        collectTriangle3D(fuselage, P.boomSR, P.boomEU, P.boomER, cx, cy, scale, pitchR, yawR, rollR, COL.bodyMid)
        collectTriangle3D(fuselage, P.boomSL, P.boomSD, P.boomEL, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.boomSD, P.boomED, P.boomEL, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.boomSD, P.boomSR, P.boomED, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.boomSR, P.boomER, P.boomED, cx, cy, scale, pitchR, yawR, rollR, COL.bodyDark)
        collectTriangle3D(fuselage, P.nose, P.lf, P.rf, cx, cy, scale, pitchR, yawR, rollR, COL.canopy)
        drawTriangleList(fuselage)
    elseif detail == 1 then
        setColorV(COL.bodyMid)
        drawFilledTriangle3D(P.nose, P.lf, P.top, cx, cy, scale, pitchR, yawR, rollR)
        drawFilledTriangle3D(P.nose, P.top, P.rf, cx, cy, scale, pitchR, yawR, rollR)
        setColorV(COL.bodyDark)
        drawFilledTriangle3D(P.lf, P.lb, P.rb, cx, cy, scale, pitchR, yawR, rollR)
        drawFilledTriangle3D(P.lf, P.rb, P.rf, cx, cy, scale, pitchR, yawR, rollR)
        drawFilledTriangle3D(P.boomSU, P.boomSL, P.boomEU, cx, cy, scale, pitchR, yawR, rollR)
        drawFilledTriangle3D(P.boomSU, P.boomEU, P.boomSR, cx, cy, scale, pitchR, yawR, rollR)
        setColorV(COL.canopy)
        drawFilledTriangle3D(P.nose, P.lf, P.rf, cx, cy, scale, pitchR, yawR, rollR)
    else
        setColorV(COL.canopy)
        drawFilledTriangle3D(P.nose, P.lf, P.rf, cx, cy, scale, pitchR, yawR, rollR)
    end

    setColorV(COL.rotor)
    drawLine3D(P.rotorA, P.rotorB, cx, cy, scale, pitchR, yawR, rollR)
    drawLine3D(P.rotorC, P.rotorD, cx, cy, scale, pitchR, yawR, rollR)
    drawLine3D(P.top, P.mast, cx, cy, scale, pitchR, yawR, rollR)

    local mainEdges = (detail >= 2) and MAIN_EDGES_HIGH or MAIN_EDGES_LOW
    local accentEdges = (detail >= 2) and ACCENT_EDGES_HIGH or ACCENT_EDGES_LOW

    setColorV(COL.lineMain)
    for i = 1, #mainEdges do
        local edge = mainEdges[i]
        drawLine3D(edge[1], edge[2], cx, cy, scale, pitchR, yawR, rollR)
    end

    setColorV(COL.lineAccent)
    for i = 1, #accentEdges do
        local edge = accentEdges[i]
        drawLine3D(edge[1], edge[2], cx, cy, scale, pitchR, yawR, rollR)
    end

    return true
end

return heli3d
