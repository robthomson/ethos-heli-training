local game = {}

local ELEVATOR_SOURCE_MEMBER = 1
local COLLECTIVE_SOURCE_MEMBER = 2
local ROLL_SOURCE_MEMBER = 3

local ACTIVE_RENDER_FPS = 40
local IDLE_RENDER_FPS = 14
local ACTIVE_INVALIDATE_DT = 1 / ACTIVE_RENDER_FPS
local IDLE_INVALIDATE_DT = 1 / IDLE_RENDER_FPS

local ELEVATOR_DEADZONE = 0.06
local COLLECTIVE_DEADZONE = 0.06
local ROLL_DEADZONE = 0.06
local ELEVATOR_THRESHOLD = 0.44
local COLLECTIVE_THRESHOLD = 0.42

local AXIS_MODE_ELEVATOR = 1
local AXIS_MODE_AILERON = 2

local ORIENTATION_SAME = 1
local ORIENTATION_OPPOSITE = 2

local SPEED_SLOW = 1
local SPEED_NORMAL = 2
local SPEED_FAST = 3
local SPEED_VERY_FAST = 4

local COLLECTIVE_RATIO_55 = 1
local COLLECTIVE_RATIO_70 = 2
local COLLECTIVE_RATIO_85 = 3
local COLLECTIVE_RATIO_100 = 4

local AXIS_MODE_CHOICES_FORM = {
    {"Elevator", AXIS_MODE_ELEVATOR},
    {"Aileron", AXIS_MODE_AILERON}
}

local ORIENTATION_CHOICES_FORM = {
    {"Same Direction", ORIENTATION_SAME},
    {"Opposite Direction", ORIENTATION_OPPOSITE}
}

local SPEED_CHOICES_FORM = {
    {"Slow", SPEED_SLOW},
    {"Normal", SPEED_NORMAL},
    {"Fast", SPEED_FAST},
    {"Very Fast", SPEED_VERY_FAST}
}

local COLLECTIVE_RATIO_CHOICES_FORM = {
    {"55%", COLLECTIVE_RATIO_55},
    {"70%", COLLECTIVE_RATIO_70},
    {"85%", COLLECTIVE_RATIO_85},
    {"100%", COLLECTIVE_RATIO_100}
}

local BEAT_PERIOD_START = 0.95
local BEAT_PERIOD_MIN = 0.45
local BEAT_ACCEL_STEP = 0.03
local BEAT_ACCEL_EVERY = 6

local COLLECTIVE_RESPONSE_RATE_BASE = 7.0

local HIT_WINDOW_GOOD = 0.26
local HIT_WINDOW_GREAT = 0.12
local SCORE_GREAT = 120
local SCORE_GOOD = 80
local SCORE_LATE = 45
local SCORE_MISS_PENALTY = 35

local CONFIG_FILE = "tictoc-rhythm.cfg"
local CONFIG_VERSION = 4
local CONFIG_BUTTON_CATEGORY = 0
local CONFIG_BUTTON_VALUE = 128

local function clamp(v, lo, hi)
    if v < lo then
        return lo
    end
    if v > hi then
        return hi
    end
    return v
end

local function keyMatches(value, ...)
    for i = 1, select("#", ...) do
        local key = select(i, ...)
        if key and value == key then
            return true
        end
    end
    return false
end

local function isKeyCategory(category)
    if type(EVT_KEY) == "number" then
        return category == EVT_KEY
    end
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
    if not isKeyCategory(category) then
        return false
    end
    if keyMatches(value, KEY_EXIT_FIRST, KEY_EXIT_BREAK) then
        return true
    end
    return value == 35
end

local function isResetEvent(category, value)
    if not isKeyCategory(category) then
        return false
    end
    return keyMatches(value, KEY_ENTER_FIRST, KEY_ENTER_BREAK, KEY_ENTER_LONG)
end

local function nowSeconds()
    if os and os.clock then
        return os.clock()
    end
    return 0
end

