local game = {}

local YAW_SOURCE_MEMBER = 0
local ROLL_SOURCE_MEMBER = 3
local PITCH_SOURCE_MEMBER = 1

local ACTIVE_RENDER_FPS = 40
local IDLE_RENDER_FPS = 14
local ACTIVE_INVALIDATE_DT = 1 / ACTIVE_RENDER_FPS
local IDLE_INVALIDATE_DT = 1 / IDLE_RENDER_FPS

local MAX_TARGET_RATE = 4.8
local MIN_TARGET_RATE = 0.8
local MAX_CURSOR_RATE = 2.6
local CURSOR_LIMIT = 1.15
local YAW_DEADZONE = 0.06
local CYCLIC_DEADZONE = 0.05
local YAW_INPUT_SIGN = -1
local PITCH_AXIS_SIGN = -1
local MIN_SCORING_RATE = 0.8
local TARGET_RADIUS_MIN = 0.25
local TARGET_RADIUS_MAX = 1.0
local TARGET_RADIUS_SWEEP_RATE_FAST = 0.85
local TARGET_RADIUS_SWEEP_RATE_SLOW = 0.35

local LOCK_WINDOW = 0.22
local GREAT_WINDOW = 0.10
local SCORE_LOCK_PER_S = 24
local SCORE_GREAT_PER_S = 42
local SCORE_MISS_PER_S = 10
local LOCK_DECAY_PER_S = 1.6
local COMBO_STEP_S = 1.0
local MAX_COMBO = 8

local CONFIG_FILE = "piroflip-chase.cfg"
local CONFIG_VERSION = 2
local CONFIG_SAVE_DEBOUNCE_S = 1.0
local CONFIG_BUTTON_CATEGORY = 0
local CONFIG_BUTTON_VALUE = 128

local RADIUS_MODE_FIXED_NARROW = 1
local RADIUS_MODE_FIXED_50 = 2
local RADIUS_MODE_FIXED_75 = 3
local RADIUS_MODE_FIXED_WIDE = 4
local RADIUS_MODE_SWEEP_FAST = 5
local RADIUS_MODE_SWEEP_SLOW = 6

local RADIUS_MODE_CHOICES_FORM = {
    {"Fixed 25%", RADIUS_MODE_FIXED_NARROW},
    {"Fixed 50%", RADIUS_MODE_FIXED_50},
    {"Fixed 75%", RADIUS_MODE_FIXED_75},
    {"Fixed 100%", RADIUS_MODE_FIXED_WIDE},
    {"Vary Fast", RADIUS_MODE_SWEEP_FAST},
    {"Vary Slow", RADIUS_MODE_SWEEP_SLOW}
}

local TUNE_FIELDS = {
    {id = "yawRateScale", label = "Yaw Rate", min = 0.6, max = 2.2, step = 0.1, fmt = "x%.1f"},
    {id = "yawExpo", label = "Yaw Expo", min = 0.6, max = 1.8, step = 0.1, fmt = "%.1f"},
    {id = "rollRateScale", label = "Roll Rate", min = 0.8, max = 3.0, step = 0.1, fmt = "x%.1f"},
    {id = "rollExpo", label = "Roll Expo", min = 0.6, max = 1.8, step = 0.1, fmt = "%.1f"},
    {id = "pitchRateScale", label = "Pitch Rate", min = 0.8, max = 3.0, step = 0.1, fmt = "x%.1f"},
    {id = "pitchExpo", label = "Pitch Expo", min = 0.6, max = 1.8, step = 0.1, fmt = "%.1f"},
    {id = "radiusMode", label = "Radius", min = RADIUS_MODE_FIXED_NARROW, max = RADIUS_MODE_SWEEP_SLOW, step = 1, isEnum = true}
}

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

local function isTuneIncreaseEvent(category, value)
    if not isKeyCategory(category) then
        return false
    end
    return keyMatches(value, KEY_PGUP_LONG)
