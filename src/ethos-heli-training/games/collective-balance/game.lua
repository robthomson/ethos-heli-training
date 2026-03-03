local game = {}

local COLLECTIVE_SOURCE_MEMBER = 2
local ROLL_SOURCE_MEMBER = 3
local PITCH_SOURCE_MEMBER = 1

local ACTIVE_RENDER_FPS = 40
local IDLE_RENDER_FPS = 14
local ACTIVE_INVALIDATE_DT = 1 / ACTIVE_RENDER_FPS
local IDLE_INVALIDATE_DT = 1 / IDLE_RENDER_FPS

local COL_DEADZONE = 0.06
local CYCLIC_DEADZONE = 0.04

local TARGET_GAIN = 0.88
local FLIP_RATE_MAX = 1.35
local FLIP_RATE_ACTIVE_MIN = 0.12

local ERR_GOOD_WINDOW = 0.22
local ERR_GREAT_WINDOW = 0.11
local CYCLIC_STABLE_WINDOW = 0.22
local CYCLIC_GREAT_WINDOW = 0.12

local SCORE_GOOD_PER_S = 32
local SCORE_GREAT_PER_S = 58
local SCORE_DRIFT_PER_S = 16
local CYCLIC_DRIFT_PER_S = 24
local COMBO_STEP_S = 1.2
local COMBO_MAX = 8

local CONFIG_FILE = "collective-balance.cfg"
local LEGACY_CONFIG_FILE = "collective-bounce.cfg"
local CONFIG_VERSION = 1
local CONFIG_BUTTON_CATEGORY = 0
local CONFIG_BUTTON_VALUE = 128

local SPEED_SLOW = 1
local SPEED_NORMAL = 2
local SPEED_FAST = 3

local FEEL_SOFT = 1
local FEEL_NORMAL = 2
local FEEL_AGGRESSIVE = 3

local STRICTNESS_RELAXED = 1
local STRICTNESS_NORMAL = 2
local STRICTNESS_HARD = 3

local RANGE_LOW = 1
local RANGE_NORMAL = 2
local RANGE_HIGH = 3

local SPEED_CHOICES_FORM = {
    {"Slow", SPEED_SLOW},
    {"Normal", SPEED_NORMAL},
    {"Fast", SPEED_FAST}
}

local FEEL_CHOICES_FORM = {
    {"Soft", FEEL_SOFT},
    {"Normal", FEEL_NORMAL},
    {"Aggressive", FEEL_AGGRESSIVE}
}

local STRICTNESS_CHOICES_FORM = {
    {"Relaxed", STRICTNESS_RELAXED},
    {"Normal", STRICTNESS_NORMAL},
    {"Hard", STRICTNESS_HARD}
}