local function setColor(r, g, b)
    if not (lcd and lcd.color and lcd.RGB) then
        return
    end
    pcall(lcd.color, lcd.RGB(r, g, b))
end

local function setFont(font)
    if not (lcd and lcd.font and font) then
        return
    end
    pcall(lcd.font, font)
end

local function playTone(freq, duration, pause)
    if not (system and system.playTone) then
        return
    end
    pcall(system.playTone, freq, duration or 25, pause or 0)
end

local function resolveAnalogSource(member)
    if not (system and system.getSource) then
        return nil
    end
    local ok, src = pcall(system.getSource, {category = CATEGORY_ANALOG, member = member})
    if ok then
        return src
    end
    return nil
end

local function sourceValue(src)
    if not (src and src.value) then
        return 0
    end
    local ok, value = pcall(src.value, src)
    if not ok then
        return 0
    end
    if type(value) == "number" then
        return value
    end
    return tonumber(value) or 0
end

local function toSigned16(v)
    if v > 32767 then
        return v - 65536
    end
    if v < -32768 then
        return v + 65536
    end
    return v
end

local function normalizeStick(v)
    v = tonumber(v) or 0
    v = toSigned16(v)
    v = clamp(v, -1024, 1024)
    return v / 1024.0
end

local function applyDeadzone(v, deadzone)
    local absV = math.abs(v)
    if absV <= deadzone then
        return 0
    end
    local sign = (v < 0) and -1 or 1
    local scaled = (absV - deadzone) / (1.0 - deadzone)
    return sign * clamp(scaled, 0, 1)
end

local function keepScreenAwake(state)
    if not state then
        return
    end

    local now = nowSeconds()
    if state.lastFocusKick and (now - state.lastFocusKick) < 1.0 then
        return
    end
    state.lastFocusKick = now

    if system and system.resetBacklightTimeout then
        pcall(system.resetBacklightTimeout)
    end

    if system and system.resetFocusTimeout then
        pcall(system.resetFocusTimeout)
        return
    end

    if resetFocusTimeout then
        pcall(resetFocusTimeout)
        return
    end

    if system and system.resetTimeout then
        pcall(system.resetTimeout)
    end
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
    if not state then
        return
    end
    state.suppressExitUntil = nowSeconds() + (windowSeconds or 0.25)
    killPendingKeyEvents(KEY_EXIT_BREAK)
    killPendingKeyEvents(KEY_EXIT_FIRST)
end

local function suppressEnterEvents(state, windowSeconds)
    if not state then
        return
    end
    state.suppressEnterUntil = nowSeconds() + (windowSeconds or 0.20)
    killPendingKeyEvents(KEY_ENTER_BREAK)
    killPendingKeyEvents(KEY_ENTER_FIRST)
end

local function requestTimedInvalidate(state)
    if not (state and lcd and lcd.invalidate) then
        return
    end

    local now = nowSeconds()
    local active = state.settingsFormOpen
        or state.running
        or math.abs(state.eleInput) > 0.03
        or math.abs(state.colInput) > 0.03
        or math.abs(state.rollInput) > 0.03
    local targetDt = active and ACTIVE_INVALIDATE_DT or IDLE_INVALIDATE_DT

    if (not state.nextInvalidateAt) or now >= state.nextInvalidateAt then
        state.nextInvalidateAt = now + targetDt
        lcd.invalidate()
    end
end

local function forceInvalidate(state)
    if not state then
        return
    end
    state.nextInvalidateAt = 0
    if lcd and lcd.invalidate then
        lcd.invalidate()
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
    if not state then
        return
    end

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

local function configPathCandidates()
    return {"SCRIPTS:/ethos-heli-training/games/tictoc-rhythm/" .. CONFIG_FILE}
end

local function readConfigTable()
    if not (io and io.open) then
        return {}
    end

    local f
    for _, path in ipairs(configPathCandidates()) do
        f = io.open(path, "r")
        if f then
            break
        end
    end

    if not f then
        return {}
    end

    local values = {}
    while true do
        local okRead, line = pcall(f.read, f, "*l")
        if not okRead or not line then
            break
        end
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key then
            values[key] = value
        end
    end

    pcall(f.close, f)
    return values