end

local function isTuneDecreaseEvent(category, value)
    if not isKeyCategory(category) then
        return false
    end
    return keyMatches(value, KEY_PGDN_LONG)
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
    pcall(system.playTone, freq, duration or 30, pause or 0)
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

local function applyExpo(v, expo)
    local av = math.abs(v)
    if av <= 0 then
        return 0
    end
    local sign = (v < 0) and -1 or 1
    return sign * (av ^ expo)
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
        or math.abs(state.targetRate or 0) > 0.01
        or math.abs(state.rollInput or 0) > 0.01
        or math.abs(state.pitchInput or 0) > 0.01
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
    return {"SCRIPTS:/ethos-heli-training/games/piroflip-chase/" .. CONFIG_FILE}
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

local function normalizeRadiusMode(value, configVersion)
    local v = math.floor(tonumber(value) or RADIUS_MODE_SWEEP_FAST)

    local version = math.floor(tonumber(configVersion) or CONFIG_VERSION)
    if version < CONFIG_VERSION then
        if v == 1 then
            return RADIUS_MODE_FIXED_NARROW
        elseif v == 2 then
            return RADIUS_MODE_FIXED_WIDE
        elseif v == 3 then
            return RADIUS_MODE_SWEEP_FAST
        elseif v == 4 then
            return RADIUS_MODE_SWEEP_SLOW
        elseif v == 5 then
            return RADIUS_MODE_SWEEP_FAST
        end
    end

    return clamp(v, RADIUS_MODE_FIXED_NARROW, RADIUS_MODE_SWEEP_SLOW)
end

local function normalizeConfigNumber(value, defaultValue, minValue, maxValue)
    local v = tonumber(value)
    if not v then
        return defaultValue
    end
    return clamp(v, minValue, maxValue)
end

local function defaultConfig()
    return {
        bestScore = 0,
        yawRateScale = 1.0,
        yawExpo = 1.0,
        rollRateScale = 1.8,
        rollExpo = 1.0,
        pitchRateScale = 1.8,
        pitchExpo = 1.0,
        radiusMode = RADIUS_MODE_SWEEP_FAST
    }
end

