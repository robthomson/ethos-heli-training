local game = {}

local YAW_SOURCE_MEMBER = 0
local ROLL_SOURCE_MEMBER = 3
local PITCH_SOURCE_MEMBER = 1

local ACTIVE_RENDER_FPS = 40
local IDLE_RENDER_FPS = 14
local ACTIVE_INVALIDATE_DT = 1 / ACTIVE_RENDER_FPS
local IDLE_INVALIDATE_DT = 1 / IDLE_RENDER_FPS

local YAW_DEADZONE = 0.05
local CYCLIC_DEADZONE = 0.04
local TARGET_RATE_MAX = 1.0

local COMMAND_INTERVAL_START = 2.9
local COMMAND_INTERVAL_MIN = 1.5
local COMMAND_ACCEL_STEP = 0.08
local COMMAND_ACCEL_EVERY = 6

local RATE_LOCK_WINDOW = 0.14
local RATE_GREAT_WINDOW = 0.07
local CYCLIC_LOCK_WINDOW = 0.22
local CYCLIC_GREAT_WINDOW = 0.11

local SCORE_LOCK_PER_S = 24
local SCORE_GREAT_PER_S = 44
local SCORE_DRIFT_PER_S = 11
local CYCLIC_DRIFT_PER_S = 26
local COMBO_STEP_S = 1.0
local COMBO_MAX = 8

local CONFIG_FILE = "piro-rate-lock.cfg"
local CONFIG_VERSION = 3
local CONFIG_BUTTON_CATEGORY = 0
local CONFIG_BUTTON_VALUE = 128
local BEST_SCORE_SAVE_DEBOUNCE_S = 1.0

local PACE_SLOW = 1
local PACE_NORMAL = 2
local PACE_FAST = 3

local STRICTNESS_RELAXED = 1
local STRICTNESS_NORMAL = 2
local STRICTNESS_HARD = 3

local PACE_CHOICES_FORM = {
    {"Slow", PACE_SLOW},
    {"Normal", PACE_NORMAL},
    {"Fast", PACE_FAST}
}