end

local applySpeedProfile
local applyCollectiveResponseProfile

local function normalizeAxisMode(value)
    local v = math.floor(tonumber(value) or AXIS_MODE_ELEVATOR)
    if v == AXIS_MODE_AILERON then
        return AXIS_MODE_AILERON
    end
    return AXIS_MODE_ELEVATOR
end

local function normalizeOrientation(value, configVersion)
    local v = math.floor(tonumber(value) or ORIENTATION_SAME)
    local version = math.floor(tonumber(configVersion) or CONFIG_VERSION)

    -- v1/v2 had four concrete orientations; map down to logical two-mode orientation.
    if version < 3 then
        if v == 1 or v == 2 then
            return ORIENTATION_SAME
        elseif v == 3 or v == 4 then
            return ORIENTATION_OPPOSITE
        end
        return ORIENTATION_SAME
    end

    return clamp(v, ORIENTATION_SAME, ORIENTATION_OPPOSITE)
end

local function normalizeSpeed(value)
    local v = math.floor(tonumber(value) or SPEED_NORMAL)
    if v == SPEED_SLOW then
        return SPEED_SLOW
    elseif v == SPEED_FAST then
        return SPEED_FAST
    elseif v == SPEED_VERY_FAST then
        return SPEED_VERY_FAST
    end
    return SPEED_NORMAL
end

local function normalizeCollectiveRatio(value)
    local v = math.floor(tonumber(value) or COLLECTIVE_RATIO_70)
    if v == COLLECTIVE_RATIO_55 then
        return COLLECTIVE_RATIO_55
    elseif v == COLLECTIVE_RATIO_85 then
        return COLLECTIVE_RATIO_85
    elseif v == COLLECTIVE_RATIO_100 then
        return COLLECTIVE_RATIO_100
    end
    return COLLECTIVE_RATIO_70
end

local function defaultConfig()
    return {
        bestScore = 0,
        axisMode = AXIS_MODE_ELEVATOR,
        orientation = ORIENTATION_SAME,
        speed = SPEED_NORMAL,
        collectiveRatio = COLLECTIVE_RATIO_70
    }
end

local function loadStateConfig()
    local defaults = defaultConfig()
    local raw = readConfigTable()
    local version = math.floor(tonumber(raw.configVersion) or 1)

    return {
        bestScore = math.max(0, math.floor(tonumber(raw.bestScore) or defaults.bestScore)),
        axisMode = normalizeAxisMode(raw.axisMode),
        orientation = normalizeOrientation(raw.orientation, version),
        speed = normalizeSpeed(raw.speed),
        collectiveRatio = normalizeCollectiveRatio(raw.collectiveRatio)
    }
end

local function saveStateConfig(state)
    if not (state and state.config and io and io.open) then
        return false
    end

    local f
    for _, path in ipairs(configPathCandidates()) do
        f = io.open(path, "w")
        if f then
            break
        end
    end
    if not f then
        return false
    end

    local cfg = state.config
    f:write("configVersion=", CONFIG_VERSION, "\n")
    f:write("bestScore=", math.max(0, math.floor(tonumber(state.bestScore) or 0)), "\n")
    f:write("axisMode=", normalizeAxisMode(cfg.axisMode), "\n")
    f:write("orientation=", normalizeOrientation(cfg.orientation), "\n")
    f:write("speed=", normalizeSpeed(cfg.speed), "\n")
    f:write("collectiveRatio=", normalizeCollectiveRatio(cfg.collectiveRatio), "\n")
    pcall(f.close, f)
    return true
end