local function loadStateConfig()
    local defaults = defaultConfig()
    local raw = readConfigTable()
    local version = math.floor(tonumber(raw.configVersion) or 1)

    return {
        bestScore = math.max(0, math.floor(tonumber(raw.bestScore) or defaults.bestScore)),
        yawRateScale = normalizeConfigNumber(raw.yawRateScale, defaults.yawRateScale, 0.6, 2.2),
        yawExpo = normalizeConfigNumber(raw.yawExpo, defaults.yawExpo, 0.6, 1.8),
        rollRateScale = normalizeConfigNumber(raw.rollRateScale, defaults.rollRateScale, 0.8, 3.0),
        rollExpo = normalizeConfigNumber(raw.rollExpo, defaults.rollExpo, 0.6, 1.8),
        pitchRateScale = normalizeConfigNumber(raw.pitchRateScale, defaults.pitchRateScale, 0.8, 3.0),
        pitchExpo = normalizeConfigNumber(raw.pitchExpo, defaults.pitchExpo, 0.6, 1.8),
        radiusMode = normalizeRadiusMode(raw.radiusMode, version)
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
    f:write("yawRateScale=", string.format("%.1f", cfg.yawRateScale), "\n")
    f:write("yawExpo=", string.format("%.1f", cfg.yawExpo), "\n")
    f:write("rollRateScale=", string.format("%.1f", cfg.rollRateScale), "\n")
    f:write("rollExpo=", string.format("%.1f", cfg.rollExpo), "\n")
    f:write("pitchRateScale=", string.format("%.1f", cfg.pitchRateScale), "\n")
    f:write("pitchExpo=", string.format("%.1f", cfg.pitchExpo), "\n")
    f:write("radiusMode=", normalizeRadiusMode(cfg.radiusMode), "\n")
    pcall(f.close, f)
    return true
end

local function queueConfigSave(state, immediate)
    if not state then
        return
    end
    state.configDirty = true
    local due = nowSeconds() + (immediate and 0 or CONFIG_SAVE_DEBOUNCE_S)
    if not state.configSaveDueAt or state.configSaveDueAt <= 0 or due < state.configSaveDueAt then
        state.configSaveDueAt = due
    end
end

local function flushConfigSave(state, force)
    if not (state and state.configDirty) then
        return true
    end

    local now = nowSeconds()
    if (not force) and state.configSaveDueAt and now < state.configSaveDueAt then
        return false
    end

    if saveStateConfig(state) then
        state.configDirty = false
        state.configSaveDueAt = 0
        return true
    end

    state.configSaveDueAt = now + 2.0
    return false
end

local function radiusModeLabel(mode)
    mode = normalizeRadiusMode(mode)
    if mode == RADIUS_MODE_FIXED_NARROW then
        return "Fixed 25%"
    elseif mode == RADIUS_MODE_FIXED_50 then
        return "Fixed 50%"
    elseif mode == RADIUS_MODE_FIXED_75 then
        return "Fixed 75%"
    elseif mode == RADIUS_MODE_FIXED_WIDE then
        return "Fixed 100%"
    elseif mode == RADIUS_MODE_SWEEP_FAST then
        return "Vary Fast"
    elseif mode == RADIUS_MODE_SWEEP_SLOW then
        return "Vary Slow"
    end
    return "Vary Fast"
end

local function tuneValueText(state, field)
    if not (state and state.config and field) then
        return ""
    end
    local value = state.config[field.id]
    if field.isEnum then
        return radiusModeLabel(value)
    end
    return string.format(field.fmt or "%.1f", value)
end

local function roundToStep(value, step)
    step = tonumber(step) or 1
    if step <= 0 then
        return value
    end
    return math.floor((value / step) + 0.5) * step
end

local function setConfigValue(state, key, value, skipSave)
    if not (state and state.config) then
        return
    end

    local cfg = state.config
    if key == "bestScore" then
        local best = math.max(0, math.floor(tonumber(value) or 0))
        state.bestScore = best
        cfg.bestScore = best
    elseif key == "yawRateScale" then
        cfg.yawRateScale = clamp(roundToStep(tonumber(value) or cfg.yawRateScale, 0.1), 0.6, 2.2)
    elseif key == "yawExpo" then
        cfg.yawExpo = clamp(roundToStep(tonumber(value) or cfg.yawExpo, 0.1), 0.6, 1.8)
    elseif key == "rollRateScale" then
        cfg.rollRateScale = clamp(roundToStep(tonumber(value) or cfg.rollRateScale, 0.1), 0.8, 3.0)
    elseif key == "rollExpo" then
        cfg.rollExpo = clamp(roundToStep(tonumber(value) or cfg.rollExpo, 0.1), 0.6, 1.8)
    elseif key == "pitchRateScale" then
        cfg.pitchRateScale = clamp(roundToStep(tonumber(value) or cfg.pitchRateScale, 0.1), 0.8, 3.0)
    elseif key == "pitchExpo" then
        cfg.pitchExpo = clamp(roundToStep(tonumber(value) or cfg.pitchExpo, 0.1), 0.6, 1.8)
    elseif key == "radiusMode" then
        cfg.radiusMode = normalizeRadiusMode(value)
        state.targetRadiusPhase = 0
    else
        return
    end

    cfg.bestScore = state.bestScore
    if not skipSave then
        queueConfigSave(state, true)
    end
end

local function buildNumberChoices(minValue, maxValue, step, fmt)
    local choices = {}
    local values = {}
    local idx = 1
    local value = minValue
    while value <= (maxValue + 0.0001) do
        local rounded = roundToStep(value, step)
        choices[idx] = {string.format(fmt or "%.1f", rounded), idx}
        values[idx] = rounded
        idx = idx + 1
        value = value + step
    end
    return choices, values
end

local function closestChoiceIndex(currentValue, values)
    local bestIndex = 1
    local bestErr = math.huge
    for i = 1, #values do
        local candidate = values[i]
        local err = math.abs((tonumber(currentValue) or 0) - candidate)
        if err < bestErr then
            bestErr = err
            bestIndex = i
        end
    end
    return bestIndex
end

local function addNumericChoiceField(state, label, key, minValue, maxValue, step, fmt)
    local line = form.addLine(label)
    local choices, values = buildNumberChoices(minValue, maxValue, step, fmt)
    form.addChoiceField(
        line,
        nil,
        choices,
        function()
            return closestChoiceIndex(state.config[key], values)
        end,
        function(newIndex)
            local index = clamp(math.floor(tonumber(newIndex) or 1), 1, #values)
            setConfigValue(state, key, values[index])
            forceInvalidate(state)
        end
    )
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

    local infoLine = form.addLine("Piroflip Chase")
    if form.addStaticText then
        form.addStaticText(infoLine, nil, "Settings (Exit/Back to return)")
    end

    addNumericChoiceField(state, "Yaw rate", "yawRateScale", 0.6, 2.2, 0.1, "x%.1f")
    addNumericChoiceField(state, "Yaw expo", "yawExpo", 0.6, 1.8, 0.1, "%.1f")
    addNumericChoiceField(state, "Roll rate", "rollRateScale", 0.8, 3.0, 0.1, "x%.1f")
    addNumericChoiceField(state, "Roll expo", "rollExpo", 0.6, 1.8, 0.1, "%.1f")
    addNumericChoiceField(state, "Pitch rate", "pitchRateScale", 0.8, 3.0, 0.1, "x%.1f")
    addNumericChoiceField(state, "Pitch expo", "pitchExpo", 0.6, 1.8, 0.1, "%.1f")

    local radiusLine = form.addLine("Target radius")
    form.addChoiceField(
        radiusLine,
        nil,
        RADIUS_MODE_CHOICES_FORM,
        function()
            return normalizeRadiusMode(state.config.radiusMode)
        end,
        function(newValue)
            setConfigValue(state, "radiusMode", newValue)
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

local function adjustFallbackTune(state, direction)
    local field = TUNE_FIELDS[state.tuneIndex]
    if not field then
        return
    end

    local current = state.config[field.id]
    local nextValue
    if field.isEnum then
        nextValue = clamp(math.floor((tonumber(current) or field.min) + (direction * field.step)), field.min, field.max)
    else
        nextValue = clamp(roundToStep((tonumber(current) or field.min) + (direction * field.step), field.step), field.min, field.max)
    end

    setConfigValue(state, field.id, nextValue)
    state.lastMessage = string.format("Tune %s %s", field.label, tuneValueText(state, field))
end

local function nextFallbackTuneField(state)
    state.tuneIndex = (state.tuneIndex % #TUNE_FIELDS) + 1
    local field = TUNE_FIELDS[state.tuneIndex]
    if field then
        state.lastMessage = string.format("Tune %s %s", field.label, tuneValueText(state, field))
    end
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

local function resolveSources(state)
    if not state.yawSource then
        state.yawSource = resolveAnalogSource(YAW_SOURCE_MEMBER)
    end
    if not state.rollSource then
        state.rollSource = resolveAnalogSource(ROLL_SOURCE_MEMBER)
    end
    if not state.pitchSource then
        state.pitchSource = resolveAnalogSource(PITCH_SOURCE_MEMBER)
    end
end

local function setInitialRadius(state)
    local mode = normalizeRadiusMode(state.config.radiusMode)
    if mode == RADIUS_MODE_FIXED_NARROW then
        state.targetRadiusNorm = TARGET_RADIUS_MIN
    elseif mode == RADIUS_MODE_FIXED_50 then
        state.targetRadiusNorm = 0.50
    elseif mode == RADIUS_MODE_FIXED_75 then
        state.targetRadiusNorm = 0.75
    elseif mode == RADIUS_MODE_FIXED_WIDE then
        state.targetRadiusNorm = TARGET_RADIUS_MAX
    else
        state.targetRadiusNorm = (TARGET_RADIUS_MIN + TARGET_RADIUS_MAX) * 0.5
    end
end

local function resetSession(state)
    state.targetAngle = 0
    state.targetRadiusPhase = 0
    setInitialRadius(state)
    state.targetX = state.targetRadiusNorm
    state.targetY = 0
    state.chaserX = 0
    state.chaserY = 0
    state.targetRate = 0
    state.score = 0
    state.combo = 1
    state.lockTime = 0
    state.locked = false
    state.greatLock = false
    state.sessionTime = 0
    state.targetTravel = 0
    state.lastMessage = "Add yaw, then chase with roll/pitch"
    state.lastError = 1.0
end

local function updateTargetRadius(state, dt)
    local mode = normalizeRadiusMode(state.config.radiusMode)
    if mode == RADIUS_MODE_FIXED_NARROW then
        state.targetRadiusNorm = TARGET_RADIUS_MIN
        return
    end
    if mode == RADIUS_MODE_FIXED_50 then
        state.targetRadiusNorm = 0.50
        return
    end
    if mode == RADIUS_MODE_FIXED_75 then
        state.targetRadiusNorm = 0.75
        return
    end
    if mode == RADIUS_MODE_FIXED_WIDE then
        state.targetRadiusNorm = TARGET_RADIUS_MAX
        return
    end
    if mode == RADIUS_MODE_SWEEP_FAST or mode == RADIUS_MODE_SWEEP_SLOW then
        local sweepRate = (mode == RADIUS_MODE_SWEEP_FAST) and TARGET_RADIUS_SWEEP_RATE_FAST or TARGET_RADIUS_SWEEP_RATE_SLOW
        state.targetRadiusPhase = normalizeAngle(state.targetRadiusPhase + sweepRate * dt)
        state.targetRadiusNorm = TARGET_RADIUS_MIN + (TARGET_RADIUS_MAX - TARGET_RADIUS_MIN) * (0.5 + 0.5 * math.sin(state.targetRadiusPhase))
        return
    end
    state.targetRadiusNorm = (TARGET_RADIUS_MIN + TARGET_RADIUS_MAX) * 0.5
end

local function updateInputAndMotion(state, dt)
    resolveSources(state)

    local yawNorm = normalizeStick(sourceValue(state.yawSource))
    local rollNorm = normalizeStick(sourceValue(state.rollSource))
    local pitchNorm = normalizeStick(sourceValue(state.pitchSource))

    state.yawInput = applyDeadzone(yawNorm, YAW_DEADZONE) * YAW_INPUT_SIGN
    state.rollInput = applyDeadzone(rollNorm, CYCLIC_DEADZONE)
    state.pitchInput = applyDeadzone(pitchNorm, CYCLIC_DEADZONE) * PITCH_AXIS_SIGN

    local yawCmd = applyExpo(state.yawInput, state.config.yawExpo)
    local absYaw = math.abs(yawCmd)
    if absYaw > 0 then
        local direction = (yawCmd < 0) and -1 or 1
        local maxRate = math.max(MIN_TARGET_RATE, MAX_TARGET_RATE * state.config.yawRateScale)
        local rate = MIN_TARGET_RATE + absYaw * (maxRate - MIN_TARGET_RATE)
        state.targetRate = direction * rate
    else
        state.targetRate = 0
    end

    state.targetAngle = normalizeAngle(state.targetAngle + state.targetRate * dt)
    updateTargetRadius(state, dt)
    state.targetX = math.cos(state.targetAngle) * state.targetRadiusNorm
    state.targetY = math.sin(state.targetAngle) * state.targetRadiusNorm

    local rollCmd = applyExpo(state.rollInput, state.config.rollExpo) * state.config.rollRateScale
    local pitchCmd = applyExpo(state.pitchInput, state.config.pitchExpo) * state.config.pitchRateScale

    state.chaserX = clamp(state.chaserX + rollCmd * MAX_CURSOR_RATE * dt, -CURSOR_LIMIT, CURSOR_LIMIT)
    state.chaserY = clamp(state.chaserY + pitchCmd * MAX_CURSOR_RATE * dt, -CURSOR_LIMIT, CURSOR_LIMIT)

    state.targetTravel = state.targetTravel + math.abs(state.targetRate) * dt
    state.sessionTime = state.sessionTime + dt
end

local function updateScoring(state, dt)
    local dx = state.targetX - state.chaserX
    local dy = state.targetY - state.chaserY
    local errDist = math.sqrt(dx * dx + dy * dy)
    state.lastError = errDist

    local scoringActive = math.abs(state.targetRate) >= MIN_SCORING_RATE

    if scoringActive and errDist <= LOCK_WINDOW then
        state.locked = true
        state.greatLock = errDist <= GREAT_WINDOW
        state.lockTime = state.lockTime + dt

        local comboSteps = math.floor(state.lockTime / COMBO_STEP_S)
        state.combo = 1 + clamp(comboSteps, 0, MAX_COMBO - 1)

        local perSecond = state.greatLock and SCORE_GREAT_PER_S or SCORE_LOCK_PER_S
        state.score = state.score + perSecond * state.combo * dt
        state.lastMessage = state.greatLock and "Great lock" or "Lock maintained"
    else
        state.locked = false
        state.greatLock = false

        state.lockTime = math.max(0, state.lockTime - LOCK_DECAY_PER_S * dt)
        local comboSteps = math.floor(state.lockTime / COMBO_STEP_S)
        state.combo = 1 + clamp(comboSteps, 0, MAX_COMBO - 1)

        if scoringActive and errDist > LOCK_WINDOW then
            state.score = math.max(0, state.score - SCORE_MISS_PER_S * dt)
            state.lastMessage = "Chase target with roll/pitch"
        elseif not scoringActive then
            state.lastMessage = "Increase yaw to spin target"
        end
    end

    local scoreRounded = math.floor(state.score + 0.5)
    if scoreRounded > state.bestScore then
        state.bestScore = scoreRounded
        state.config.bestScore = scoreRounded
        queueConfigSave(state, false)
    end
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
    lcd.drawText(14, 12, "Piroflip Chase")

    setColor(170, 184, 208)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(16, 38, "Yaw spins target. Roll+Pitch chase. Long PAGE: settings")

    local infoRight = state.windowW - 14
    local infoY = 18
    local infoRow = 22
    local smallTextYOffset = 8

    local turns = math.floor(state.targetTravel / (2 * math.pi))
    local yawPct = math.floor(state.yawInput * 100)
    local rollPct = math.floor(state.rollInput * 100)
    local pitchPct = math.floor(state.pitchInput * 100)
    local targetDeg = math.floor((state.targetRate * 57.2958) + 0.5)
    local radiusPct = math.floor(state.targetRadiusNorm * 100 + 0.5)

    setColor(236, 242, 252)
    drawRightText(infoRight, infoY + (infoRow * 0), "Score " .. tostring(math.floor(state.score + 0.5)), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 1), "Best " .. tostring(state.bestScore), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 2), "Combo x" .. tostring(state.combo), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 3), "Turns " .. tostring(turns), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 4), "Yaw " .. tostring(yawPct) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 5), "Roll " .. tostring(rollPct) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 6), "Pitch " .. tostring(pitchPct) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 7), "Target " .. tostring(targetDeg) .. " deg/s", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 8), "Radius " .. tostring(radiusPct) .. "%", FONT_STD)

    setColor(186, 202, 222)
    drawRightText(
        infoRight,
        infoY + (infoRow * 9) + smallTextYOffset,
        string.format(
            "R/E Y %.1f/%.1f  R %.1f/%.1f  P %.1f/%.1f",
            state.config.yawRateScale, state.config.yawExpo,
            state.config.rollRateScale, state.config.rollExpo,
            state.config.pitchRateScale, state.config.pitchExpo
        ),
        FONT_XXS or FONT_STD
    )
    drawRightText(
        infoRight,
        infoY + (infoRow * 10) + smallTextYOffset,
        "Radius mode: " .. radiusModeLabel(state.config.radiusMode),
        FONT_XXS or FONT_STD
    )

    setColor(152, 170, 194)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(16, state.windowH - 40, state.lastMessage)
    lcd.drawText(16, state.windowH - 20, "Enter: reset  |  Long PAGE: settings  |  Exit: back")
