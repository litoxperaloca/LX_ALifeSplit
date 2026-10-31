--[[
    LX_ALifeSplit - enganches del lado "servidor" de A-Life (en un solo jugador / pantalla
    dividida el servidor corre en la misma partida). Todo se aplica solo si NO es
    multijugador; en multijugador A-Life queda exactamente igual.

    1. PlayerLocator.list: la lista de jugadores que usa TODA la IA (percepcion, aparicion y
       desaparicion de NPCs, ritmo de decisiones, visitantes de refugio...). Antes: un solo
       jugador. Ahora: el original + los demas jugadores locales.
    2. EncounterDirector.anyPlayer / playerLive / watchRoads: los encuentros podian girar solo
       alrededor del jugador 1, se descartaban si el elegido era otro, y los de la ruta (al
       manejar) solo miraban a un jugador.
    Nada de este mod vive dentro de las carpetas de A-Life (A-Life avisa "incompatible" a
    cualquier mod que ponga Lua ahi): todo son enganches en tiempo de ejecucion.
    3. RaidDirector / MetaDirector / BaseHeat: incursiones, eventos del mundo y "calor" de
       base solo miraban al jugador 1. Se usa el enchufe oficial adapters.players.
    4. Reputation: avisos falsos de "cambio de nivel" al alternar datos de ambos jugadores.
    5. Combat.aimRamp: la punteria de un NPC no se reiniciaba al cambiar del jugador 1 al 2
       (los dos tenian la misma clave).
]]
require "LXAS_Core"
require "ProjectALife/Core/ALifePlayerLocator"
require "ProjectALife/World/ALifeEncounterDirector"
require "ProjectALife/World/ALifeRaidDirector"
require "ProjectALife/World/ALifeMetaDirector"
require "ProjectALife/World/ALifeBaseHeat"
require "ProjectALife/Decisions/ALifeReputation"
require "ProjectALife/Combat/ALifeCombatFire"

local SIDE = "servidor"
local PA = ProjectALife or {}

-- ---------------------------------------------------------------- 1. PlayerLocator.list
LXAS.apply(SIDE, "PlayerLocator.list", function()
    return LXAS.wrapOnce(PA.PlayerLocator, "list", function(original)
        return function(adapter, ...)
            local result = original(adapter, ...)
            if type(adapter) == "function" or type(result) ~= "table" or not LXAS.isSP() then
                return result
            end
            pcall(LXAS.fillLocalPlayers, result)
            return result
        end
    end)
end)

-- ---------------------------------------------------------------- 2. Encuentros
local function directorNow(D)
    if type(D.adapters) == "table" and type(D.adapters.nowMs) == "function" then
        local ok, v = pcall(D.adapters.nowMs)
        if ok and tonumber(v) ~= nil then return tonumber(v) end
    end
    return getTimestampMs()
end