local function setConfigValue(state, key, value, skipSave)
    if not (state and state.config) then
        return
    end

    if key == "bestScore" then
        local best = math.max(0, math.floor(tonumber(value) or 0))
        state.bestScore = best
        state.config.bestScore = best
    elseif key == "axisMode" then
        local mode = normalizeAxisMode(value)
        state.axisMode = mode
        state.config.axisMode = mode
    elseif key == "orientation" then
        local orientation = normalizeOrientation(value)
        state.orientation = orientation
        state.config.orientation = orientation
    elseif key == "speed" then
        local speed = normalizeSpeed(value)
        state.speed = speed
        state.config.speed = speed
        applySpeedProfile(state, true)
    elseif key == "collectiveRatio" then
        local ratio = normalizeCollectiveRatio(value)
        state.collectiveRatio = ratio
        state.config.collectiveRatio = ratio
        applyCollectiveResponseProfile(state)
    else
        return
    end

    state.config.bestScore = state.bestScore
    if not skipSave then
        saveStateConfig(state)
    end
end

local function axisModeName(mode)
    if mode == AXIS_MODE_AILERON then
        return "Aileron"
    end
    return "Elevator"
end

local function orientationName(orientation)
    if orientation == ORIENTATION_OPPOSITE then
        return "Opposite Direction"
    end
    return "Same Direction"
end

local function speedName(speed)
    if speed == SPEED_SLOW then
        return "Slow"
    elseif speed == SPEED_VERY_FAST then
        return "Very Fast"
    elseif speed == SPEED_FAST then
        return "Fast"
    end
    return "Normal"
end

local function collectiveRatioName(mode)
    mode = normalizeCollectiveRatio(mode)
    if mode == COLLECTIVE_RATIO_55 then
        return "55%"
    elseif mode == COLLECTIVE_RATIO_85 then
        return "85%"
    elseif mode == COLLECTIVE_RATIO_100 then
        return "100%"
    end
    return "70%"
end

local function collectiveResponseScale(mode)
    mode = normalizeCollectiveRatio(mode)
    if mode == COLLECTIVE_RATIO_55 then
        return 0.55
    elseif mode == COLLECTIVE_RATIO_85 then
        return 0.85
    elseif mode == COLLECTIVE_RATIO_100 then
        return 1.00
    end
    return 0.70
end

local function beatSpeedScale(speed)
    if speed == SPEED_SLOW then
        return 1.08
    elseif speed == SPEED_VERY_FAST then
        return 0.66
    elseif speed == SPEED_FAST then
        return 0.78
    end
    return 0.90
end

applySpeedProfile = function(state, keepCurrentPeriod)
    local scale = beatSpeedScale(state.speed)
    state.beatPeriodStart = BEAT_PERIOD_START * scale
    state.beatPeriodMin = BEAT_PERIOD_MIN * scale
    state.beatAccelStep = BEAT_ACCEL_STEP * scale

    if keepCurrentPeriod then
        state.beatPeriod = clamp(state.beatPeriod or state.beatPeriodStart, state.beatPeriodMin, state.beatPeriodStart)
    else
        state.beatPeriod = state.beatPeriodStart
    end
end

