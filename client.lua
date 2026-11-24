local EVOCore = exports["evolution-core"]:GetCoreObject()

local DEFAULT_SPAWN_HEALTH = 600
local MIN_SAFE_SPAWN_HEALTH = 300
local POST_SPAWN_HEALTH_GUARD_MS = 15000
local SELECTOR_STREAMING_WARMUP_MS = 1250

local hasFocus = false
local locations = false
local fading = false
local selectorOpening = false
local spawnInProgress = false
local playerLoadEventSent = false
local current = {}
local activeCamera = nil
local spawnLoadSceneStarted = false
local spawnStreamingKey = nil
local playerData = {}
local PlayerJob = {}
local pendingSpawn = {
    isNew = false,
    appearance = nil,
    clearDeathState = false
}

local SetEntityVisibleRedM, SetEntityCollisionRedM, FreezeEntityPositionRedM

local function clearPreviousStreamingOverrides()
    if spawnLoadSceneStarted then
        pcall(function()
            Citizen.InvokeNative(0x5A8B01199C3E79C3)
        end)
        spawnLoadSceneStarted = false
    end
    spawnStreamingKey = nil

    if NewLoadSceneStop then
        pcall(NewLoadSceneStop)
    end

    if ClearHdArea then
        pcall(ClearHdArea)
    end

    if ClearFocus then
        ClearFocus()
    end
end

local function beginSpawnStreaming(x, y, z, radius)
    if not x or not y or not z then
        return false
    end

    local focusKey = ("%.1f:%.1f:%.1f"):format(x, y, z)
    if spawnLoadSceneStarted and spawnStreamingKey == focusKey then
        RequestCollisionAtCoord(x, y, z)
        return true
    end

    if spawnLoadSceneStarted then
        pcall(function()
            Citizen.InvokeNative(0x5A8B01199C3E79C3)
        end)
    end

    if SetFocusPosAndVel then
        pcall(SetFocusPosAndVel, x, y, z, 0.0, 0.0, 0.0)
    end
    if SetHdArea then
        pcall(SetHdArea, x, y, z, tonumber(radius) or 100.0)
    end

    pcall(function()
        Citizen.InvokeNative(0x513F8AA5BF2F17CF, x, y, z, tonumber(radius) or 100.0, 20)
    end)
    spawnLoadSceneStarted = true
    spawnStreamingKey = focusKey
    RequestCollisionAtCoord(x, y, z)
    return true
end

local function waitForSpawnStreamingScene(timeoutMs)
    if not spawnLoadSceneStarted then
        return true
    end

    local requestedTimeout = tonumber(timeoutMs) or SELECTOR_STREAMING_WARMUP_MS
    local timeoutAt = GetGameTimer() + math.min(requestedTimeout, SELECTOR_STREAMING_WARMUP_MS)
    while GetGameTimer() < timeoutAt do
        local loaded = false
        local ok, result = pcall(function()
            return Citizen.InvokeNative(0x0909F71B5C070797)
        end)
        loaded = ok and (result == true or result == 1)
        if loaded then
            return true
        end
        Wait(50)
    end

    -- O status deste native nao e consistente entre artifacts RedM. Foco,
    -- colisao e o warmup acima continuam sendo as barreiras efetivas.
    return true
end

local function setAntiCheatProtection(reason, duration)
    if GetResourceState("evolution-anticheat") ~= "started" then
        return
    end

    TriggerEvent("anticheat:client:setTemporaryProtection", reason, duration)
    TriggerServerEvent("anticheat:setTemporaryProtection", reason, duration)
end

local function setSpawnRoutingBucket(usePrivateBucket)
    if GetResourceState("evolution-appearance") ~= "started" then
        print("[evolution-spawnselector] evolution-appearance indisponivel para controlar o bucket.")
        return false
    end

    local ok, result = pcall(function()
        return exports["evolution-appearance"]:SetPrivateRoutingBucket(usePrivateBucket == true, 5000)
    end)
    if not ok or result ~= true then
        print(("[evolution-spawnselector] Falha ao alterar bucket do spawn: %s"):format(tostring(result)))
        return false
    end

    return true
end

local function setSpawnTransitionState(active)
    if LocalPlayer and LocalPlayer.state then
        if active then
            -- Ownership atomico: o multichar mantem o ped oculto ate este
            -- recurso assumir o fluxo, impedindo que terceiros o revelem.
            LocalPlayer.state:set("evoSpawnInProgress", true, true)
            LocalPlayer.state:set("evoCharacterSelectorActive", false, false)
            TriggerEvent("evolution-multicharacter:client:spawnFlowStarted")
        else
            LocalPlayer.state:set("evoSpawnInProgress", false, true)
            LocalPlayer.state:set("evoCharacterSelectorActive", false, false)
            LocalPlayer.state:set("evoAnimationInteractionsBlocked", false, false)
            TriggerEvent("evolution-animations:client:SetInteractionBlocked", false)
        end
    end