LXAS.apply(SIDE, "EncounterDirector.anyPlayer", function()
    local D = PA.EncounterDirector
    return LXAS.wrapOnce(D, "anyPlayer", function(original)
        return function(...)
            if not LXAS.isSP() then return original(...) end
            local list = LXAS.livePlayers()
            if #list == 0 then return original(...) end
            -- un jugador al azar; si esta "entrando en calor" (recien aparecido), probar otro
            local now = directorNow(D)
            local start = ZombRand(#list)
            for i = 0, #list - 1 do
                local p = list[(start + i) % #list + 1]
                local warming = false
                if type(D.warming) == "function" then
                    local ok, w = pcall(D.warming, p, now)
                    warming = ok and w == true
                end
                if not warming then return p end
            end
            return nil
        end
    end)
end)

LXAS.apply(SIDE, "EncounterDirector.playerLive", function()
    return LXAS.wrapOnce(PA.EncounterDirector, "playerLive", function(original)
        return function(player, ...)
            if player ~= nil and LXAS.isSP() and LXAS.isLocalPlayerObj(player) then return true end
            return original(player, ...)
        end
    end)
end)

-- Encuentros en la ruta (al manejar): A-Life arma su lista con getOnlinePlayers() (vacio aca)
-- y despues getPlayer() (un solo jugador). La corremos una vez por jugador local vivo, con
-- getPlayer() devolviendo ese jugador durante la llamada (se restaura siempre).
LXAS.apply(SIDE, "EncounterDirector.watchRoads", function()
    local D = PA.EncounterDirector
    return LXAS.wrapOnce(D, "watchRoads", function(original)
        return function(now, ...)
            if not LXAS.isSP() or type(D.roadWatch) ~= "table" or type(getPlayer) ~= "function" then
                return original(now, ...)
            end
            local players = LXAS.livePlayers()
            if #players <= 1 then return original(now, ...) end
            local realGetPlayer = getPlayer
            local gate = D.roadWatch.nextAtMs -- A-Life corre esto cada 500 ms; mismo turno para todos
            local total = 0
            for index, player in ipairs(players) do
                if index > 1 then D.roadWatch.nextAtMs = gate end
                getPlayer = function() return player end
                local ok, placed = pcall(original, now, ...)
                getPlayer = realGetPlayer
                if ok then
                    total = total + (tonumber(placed) or 0)
                else
                    LXAS.log("encuentros en ruta: " .. tostring(placed))
                end
            end
            return total
        end
    end)
end)

-- ---------------------------------------------------------------- 3. Incursiones / eventos / calor de base
local function localPlayersAdapter()
    return LXAS.localPlayers()
end

local function ensurePlayersAdapter(mod)
    if not LXAS.isSP() or type(mod) ~= "table" or type(mod.adapters) ~= "table" then return end
    if mod.adapters.players == nil then mod.adapters.players = localPlayersAdapter end
end

for _, name in ipairs({ "RaidDirector", "MetaDirector", "BaseHeat" }) do
    LXAS.apply(SIDE, name .. ".jugadores", function()
        local mod = PA[name]
        if type(mod) ~= "table" then return false, "modulo no existe" end
        -- A-Life reemplaza la tabla de enchufes en configure()/reset() al iniciar la partida:
        -- volvemos a poner el nuestro despues de cada una (solo si nadie puso otro).
        local okConfigure, why = LXAS.wrapOnce(mod, "configure", function(original)
            return function(...)
                local a, b = original(...)
                pcall(ensurePlayersAdapter, mod)
                return a, b
            end
        end)
        if not okConfigure then return false, why end
        if type(mod.reset) == "function" then
            LXAS.wrapOnce(mod, "reset", function(original)
                return function(...)
                    local a, b = original(...)
                    pcall(ensurePlayersAdapter, mod)
                    return a, b
                end
            end)
        end
        pcall(ensurePlayersAdapter, mod)
        return true
    end)
end

-- ---------------------------------------------------------------- 4. Reputacion: aviso por jugador
-- En un solo jugador A-Life entrega la reputacion al cliente llamando StatusStore.receive
-- sin decir de que jugador es, y RepNotify compara con UN "ultimo nivel" global: al llegar
-- alternados los del jugador 1 y 2 mostraba carteles falsos de "subiste/bajaste de nivel".
-- Este enchufe hace la misma entrega, guardando y restaurando el ultimo nivel por jugador.
LXAS.repLevel = LXAS.repLevel or {}

local function repSend(player, module, command, payload)
    local store = PA.StatusStore
    if store == nil or type(store.receive) ~= "function" then
        if type(sendServerCommand) ~= "function" then return false end
        sendServerCommand(player, module, command, payload)
        return true
    end
    local n = LXAS.playerNumOf(player)
    local notify = PA.RepNotify
    local track = notify ~= nil and n ~= nil and command == "reputationSync"
    if track then notify.lastLevel = LXAS.repLevel[n] end
    local ok, err = pcall(store.receive, module, command, payload)
    if track then LXAS.repLevel[n] = notify.lastLevel end
    if not ok then LXAS.log("reputacion: " .. tostring(err)) end
    return ok
end

local function ensureRepSend(mod)
    if not LXAS.isSP() or type(mod) ~= "table" or type(mod.adapters) ~= "table" then return end
    if mod.adapters.send == nil then mod.adapters.send = repSend end
end

LXAS.apply(SIDE, "Reputation.avisos_por_jugador", function()
    local R = PA.Reputation
    if type(R) ~= "table" then return false, "modulo no existe" end
    local ok, why = LXAS.wrapOnce(R, "configure", function(original)
        return function(...)
            local a, b = original(...)
            pcall(ensureRepSend, R)
            return a, b
        end
    end)
    if not ok then return false, why end
    pcall(ensureRepSend, R)
    return true
end)

-- ---------------------------------------------------------------- 5. Punteria por jugador
LXAS.apply(SIDE, "Combat.aimRamp", function()
    local C = PA.Combat
    return LXAS.wrapOnce(C, "aimRamp", function(original)
        return function(shell, target, distance, ...)
            if target ~= nil and LXAS.isSP() and type(C.dataOf) == "function" then
                pcall(function()
                    local data = C.dataOf(shell)
                    if type(data) ~= "table" and type(data) ~= "userdata" then return end
                    local key = nil
                    if LXAS.isLocalPlayerObj(target) then
                        local n = LXAS.playerNumOf(target)
                        if n ~= nil then key = "lp" .. tostring(n) end
                    end
                    if key ~= nil and data.LXASAimRampPlayer ~= key then
                        data.ProjectALifeAimRampKey = nil -- distinto jugador: la rampa empieza de nuevo
                    end
                    data.LXASAimRampPlayer = key
                end)
            end
            return original(shell, target, distance, ...)
        end
    end)
end)

LXAS.summary(SIDE)
