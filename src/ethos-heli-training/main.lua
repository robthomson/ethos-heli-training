local APP_NAME = "Heli Training"
local DEBUG_EVENTS = false
local DEBUG_GC = true

local games = {
    {
        id = "piroflip-chase",
        name = "Piroflip Chase",
        description = "Yaw spins target, collective chases phase",
        modulePath = "SCRIPTS:/ethos-heli-training/games/piroflip-chase/game.lua",
        iconPath = "SCRIPTS:/ethos-heli-training/games/piroflip-chase/gfx/icon.png"
    },
    {
        id = "tictoc-rhythm",
        name = "TicToc Rhythm",
        description = "Beat-based elevator and collective tic-toc trainer",
        modulePath = "SCRIPTS:/ethos-heli-training/games/tictoc-rhythm/game.lua",
        iconPath = "SCRIPTS:/ethos-heli-training/games/tictoc-rhythm/gfx/icon.png"
    },
    {
        id = "piro-rate-lock",
        name = "Piro Rate Lock",
        description = "Match target piro rate while keeping cyclic stable",
        modulePath = "SCRIPTS:/ethos-heli-training/games/piro-rate-lock/game.lua",
        iconPath = "SCRIPTS:/ethos-heli-training/games/piro-rate-lock/gfx/icon.png"
    },
    {
        id = "collective-balance",
        name = "Col. Balance",
        description = "Track collective through continuous flip attitude",
        modulePath = "SCRIPTS:/ethos-heli-training/games/collective-balance/game.lua",
        iconPath = "SCRIPTS:/ethos-heli-training/games/collective-balance/gfx/icon.png"
    }
}

local function keyMatches(value, ...)
    for i = 1, select("#", ...) do
        local key = select(i, ...)
        if key and value == key then
            return true
        end
    end
    return false
end

local function debugEvent(state, category, value)
    if not DEBUG_EVENTS then
        return
    end

    local scope = "menu"
    if state and state.activeDef and state.activeDef.id then
        scope = state.activeDef.id
    end

    print(string.format("[heli training event] scope=%s category=%s value=%s", scope, tostring(category), tostring(value)))
end

local function isKeyCategory(category)
    if type(EVT_KEY) == "number" then
        return category == EVT_KEY
    end
    return category == 0
end

local function isCloseEvent(category)
    if type(EVT_CLOSE) == "number" and category == EVT_CLOSE then
        return true
    end
    return false
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

local function nowSeconds()
    if os and os.clock then
        return os.clock()
    end
    return 0
end

local function suppressExitEvents(state, windowSeconds)
    if not state then
        return
    end
    state.suppressExitUntil = nowSeconds() + (windowSeconds or 0.35)
end

local function shouldSuppressExit(state)
    if not state or not state.suppressExitUntil then
        return false
    end
    return nowSeconds() < state.suppressExitUntil
end

local function loadIcon(path)
    local okMask, mask = pcall(lcd.loadMask, path)
    if okMask and mask then
        return mask
    end

    local okBitmap, bitmap = pcall(lcd.loadBitmap, path)
    if okBitmap and bitmap then
        return bitmap
    end

    return nil
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

local function loadGameModule(def)
    if not def then
        return nil, "Missing game definition"
    end

    if def.module then
        return def.module
    end

    local chunk, err = loadfile(def.modulePath)
    if not chunk then
        return nil, err
    end

    local ok, module = pcall(chunk)
    if not ok then
        return nil, module
    end

    if type(module) ~= "table" then
        return nil, "Module did not return a table"
    end

    def.module = module
    return module
end

local function formatError(err)
    local msg = tostring(err)
    if debug and debug.traceback then
        return debug.traceback(msg, 2)
    end
    return msg
end

local function setLastError(state, prefix, err)
    if not state then
        return
    end
    local short = string.format("%s: %s", prefix, tostring(err))
    local full = string.format("%s: %s", prefix, formatError(err))
    state.lastError = short
    state.lastErrorFull = full
    print(full)
end