end

local function isTruthy(value)
    return value == true or value == 1 or value == "1" or value == "true"
end

local function waitForPlayerData(timeoutMs)
    local timeoutAt = GetGameTimer() + (tonumber(timeoutMs) or 15000)
    local data = EVOCore.Functions.GetPlayerData()

    while GetGameTimer() < timeoutAt do
        if data and data.charinfo and data.citizenid then
            return data
        end

        Wait(100)
        data = EVOCore.Functions.GetPlayerData()
    end

    return data or {}
end

local function normalizeCoords4(coords4, fallbackPed)
    if coords4 then
        if type(coords4) == "string" then
            local nums = {}
            for n in coords4:gmatch("[%-+]?%d*%.?%d+") do
                nums[#nums + 1] = tonumber(n)
                if #nums >= 4 then
                    break
                end
            end

            if nums[1] and nums[2] and nums[3] then
                return nums[1], nums[2], nums[3], nums[4] or 0.0
            end
        elseif type(coords4) == "table" or type(coords4) == "vector3" or type(coords4) == "vector4" then
            local x = tonumber(coords4.x) or tonumber(coords4[1])
            local y = tonumber(coords4.y) or tonumber(coords4[2])
            local z = tonumber(coords4.z) or tonumber(coords4[3])
            local w = tonumber(coords4.w) or tonumber(coords4[4]) or 0.0

            if x and y and z then
                return x, y, z, w
            end
        end
    end

    if fallbackPed and fallbackPed ~= 0 then
        local coords = GetEntityCoords(fallbackPed)
        return coords.x, coords.y, coords.z, GetEntityHeading(fallbackPed)
    end
end

local function normalizePosition(pos)
    local x, y, z = normalizeCoords4(pos)
    return x, y, z
end

local function waitForSpawnCollision(ped, x, y, z, timeoutMs)
    local timeoutAt = GetGameTimer() + (tonumber(timeoutMs) or 8000)

    while GetGameTimer() < timeoutAt do
        RequestCollisionAtCoord(x, y, z)
        RequestCollisionAtCoord(x, y, z + 1.0)

        if HasCollisionLoadedAroundEntity(ped) then
            return true
        end

        Wait(50)
    end

    return HasCollisionLoadedAroundEntity(ped)
end

local function resolveSafeSpawnZ(ped, x, y, z)
    if type(GetGroundZAndNormalFor_3dCoord) ~= "function" then
        return z + 0.75
    end

    local probes = {
        z + 120.0,
        z + 80.0,
        z + 50.0,
        z + 25.0,
        z + 10.0,
        z + 2.0,
        z
    }

    for _, probeZ in ipairs(probes) do
        RequestCollisionAtCoord(x, y, probeZ)

        for _ = 1, 4 do
            local ok, hasGround, groundZ = pcall(GetGroundZAndNormalFor_3dCoord, x, y, probeZ)

            if ok
                and hasGround
                and type(groundZ) == "number"
                and groundZ > -100.0
                and groundZ < probeZ + 5.0 then
                return groundZ + 0.75
            end

            Wait(25)
        end
    end

    return z + 0.75
end

local function getSpawnMaxHealth(ped)
    if not ped or ped == 0 then
        return DEFAULT_SPAWN_HEALTH
    end

    local maxHealth = tonumber(GetEntityMaxHealth(ped)) or 0
    if maxHealth < DEFAULT_SPAWN_HEALTH then
        SetEntityMaxHealth(ped, DEFAULT_SPAWN_HEALTH)
        maxHealth = tonumber(GetEntityMaxHealth(ped)) or DEFAULT_SPAWN_HEALTH
    end

    if maxHealth < DEFAULT_SPAWN_HEALTH then
        return DEFAULT_SPAWN_HEALTH
    end

    return math.floor(maxHealth)
end

local function sanitizeSpawnHealth(value, ped, forceFullHealth)
    local maxHealth = getSpawnMaxHealth(ped)
    local health = tonumber(value)

    if forceFullHealth or not health or health < MIN_SAFE_SPAWN_HEALTH then
        return maxHealth, true
    end

    if health > maxHealth then
        return maxHealth, true
    end

    return math.floor(health), false
end

local function ensureSpawnPedAlive(ped, coords4, requestedHealth, clearDeathState)
    if not ped or ped == 0 then
        ped = PlayerPedId()
    end

    if not ped or ped == 0 then
        return ped, requestedHealth or DEFAULT_SPAWN_HEALTH, false
    end

    local x, y, z, w = normalizeCoords4(coords4, ped)
    local wasDead = IsEntityDead(ped) or (tonumber(GetEntityHealth(ped)) or 0) <= 0

    if wasDead and x and y and z then
        NetworkResurrectLocalPlayer(x, y, z, w or GetEntityHeading(ped), true, false)
        Wait(100)
        ped = PlayerPedId()
    end

    local health, repairedHealth = sanitizeSpawnHealth(requestedHealth or GetEntityHealth(ped), ped, clearDeathState or wasDead)

    SetEntityInvincible(ped, false)
    ClearPedBloodDamage(ped)
    SetAttributeCoreValue(ped, 0, 100)
    SetAttributeCoreValue(ped, 1, 100)
    SetEntityHealth(ped, health)
    LocalPlayer.state:set("health", health, true)

    if clearDeathState or wasDead or repairedHealth then
        TriggerEvent("evolution-medic:client:resetDeathState", true)
        TriggerServerEvent("EVOCoreServer:SetMetaData", "isdead", false)
        TriggerServerEvent("EVOCoreServer:SetMetaData", "health", health)
        LocalPlayer.state:set("isDead", false, true)
    end

    return ped, health, wasDead or repairedHealth
end

local placePedAtSpawn

local function startPostSpawnHealthGuard(coords4, desiredHealth)
    CreateThread(function()
        local timeoutAt = GetGameTimer() + POST_SPAWN_HEALTH_GUARD_MS
        local lastPed = PlayerPedId()
        local safeX, safeY, safeZ = normalizeCoords4(coords4, lastPed)

        while GetGameTimer() < timeoutAt do
            Wait(750)

            local ped = PlayerPedId()
            if ped and ped ~= 0 then
                local health = tonumber(GetEntityHealth(ped)) or 0
                local coords = GetEntityCoords(ped)
                local belowSpawn = safeZ and coords and coords.z < (safeZ - 8.0)
                getSpawnMaxHealth(ped)

                if belowSpawn then
                    local correctedCoords = placePedAtSpawn(ped, coords4)
                    if correctedCoords then
                        coords4 = correctedCoords
                        safeX, safeY, safeZ = normalizeCoords4(coords4, PlayerPedId())
                    end
                    lastPed = PlayerPedId()
                elseif ped ~= lastPed or IsEntityDead(ped) or health <= 0 or health < MIN_SAFE_SPAWN_HEALTH then
                    ped = ensureSpawnPedAlive(ped, coords4, desiredHealth or DEFAULT_SPAWN_HEALTH, true)
                    lastPed = ped
                else
                    LocalPlayer.state:set("health", health, true)
                    LocalPlayer.state:set("isDead", false, true)
                    lastPed = ped
                end
            end
        end
    end)
end

placePedAtSpawn = function(ped, coords4)
    if not ped or not coords4 then
        return nil
    end

    local x, y, z, w = normalizeCoords4(coords4, ped)
    if not x or not y or not z then
        return nil
    end

    FreezeEntityPosition(ped, true)
    SetEntityVelocity(ped, 0.0, 0.0, 0.0)
    SetEntityCoordsNoOffset(ped, x, y, z + 0.75, true, true, true)
    SetEntityHeading(ped, w)

    beginSpawnStreaming(x, y, z + 1.0, 100.0)
    waitForSpawnStreamingScene(6000)
    waitForSpawnCollision(ped, x, y, z + 0.75, 8000)
    local safeZ = resolveSafeSpawnZ(ped, x, y, z)

    pcall(function()
        Citizen.InvokeNative(0x203BEFFDBE12E96A, ped, vector4(x, y, safeZ, w), false, false, false)
    end)
    SetEntityCoordsNoOffset(ped, x, y, safeZ, true, true, true)
    SetEntityHeading(ped, w)
    SetPedDesiredHeading(ped, w)

    waitForSpawnCollision(ped, x, y, safeZ, 8000)
    SetEntityCoordsNoOffset(ped, x, y, safeZ, true, true, true)
    SetEntityVelocity(ped, 0.0, 0.0, 0.0)

    SetEntityVisibleRedM(ped, true)
    SetEntityAlpha(ped, 255, false)
    Citizen.InvokeNative(0x9587913B9E772D29, ped, true)
    SetEntityCollisionRedM(ped, true)
    Wait(250)
    FreezeEntityPositionRedM(ped, false)

    Wait(350)
    local currentCoords = GetEntityCoords(ped)
    if currentCoords and currentCoords.z < safeZ - 3.0 then
        FreezeEntityPositionRedM(ped, true)
        SetEntityCoordsNoOffset(ped, x, y, safeZ + 0.35, true, true, true)
        SetEntityVelocity(ped, 0.0, 0.0, 0.0)
        waitForSpawnCollision(ped, x, y, safeZ + 0.35, 4000)
        SetEntityVisibleRedM(ped, true)
        SetEntityAlpha(ped, 255, false)
        SetEntityCollisionRedM(ped, true)
        Wait(250)
        FreezeEntityPositionRedM(ped, false)
        safeZ = safeZ + 0.35
    end

    return vector4(x, y, safeZ, w)
end

local function resolveAppearancePayload(appearancePayload)
    if type(appearancePayload) == "table" then
        if type(appearancePayload.skin) == "table" then
            return appearancePayload
        end

        if type(appearancePayload.previewAppearance) == "table" then
            return appearancePayload.previewAppearance
        end
    elseif type(appearancePayload) == "string" and appearancePayload ~= "" then
        local ok, decoded = pcall(json.decode, appearancePayload)
        if ok and type(decoded) == "table" then
            if type(decoded.skin) == "table" then
                return decoded
            end

            return {
                skin = decoded,
                clothes = {}
            }
        end
    end

    return nil
end

local function applyAppearanceForSpawn(appearancePayload, isNew)
    local directAppearance = resolveAppearancePayload(appearancePayload)
    local customPed = directAppearance and directAppearance.current_ped
        or (type(appearancePayload) == "table" and appearancePayload.current_ped or nil)

    if customPed and customPed ~= "" and customPed ~= "mp_male" and customPed ~= "mp_female" then
        local model = type(customPed) == "number" and customPed or (tonumber(customPed) or joaat(customPed))
        if model and model ~= 0
            and (not IsModelInCdimage or IsModelInCdimage(model))
            and (not IsModelValid or IsModelValid(model)) then
            RequestModel(model)
            local timeoutAt = GetGameTimer() + 10000
            while not HasModelLoaded(model) and GetGameTimer() < timeoutAt do
                Wait(25)
            end

            if HasModelLoaded(model) then
                SetPlayerModel(PlayerId(), model)
                Wait(250)
                local ped = PlayerPedId()
                Citizen.InvokeNative(0x283978A15512B2FE, ped, true)
                SetEntityVisibleRedM(ped, true)
                SetEntityAlpha(ped, 255, false)
                SetEntityCollisionRedM(ped, true)
                SetModelAsNoLongerNeeded(model)
                return true
            end

            SetModelAsNoLongerNeeded(model)
            print(('[evolution-spawnselector] Timeout ao carregar PED customizado: %s'):format(tostring(customPed)))
        else
            print(('[evolution-spawnselector] PED customizado invalido: %s'):format(tostring(customPed)))
        end
    end

    if isNew and not directAppearance then
        if GetResourceState("evolution-appearance") == "started" then
            local ok, result = pcall(function()
                return exports["evolution-appearance"]:ApplyPendingSpawnAppearanceNow()
            end)

            if ok and result == true then
                Wait(500)
                return true
            end
        end
    end

    if GetResourceState("evolution-appearance") == "started"
        and directAppearance
        and type(directAppearance.skin) == "table"
        and next(directAppearance.skin) ~= nil then
        local ok, result = pcall(function()
            return exports["evolution-appearance"]:ApplySpawnAppearanceNow(
                directAppearance.skin,
                directAppearance.clothes or {}
            )
        end)

        if ok and result == true then
            Wait(250)
            return true
        end

        print(("[evolution-spawnselector] Falha ao aplicar payload direto de aparencia: %s"):format(tostring(result)))
    end

    if GetResourceState("evolution-appearance") == "started" then
        local ok, result = pcall(function()
            return exports["evolution-appearance"]:LoadSavedAppearanceNow()
        end)

        if ok and result == true then
            Wait(250)
            return true
        end

        print(("[evolution-spawnselector] Falha ao carregar aparencia salva: %s"):format(tostring(result)))
    end

    -- Compatibilidade com versoes antigas do appearance. O comando pode ser
    -- bloqueado durante invencibilidade, por isso nao e mais o caminho principal.
    ExecuteCommand("loadskin")
    Wait(2000)
    return false
end

local function finalizeSpawn(reason, coords4, desiredHealth, clearDeathState)
    local ped, health = ensureSpawnPedAlive(PlayerPedId(), coords4, desiredHealth, clearDeathState)

    FreezeEntityPositionRedM(ped, true)
    setSpawnRoutingBucket(false)
    clearPreviousStreamingOverrides()
    coords4 = placePedAtSpawn(ped, coords4) or coords4
    waitForSpawnStreamingScene(6000)
    ped, health = ensureSpawnPedAlive(PlayerPedId(), coords4, health, clearDeathState)
    SetEntityVisibleRedM(ped, true)
    SetEntityAlpha(ped, 255, false)
    SetEntityCollisionRedM(ped, true)
    FreezeEntityPositionRedM(ped, false)
    clearPreviousStreamingOverrides()
    ShutdownLoadingScreen()
    DoScreenFadeIn(1000)
    setAntiCheatProtection(reason, 15000)

    if not playerLoadEventSent and LocalPlayer.state.isLoggedIn ~= true then
        playerLoadEventSent = true
        TriggerServerEvent("EVOCoreServer:OnPlayerLoaded")
        TriggerEvent("EVOCoreClient:OnPlayerLoaded")
    else
        playerLoadEventSent = true
    end

    startPostSpawnHealthGuard(coords4, health)
    setSpawnTransitionState(false)
end

local function cleanupCamera()
    if activeCamera then
        SetCamActive(activeCamera, false)
        DestroyCam(activeCamera, true)
        activeCamera = nil
    elseif current and current.camera then
        SetCamActive(current.camera, false)
        DestroyCam(current.camera, true)
    end

    RenderScriptCams(false, true, 1000, true, true)
end

local function resetSelectorState()
    locations = nil
    playerData = nil
    hasFocus = false
    fading = false
    selectorOpening = false
    current = {}
    pendingSpawn = {
        isNew = false,
        appearance = nil,
        clearDeathState = false
    }
end

local function cleanupSpawnSelectorRuntime(restorePlayer)
    cleanupCamera()
    clearPreviousStreamingOverrides()
    SendNUIMessage({ event = "hide" })
    SetNuiFocus(false, false)

    hasFocus = false
    fading = false
    selectorOpening = false
    spawnInProgress = false
    resetSelectorState()

    if restorePlayer ~= false then
        local ped = PlayerPedId()
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            SetEntityVisibleRedM(ped, true)
            SetEntityAlpha(ped, 255, false)
            FreezeEntityPositionRedM(ped, false)
            SetEntityCollisionRedM(ped, true)
        end
    end

    setSpawnRoutingBucket(false)
    setSpawnTransitionState(false)
end

local function serializeLocationsForNui()
    local payload = {}

    if type(locations) ~= "table" then
        return payload
    end

    for index, location in ipairs(locations) do
        payload[#payload + 1] = {
            index = index,
            name = location.name,
            label = location.label,
            region = location.region or "Fronteira",
            image = location.image or "locations/valentine.jpg",
            last = location.last == true
        }
    end

    return payload
end

SetEntityVisibleRedM = function(entity, toggle)
    Citizen.InvokeNative(0xD8C3BE3EE94CAF2D, entity, toggle)
end

SetEntityCollisionRedM = function(entity, toggle)
    Citizen.InvokeNative(0x1A9205C1B9EE827F, entity, toggle, toggle)
end

FreezeEntityPositionRedM = function(entity, freeze)
    FreezeEntityPosition(entity, freeze)
end

function BuildCameraProperties(vector)
    return vector - vector3(-26.334, -4.58, -17.80), vector3(-32.76, 4.26, 100.72)
end

function BuildLocations(data)
    local results = {}
    local baseLocations = Settings.Locations or {}

    if data then
        if data.position and not data.jail then
            local x, y, z, w = normalizeCoords4(data.position)
            if x and y and z then
                local coords, rot = BuildCameraProperties(vector3(x, y, z))
                results[#results + 1] = {
                    name = "last",
                    label = "Ultimo Local",
                    region = "Registro salvo",
                    image = "locations/valentine.jpg",
                    coords = coords,
                    rot = rot,
                    spawn = vector4(x, y, z, w or 100.0),
                    last = true
                }
            end
        end

        local hasPrisonLocation = false
        for i = 1, #baseLocations do
            if baseLocations[i] and baseLocations[i].name == "prison" then
                hasPrisonLocation = true
                break
            end
        end

        for i = 1, #baseLocations do
            local location = baseLocations[i]
            local jobOk = not location.job or location.job == PlayerJob.name
            local jailOk = (location.name == "prison" and data.jail) or (not data.jail and jobOk) or (data.jail and not hasPrisonLocation and jobOk)

            if jailOk then
                results[#results + 1] = location
            end
        end
    end

    return results
end

function BuildCamera(index)
    if fading or spawnInProgress then
        return false
    end

    current = index and locations[index]
    if not current then
        return false
    end

    current.index = index
    fading = true
    local streamingStartedAt = GetGameTimer()

    local ped = PlayerPedId()

    SendNUIMessage({ event = "cameraBusy", busy = true })
    DoScreenFadeOut(0)
    clearPreviousStreamingOverrides()
    SetEntityVisibleRedM(ped, false)
    SetEntityCoordsNoOffset(ped, current.spawn.x, current.spawn.y, current.spawn.z, false, false, false)
    SetEntityHeading(ped, current.spawn.w)
    FreezeEntityPositionRedM(ped, true)
    SetEntityCollisionRedM(ped, false)
    beginSpawnStreaming(current.coords.x, current.coords.y, current.coords.z, 150.0)

    RequestCollisionAtCoord(current.spawn.x, current.spawn.y, current.spawn.z)
    RequestCollisionAtCoord(current.coords.x, current.coords.y, current.coords.z)

    if activeCamera then
        SetCamActive(activeCamera, false)
        DestroyCam(activeCamera, true)
        activeCamera = nil
    end

    current.camera = CreateCameraWithParams(
        "DEFAULT_SCRIPTED_CAMERA",
        current.coords.x, current.coords.y, current.coords.z,
        current.rot.x, current.rot.y, current.rot.z,
        60.00, false, 0
    )

    SetCamActive(current.camera, true)
    activeCamera = current.camera
    RenderScriptCams(true, false, 1, true, true)

    SendNUIMessage({
        event = "update",
        name = current.name,
        label = current.label,
        region = current.region or "Fronteira",
        image = current.image or "locations/valentine.jpg",
        index = index,
        total = #locations,
        locations = serializeLocationsForNui()
    })

    local timeout = 500
    while not HasCollisionLoadedAroundEntity(ped) and timeout ~= 0 do
        timeout = timeout - 1
        Wait(10)
    end

    if not waitForSpawnStreamingScene(6000) then
        print(("[evolution-spawnselector] Streaming da camera %s excedeu o tempo limite."):format(tostring(current.name)))
    end

    local remainingWarmup = SELECTOR_STREAMING_WARMUP_MS - (GetGameTimer() - streamingStartedAt)
    if remainingWarmup > 0 then
        Wait(remainingWarmup)
    end

    DoScreenFadeIn(1000)
    fading = false
    SendNUIMessage({ event = "cameraBusy", busy = false, index = index })
    return true
end

function BuildSelector(data, isNew, appearancePayload)
    if spawnInProgress then
        return
    end

    selectorOpening = false
    locations = BuildLocations(data)
    playerData = data
    hasFocus = true
    pendingSpawn = {
        isNew = isNew == true,
        appearance = appearancePayload,
        clearDeathState = isNew == true or data.clearDeathState == true
    }

    if type(locations) ~= "table" or #locations == 0 then
        locations = Settings.Locations or {}
    end

    if type(locations) ~= "table" or #locations == 0 then
        TriggerEvent("evolution-spawnselector:client:spawnLastNoUI", data, isNew, appearancePayload)
        return
    end

    BuildCamera(1)
    SetNuiFocus(true, true)
    SendNUIMessage({
        event = "show",
        total = #locations,
        active = 1,
        locations = serializeLocationsForNui()
    })
end

local randomSeeded = false

local function getRandomNewPlayerSpawn()
    local spawns = Settings.NewPlayerSpawns
    local coreConfig = EVOCore and EVOCore.Config or {}

    if (type(spawns) ~= "table" or #spawns == 0) and type(coreConfig.DefaultSpawns) == "table" then
        spawns = coreConfig.DefaultSpawns
    end

    if type(spawns) ~= "table" or #spawns == 0 then
        return coreConfig.DefaultSpawn or Settings.SpawnLocation
    end

    if not randomSeeded then
        math.randomseed(GetGameTimer() + PlayerPedId())
        randomSeeded = true
    end

    return spawns[math.random(1, #spawns)] or Settings.SpawnLocation
end

local function buildRuntimeSpawnData(data, isNew)
    local player = waitForPlayerData()
    local metadata = player.metadata or {}
    local injail = metadata.injail
    local isJailed = injail == true or (type(injail) == "number" and injail > 0) or (type(injail) == "string" and tonumber(injail) and tonumber(injail) > 0)
    local savedPosition = player.position or (type(data) == "table" and data.position) or Settings.SpawnLocation
    local currentHealth = tonumber(metadata.health) or DEFAULT_SPAWN_HEALTH
    local wasDead = isTruthy(metadata.isdead)
    local skipSavePosition = false

    if isNew then
        savedPosition = getRandomNewPlayerSpawn()
        currentHealth = DEFAULT_SPAWN_HEALTH
        wasDead = true
    elseif Settings.ForceSafeSpawnOnLogin == true and not isJailed then
        savedPosition = Settings.SpawnLocation
        skipSavePosition = true
    end

    return {
        position = savedPosition,
        jail = isJailed and true or false,
        currentHealth = currentHealth,
        clearDeathState = wasDead or isNew == true,
        skipSavePosition = skipSavePosition
    }
end

local function runSpawnAt(coords4, isNew, appearancePayload, selectedData)
    if spawnInProgress then
        return false
    end

    spawnInProgress = true
    selectorOpening = false

    local ok, result = xpcall(function()
        local ped = PlayerPedId()
        local desiredHealth = (selectedData and selectedData.currentHealth) or DEFAULT_SPAWN_HEALTH
        local clearDeathState = (selectedData and selectedData.clearDeathState) or isNew == true

        DoScreenFadeOut(350)
        Wait(650)

        cleanupCamera()
        clearPreviousStreamingOverrides()

        SendNUIMessage({ event = "hide" })
        SetNuiFocus(false, false)
        hasFocus = false

        ped, desiredHealth = ensureSpawnPedAlive(ped, coords4, desiredHealth, clearDeathState)
        coords4 = placePedAtSpawn(ped, coords4) or coords4

        local appearanceApplied = applyAppearanceForSpawn(appearancePayload, isNew)
        if appearanceApplied ~= true then
            print("[evolution-spawnselector] Spawn continuou sem confirmacao de aparencia aplicada.")
        end

        ped = PlayerPedId()
        ped, desiredHealth = ensureSpawnPedAlive(ped, coords4, desiredHealth, clearDeathState)
        coords4 = placePedAtSpawn(ped, coords4) or coords4
        Wait(200)
        ped, desiredHealth = ensureSpawnPedAlive(PlayerPedId(), coords4, desiredHealth, clearDeathState)
        coords4 = placePedAtSpawn(ped, coords4) or coords4
        if not (selectedData and selectedData.skipSavePosition == true) then
            TriggerServerEvent("evolution-spawnselector:server:setSpawnPosition", coords4)
        end

        if selectedData and selectedData.jail then
            Wait(2000)
            TriggerEvent("evolution-prison:client:prisonclothes")
        end

        if Settings.AutoDualWield then
            Wait(2000)
            TriggerEvent("evolution-weapons:client:AutoDualWield")
        end

        resetSelectorState()
        finalizeSpawn(
            isNew and "spawn-newplayer-finished" or "spawn-existingplayer-finished",
            coords4,
            desiredHealth,
            clearDeathState
        )

        return true
    end, function(err)
        if debug and debug.traceback then
            return debug.traceback(tostring(err), 2)
        end

        return tostring(err)
    end)

    spawnInProgress = false

    if not ok then
        print(("[evolution-spawnselector] Spawn failed: %s"):format(result))
        cleanupCamera()
        clearPreviousStreamingOverrides()
        SendNUIMessage({ event = "hide" })
        SetNuiFocus(false, false)
        resetSelectorState()

        local ped = PlayerPedId()
        if ped and ped ~= 0 then
            SetEntityVisibleRedM(ped, true)
            SetEntityAlpha(ped, 255, false)
            FreezeEntityPositionRedM(ped, false)
            SetEntityCollisionRedM(ped, true)
        end

        setSpawnRoutingBucket(false)
        setSpawnTransitionState(false)
        DoScreenFadeIn(500)
        return false
    end

    return result
end

function Spawn()
    if spawnInProgress or fading or not current or not current.spawn then
        return false
    end

    TriggerServerEvent("evolution-spawnselector:server:markChosen")
    return runSpawnAt(current.spawn, pendingSpawn.isNew, pendingSpawn.appearance, playerData)
end

function SpawnLastLocation()
    if spawnInProgress or fading then
        return false
    end

    TriggerServerEvent("evolution-spawnselector:server:markChosen")

    local selectedData = playerData or buildRuntimeSpawnData(nil, pendingSpawn.isNew)
    local coords4 = selectedData.position or Settings.SpawnLocation
    return runSpawnAt(coords4, pendingSpawn.isNew, pendingSpawn.appearance, selectedData)
end

RegisterNetEvent("evolution-spawnselector:client:spawnLastNoUI", function(data, isNew, appearancePayload)
    local selectedData = buildRuntimeSpawnData(data, isNew)
    local coords4 = selectedData.position or Settings.SpawnLocation
    pendingSpawn = {
        isNew = isNew == true,
        appearance = appearancePayload,
        clearDeathState = selectedData.clearDeathState
    }

    runSpawnAt(coords4, isNew == true, appearancePayload, selectedData)
end)

local function openSpawnSelector(data, isNew, appearancePayload, forceSelector)
    if hasFocus or fading or selectorOpening or spawnInProgress then
        return
    end

    selectorOpening = true
    if not setSpawnRoutingBucket(true) then
        selectorOpening = false
        setSpawnTransitionState(false)
        return
    end
    clearPreviousStreamingOverrides()
    setSpawnTransitionState(true)
    setAntiCheatProtection(isNew and "spawn-newplayer-start" or "spawn-existingplayer-start", 60000)

    local payload = buildRuntimeSpawnData(data, isNew)

    if isNew and not forceSelector and Settings.UseSpawnSelectorForNewPlayers ~= true then
        selectorOpening = false
        TriggerEvent("evolution-spawnselector:client:spawnLastNoUI", payload, true, appearancePayload)
        return
    end

    if forceSelector then
        BuildSelector(payload, isNew, appearancePayload)
        return
    end

    EVOCore.Functions.TriggerCallback("evolution-spawnselector:server:shouldUseSelector", function(shouldUseSelector)
        if not selectorOpening or spawnInProgress or hasFocus then
            return
        end

        selectorOpening = false

        if shouldUseSelector then
            BuildSelector(payload, isNew, appearancePayload)
        else
            TriggerEvent("evolution-spawnselector:client:spawnLastNoUI", payload, isNew, appearancePayload)
        end
    end, payload)
end

RegisterNUICallback("spawn", function(_, cb)
    local spawned = Spawn()
    cb(spawned and "ok" or { busy = true })
end)

RegisterNUICallback("lastloc", function(_, cb)
    local spawned = SpawnLastLocation()
    cb(spawned and "ok" or { busy = true })
end)

RegisterNUICallback("ready", function(_, cb)
    cb("ok")
end)

RegisterNUICallback("forward", function(_, cb)
    if not fading and locations and current and current.index then
        local nextIndex = locations[current.index + 1] ~= nil and current.index + 1 or 1
        cb(BuildCamera(nextIndex) and "ok" or { busy = true })
        return
    end
    cb({ busy = true })
end)

RegisterNUICallback("backward", function(_, cb)
    if not fading and locations and current and current.index then
        local prevIndex = current.index - 1 > 0 and current.index - 1 or #locations
        cb(BuildCamera(prevIndex) and "ok" or { busy = true })
        return
    end
    cb({ busy = true })
end)

RegisterNUICallback("select", function(data, cb)
    local index = tonumber(data and data.index)
    if not fading and locations and index and locations[index] then
        cb(BuildCamera(index) and "ok" or { busy = true })
        return
    end
    cb({ busy = true })
end)

RegisterNetEvent("EVO:Client:OnPlayerLoaded")
AddEventHandler("EVO:Client:OnPlayerLoaded", function()
    local data = EVOCore.Functions.GetPlayerData()
    PlayerJob = data.job or {}
end)

RegisterNetEvent("EVO:Client:OnJobUpdate")
AddEventHandler("EVO:Client:OnJobUpdate", function(JobInfo)
    PlayerJob = JobInfo
end)

RegisterNetEvent("EVOCoreClient:OnPlayerLoaded")
AddEventHandler("EVOCoreClient:OnPlayerLoaded", function()
    playerLoadEventSent = true
    local data = EVOCore.Functions.GetPlayerData()
    PlayerJob = data.job or {}
end)

RegisterNetEvent("EVOCoreClient:OnPlayerUnload")
AddEventHandler("EVOCoreClient:OnPlayerUnload", function()
    playerLoadEventSent = false
    cleanupSpawnSelectorRuntime(true)
end)

AddEventHandler("onClientResourceStop", function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    cleanupSpawnSelectorRuntime(true)
end)

RegisterNetEvent("EVOCoreClient:OnJobUpdate")
AddEventHandler("EVOCoreClient:OnJobUpdate", function(JobInfo)
    PlayerJob = JobInfo
end)

RegisterNetEvent("evolution-spawnselector:client:setupSpawnUI")
AddEventHandler("evolution-spawnselector:client:setupSpawnUI", function(cData, isNew, appearancePayload)
    appearancePayload = resolveAppearancePayload(appearancePayload)
        or resolveAppearancePayload(cData)
    openSpawnSelector(cData, isNew == true, appearancePayload, false)
end)

RegisterNetEvent("evolution-spawn:client:setupSpawnUI")
AddEventHandler("evolution-spawn:client:setupSpawnUI", function(cData, isNew, appearancePayload)
    appearancePayload = resolveAppearancePayload(appearancePayload)
        or resolveAppearancePayload(cData)
    openSpawnSelector(cData, isNew == true, appearancePayload, false)
end)

RegisterNetEvent("evolution-spawnselector:client:show")
AddEventHandler("evolution-spawnselector:client:show", function(data)
    openSpawnSelector(data, false, nil, false)
end)

local function handleLegacySelectorOpen(data)
    if GetResourceState("nevada_spawnselector") == "started" then
        return
    end

    openSpawnSelector(data, false, nil, false)
end

RegisterNetEvent("evolution_spawnnew:show")
AddEventHandler("evolution_spawnnew:show", handleLegacySelectorOpen)

RegisterNetEvent("inf:selector:show")
AddEventHandler("inf:selector:show", handleLegacySelectorOpen)

RegisterCommand("spawn", function()
    if hasFocus or GetResourceState("nevada_spawnselector") == "started" then
        return
    end

    openSpawnSelector(nil, false, nil, true)
end, false)
