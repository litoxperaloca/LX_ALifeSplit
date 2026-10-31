--[[
    LX_ALifeSplit - enganches del lado cliente de A-Life (solo fuera de multijugador).

    1. TalkInput.deliver: todo lo que el jugador "dice" a los NPCs (gestos de rendirse,
       saludar, pedir que paren, insultar; ayuda al matar zombis) se enviaba como si fuera
       el jugador 1. Ahora va a nombre de quien lo hizo.
    2. Ventana de charla: con 2+ jugadores se abre en la mitad de pantalla de quien habla
       (y en version clasica si la cinematografica no entra en esa mitad).
    3. Pestana "Reputacion" (Info del personaje): no respondia al mando y lo dejaba trabado.
       Ahora LB/RB cambian de pestana y B cierra, igual que las pestanas del juego.
    4. Zombis vs NPCs: la lista de presas de los zombis solo tenia a un jugador.
]]
require "LXAS_Core"
require "ProjectALife/Talk/ALifeTalkInput"
require "ProjectALife/Talk/ALifeTalkMenu"
require "ProjectALife/Talk/ALifeTalkCinema"
require "ProjectALife/Interface/ALifeRepTab"
require "ProjectALife/Combat/ALifeHordeRelations"

local SIDE = "cliente"
local PA = ProjectALife or {}

-- ---------------------------------------------------------------- 1. Quien habla
-- LXAS.actor: personaje que esta haciendo el gesto en este momento (lo fija el menu de gestos).
LXAS.actor = nil

LXAS.apply(SIDE, "TalkInput.deliver", function()
    local Input = PA.TalkInput
    return LXAS.wrapOnce(Input, "deliver", function(original)
        return function(kind, args, who, ...)
            if not LXAS.isSP() then return original(kind, args, who, ...) end
            local player = who or LXAS.actor
            if player == nil or not LXAS.isLocalPlayerObj(player) then
                return original(kind, args, who, ...)
            end
            -- mismo camino que el original en un solo jugador, con el jugador correcto
            if type(Input.local_) ~= "table" or Input.local_[kind] == nil then return false end
            local talk = PA.Talk or (ProjectALife and ProjectALife.Talk)
            if talk == nil then return false end
            return Input.local_[kind](talk, player, args) == true
        end
    end)
end)

-- Envoltorio externo del menu de gestos: marca quien hace el gesto mientras A-Life lo procesa.
local function installEmoteActor()
    if ISEmoteRadialMenu == nil then return false, "ISEmoteRadialMenu no existe" end
    if ISEmoteRadialMenu.lxasActorWrapped == true then return true end
    local original = ISEmoteRadialMenu.emote
    if type(original) ~= "function" then return false, "emote no existe" end
    ISEmoteRadialMenu.emote = function(self, emote, ...)
        local previous = LXAS.actor
        LXAS.actor = type(self) == "table" and self.character or nil
        local ok, a, b, c = pcall(original, self, emote, ...)
        LXAS.actor = previous
        if not ok then error(a, 0) end
        return a, b, c
    end
    ISEmoteRadialMenu.lxasActorWrapped = true
    return true
end

LXAS.apply(SIDE, "TalkInput.gestos", function()
    local Input = PA.TalkInput
    if type(Input) ~= "table" then return false, "TalkInput no existe" end
    if ISEmoteRadialMenu ~= nil and ISEmoteRadialMenu.alifeTalkWrapped == true then
        -- A-Life ya envolvio los gestos (recarga de Lua): nos ponemos por fuera ya mismo
        return installEmoteActor()
    end
    -- A-Life envuelve los gestos en OnGameStart llamando Input.wrapEmotes(): nos ponemos
    -- justo por fuera de su envoltorio, en el mismo momento.
    return LXAS.wrapOnce(Input, "wrapEmotes", function(original)
        return function(...)
            local a, b = original(...)
            local ok, err = pcall(installEmoteActor)
            if not ok then LXAS.log("gestos: " .. tostring(err)) end
            return a, b
        end
    end)
end)

-- Ayuda al matar zombis: A-Life solo la acreditaba si el que mato era el jugador 1.
LXAS.apply(SIDE, "TalkInput.zombis_ayuda", function()
    local Input = PA.TalkInput
    if type(Input) ~= "table" or type(Input.onZombieDead) ~= "function" then return false, "onZombieDead no existe" end
    if Events == nil or Events.OnZombieDead == nil then return false, "evento no existe" end
    if LXAS._zombieDeadInstalled then return true end
    local original = Input.onZombieDead
    local function onZombieDead(zombie)
        if not LXAS.isSP() then return original(zombie) end
        if type(Input.settings) ~= "table" or Input.settings.enabled ~= true or zombie == nil then return end
        pcall(function()
            local attacker = zombie:getAttackedBy()
            if attacker == nil or not LXAS.isLocalPlayerObj(attacker) then return end
            local now = getTimestampMs()
            if now - (tonumber(Input.lastHelpedAt) or 0) < (tonumber(Input.settings.helpedIntervalMs) or 4000) then return end
            Input.lastHelpedAt = now
            if type(Input.metrics) == "table" then Input.metrics.helped = (Input.metrics.helped or 0) + 1 end
            Input.deliver("talkHelped", { x = zombie:getX(), y = zombie:getY() }, attacker)
        end)
    end
    -- si Remove no encontrara el original, el limite de 4 s evita contar doble
    pcall(function() Events.OnZombieDead.Remove(original) end)
    Events.OnZombieDead.Add(onZombieDead)
    LXAS._zombieDeadInstalled = true
    return true
end)