applyCollectiveResponseProfile = function(state)
    state.collectiveRatio = normalizeCollectiveRatio(state.collectiveRatio)
    state.collectiveResponseScale = collectiveResponseScale(state.collectiveRatio)
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

    local infoLine = form.addLine("TicToc Rhythm")
    if form.addStaticText then
        form.addStaticText(infoLine, nil, "Settings (Exit/Back to return)")
    end

    local axisLine = form.addLine("Cyclic axis")
    form.addChoiceField(
        axisLine,
        nil,
        AXIS_MODE_CHOICES_FORM,
        function()
            return normalizeAxisMode(state.axisMode)
        end,
        function(newValue)
            setConfigValue(state, "axisMode", newValue)
            state.lastMessage = "Mode set: " .. axisModeName(state.axisMode)
            forceInvalidate(state)
        end
    )

    local orientationLine = form.addLine("Direction orientation")
    form.addChoiceField(
        orientationLine,
        nil,
        ORIENTATION_CHOICES_FORM,
        function()
            return normalizeOrientation(state.orientation)
        end,
        function(newValue)
            setConfigValue(state, "orientation", newValue)
            state.lastMessage = "Orientation: " .. orientationName(state.orientation)
            forceInvalidate(state)
        end
    )

    local speedLine = form.addLine("Beat speed")
    form.addChoiceField(
        speedLine,
        nil,
        SPEED_CHOICES_FORM,
        function()
            return normalizeSpeed(state.speed)
        end,
        function(newValue)
            setConfigValue(state, "speed", newValue)
            state.lastMessage = "Speed: " .. speedName(state.speed)
            forceInvalidate(state)
        end
    )

    local ratioLine = form.addLine("Collective/cyclic ratio")
    form.addChoiceField(
        ratioLine,
        nil,
        COLLECTIVE_RATIO_CHOICES_FORM,
        function()
            return normalizeCollectiveRatio(state.collectiveRatio)
        end,
        function(newValue)
            setConfigValue(state, "collectiveRatio", newValue)
            state.lastMessage = "Collective ratio: " .. collectiveRatioName(state.collectiveRatio)
            forceInvalidate(state)
        end
    )

    local bestLine = form.addLine("Best score")
    if form.addStaticText then
        form.addStaticText(bestLine, nil, tostring(state.bestScore))
    end

    local resetBest = function()
        setConfigValue(state, "bestScore", 0)
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
    local width = (type(LCD_W) == "number") and LCD_W or 784
    local height = (type(LCD_H) == "number") and LCD_H or 406

    if lcd and lcd.getWindowSize then
        local ok, w, h = pcall(lcd.getWindowSize)
        if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
            width = w
            height = h
        end
    end

    state.windowW = width
    state.windowH = height
end

local function orientationSigns(orientation)
    orientation = normalizeOrientation(orientation)
    if orientation == ORIENTATION_OPPOSITE then
        return 1, -1
    end
    return 1, 1
end

local function phaseName(phase)
    if phase == 1 then
        return "TIC"
    end
    return "TOC"
end

local function updateCollectiveTargetAxis(state, dt)
    if not state then
        return
    end

    local colMul = orientationSigns(state.orientation)
    local desired = state.phase * colMul
    local prev = state.colTargetAxis
    if type(prev) ~= "number" then
        state.colTargetAxis = desired
        return
    end

    local responseRate = COLLECTIVE_RESPONSE_RATE_BASE * (state.collectiveResponseScale or 0.70)
    local maxDelta = responseRate * math.max(tonumber(dt) or 0, 0)
    local delta = desired - prev
    if math.abs(delta) <= maxDelta then
        state.colTargetAxis = desired
    else
        state.colTargetAxis = prev + ((delta > 0) and maxDelta or -maxDelta)
    end
end

local function resetRun(state)
    state.score = 0
    state.streak = 0
    state.phase = 1
    state.hitThisBeat = false
    state.phaseElapsed = 0
    applySpeedProfile(state, false)
    state.beatsTotal = 0
    state.beatsHit = 0
    state.running = true
    state.rollInput = 0
    state.colInput = 0
    state.colInputTarget = 0
    state.colTargetAxis = state.phase
    state.cyclicAxisInput = 0
    state.lastMessage = "Long PAGE: preferences"
end

local function resolveSources(state)
    if not state.elevatorSource then
        state.elevatorSource = resolveAnalogSource(ELEVATOR_SOURCE_MEMBER)
    end
    if not state.collectiveSource then
        state.collectiveSource = resolveAnalogSource(COLLECTIVE_SOURCE_MEMBER)
    end
    if not state.rollSource then
        state.rollSource = resolveAnalogSource(ROLL_SOURCE_MEMBER)
    end
end