local RANGE_CHOICES_FORM = {
    {"Low", RANGE_LOW},
    {"Normal", RANGE_NORMAL},
    {"High", RANGE_HIGH}
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function keyMatches(value, ...)
    for i = 1, select("#", ...) do
        local key = select(i, ...)
        if key and value == key then return true end
    end
    return false
end

local function isKeyCategory(category)
    if type(EVT_KEY) == "number" then return category == EVT_KEY end
    return category == 0
end

local function isConfigButtonEvent(category, value)
    if type(EVT_KEY) == "number" then
        return category == EVT_KEY and value == CONFIG_BUTTON_VALUE
    end
    return category == CONFIG_BUTTON_CATEGORY and value == CONFIG_BUTTON_VALUE
end

local function isSettingsOpenEvent(category, value)
    if isConfigButtonEvent(category, value) then
        return true
    end
    if not isKeyCategory(category) then
        return false
    end
    return keyMatches(value, KEY_PAGE_LONG)
end

local function isExitKeyEvent(category, value)
    if not isKeyCategory(category) then return false end
    if keyMatches(value, KEY_EXIT_FIRST, KEY_EXIT_BREAK) then return true end
    return value == 35
end

local function isResetEvent(category, value)
    if not isKeyCategory(category) then return false end
    return keyMatches(value, KEY_ENTER_FIRST, KEY_ENTER_BREAK, KEY_ENTER_LONG)
end

local function nowSeconds()
    if os and os.clock then return os.clock() end
    return 0
end

local function setColor(r, g, b)
    if not (lcd and lcd.color and lcd.RGB) then return end
    pcall(lcd.color, lcd.RGB(r, g, b))
end

local function setFont(font)
    if not (lcd and lcd.font and font) then return end
    pcall(lcd.font, font)
end

local function playTone(freq, duration, pause)
    if not (system and system.playTone) then return end
    pcall(system.playTone, freq, duration or 30, pause or 0)
end

local function resolveAnalogSource(member)
    if not (system and system.getSource) then return nil end
    local ok, src = pcall(system.getSource, {category = CATEGORY_ANALOG, member = member})
    if ok then return src end
    return nil
end

local function sourceValue(src)
    if not (src and src.value) then return 0 end
    local ok, value = pcall(src.value, src)
    if not ok then return 0 end
    if type(value) == "number" then return value end
    return tonumber(value) or 0
end

local function toSigned16(v)
    if v > 32767 then return v - 65536 end
    if v < -32768 then return v + 65536 end
    return v
end

local function normalizeStick(v)
    v = tonumber(v) or 0
    v = toSigned16(v)
    return clamp(v, -1024, 1024) / 1024.0
end

local function applyDeadzone(v, deadzone)
    local av = math.abs(v)
    if av <= deadzone then return 0 end
    local sign = (v < 0) and -1 or 1
    return sign * clamp((av - deadzone) / (1.0 - deadzone), 0, 1)
end

local function normalizeAngle(angle)
    while angle > math.pi do angle = angle - (2 * math.pi) end
    while angle < -math.pi do angle = angle + (2 * math.pi) end
    return angle
end

local function keepScreenAwake(state)
    if not state then return end
    local now = nowSeconds()
    if state.lastFocusKick and (now - state.lastFocusKick) < 1.0 then return end
    state.lastFocusKick = now

    if system and system.resetBacklightTimeout then pcall(system.resetBacklightTimeout) end
    if system and system.resetFocusTimeout then pcall(system.resetFocusTimeout); return end
    if resetFocusTimeout then pcall(resetFocusTimeout); return end
    if system and system.resetTimeout then pcall(system.resetTimeout) end
end

local function killPendingKeyEvents(keyValue)
    if not (system and system.killEvents) then
        return
    end
    if keyValue ~= nil then
        local ok = pcall(system.killEvents, keyValue)
        if ok then
            return
        end
    end
    pcall(system.killEvents)
end

local function suppressExitEvents(state, windowSeconds)
    if not state then return end
    state.suppressExitUntil = nowSeconds() + (windowSeconds or 0.25)
    killPendingKeyEvents(KEY_EXIT_BREAK)
    killPendingKeyEvents(KEY_EXIT_FIRST)
end

local function suppressEnterEvents(state, windowSeconds)
    if not state then return end
    state.suppressEnterUntil = nowSeconds() + (windowSeconds or 0.20)
    killPendingKeyEvents(KEY_ENTER_BREAK)
    killPendingKeyEvents(KEY_ENTER_FIRST)
end

local function requestTimedInvalidate(state)
    if not (state and lcd and lcd.invalidate) then return end
    local now = nowSeconds()
    local active = state.running or state.settingsFormOpen
    local dt = active and ACTIVE_INVALIDATE_DT or IDLE_INVALIDATE_DT
    if (not state.nextInvalidateAt) or now >= state.nextInvalidateAt then
        state.nextInvalidateAt = now + dt
        lcd.invalidate()
    end
end

local function forceInvalidate(state)
    if not state then return end
    state.nextInvalidateAt = 0
    if lcd and lcd.invalidate then
        lcd.invalidate()
    end
end

local function configPathCandidates()
    return {
        "SCRIPTS:/ethos-heli-training/games/collective-balance/" .. CONFIG_FILE,
        "SCRIPTS:/ethos-heli-training/games/collective-bounce/" .. LEGACY_CONFIG_FILE
    }
end

local function readConfigTable()
    if not (io and io.open) then return {} end
    local f
    for _, p in ipairs(configPathCandidates()) do
        f = io.open(p, "r")
        if f then break end
    end
    if not f then return {} end

    local values = {}
    while true do
        local okRead, line = pcall(f.read, f, "*l")
        if not okRead or not line then break end
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then values[k] = v end
    end
    pcall(f.close, f)
    return values
end

local function normalizeSpeed(value)
    local v = math.floor(tonumber(value) or SPEED_NORMAL)
    if v == SPEED_SLOW then
        return SPEED_SLOW
    elseif v == SPEED_FAST then
        return SPEED_FAST
    end
    return SPEED_NORMAL
end

local function normalizeFeel(value)
    local v = math.floor(tonumber(value) or FEEL_NORMAL)
    if v == FEEL_SOFT then
        return FEEL_SOFT
    elseif v == FEEL_AGGRESSIVE then
        return FEEL_AGGRESSIVE
    end
    return FEEL_NORMAL
end

local function normalizeStrictness(value)
    local v = math.floor(tonumber(value) or STRICTNESS_NORMAL)
    if v == STRICTNESS_RELAXED then
        return STRICTNESS_RELAXED
    elseif v == STRICTNESS_HARD then
        return STRICTNESS_HARD
    end
    return STRICTNESS_NORMAL
end

local function normalizeRange(value)
    local v = math.floor(tonumber(value) or RANGE_NORMAL)
    if v == RANGE_LOW then
        return RANGE_LOW
    elseif v == RANGE_HIGH then
        return RANGE_HIGH
    end
    return RANGE_NORMAL
end

local function speedName(value)
    local v = normalizeSpeed(value)
    if v == SPEED_SLOW then return "Slow" end
    if v == SPEED_FAST then return "Fast" end
    return "Normal"
end

local function feelName(value)
    local v = normalizeFeel(value)
    if v == FEEL_SOFT then return "Soft" end
    if v == FEEL_AGGRESSIVE then return "Aggressive" end
    return "Normal"
end

local function strictnessName(value)
    local v = normalizeStrictness(value)
    if v == STRICTNESS_RELAXED then return "Relaxed" end
    if v == STRICTNESS_HARD then return "Hard" end
    return "Normal"
end

local function rangeName(value)
    local v = normalizeRange(value)
    if v == RANGE_LOW then return "Low" end
    if v == RANGE_HIGH then return "High" end
    return "Normal"
end

local applyConfigProfiles

local function saveStateConfig(state)
    if not (state and io and io.open) then return false end
    local f
    for _, p in ipairs(configPathCandidates()) do
        f = io.open(p, "w")
        if f then break end
    end
    if not f then return false end

    local best = math.max(0, math.floor(tonumber(state.bestScore) or 0))
    f:write("configVersion=", CONFIG_VERSION, "\n")
    f:write("bestScore=", best, "\n")
    f:write("speed=", normalizeSpeed(state.speed), "\n")
    f:write("feel=", normalizeFeel(state.feel), "\n")
    f:write("strictness=", normalizeStrictness(state.strictness), "\n")
    f:write("range=", normalizeRange(state.range), "\n")
    pcall(f.close, f)
    return true
end

local function loadStateConfig()
    local raw = readConfigTable()
    return {
        bestScore = math.max(0, math.floor(tonumber(raw.bestScore) or 0)),
        speed = normalizeSpeed(raw.speed),
        feel = normalizeFeel(raw.feel),
        strictness = normalizeStrictness(raw.strictness),
        range = normalizeRange(raw.range)
    }
end

applyConfigProfiles = function(state)
    if not state then return end

    state.speed = normalizeSpeed(state.speed)
    state.feel = normalizeFeel(state.feel)
    state.strictness = normalizeStrictness(state.strictness)
    state.range = normalizeRange(state.range)

    local speedScale = 1.0
    if state.speed == SPEED_SLOW then
        speedScale = 0.78
    elseif state.speed == SPEED_FAST then
        speedScale = 1.22
    end
    state.flipRateMax = FLIP_RATE_MAX * speedScale
    state.flipRateActiveMin = FLIP_RATE_ACTIVE_MIN * speedScale

    local expo = 1.15
    if state.feel == FEEL_SOFT then
        expo = 1.35
    elseif state.feel == FEEL_AGGRESSIVE then
        expo = 0.95
    end
    state.pitchExpo = expo

    local strictScale = 1.0
    if state.strictness == STRICTNESS_RELAXED then
        strictScale = 1.18
    elseif state.strictness == STRICTNESS_HARD then
        strictScale = 0.84
    end
    state.errGoodWindow = ERR_GOOD_WINDOW * strictScale
    state.errGreatWindow = ERR_GREAT_WINDOW * strictScale
    state.cyclicStableWindow = CYCLIC_STABLE_WINDOW * strictScale
    state.cyclicGreatWindow = CYCLIC_GREAT_WINDOW * strictScale

    local gain = TARGET_GAIN
    if state.range == RANGE_LOW then
        gain = 0.72
    elseif state.range == RANGE_HIGH then
        gain = 0.98
    end
    state.targetGain = gain
end

local function setConfigValue(state, key, value, skipSave)
    if not state then return end

    if key == "speed" then
        state.speed = normalizeSpeed(value)
        applyConfigProfiles(state)
        state.lastMessage = "Speed: " .. speedName(state.speed)
    elseif key == "feel" then
        state.feel = normalizeFeel(value)
        applyConfigProfiles(state)
        state.lastMessage = "Feel: " .. feelName(state.feel)
    elseif key == "strictness" then
        state.strictness = normalizeStrictness(value)
        applyConfigProfiles(state)
        state.lastMessage = "Strictness: " .. strictnessName(state.strictness)
    elseif key == "range" then
        state.range = normalizeRange(value)
        applyConfigProfiles(state)
        state.lastMessage = "Range: " .. rangeName(state.range)
    elseif key == "bestScore" then
        state.bestScore = math.max(0, math.floor(tonumber(value) or 0))
    else
        return
    end

    if not skipSave then
        saveStateConfig(state)
    end
end

local function safeFormClear()
    if not (form and form.clear) then
        return false
    end
    return pcall(function()
        form.clear()
    end)
end

local function flushPendingFormClear(state)
    if not state or not state.pendingFormClear then
        return
    end
    if state.settingsFormOpen then
        return
    end
    if safeFormClear() then
        state.pendingFormClear = false
    end
end

local function closeSettingsForm(state, suppressExit, suppressEnter)
    if not state then return end

    if suppressExit ~= false then
        suppressExitEvents(state)
    end
    if suppressEnter then
        suppressEnterEvents(state)
    end

    state.settingsFormOpen = false
    state.pendingFormClear = true
    flushPendingFormClear(state)
    forceInvalidate(state)
end

local function openSettingsForm(state)
    if not (form and form.clear and form.addLine and form.addChoiceField) then
        return false
    end

    if not safeFormClear() then
        state.settingsFormOpen = false
        return false
    end
    state.settingsFormOpen = true

    local infoLine = form.addLine("Collective Balance")
    if form.addStaticText then
        form.addStaticText(infoLine, nil, "Settings (Exit/Back to return)")
    end

    local speedLine = form.addLine("Flip speed")
    form.addChoiceField(
        speedLine,
        nil,
        SPEED_CHOICES_FORM,
        function()
            return normalizeSpeed(state.speed)
        end,
        function(newValue)
            setConfigValue(state, "speed", newValue)
            forceInvalidate(state)
        end
    )

    local feelLine = form.addLine("Pitch feel")
    form.addChoiceField(
        feelLine,
        nil,
        FEEL_CHOICES_FORM,
        function()
            return normalizeFeel(state.feel)
        end,
        function(newValue)
            setConfigValue(state, "feel", newValue)
            forceInvalidate(state)
        end
    )

    local strictLine = form.addLine("Lock strictness")
    form.addChoiceField(
        strictLine,
        nil,
        STRICTNESS_CHOICES_FORM,
        function()
            return normalizeStrictness(state.strictness)
        end,
        function(newValue)
            setConfigValue(state, "strictness", newValue)
            forceInvalidate(state)
        end
    )

    local rangeLine = form.addLine("Target range")
    form.addChoiceField(
        rangeLine,
        nil,
        RANGE_CHOICES_FORM,
        function()
            return normalizeRange(state.range)
        end,
        function(newValue)
            setConfigValue(state, "range", newValue)
            forceInvalidate(state)
        end
    )

    local bestLine = form.addLine("Best score")
    if form.addStaticText then
        form.addStaticText(bestLine, nil, tostring(state.bestScore))
    end

    local resetBest = function()
        setConfigValue(state, "bestScore", 0)
        state.lastMessage = "Best score reset"
        playTone(420, 40, 0)
        forceInvalidate(state)
    end
    if form.addButton then
        form.addButton(bestLine, nil, {text = "Reset", press = resetBest})
    elseif form.addTextButton then
        form.addTextButton(bestLine, nil, "Reset", resetBest)
    end

    local backLine = form.addLine("")
    local backAction = function()
        closeSettingsForm(state, true, true)
    end
    if form.addButton then
        form.addButton(backLine, nil, {text = "Back to Game", press = backAction})
    elseif form.addTextButton then
        form.addTextButton(backLine, nil, "Back to Game", backAction)
    end

    forceInvalidate(state)
    return true
end

local function refreshGeometry(state)
    local w = (type(LCD_W) == "number") and LCD_W or 784
    local h = (type(LCD_H) == "number") and LCD_H or 406
    if lcd and lcd.getWindowSize then
        local ok, ww, hh = pcall(lcd.getWindowSize)
        if ok and type(ww) == "number" and type(hh) == "number" and ww > 0 and hh > 0 then
            w, h = ww, hh
        end
    end
    state.windowW = w
    state.windowH = h
end

local function resolveSources(state)
    if not state.collectiveSource then state.collectiveSource = resolveAnalogSource(COLLECTIVE_SOURCE_MEMBER) end
    if not state.rollSource then state.rollSource = resolveAnalogSource(ROLL_SOURCE_MEMBER) end
    if not state.pitchSource then state.pitchSource = resolveAnalogSource(PITCH_SOURCE_MEMBER) end
end

local function readInputs(state)
    resolveSources(state)
    state.colInput = applyDeadzone(normalizeStick(sourceValue(state.collectiveSource)), COL_DEADZONE)
    state.rollInput = applyDeadzone(normalizeStick(sourceValue(state.rollSource)), CYCLIC_DEADZONE)
    state.pitchInput = applyDeadzone(normalizeStick(sourceValue(state.pitchSource)), CYCLIC_DEADZONE)
    state.cyclicMag = math.abs(state.rollInput)
end

local function resetRun(state)
    state.score = 0
    state.combo = 1
    state.lockTime = 0
    state.sampleTime = 0
    state.trackTime = 0
    state.greatTime = 0
    state.flipAngle = 0
    state.flipRate = 0
    state.rotationActive = false
    state.targetCollective = state.targetGain or TARGET_GAIN
    state.trackingError = 1
    state.running = true
    state.lastMessage = "Long PAGE: settings"
end

local function updateTarget(state, dt)
    local pitch = state.pitchInput or 0
    local expo = state.pitchExpo or 1.15
    local shaped = (pitch >= 0 and 1 or -1) * (math.abs(pitch) ^ expo)
    local maxRate = state.flipRateMax or FLIP_RATE_MAX
    state.flipRate = shaped * maxRate
    state.rotationActive = math.abs(state.flipRate) >= (state.flipRateActiveMin or FLIP_RATE_ACTIVE_MIN)
    local spin = state.flipRate * (2 * math.pi)
    state.flipAngle = normalizeAngle(state.flipAngle + (spin * dt))
    state.targetCollective = clamp(math.cos(state.flipAngle) * (state.targetGain or TARGET_GAIN), -1, 1)
end

local function updateScoring(state, dt)
    if not state.rotationActive then
        state.lockTime = math.max(0, state.lockTime - 1.8 * dt)
        local comboSteps = math.floor(state.lockTime / COMBO_STEP_S)
        state.combo = 1 + clamp(comboSteps, 0, COMBO_MAX - 1)
        state.score = math.max(0, state.score - (SCORE_DRIFT_PER_S * 0.45) * dt)
        state.lastMessage = "Use elevator to set flip speed/direction"
        return
    end

    local err = math.abs(state.colInput - state.targetCollective)
    local errGoodWindow = state.errGoodWindow or ERR_GOOD_WINDOW
    local errGreatWindow = state.errGreatWindow or ERR_GREAT_WINDOW
    local cyclicStableWindow = state.cyclicStableWindow or CYCLIC_STABLE_WINDOW
    local cyclicGreatWindow = state.cyclicGreatWindow or CYCLIC_GREAT_WINDOW

    local cyclicGood = state.cyclicMag <= cyclicStableWindow
    local cyclicGreat = state.cyclicMag <= cyclicGreatWindow
    local good = err <= errGoodWindow and cyclicGood
    local great = err <= errGreatWindow and cyclicGreat

    state.trackingError = err
    state.sampleTime = state.sampleTime + dt
    if good then state.trackTime = state.trackTime + dt end
    if great then state.greatTime = state.greatTime + dt end

    if good then
        state.lockTime = state.lockTime + dt
        local comboSteps = math.floor(state.lockTime / COMBO_STEP_S)
        state.combo = 1 + clamp(comboSteps, 0, COMBO_MAX - 1)

        local gain = great and SCORE_GREAT_PER_S or SCORE_GOOD_PER_S
        state.score = state.score + gain * state.combo * dt
        state.lastMessage = great and "Great timing" or "Good tracking"
    else
        local cyclicPenalty = clamp((state.cyclicMag - cyclicStableWindow) / (1.0 - cyclicStableWindow), 0, 1)
        state.lockTime = math.max(0, state.lockTime - (1.8 + cyclicPenalty * 2.0) * dt)
        local comboSteps = math.floor(state.lockTime / COMBO_STEP_S)
        state.combo = 1 + clamp(comboSteps, 0, COMBO_MAX - 1)

        local penalty = SCORE_DRIFT_PER_S + CYCLIC_DRIFT_PER_S * cyclicPenalty
        state.score = math.max(0, state.score - penalty * dt)

        if err <= errGoodWindow and not cyclicGood then
            state.lastMessage = "Collective on target, cyclic too high"
        elseif err > errGoodWindow and cyclicGood then
            state.lastMessage = "Follow flip attitude with collective"
        else
            state.lastMessage = "Track target and keep cyclic calm"
        end
    end

    local rounded = math.floor(state.score + 0.5)
    if rounded > state.bestScore then
        state.bestScore = rounded
        saveStateConfig(state)
    end
end

local function valueToY(y, h, value)
    local yy = y + math.floor((1.0 - ((value + 1.0) * 0.5)) * (h - 1))
    return clamp(yy, y + 1, y + h - 2)
end

local function drawCollectiveMeter(x, y, w, h, value, target, label, errGoodWindow, errGreatWindow)
    setColor(52, 68, 96)
    lcd.drawFilledRectangle(x, y, w, h)

    local mid = y + math.floor(h * 0.5)
    setColor(108, 126, 156)
    lcd.drawLine(x + 2, mid, x + w - 2, mid)

    local targetY = valueToY(y, h, target)
    local goodHalf = math.max(7, math.floor(h * (errGoodWindow or ERR_GOOD_WINDOW) * 0.25))
    local greatHalf = math.max(4, math.floor(h * (errGreatWindow or ERR_GREAT_WINDOW) * 0.25))

    setColor(188, 144, 82)
    lcd.drawFilledRectangle(x + 2, targetY - goodHalf, w - 4, goodHalf * 2)
    setColor(68, 162, 106)
    lcd.drawFilledRectangle(x + 2, targetY - greatHalf, w - 4, greatHalf * 2)

    setColor(226, 96, 96)
    lcd.drawLine(x + 2, targetY, x + w - 2, targetY)

    local markerY = valueToY(y, h, value)
    setColor(230, 238, 248)
    lcd.drawFilledRectangle(x + 2, markerY - 1, w - 4, 3)

    setColor(176, 192, 216)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(x, y - 15, label)
end

local function orbitPoint(cx, cy, r, angle)
    local x = cx + math.cos(angle) * r
    local y = cy + math.sin(angle) * r
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function drawFlipHeli(state, x, y, size)
    local cx = x + math.floor(size * 0.5)
    local cy = y + math.floor(size * 0.5)
    local radius = math.floor(size * 0.44)

    setColor(52, 68, 96)
    lcd.drawFilledRectangle(x, y, size, size)

    if lcd and lcd.drawCircle then
        setColor(88, 106, 136)
        lcd.drawCircle(cx, cy, radius)
        lcd.drawCircle(cx, cy, math.floor(radius * 0.65))
    end

    local angle = state.flipAngle
    local bodyR = math.floor(size * 0.27)
    local rotorR = math.floor(size * 0.22)

    local noseX, noseY = orbitPoint(cx, cy, bodyR, angle)
    local tailX, tailY = orbitPoint(cx, cy, bodyR, angle + math.pi)
    local rotorAX, rotorAY = orbitPoint(cx, cy, rotorR, angle + (math.pi * 0.5))
    local rotorBX, rotorBY = orbitPoint(cx, cy, rotorR, angle - (math.pi * 0.5))

    setColor(120, 146, 188)
    lcd.drawLine(tailX, tailY, noseX, noseY)

    setColor(170, 188, 216)
    lcd.drawLine(rotorAX, rotorAY, rotorBX, rotorBY)

    local finX, finY = orbitPoint(tailX, tailY, 9, angle + (math.pi * 0.5))
    setColor(102, 132, 176)
    lcd.drawLine(tailX, tailY, finX, finY)

    setColor(228, 102, 92)
    lcd.drawFilledRectangle(noseX - 2, noseY - 2, 5, 5)

end

local function measureTextWidth(text)
    text = tostring(text or "")
    if lcd and lcd.getTextSize then
        local ok, w = pcall(lcd.getTextSize, text)
        if ok and type(w) == "number" then
            return w
        end
    end
    return #text * 6
end

local function drawRightText(rightX, y, text, font)
    setFont(font or FONT_STD)
    local w = measureTextWidth(text)
    lcd.drawText(rightX - w, y, text)
end

local function drawHud(state)
    setColor(14, 22, 34)
    lcd.drawFilledRectangle(0, 0, state.windowW, state.windowH)

    setColor(236, 242, 252)
    setFont(FONT_L_BOLD or FONT_STD)
    lcd.drawText(14, 12, "Collective Balance")

    setColor(166, 180, 204)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(16, 38, "Elevator controls flip rate + direction")

    local targetPct = math.floor(state.targetCollective * 100 + 0.5)
    if state.targetCollective >= 0 then
        setColor(86, 222, 128)
    else
        setColor(248, 188, 90)
    end
    setFont(FONT_XL_BOLD or FONT_L_BOLD or FONT_STD)
    lcd.drawText(16, 62, "Target " .. tostring(targetPct) .. "%")

    local infoRight = state.windowW - 14
    local infoY = 18
    local infoRow = 23

    local accuracy = 0
    local greatPct = 0
    if state.sampleTime > 0 then
        accuracy = math.floor((state.trackTime / state.sampleTime) * 100 + 0.5)
        greatPct = math.floor((state.greatTime / state.sampleTime) * 100 + 0.5)
    end

    local footerReserve = 52
    local viewportTop = 112
    local viewportBottom = state.windowH - footerReserve
    local viewportH = math.max(140, viewportBottom - viewportTop)

    local meterX = 16
    local meterW = clamp(math.floor(state.windowW * 0.12), 84, 114)
    local meterH = viewportH
    drawCollectiveMeter(
        meterX,
        viewportTop,
        meterW,
        meterH,
        state.colInput,
        state.targetCollective,
        "Collective",
        state.errGoodWindow,
        state.errGreatWindow
    )

    local statsReserve = 240
    local mainLeft = meterX + meterW + 20
    local mainRight = state.windowW - statsReserve
    local maxDialW = math.max(120, mainRight - mainLeft)
    local dialSize = clamp(math.floor(math.min(maxDialW, viewportH)), 150, 300)
    local dialX = math.floor((state.windowW - dialSize) * 0.5)
    dialX = clamp(dialX, mainLeft, mainRight - dialSize)
    local dialY = viewportTop + math.floor((viewportH - dialSize) * 0.5)
    drawFlipHeli(state, dialX, dialY, dialSize)

    setColor(228, 236, 248)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(dialX, dialY - 16, string.format("Flip %+.2f r/s", state.flipRate))

    setColor(236, 242, 252)
    drawRightText(infoRight, infoY + (infoRow * 0), "Score " .. tostring(math.floor(state.score + 0.5)), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 1), "Best " .. tostring(state.bestScore), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 2), "Combo x" .. tostring(state.combo), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 3), "Track " .. tostring(accuracy) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 4), "Great " .. tostring(greatPct) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 5), "Err " .. tostring(math.floor(state.trackingError * 100 + 0.5)) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 6), "Cyclic " .. tostring(math.floor(state.cyclicMag * 100 + 0.5)) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 7), "Elev " .. tostring(math.floor(state.pitchInput * 100 + 0.5)) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 8), "Speed " .. speedName(state.speed), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 9), "Strict " .. strictnessName(state.strictness), FONT_STD)

    setColor(166, 180, 204)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(16, state.windowH - 40, state.lastMessage)
    lcd.drawText(16, state.windowH - 20, "Enter: reset run | Long PAGE: settings | Exit: back")