-- ---------------------------------------------------------------- 2. Ventana de charla
local CINEMA_MIN_WIDTH = 840 -- la cinematografica mide ~820 px: si la mitad es mas angosta, clasica

local function clamp(v, lo, hi)
    if hi < lo then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function placeInViewport(panel, playerNum)
    if panel == nil or type(panel.setX) ~= "function" then return end
    if tonumber(panel.playerNum) ~= tonumber(playerNum) then return end
    local left, top = getPlayerScreenLeft(playerNum), getPlayerScreenTop(playerNum)
    local w, h = getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)
    local core = getCore()
    local sw, sh = core:getScreenWidth(), core:getScreenHeight()
    local pw, ph = panel:getWidth(), panel:getHeight()
    local x = clamp(math.floor(left + (w - pw) / 2), 0, sw - pw)
    local y = clamp(math.floor(top + (h - ph) / 2), 0, sh - ph)
    panel:setX(x)
    panel:setY(y)
end

LXAS.apply(SIDE, "TalkMenu.ventana_por_jugador", function()
    local Menu = PA.TalkMenu
    return LXAS.wrapOnce(Menu, "open", function(original)
        return function(playerNum, ...)
            if not LXAS.isSP() or LXAS.activePlayerCount() < 2 or tonumber(playerNum) == nil then
                return original(playerNum, ...)
            end
            local result
            local okW, w = pcall(getPlayerScreenWidth, playerNum)
            if okW and tonumber(w) ~= nil and w < CINEMA_MIN_WIDTH and type(Menu.openClassic) == "function" then
                result = Menu.openClassic(playerNum, ...)
            else
                result = original(playerNum, ...)
            end
            local ok, err = pcall(placeInViewport, Menu.instance, playerNum)
            if not ok then LXAS.log("ventana de charla: " .. tostring(err)) end
            return result
        end
    end)
end)

-- ---------------------------------------------------------------- 3. Pestana Reputacion con mando
local function addJoypad(class)
    if type(class) ~= "table" or class.lxasJoypad == true then return end
    class.lxasJoypad = true
    if rawget(class, "onJoypadDown") ~= nil then return end -- A-Life ya lo maneja
    function class:onJoypadDown(button, joypadData)
        pcall(function()
            if Joypad == nil then return end
            local info = type(getPlayerInfoPanel) == "function" and getPlayerInfoPanel(self.playerNum) or nil
            if button == Joypad.BButton then
                local Tab = PA.RepTab
                if info ~= nil and type(info.toggleView) == "function" and Tab ~= nil and type(Tab.title) == "function" then
                    info:toggleView(Tab.title())
                end
                setJoypadFocus(self.playerNum, nil)
            elseif button == Joypad.LBumper or button == Joypad.RBumper then
                if info ~= nil and type(info.onJoypadDown) == "function" then info:onJoypadDown(button, joypadData) end
            end
        end)
    end
end

LXAS.apply(SIDE, "RepTab.mando", function()
    local Tab = PA.RepTab
    local ok, why = LXAS.wrapOnce(Tab, "viewClass", function(original)
        return function(...)
            local class = original(...)
            pcall(addJoypad, class)
            return class
        end
    end)
    if not ok then return false, why end
    if type(Tab.View) == "table" then pcall(addJoypad, Tab.View) end
    return true
end)

-- ---------------------------------------------------------------- 4. Presas de los zombis
LXAS.apply(SIDE, "HordeRelations.jugadores", function()
    local Horde = PA.HordeRelations
    return LXAS.wrapOnce(Horde, "sweepPlayers", function(original)
        return function(...)
            local roster, listed = original(...)
            -- 'listed' (jugadores online) queda en 0 como en el original: solo agregamos filas
            if not LXAS.isSP() or type(roster) ~= "table" or (tonumber(listed) or 0) > 0
                    or type(Horde.rosterRow) ~= "function" then
                return roster, listed
            end
            pcall(function()
                for _, p in ipairs(LXAS.localPlayers()) do
                    local present = false
                    for _, row in ipairs(roster) do
                        if type(row) == "table" and row.body == p then present = true; break end
                    end
                    if not present then
                        local row = Horde.rosterRow(p)
                        if row ~= nil then roster[#roster + 1] = row end
                    end
                end
            end)
            return roster, listed
        end
    end)
end)

-- Partida nueva: olvidar niveles de reputacion de la partida anterior.
if Events ~= nil and Events.OnGameStart ~= nil then
    Events.OnGameStart.Add(function() LXAS.repLevel = {} end)
end

LXAS.summary(SIDE)