local function readInputs(state, dt)
    resolveSources(state)

    local eleRaw = normalizeStick(sourceValue(state.elevatorSource))
    local colRaw = normalizeStick(sourceValue(state.collectiveSource))
    local rollRaw = normalizeStick(sourceValue(state.rollSource))

    state.eleInput = applyDeadzone(eleRaw, ELEVATOR_DEADZONE)
    local colTarget = applyDeadzone(colRaw, COLLECTIVE_DEADZONE)
    state.colInputTarget = colTarget
    if (state.collectiveResponseScale or 0.70) >= 0.999 then
        state.colInput = colTarget
    else
        local prev = state.colInput or colTarget
        local responseRate = COLLECTIVE_RESPONSE_RATE_BASE * (state.collectiveResponseScale or 0.70)
        local maxDelta = responseRate * math.max(tonumber(dt) or 0, 0)
        local delta = colTarget - prev
        if math.abs(delta) <= maxDelta then
            state.colInput = colTarget
        else
            state.colInput = prev + ((delta > 0) and maxDelta or -maxDelta)
        end
    end
    state.rollInput = applyDeadzone(rollRaw, ROLL_DEADZONE)

    if state.axisMode == AXIS_MODE_AILERON then
        state.cyclicAxisInput = state.rollInput
    else
        state.cyclicAxisInput = state.eleInput
    end
end

local function checkHitForPhase(state)
    if state.hitThisBeat then
        return
    end

    local colMul, cycMul = orientationSigns(state.orientation)
    local colSign = state.phase * colMul
    local cycSign = state.phase * cycMul

    local cycOK = (cycSign == 1 and state.cyclicAxisInput > ELEVATOR_THRESHOLD) or (cycSign == -1 and state.cyclicAxisInput < -ELEVATOR_THRESHOLD)
    local colTargetForHit = state.colTargetAxis
    if type(colTargetForHit) ~= "number" then
        colTargetForHit = colSign
    end
    local colOK = (colTargetForHit >= 0 and state.colInput > COLLECTIVE_THRESHOLD) or (colTargetForHit < 0 and state.colInput < -COLLECTIVE_THRESHOLD)

    if not (cycOK and colOK) then
        return
    end

    local timing = state.phaseElapsed
    local added
    if timing <= HIT_WINDOW_GREAT then
        added = SCORE_GREAT
        state.lastMessage = "Great " .. phaseName(state.phase)
        playTone(1050, 45, 0)
    elseif timing <= HIT_WINDOW_GOOD then
        added = SCORE_GOOD
        state.lastMessage = "Good " .. phaseName(state.phase)
        playTone(820, 35, 0)
    else
        added = SCORE_LATE
        state.lastMessage = "Late " .. phaseName(state.phase)
        playTone(660, 30, 0)
    end

    state.hitThisBeat = true
    state.streak = state.streak + 1
    state.score = state.score + added + (state.streak * 4)
    state.beatsHit = state.beatsHit + 1

    if state.score > state.bestScore then
        setConfigValue(state, "bestScore", state.score)
    end
end

local function finishBeat(state)
    state.beatsTotal = state.beatsTotal + 1

    if not state.hitThisBeat then
        state.streak = 0
        state.score = math.max(0, state.score - SCORE_MISS_PENALTY)
        state.lastMessage = "Missed " .. phaseName(state.phase)
        playTone(340, 100, 0)
    end

    if state.beatsTotal > 0 and (state.beatsTotal % BEAT_ACCEL_EVERY == 0) then
        state.beatPeriod = math.max(state.beatPeriodMin, state.beatPeriod - state.beatAccelStep)
    end

    state.phase = -state.phase
    state.hitThisBeat = false
    state.phaseElapsed = 0
end

local function updateRun(state, dt)
    if not state.running then
        return
    end

    state.phaseElapsed = state.phaseElapsed + dt
    updateCollectiveTargetAxis(state, dt)
    checkHitForPhase(state)

    while state.phaseElapsed >= state.beatPeriod do
        state.phaseElapsed = state.phaseElapsed - state.beatPeriod
        finishBeat(state)
        updateCollectiveTargetAxis(state, dt)
        checkHitForPhase(state)
    end
end