local STRICTNESS_CHOICES_FORM = {
    {"Relaxed", STRICTNESS_RELAXED},
    {"Normal", STRICTNESS_NORMAL},
    {"Hard", STRICTNESS_HARD}
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
    if not (state and lcd and lcd.invalidate) then return end
    local now = nowSeconds()
    local active = state.settingsFormOpen
        or math.abs(state.targetRateCmd or 0) > 0.01
        or math.abs(state.playerRate or 0) > 0.01
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

local function normalizeAngle(angle)
    while angle > math.pi do angle = angle - (2 * math.pi) end
    while angle < -math.pi do angle = angle + (2 * math.pi) end
    return angle
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

local function configPathCandidates()
    return {"SCRIPTS:/ethos-heli-training/games/piro-rate-lock/" .. CONFIG_FILE}
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

local applyConfigProfiles

local function normalizePace(value)
    local v = math.floor(tonumber(value) or PACE_NORMAL)
    if v == PACE_SLOW then
        return PACE_SLOW
    elseif v == PACE_FAST then
        return PACE_FAST
    end
    return PACE_NORMAL
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

local function paceName(value)
    local v = normalizePace(value)
    if v == PACE_SLOW then
        return "Slow"
    elseif v == PACE_FAST then
        return "Fast"
    end
    return "Normal"
end

local function strictnessName(value)
    local v = normalizeStrictness(value)
    if v == STRICTNESS_RELAXED then
        return "Relaxed"
    elseif v == STRICTNESS_HARD then
        return "Hard"
    end
    return "Normal"
end

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
    f:write("pace=", normalizePace(state.pace), "\n")
    f:write("strictness=", normalizeStrictness(state.strictness), "\n")
    pcall(f.close, f)
    return true
end

local function loadStateConfig()
    local raw = readConfigTable()
    return {
        bestScore = math.max(0, math.floor(tonumber(raw.bestScore) or 0)),
        pace = normalizePace(raw.pace),
        strictness = normalizeStrictness(raw.strictness)
    }
end

local function queueBestScoreSave(state, bestScore)
    if not state then return end
    state.pendingBestScore = math.max(0, math.floor(tonumber(bestScore) or 0))
    state.bestScoreSaveDueAt = nowSeconds() + BEST_SCORE_SAVE_DEBOUNCE_S
end

local function flushBestScoreSave(state, force)
    if not state or state.pendingBestScore == nil then
        return true
    end

    if (not force) and state.bestScoreSaveDueAt and nowSeconds() < state.bestScoreSaveDueAt then
        return false
    end

    local prevBest = state.bestScore
    state.bestScore = state.pendingBestScore
    local ok = saveStateConfig(state)
    if ok then
        state.pendingBestScore = nil
        state.bestScoreSaveDueAt = 0
        return true
    end

    state.bestScore = prevBest
    state.bestScoreSaveDueAt = nowSeconds() + 2.0
    return false
end

applyConfigProfiles = function(state, keepCurrentCommandInterval)
    if not state then return end

    local pace = normalizePace(state.pace)
    local strictness = normalizeStrictness(state.strictness)
    state.pace = pace
    state.strictness = strictness

    local paceScale = 1.0
    if pace == PACE_SLOW then
        paceScale = 1.20
    elseif pace == PACE_FAST then
        paceScale = 0.82
    end

    state.commandIntervalStart = COMMAND_INTERVAL_START * paceScale
    state.commandIntervalMin = COMMAND_INTERVAL_MIN * paceScale
    state.commandAccelStep = COMMAND_ACCEL_STEP * paceScale

    local strictScale = 1.0
    if strictness == STRICTNESS_RELAXED then
        strictScale = 1.18
    elseif strictness == STRICTNESS_HARD then
        strictScale = 0.84
    end

    state.rateLockWindow = RATE_LOCK_WINDOW * strictScale
    state.rateGreatWindow = RATE_GREAT_WINDOW * strictScale
    state.cyclicLockWindow = CYCLIC_LOCK_WINDOW * strictScale
    state.cyclicGreatWindow = CYCLIC_GREAT_WINDOW * strictScale

    if keepCurrentCommandInterval then
        state.commandInterval = clamp(
            state.commandInterval or state.commandIntervalStart,
            state.commandIntervalMin,
            state.commandIntervalStart
        )
    else
        state.commandInterval = state.commandIntervalStart
    end
end

local function setConfigValue(state, key, value, skipSave)
    if not state then return end

    if key == "pace" then
        state.pace = normalizePace(value)
        applyConfigProfiles(state, true)
        state.lastMessage = "Pace: " .. paceName(state.pace)
    elseif key == "strictness" then
        state.strictness = normalizeStrictness(value)
        applyConfigProfiles(state, true)
        state.lastMessage = "Strictness: " .. strictnessName(state.strictness)
    elseif key == "bestScore" then
        state.bestScore = math.max(0, math.floor(tonumber(value) or 0))
    else
        return
    end

    if not skipSave then
        saveStateConfig(state)
    end
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

    local infoLine = form.addLine("Piro Rate Lock")
    if form.addStaticText then
        form.addStaticText(infoLine, nil, "Settings (Exit/Back to return)")
    end

    local paceLine = form.addLine("Command pace")
    form.addChoiceField(
        paceLine,
        nil,
        PACE_CHOICES_FORM,
        function()
            return normalizePace(state.pace)
        end,
        function(newValue)
            setConfigValue(state, "pace", newValue)
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

    local bestLine = form.addLine("Best score")
    if form.addStaticText then
        form.addStaticText(bestLine, nil, tostring(state.bestScore))
    end

    local resetBest = function()
        setConfigValue(state, "bestScore", 0)
        queueBestScoreSave(state, state.bestScore)
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

local function randomTargetRate()
    local sign = (math.random() < 0.5) and -1 or 1
    local magnitude = 0.30 + math.random() * 0.70
    return sign * magnitude * TARGET_RATE_MAX
end

local function resetRun(state)
    state.score = 0
    state.combo = 1
    state.lockTime = 0
    state.commandElapsed = 0
    state.commandInterval = state.commandIntervalStart or COMMAND_INTERVAL_START
    state.commandsIssued = 0
    state.targetRateCmd = randomTargetRate()
    state.playerRate = 0
    state.cyclicMag = 0
    state.lastMessage = "Match target piro rate"
    state.locked = false
    state.greatLock = false
    state.rateError = 1
    state.cyclicPenaltyNorm = 0
    state.cyclicYawTrackNorm = 0
    state.targetAngle = 0
    state.playerAngle = 0
end

local function resolveSources(state)
    if not state.yawSource then state.yawSource = resolveAnalogSource(YAW_SOURCE_MEMBER) end
    if not state.rollSource then state.rollSource = resolveAnalogSource(ROLL_SOURCE_MEMBER) end
    if not state.pitchSource then state.pitchSource = resolveAnalogSource(PITCH_SOURCE_MEMBER) end
end

local function readInputs(state)
    resolveSources(state)
    state.yawInput = applyDeadzone(normalizeStick(sourceValue(state.yawSource)), YAW_DEADZONE)
    state.rollInput = applyDeadzone(normalizeStick(sourceValue(state.rollSource)), CYCLIC_DEADZONE)
    state.pitchInput = applyDeadzone(normalizeStick(sourceValue(state.pitchSource)), CYCLIC_DEADZONE)

    state.playerRate = state.yawInput * TARGET_RATE_MAX
    state.cyclicMag = math.sqrt(state.rollInput * state.rollInput + state.pitchInput * state.pitchInput)
end

local function updateCommand(state, dt)
    state.commandElapsed = state.commandElapsed + dt
    if state.commandElapsed >= state.commandInterval then
        state.commandElapsed = state.commandElapsed - state.commandInterval
        state.commandsIssued = state.commandsIssued + 1
        state.targetRateCmd = randomTargetRate()

        if state.commandsIssued > 0 and (state.commandsIssued % COMMAND_ACCEL_EVERY == 0) then
            state.commandInterval = math.max(state.commandIntervalMin, state.commandInterval - state.commandAccelStep)
        end

        playTone(700, 45, 0)
    end
end

local function updateVisualRotation(state, dt)
    local spinScale = 2 * math.pi
    state.targetAngle = normalizeAngle(state.targetAngle + (state.targetRateCmd * spinScale * dt))
    state.playerAngle = normalizeAngle(state.playerAngle + (state.playerRate * spinScale * dt))
end

local function updateScoring(state, dt)
    local err = math.abs(state.targetRateCmd - state.playerRate)
    state.rateError = err

    local rateGood = err <= state.rateLockWindow
    local rateGreat = err <= state.rateGreatWindow
    local cyclicGood = state.cyclicMag <= state.cyclicLockWindow
    local cyclicGreat = state.cyclicMag <= state.cyclicGreatWindow
    local cyclicPenaltyNorm = clamp((state.cyclicMag - state.cyclicLockWindow) / (1.0 - state.cyclicLockWindow), 0, 1)
    state.cyclicPenaltyNorm = cyclicPenaltyNorm

    local rateTrackNorm = clamp(1.0 - (err / state.rateLockWindow), 0, 1)
    local cyclicTrackNorm = clamp(1.0 - (state.cyclicMag / state.cyclicLockWindow), 0, 1)
    state.cyclicYawTrackNorm = clamp((rateTrackNorm * 0.65) + (cyclicTrackNorm * 0.35), 0, 1)

    if rateGood and cyclicGood then
        state.locked = true
        state.greatLock = rateGreat and cyclicGreat
        state.lockTime = state.lockTime + dt
        local comboSteps = math.floor(state.lockTime / COMBO_STEP_S)
        state.combo = 1 + clamp(comboSteps, 0, COMBO_MAX - 1)

        local gain = state.greatLock and SCORE_GREAT_PER_S or SCORE_LOCK_PER_S
        state.score = state.score + gain * state.combo * dt
        state.lastMessage = state.greatLock and "Great lock" or "Rate lock"
    else
        state.locked = false
        state.greatLock = false
        state.lockTime = math.max(0, state.lockTime - (1.7 + (cyclicPenaltyNorm * 2.0)) * dt)
        local comboSteps = math.floor(state.lockTime / COMBO_STEP_S)
        state.combo = 1 + clamp(comboSteps, 0, COMBO_MAX - 1)
        local penalty = SCORE_DRIFT_PER_S + (CYCLIC_DRIFT_PER_S * cyclicPenaltyNorm)
        state.score = math.max(0, state.score - penalty * dt)
        if rateGood and not cyclicGood then
            state.lastMessage = "Rate matched: reduce cyclic"
        elseif (not rateGood) and cyclicGood then
            state.lastMessage = "Match target rate"
        else
            state.lastMessage = "Match rate + keep cyclic quiet"
        end
    end

    local rounded = math.floor(state.score + 0.5)
    if rounded > state.bestScore then
        state.bestScore = rounded
        queueBestScoreSave(state, rounded)
    end
end

local function orbitPoint(cx, cy, r, angle)
    local x = cx + math.cos(angle) * r
    local y = cy + math.sin(angle) * r
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function drawRateDial(state, x, y, size)
    local radius = math.floor(size * 0.5)
    local cx = x + radius
    local cy = y + radius

    setColor(56, 74, 102)
    lcd.drawFilledRectangle(x, y, size, size)

    if lcd and lcd.drawCircle then
        setColor(102, 122, 156)
        lcd.drawCircle(cx, cy, radius - 6)
        setColor(78, 96, 126)
        lcd.drawCircle(cx, cy, math.floor(radius * 0.68))
    end

    setColor(94, 112, 142)
    lcd.drawLine(cx - radius + 10, cy, cx + radius - 10, cy)
    lcd.drawLine(cx, cy - radius + 10, cx, cy + radius - 10)

    local tipR = math.max(22, radius - 12)
    local targetTipX, targetTipY = orbitPoint(cx, cy, tipR, state.targetAngle)
    local playerTipX, playerTipY = orbitPoint(cx, cy, tipR, state.playerAngle)

    setColor(226, 96, 96)
    lcd.drawLine(cx, cy, targetTipX, targetTipY)
    lcd.drawFilledRectangle(targetTipX - 3, targetTipY - 3, 7, 7)

    if state.greatLock then
        setColor(78, 216, 116)
    elseif state.locked then
        setColor(186, 214, 92)
    else
        setColor(90, 188, 242)
    end
    lcd.drawLine(cx, cy, playerTipX, playerTipY)
    lcd.drawFilledRectangle(playerTipX - 3, playerTipY - 3, 7, 7)

    setColor(178, 194, 216)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(x, y - 16, "Rotating Rate Match")
end

local function drawCyclicYawGauge(state, x, y, w, h)
    setColor(56, 74, 102)
    lcd.drawFilledRectangle(x, y, w, h)

    local fillH = clamp(math.floor(h * state.cyclicYawTrackNorm + 0.5), 0, h)
    if state.cyclicYawTrackNorm >= 0.82 then
        setColor(76, 212, 112)
    elseif state.cyclicYawTrackNorm >= 0.55 then
        setColor(186, 214, 92)
    else
        setColor(220, 124, 88)
    end
    if fillH > 0 then
        lcd.drawFilledRectangle(x, y + h - fillH, w, fillH)
    end

    if lcd and lcd.drawRectangle then
        setColor(108, 126, 156)
        lcd.drawRectangle(x, y, w, h)
    end

    setColor(224, 232, 244)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(x - 2, y - 16, "Cyc/Yaw")
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
    lcd.drawText(14, 12, "Piro Rate Lock")

    setColor(168, 182, 206)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(16, 38, "Follow target yaw rate while minimizing cyclic drift")
    lcd.drawText(16, 56, "Long PAGE: settings")

    local infoRight = state.windowW - 14
    local infoY = 18
    local infoRow = 22
    local nextCmd = clamp(state.commandInterval - state.commandElapsed, 0, state.commandInterval)
    local errPct = math.floor(clamp(state.rateError / TARGET_RATE_MAX, 0, 1) * 100 + 0.5)
    local cyclicPct = math.floor(state.cyclicMag * 100 + 0.5)
    local cycPenPct = math.floor(state.cyclicPenaltyNorm * 100 + 0.5)
    local cycYawPct = math.floor(state.cyclicYawTrackNorm * 100 + 0.5)

    setColor(236, 242, 252)
    drawRightText(infoRight, infoY + (infoRow * 0), "Score " .. tostring(math.floor(state.score + 0.5)), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 1), "Best " .. tostring(state.bestScore), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 2), "Combo x" .. tostring(state.combo), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 3), string.format("Cmd in %.2fs", nextCmd), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 4), "Rate err " .. tostring(errPct) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 5), "Cyclic " .. tostring(cyclicPct) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 6), "Cyc pen " .. tostring(cycPenPct) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 7), "Cyc/Yaw " .. tostring(cycYawPct) .. "%", FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 8), "Pace " .. paceName(state.pace), FONT_STD)
    drawRightText(infoRight, infoY + (infoRow * 9), "Strict " .. strictnessName(state.strictness), FONT_STD)

    local footerReserve = 48
    local dialTop = 88
    local maxDialH = math.max(130, state.windowH - dialTop - footerReserve)
    local dialSize = clamp(math.floor(math.min(state.windowW * 0.52, maxDialH)), 150, 260)
    local dialX = math.floor((state.windowW - dialSize) * 0.5)
    local dialY = clamp(math.floor((state.windowH - dialSize) * 0.5) + 6, dialTop, state.windowH - footerReserve - dialSize)
    drawRateDial(state, dialX, dialY, dialSize)

    local gaugeX = 14
    local gaugeW = 12
    local gaugeTop = dialTop + 8
    local gaugeBottom = state.windowH - footerReserve - 8
    local gaugeH = math.max(80, gaugeBottom - gaugeTop)
    drawCyclicYawGauge(state, gaugeX, gaugeTop, gaugeW, gaugeH)

    setColor(164, 178, 202)
    setFont(FONT_XXS or FONT_STD)
    lcd.drawText(16, state.windowH - 40, state.lastMessage)
    lcd.drawText(16, state.windowH - 20, "Enter: reset run | Long PAGE: settings | Exit: back")