end

local function drawArena(state)
    local topPad = 50
    local bottomPad = 34
    local sidePad = 26
    local cx = math.floor(state.windowW * 0.5)
    local cy = math.floor((topPad + (state.windowH - bottomPad)) * 0.5)

    local maxRadiusX = math.min(cx - sidePad, state.windowW - sidePad - cx)
    local maxRadiusY = math.min(cy - topPad, (state.windowH - bottomPad) - cy)
    local radius = clamp(math.floor(math.min(maxRadiusX, maxRadiusY)), 92, 190)

    setColor(52, 70, 96)
    if lcd and lcd.drawCircle then
        lcd.drawCircle(cx, cy, radius)
        lcd.drawCircle(cx, cy, math.max(6, math.floor(radius * TARGET_RADIUS_MIN + 0.5)))
        lcd.drawCircle(cx, cy, math.max(6, math.floor(radius * TARGET_RADIUS_MAX + 0.5)))
        setColor(88, 112, 144)
        lcd.drawCircle(cx, cy, math.max(6, math.floor(radius * state.targetRadiusNorm + 0.5)))
    end

    setColor(78, 98, 126)
    lcd.drawLine(cx - radius - 8, cy, cx + radius + 8, cy)
    lcd.drawLine(cx, cy - radius - 8, cx, cy + radius + 8)

    local tx = math.floor(cx + state.targetX * radius + 0.5)
    local ty = math.floor(cy + state.targetY * radius + 0.5)
    local px = math.floor(cx + state.chaserX * radius + 0.5)
    local py = math.floor(cy + state.chaserY * radius + 0.5)
    local marker = clamp(math.floor(radius * 0.055), 4, 9)

    setColor(218, 86, 86)
    lcd.drawFilledRectangle(tx - marker, ty - marker, marker * 2 + 1, marker * 2 + 1)

    if state.locked then
        setColor(82, 226, 118)
    else
        setColor(96, 160, 232)
    end
    lcd.drawFilledRectangle(px - marker, py - marker, marker * 2 + 1, marker * 2 + 1)

    setColor(120, 140, 168)
    lcd.drawLine(px, py, tx, ty)

    local errNorm = clamp(state.lastError / LOCK_WINDOW, 0, 1)
    local meterW = 12
    local meterTopMin = topPad + 18
    local meterBottomLimit = state.windowH - 56
    local meterHMax = math.max(72, meterBottomLimit - meterTopMin)
    local desiredMeterH = math.max(72, (radius * 2) - 18)
    local meterH = clamp(desiredMeterH, 72, meterHMax)
    local meterX = 14
    local meterY = clamp(
        cy - math.floor(meterH * 0.5) + 8,
        meterTopMin,
        math.max(meterTopMin, meterBottomLimit - meterH)
    )

    setColor(56, 74, 102)
    lcd.drawFilledRectangle(meterX, meterY, meterW, meterH)

    local goodH = math.floor(meterH * (1.0 - errNorm) + 0.5)
    if state.greatLock then
        setColor(72, 214, 112)
    elseif state.locked then
        setColor(182, 214, 88)
    else
        setColor(212, 124, 84)
    end
    lcd.drawFilledRectangle(meterX, meterY + meterH - goodH, meterW, goodH)

    if lcd and lcd.drawRectangle then
        setColor(108, 126, 156)
        lcd.drawRectangle(meterX, meterY, meterW, meterH)
    end

    setColor(224, 232, 244)
    setFont(FONT_XXS or FONT_STD)
    local lockLabelY = clamp(meterY - 14, topPad + 4, meterY - 2)
    lcd.drawText(meterX - 2, lockLabelY, "Lock")