local function drawAxisMeter(x, y, w, h, value, targetValue, label, zoneScale)
    setColor(50, 66, 94)
    lcd.drawFilledRectangle(x, y, w, h)

    local midY = y + math.floor(h * 0.5)
    setColor(108, 128, 160)
    lcd.drawLine(x + 2, midY, x + w - 2, midY)

    local scale = clamp(tonumber(zoneScale) or 0.16, 0.10, 0.40)
    local zoneH = math.max(8, math.floor(h * scale))
    local targetY = y + math.floor((1.0 - ((targetValue + 1.0) * 0.5)) * (h - 1))
    targetY = clamp(targetY, y + 1, y + h - 2)
    local zoneY = clamp(targetY - math.floor(zoneH * 0.5), y + 2, y + h - zoneH - 2)
    setColor(62, 146, 88)
    lcd.drawFilledRectangle(x + 2, zoneY, w - 4, zoneH)

    local markerY = y + math.floor((1.0 - ((value + 1.0) * 0.5)) * (h - 1))
    markerY = clamp(markerY, y + 1, y + h - 2)

    setColor(230, 238, 248)
    lcd.drawFilledRectangle(x + 2, markerY - 1, w - 4, 3)

    setColor(174, 190, 214)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(x, y - 15, label)
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
    lcd.drawText(14, 12, "TicToc Rhythm")

    setColor(164, 178, 202)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(16, 38, "Long PAGE: preferences")

    local phaseText = phaseName(state.phase)
    if state.phase == 1 then
        setColor(84, 222, 126)
    else
        setColor(246, 188, 86)
    end
    setFont(FONT_XL_BOLD or FONT_L_BOLD or FONT_STD)
    lcd.drawText(16, 66, phaseText)

    local progress = clamp(state.phaseElapsed / state.beatPeriod, 0, 1)
    local barX = 16
    local barY = 108
    local barW = clamp(math.floor(state.windowW * 0.46), 180, 360)
    local barH = 14

    setColor(52, 70, 98)
    lcd.drawFilledRectangle(barX, barY, barW, barH)
    setColor(104, 196, 236)
    lcd.drawFilledRectangle(barX, barY, math.floor(barW * progress + 0.5), barH)

    setColor(226, 236, 248)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(barX, barY - 16, string.format("Beat %.2fs", state.beatPeriod))

    local colMul, cycMul = orientationSigns(state.orientation)
    local colTargetSign = state.phase * colMul
    local cycTargetSign = state.phase * cycMul

    local meterTop = 144
    local meterH = clamp(state.windowH - meterTop - 44, 120, 220)
    local meterW = 68
    local collectiveX = 18
    local cyclicX = 102
    local colTargetDisplay = state.colTargetAxis or colTargetSign
    drawAxisMeter(collectiveX, meterTop, meterW, meterH, state.colInput, colTargetDisplay, "Collective", 0.24)
    drawAxisMeter(cyclicX, meterTop, meterW, meterH, state.cyclicAxisInput, cycTargetSign, "Cyclic Axis", 0.16)

    local infoRight = state.windowW - 14
    local infoY = 18
    local infoRow = 24

    local acc = 0
    if state.beatsTotal > 0 then
        acc = math.floor((state.beatsHit / state.beatsTotal) * 100 + 0.5)
    end

    setColor(236, 242, 252)
    drawRightText(infoRight, infoY + (infoRow * 0), "Score " .. tostring(state.score), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 1), "Best " .. tostring(state.bestScore), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 2), "Streak " .. tostring(state.streak), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 3), "Accuracy " .. tostring(acc) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 4), "Axis " .. axisModeName(state.axisMode), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 5), orientationName(state.orientation), FONT_XXS or FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 6), "Speed " .. speedName(state.speed), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 7), "Col/Cyc " .. collectiveRatioName(state.collectiveRatio), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 8), string.format("Roll %d%%", math.floor(state.rollInput * 100 + 0.5)), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 9), string.format("Elev %d%%", math.floor(state.eleInput * 100 + 0.5)), FONT_STD)

    setColor(164, 178, 202)
    drawRightText(infoRight, infoY + (infoRow * 10), state.lastMessage, FONT_XXS or FONT_STD)
    lcd.drawText(16, state.windowH - 20, "Enter: reset  |  Long PAGE: preferences  |  Exit: back")
