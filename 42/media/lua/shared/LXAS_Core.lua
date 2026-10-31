--[[
    LX_ALifeSplit - nucleo.

    1) Helpers de "jugadores locales" (pantalla dividida: slots 0..3 de getSpecificPlayer).
       En un solo jugador / pantalla dividida getOnlinePlayers() viene VACIO y getPlayer()
       devuelve un unico jugador: A-Life solo "veia" a uno.
    2) Registro de parches: cada enganche se aplica dentro de pcall y se anota OK / FALLO.
       Si algo no encaja (por ejemplo, A-Life cambio en una actualizacion), ese enganche se
       omite, se avisa en console.txt y A-Life sigue funcionando como siempre.
    3) Nada de este mod vive dentro de las carpetas de A-Life: A-Life marca como
       "incompatible" a cualquier mod que ponga archivos Lua ahi.
]]

LXAS = LXAS or {}
LXAS.report = LXAS.report or {}

local function log(msg) print("[LX_ALifeSplit] " .. tostring(msg)) end
LXAS.log = log

-- =====================================================================
-- Jugadores locales
-- =====================================================================

-- true en un solo jugador / pantalla dividida (no cliente ni servidor de multijugador).
function LXAS.isSP()
    if type(isClient) == "function" and isClient() then return false end
    if type(isServer) == "function" and isServer() then return false end
    return true
end

-- Jugadores locales existentes (los slots pueden tener huecos), vivos o no.
function LXAS.localPlayers()
    local list = {}
    if type(getSpecificPlayer) ~= "function" then return list end
    for i = 0, 3 do
        local ok, p = pcall(getSpecificPlayer, i)
        if ok and p ~= nil then list[#list + 1] = p end
    end
    return list
end

function LXAS.isAlive(p)
    if p == nil then return false end
    local ok, dead = pcall(function() return p:isDead() end)
    return ok and dead ~= true
end

-- Jugadores locales vivos con casilla cargada (para elegir alrededor de quien pasan cosas).
function LXAS.livePlayers()
    local list = {}
    for _, p in ipairs(LXAS.localPlayers()) do
        if LXAS.isAlive(p) then
            local ok, sq = pcall(function() return p:getCurrentSquare() end)
            if ok and sq ~= nil then list[#list + 1] = p end
        end
    end
    return list
end

function LXAS.isLocalPlayerObj(obj)
    if obj == nil then return false end
    for _, p in ipairs(LXAS.localPlayers()) do
        if p == obj then return true end
    end
    return false
end

function LXAS.playerNumOf(p)
    if p == nil then return nil end
    local ok, n = pcall(function() return p:getPlayerNum() end)
    if ok and type(n) == "number" and n >= 0 and n <= 3 then return n end
    return nil
end

-- Agrega a 'list' los jugadores locales que falten. Devuelve cuantos agrego.
function LXAS.fillLocalPlayers(list)
    if type(list) ~= "table" then return 0 end
    local added = 0
    for _, p in ipairs(LXAS.localPlayers()) do
        local present = false
        for _, q in ipairs(list) do
            if q == p then present = true; break end
        end
        if not present then
            list[#list + 1] = p
            added = added + 1
        end
    end
    return added
end

function LXAS.activePlayerCount()
    if type(getNumActivePlayers) == "function" then
        local ok, n = pcall(getNumActivePlayers)
        if ok and type(n) == "number" then return n end
    end
    return #LXAS.localPlayers()
end

-- =====================================================================
-- Registro de parches
-- =====================================================================

-- Aplica un enganche (fn devuelve true/nil si quedo puesto, false + motivo si no aplica).
function LXAS.apply(side, name, fn)
    LXAS.report[side] = LXAS.report[side] or { ok = 0, total = 0, failed = {} }
    local r = LXAS.report[side]
    r.total = r.total + 1
    local ok, result, why = pcall(fn)
    if ok and result ~= false then
        r.ok = r.ok + 1
        return true
    end
    local reason = ok and tostring(why or "no encontrado") or tostring(result)
    r.failed[#r.failed + 1] = name .. " (" .. reason .. ")"
    log("parche '" .. name .. "' NO aplicado: " .. reason .. " (A-Life sigue como el original en esa parte)")
    return false
end

function LXAS.summary(side)
    local r = LXAS.report[side]
    if r == nil then return end
    if #r.failed > 0 then
        log(side .. ": " .. r.ok .. "/" .. r.total .. " parches OK. Omitidos: " .. table.concat(r.failed, "; "))
    else
        log(side .. ": " .. r.ok .. "/" .. r.total .. " parches OK")
    end
end

-- Evita envolver dos veces la misma funcion (por ejemplo, si un archivo se recarga).
function LXAS.wrapOnce(tbl, key, makeWrapper)
    if type(tbl) ~= "table" then return false, "modulo no existe" end
    local original = tbl[key]
    if type(original) ~= "function" then return false, key .. " no existe" end
    LXAS._wrapped = LXAS._wrapped or {}
    local marks = LXAS._wrapped[tbl]
    if marks == nil then
        marks = {}
        LXAS._wrapped[tbl] = marks
    end
    if marks[key] == original then return true end -- ya es nuestro envoltorio
    local wrapper = makeWrapper(original)
    if type(wrapper) ~= "function" then return false, "envoltorio invalido" end
    tbl[key] = wrapper
    marks[key] = wrapper
    return true
end