end

local function updateRun(state, dt)
    if not state.running then return end
    updateTarget(state, dt)
    updateScoring(state, dt)
end

local function createState()
    local loadedConfig = loadStateConfig()
    local state = {
        collectiveSource = resolveAnalogSource(COLLECTIVE_SOURCE_MEMBER),
        rollSource = resolveAnalogSource(ROLL_SOURCE_MEMBER),
        pitchSource = resolveAnalogSource(PITCH_SOURCE_MEMBER),
        colInput = 0,
        rollInput = 0,
        pitchInput = 0,
        cyclicMag = 0,
        score = 0,
        bestScore = loadedConfig.bestScore,
        speed = loadedConfig.speed,
        feel = loadedConfig.feel,
        strictness = loadedConfig.strictness,
        range = loadedConfig.range,
        flipRateMax = FLIP_RATE_MAX,
        flipRateActiveMin = FLIP_RATE_ACTIVE_MIN,
        pitchExpo = 1.15,
        targetGain = TARGET_GAIN,
        errGoodWindow = ERR_GOOD_WINDOW,
        errGreatWindow = ERR_GREAT_WINDOW,
        cyclicStableWindow = CYCLIC_STABLE_WINDOW,
        cyclicGreatWindow = CYCLIC_GREAT_WINDOW,
        combo = 1,
        lockTime = 0,
        sampleTime = 0,
        trackTime = 0,
        greatTime = 0,
        flipAngle = 0,
        flipRate = 0,
        rotationActive = false,
        targetCollective = TARGET_GAIN,
        trackingError = 1,
        running = true,
        settingsFormOpen = false,
        pendingFormClear = false,
        suppressExitUntil = 0,
        suppressEnterUntil = 0,
        lastMessage = "Long PAGE: settings",
        lastFrameAt = 0,
        nextInvalidateAt = 0,
        lastFocusKick = 0,
        windowW = (type(LCD_W) == "number") and LCD_W or 784,
        windowH = (type(LCD_H) == "number") and LCD_H or 406
    }
    applyConfigProfiles(state)
    state.targetCollective = state.targetGain
    refreshGeometry(state)
    resetRun(state)
    return state