end

local function createState()
    local loadedConfig = loadStateConfig()
    local state = {
        yawSource = resolveAnalogSource(YAW_SOURCE_MEMBER),
        rollSource = resolveAnalogSource(ROLL_SOURCE_MEMBER),
        pitchSource = resolveAnalogSource(PITCH_SOURCE_MEMBER),
        yawInput = 0,
        rollInput = 0,
        pitchInput = 0,
        targetAngle = 0,
        targetRadiusPhase = 0,
        targetRadiusNorm = (TARGET_RADIUS_MIN + TARGET_RADIUS_MAX) * 0.5,
        targetX = (TARGET_RADIUS_MIN + TARGET_RADIUS_MAX) * 0.5,
        targetY = 0,
        chaserX = 0,
        chaserY = 0,
        targetRate = 0,
        score = 0,
        bestScore = loadedConfig.bestScore,
        combo = 1,
        lockTime = 0,
        locked = false,
        greatLock = false,
        sessionTime = 0,
        targetTravel = 0,
        lastMessage = "Add yaw, then chase with roll/pitch",
        lastError = 1.0,
        lastFrameAt = 0,
        nextInvalidateAt = 0,
        lastFocusKick = 0,
        windowW = (type(LCD_W) == "number") and LCD_W or 784,
        windowH = (type(LCD_H) == "number") and LCD_H or 406,
        config = loadedConfig,
        configDirty = false,
        configSaveDueAt = 0,
        tuneIndex = 1,
        settingsFormOpen = false,
        pendingFormClear = false,
        suppressExitUntil = 0,
        suppressEnterUntil = 0
    }

    refreshGeometry(state)
    resetSession(state)
    return state