end

local function createState()
    local loadedConfig = loadStateConfig()
    local state = {
        elevatorSource = resolveAnalogSource(ELEVATOR_SOURCE_MEMBER),
        collectiveSource = resolveAnalogSource(COLLECTIVE_SOURCE_MEMBER),
        rollSource = resolveAnalogSource(ROLL_SOURCE_MEMBER),
        eleInput = 0,
        colInput = 0,
        rollInput = 0,
        axisMode = loadedConfig.axisMode,
        orientation = loadedConfig.orientation,
        speed = loadedConfig.speed,
        collectiveRatio = loadedConfig.collectiveRatio,
        collectiveResponseScale = collectiveResponseScale(loadedConfig.collectiveRatio),
        cyclicAxisInput = 0,
        score = 0,
        bestScore = loadedConfig.bestScore,
        streak = 0,
        phase = 1,
        hitThisBeat = false,
        phaseElapsed = 0,
        beatPeriod = BEAT_PERIOD_START,
        beatPeriodStart = BEAT_PERIOD_START,
        beatPeriodMin = BEAT_PERIOD_MIN,
        beatAccelStep = BEAT_ACCEL_STEP,
        beatsTotal = 0,
        beatsHit = 0,
        running = true,
        lastMessage = "Long PAGE: preferences",
        lastFrameAt = 0,
        nextInvalidateAt = 0,
        lastFocusKick = 0,
        windowW = (type(LCD_W) == "number") and LCD_W or 784,
        windowH = (type(LCD_H) == "number") and LCD_H or 406,
        config = loadedConfig,
        settingsFormOpen = false,
        pendingFormClear = false,
        suppressExitUntil = 0,
        suppressEnterUntil = 0
    }

    refreshGeometry(state)
    applyCollectiveResponseProfile(state)
    resetRun(state)
    return state
end

function game.create()
    return createState()
end

function game.wakeup(state)
    if not state then
        return
    end

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
    if not state then
        return false
    end

    local now = nowSeconds()
    if state.suppressExitUntil and now < state.suppressExitUntil then
        if category == EVT_CLOSE then
            return true
        end
        if isExitKeyEvent(category, value) then
            return true
        end
    elseif state.suppressExitUntil and state.suppressExitUntil ~= 0 then
        state.suppressExitUntil = 0
    end

    if state.suppressEnterUntil and now < state.suppressEnterUntil then
        if isResetEvent(category, value) then
            return true
        end
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

    if category == EVT_CLOSE then
        return false
    end

    if isExitKeyEvent(category, value) then
        return false
    end

    if isSettingsOpenEvent(category, value) then
        local okOpen, opened = pcall(openSettingsForm, state)
        if okOpen and opened then
            return true
        end

        -- Fallback for radios/builds without form API support.
        if state.axisMode == AXIS_MODE_ELEVATOR then
            setConfigValue(state, "axisMode", AXIS_MODE_AILERON)
        else
            setConfigValue(state, "axisMode", AXIS_MODE_ELEVATOR)
        end
        state.lastMessage = "Mode set: " .. axisModeName(state.axisMode)
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
    if not state then
        return
    end

    flushPendingFormClear(state)
    if state.settingsFormOpen then
        return
    end

    local now = nowSeconds()
    if state.lastFrameAt <= 0 then
        state.lastFrameAt = now
    end

    local dt = now - state.lastFrameAt
    state.lastFrameAt = now
    if dt < 0 then
        dt = 0
    elseif dt > 0.2 then
        dt = 0.2
    end
    state.lastDt = dt

    readInputs(state, dt)
    updateRun(state, dt)

    drawHud(state)
end

function game.close(state)
    if type(state) ~= "table" then
        return
    end

    if state.settingsFormOpen then
        closeSettingsForm(state, false, false)
    else
        flushPendingFormClear(state)
    end

    state.running = false
    state.hitThisBeat = false

    if collectgarbage then
        pcall(collectgarbage, "collect")
        pcall(collectgarbage, "collect")
    end
end

return game