local function wrapText(text, maxLen)
    local lines = {}
    local line = ""
    local limit = maxLen or 60
    for word in tostring(text):gmatch("%S+") do
        if #line == 0 then
            line = word
        elseif (#line + 1 + #word) <= limit then
            line = line .. " " .. word
        else
            lines[#lines + 1] = line
            line = word
        end
    end
    if line ~= "" then
        lines[#lines + 1] = line
    end
    return lines
end

local function clearMenuForm(state)
    if state then
        state.menuBuilt = false
        state.menuButtons = nil
        state.menuClearRequested = true
    end
end

local function releaseAssets(value, visited)
    if value == nil then
        return
    end
    local valueType = type(value)
    if valueType == "userdata" then
        return
    end
    if valueType ~= "table" then
        return
    end
    if not visited then
        visited = {}
    end
    if visited[value] then
        return
    end
    visited[value] = true

    for key, item in pairs(value) do
        local keyType = type(key)
        local itemType = type(item)
        local keyName = keyType == "string" and key:lower() or ""
        if itemType == "userdata" then
            value[key] = nil
        elseif itemType == "table" then
            if keyName:find("bitmap", 1, true) or keyName:find("mask", 1, true) or keyName:find("image", 1, true) then
                value[key] = nil
            else
                releaseAssets(item, visited)
            end
        elseif keyType == "string" and (keyName:find("bitmap", 1, true) or keyName:find("mask", 1, true) or keyName:find("image", 1, true)) then
            value[key] = nil
        end
    end
end

local function stopActiveGame(state)
    if not state then
        return
    end

    local memBefore
    if DEBUG_GC and collectgarbage then
        local ok, value = pcall(collectgarbage, "count")
        if ok then
            memBefore = value
        end
    end

    if state.activeModule and state.activeState and type(state.activeModule.close) == "function" then
        pcall(state.activeModule.close, state.activeState)
    end

    if state.activeState then
        releaseAssets(state.activeState)
    end

    if state.activeDef then
        state.activeDef.module = nil
    end

    state.activeDef = nil
    state.activeModule = nil
    state.activeState = nil
    clearMenuForm(state)

    if collectgarbage then
        pcall(collectgarbage, "collect")
        pcall(collectgarbage, "collect")
    end

    if DEBUG_GC and collectgarbage then
        local ok, after = pcall(collectgarbage, "count")
        if ok then
            local beforeText = memBefore and string.format("%.1f", memBefore) or "n/a"
            print(string.format("[heli training gc] before=%sKB after=%.1fKB", beforeText, after))
        end
    end

    if lcd and lcd.invalidate then
        pcall(lcd.invalidate)
    end
end

local function startGame(state, index)
    if not state then
        return false
    end

    local def = games[index]
    if not def then
        return false
    end

    local module, err = loadGameModule(def)
    if not module then
        setLastError(state, def.name, err)
        clearMenuForm(state)
        return false
    end

    clearMenuForm(state)

    local gameState = {}
    if type(module.create) == "function" then
        local okCreate, created = pcall(module.create)
        if not okCreate then
            setLastError(state, def.name .. " create() failed", created)
            return false
        end
        if created ~= nil then
            gameState = created
        end
    end

    state.selectedIndex = index
    state.activeDef = def
    state.activeModule = module
    state.activeState = gameState

    if type(module.wakeup) == "function" then
        local okWake, wakeErr = pcall(module.wakeup, state.activeState)
        if not okWake then
            setLastError(state, def.name .. " wakeup() failed", wakeErr)
            stopActiveGame(state)
            return false
        end
    end

    state.lastError = nil
    state.lastErrorFull = nil
    return true
end

local function addMenuButton(rect, def, onPress)
    if form and form.addButton then
        return form.addButton(nil, rect, {
            text = def.name,
            icon = def.icon,
            options = FONT_S,
            paint = function() end,
            press = onPress
        })
    end

    if form and form.addTextButton then
        return form.addTextButton(nil, rect, def.name, onPress)
    end

    return nil
end

local function buildMenuForm(state)
    if state.activeModule or state.menuBuilt then
        return
    end

    if not (form and form.clear and form.addLine and form.addStaticText) then
        return
    end

    form.clear()
    state.menuClearRequested = false

    local width = 480
    if lcd and lcd.getWindowSize then
        local w = lcd.getWindowSize()
        if type(w) == "number" and w > 0 then
            width = w
        end
    end

    local padding = 8
    local buttonSize = 110
    if width >= 620 then
        padding = 10
        buttonSize = 118
    elseif width < 420 then
        padding = 6
        buttonSize = 84
    end

    local perRow = math.max(1, math.floor((width - padding) / (buttonSize + padding)))

    local header = form.addLine("")
    form.addStaticText(header, {x = 0, y = 0, w = width, h = 28}, APP_NAME)
    state.menuButtons = {}

    local y = form.height() + padding
    local col = 0

    for i, def in ipairs(games) do
        if col >= perRow then
            col = 0
            y = y + buttonSize + padding
        end

        local x = padding + col * (buttonSize + padding)
        local button = addMenuButton({x = x, y = y, w = buttonSize, h = buttonSize}, def, function()
            state.selectedIndex = i
            startGame(state, i)
        end)

        state.menuButtons[i] = button

        if i == state.selectedIndex and button and button.focus then
            button:focus()
        end

        col = col + 1
    end

    if state.lastError then
        form.addLine("Last error:")
        local lines = wrapText(state.lastErrorFull or state.lastError, 60)
        for i = 1, math.min(#lines, 6) do
            form.addLine(lines[i])
        end
    end

    state.menuBuilt = true
end

local function handleActiveGameEvent(state, category, value)
    local module = state.activeModule
    if not module then
        return false
    end

    if type(module.event) == "function" then
        local okEvent, eventResult = pcall(module.event, state.activeState, category, value)
        if not okEvent then
            setLastError(state, state.activeDef.name .. " event() failed", eventResult)
            stopActiveGame(state)
            return true
        end
        if eventResult == true then
            return true
        end
    end

    if isCloseEvent(category) then
        suppressExitEvents(state)
        stopActiveGame(state)
        return true
    end

    if isExitKeyEvent(category, value) then
        suppressExitEvents(state)
        stopActiveGame(state)
        return true
    end

    return false
end

local function createState()
    local state = {
        selectedIndex = 1,
        activeDef = nil,
        activeModule = nil,
        activeState = nil,
        menuBuilt = false,
        menuButtons = nil,
        menuClearRequested = false,
        lastFocusKick = 0,
        lastError = nil,
        lastErrorFull = nil,
        suppressExitUntil = 0
    }

    for _, def in ipairs(games) do
        def.icon = loadIcon(def.iconPath)
    end

    return state
end

local app = {}

function app.create()
    return createState()
end

function app.wakeup(state)
    if type(state) ~= "table" then
        return
    end

    if state.menuClearRequested and form and form.clear then
        pcall(form.clear)
        state.menuClearRequested = false
    end

    if state.activeModule and type(state.activeModule.wakeup) == "function" then
        local okWake, wakeErr = pcall(state.activeModule.wakeup, state.activeState)
        if not okWake then
            setLastError(state, state.activeDef.name .. " wakeup() failed", wakeErr)
            stopActiveGame(state)
            return
        end
    else
        keepScreenAwake(state)
        buildMenuForm(state)
    end
end

function app.event(state, category, value)
    if type(state) ~= "table" then
        return false
    end

    debugEvent(state, category, value)

    if state.activeModule then
        return handleActiveGameEvent(state, category, value)
    end

    if isExitKeyEvent(category, value) and shouldSuppressExit(state) then
        return true
    end

    return false
end

function app.paint(state)
    if type(state) ~= "table" then
        return
    end

    if state.activeModule and type(state.activeModule.paint) == "function" then
        local okPaint, paintErr = pcall(state.activeModule.paint, state.activeState)
        if not okPaint then
            setLastError(state, state.activeDef.name .. " paint() failed", paintErr)
            stopActiveGame(state)
        end
        return
    end

    keepScreenAwake(state)
end

function app.close(state)
    if type(state) ~= "table" then
        return
    end

    if state.activeModule then
        stopActiveGame(state)
    else
        clearMenuForm(state)
    end
end

local function loadToolIcon()
    local path = "SCRIPTS:/ethos-heli-training/gfx/icon.png"
    local icon = loadIcon(path)
    return icon or path
end

local function init()
    system.registerSystemTool({
        name = APP_NAME,
        icon = loadToolIcon(),
        create = app.create,
        wakeup = app.wakeup,
        event = app.event,
        paint = app.paint,
        close = app.close
    })
end

return {init = init}