end

function game.create()
    return createState()
end

function game.wakeup(state)
    if not state then return end
    flushPendingFormClear(state)
    refreshGeometry(state)
    resolveSources(state)

    if state.settingsFormOpen then
        return
    end

    keepScreenAwake(state)
    requestTimedInvalidate(state)
end

function game.event(state, category, value)
    if not state then return false end

    local now = nowSeconds()
    if state.suppressExitUntil and now < state.suppressExitUntil then
        if category == EVT_CLOSE then return true end
        if isExitKeyEvent(category, value) then return true end
    elseif state.suppressExitUntil and state.suppressExitUntil ~= 0 then
        state.suppressExitUntil = 0
    end

    if state.suppressEnterUntil and now < state.suppressEnterUntil then
        if isResetEvent(category, value) then return true end
    elseif state.suppressEnterUntil and state.suppressEnterUntil ~= 0 then
        state.suppressEnterUntil = 0
    end

    if state.settingsFormOpen then
        if category == EVT_CLOSE then
            closeSettingsForm(state, true, true)
            return true
        end
        if isExitKeyEvent(category, value) then
            closeSettingsForm(state, true, true)
            return true
        end
        return false
    end

    if category == EVT_CLOSE then return false end
    if isExitKeyEvent(category, value) then return false end

    if isSettingsOpenEvent(category, value) then
        local okOpen, opened = pcall(openSettingsForm, state)
        if okOpen and opened then
            return true
        end

        if state.speed == SPEED_FAST then
            setConfigValue(state, "speed", SPEED_NORMAL)
        else
            setConfigValue(state, "speed", SPEED_FAST)
        end
        state.lastMessage = "Speed: " .. speedName(state.speed)
        playTone(760, 35, 0)
        return true
    end

    if isResetEvent(category, value) then
        resetRun(state)
        playTone(560, 70, 0)
        return true
    end

    return false
end

function game.paint(state)
    if not state then return end

    flushPendingFormClear(state)
    if state.settingsFormOpen then
        return
    end

    local now = nowSeconds()
    if state.lastFrameAt <= 0 then state.lastFrameAt = now end
    local dt = now - state.lastFrameAt
    state.lastFrameAt = now
    if dt < 0 then dt = 0 elseif dt > 0.2 then dt = 0.2 end
    state.lastDt = dt

    readInputs(state)
    updateRun(state, dt)
    drawHud(state)
end

function game.close(state)
    if type(state) ~= "table" then return end

    if state.settingsFormOpen then
        closeSettingsForm(state, false, false)
    else
        flushPendingFormClear(state)
    end

    saveStateConfig(state)
    state.running = false
    if collectgarbage then
        pcall(collectgarbage, "collect")
        pcall(collectgarbage, "collect")
    end
end

return game