end

function game.create()
    math.randomseed(os.time())
    return createState()
end

function game.wakeup(state)
    if not state then
        return
    end

    flushPendingFormClear(state)
    refreshGeometry(state)
    resolveSources(state)
    flushConfigSave(state, false)

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

    if isSettingsOpenEvent(category, value) then
        local okOpen, opened = pcall(openSettingsForm, state)
        if okOpen and opened then
            return true
        end
        if not okOpen then
            state.lastMessage = "Settings form unavailable; using fallback tuning"
        end
        nextFallbackTuneField(state)
        playTone(760, 30, 0)
        return true
    end

    if isTuneIncreaseEvent(category, value) then
        adjustFallbackTune(state, 1)
        playTone(820, 25, 0)
        return true
    end

    if isTuneDecreaseEvent(category, value) then
        adjustFallbackTune(state, -1)
        playTone(620, 25, 0)
        return true
    end

    if isExitKeyEvent(category, value) then
        return false
    end

    if isResetEvent(category, value) then
        resetSession(state)
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

    updateInputAndMotion(state, dt)
    updateScoring(state, dt)

    drawHud(state)
    drawArena(state)
    flushConfigSave(state, false)
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

    state.targetRate = 0
    state.locked = false
    flushConfigSave(state, true)

    if collectgarbage then
        pcall(collectgarbage, "collect")
        pcall(collectgarbage, "collect")
    end
end

return game
