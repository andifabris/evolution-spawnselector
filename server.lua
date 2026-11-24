local EVOCore = exports['evolution-core']:GetCoreObject()

local chosenThisRestart = {}

local function getCitizenId(src)
    local Player = EVOCore.Functions.GetPlayer(src)
    return Player and Player.PlayerData and Player.PlayerData.citizenid or nil
end

local function normalizeCoords4(coords)
    local coordsType = type(coords)
    if coordsType ~= 'table' and coordsType ~= 'vector3' and coordsType ~= 'vector4' then
        return nil
    end

    local x = tonumber(coords.x) or tonumber(coords[1])
    local y = tonumber(coords.y) or tonumber(coords[2])
    local z = tonumber(coords.z) or tonumber(coords[3])
    local w = tonumber(coords.w) or tonumber(coords[4]) or 0.0

    if not x or not y or not z then
        return nil
    end

    return {
        x = x,
        y = y,
        z = z,
        w = w
    }
end

EVOCore.Functions.CreateCallback('evolution-spawnselector:server:shouldUseSelector', function(source, cb, data)
    local citizenid = getCitizenId(source)
    if not citizenid then
        return cb(true)
    end

    local jailed = type(data) == 'table' and data.jail == true
    if jailed then
        return cb(true)
    end

    cb(chosenThisRestart[citizenid] ~= true)
end)

RegisterNetEvent('evolution-spawnselector:server:markChosen', function()
    local src = source
    local citizenid = getCitizenId(src)
    if not citizenid then
        return
    end
    chosenThisRestart[citizenid] = true
end)

RegisterNetEvent('evolution-spawnselector:server:setSpawnPosition', function(coords)
    local src = source
    local Player = EVOCore.Functions.GetPlayer(src)
    if not Player then
        return
    end

    local position = normalizeCoords4(coords)
    if not position then
        return
    end

    Player.PlayerData.position = position
    MySQL.update('UPDATE players SET position = ? WHERE citizenid = ?', {
        json.encode(position),
        Player.PlayerData.citizenid
    })
end)