end

local function createState()
    math.randomseed(os.time())
    local loadedConfig = loadStateConfig()
    local state = {
        yawSource = resolveAnalogSource(YAW_SOURCE_MEMBER),
        rollSource = resolveAnalogSource(ROLL_SOURCE_MEMBER),
        pitchSource = resolveAnalogSource(PITCH_SOURCE_MEMBER),
        yawInput = 0,
        rollInput = 0,
        pitchInput = 0,
        playerRate = 0,
        targetRateCmd = 0,
        commandElapsed = 0,
        commandInterval = COMMAND_INTERVAL_START,
        commandsIssued = 0,
        cyclicMag = 0,
        cyclicYawTrackNorm = 0,
        rateError = 1,
        score = 0,
        bestScore = loadedConfig.bestScore,
        pace = loadedConfig.pace,
        strictness = loadedConfig.strictness,
        combo = 1,
        lockTime = 0,
        locked = false,
        greatLock = false,
        cyclicPenaltyNorm = 0,
        commandIntervalStart = COMMAND_INTERVAL_START,
        commandIntervalMin = COMMAND_INTERVAL_MIN,
        commandAccelStep = COMMAND_ACCEL_STEP,
        rateLockWindow = RATE_LOCK_WINDOW,
        rateGreatWindow = RATE_GREAT_WINDOW,
        cyclicLockWindow = CYCLIC_LOCK_WINDOW,
        cyclicGreatWindow = CYCLIC_GREAT_WINDOW,
        targetAngle = 0,
        playerAngle = 0,
        lastMessage = "Match target piro rate",
        lastFrameAt = 0,
        nextInvalidateAt = 0,
        lastFocusKick = 0,
        windowW = (type(LCD_W) == "number") and LCD_W or 784,
        windowH = (type(LCD_H) == "number") and LCD_H or 406,
        settingsFormOpen = false,
        pendingFormClear = false,
        suppressExitUntil = 0,
        suppressEnterUntil = 0,
        pendingBestScore = nil,
        bestScoreSaveDueAt = 0
    }
    applyConfigProfiles(state, false)
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
    flushBestScoreSave(state, false)

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

    if category == EVT_CLOSE then return false end
    if isExitKeyEvent(category, value) then return false end

    if isSettingsOpenEvent(category, value) then
        local okOpen, opened = pcall(openSettingsForm, state)
        if okOpen and opened then
            return true
        end
        state.lastMessage = "Settings form unavailable on this build"
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
    updateCommand(state, dt)
    updateVisualRotation(state, dt)
    updateScoring(state, dt)
    drawHud(state)
    flushBestScoreSave(state, false)
end

function game.close(state)
    if type(state) ~= "table" then return end

    if state.settingsFormOpen then
        closeSettingsForm(state, false, false)
    else
        flushPendingFormClear(state)
    end

    flushBestScoreSave(state, true)
    state.locked = false

    if collectgarbage then
        pcall(collectgarbage, "collect")
        pcall(collectgarbage, "collect")
    end
end

return game
