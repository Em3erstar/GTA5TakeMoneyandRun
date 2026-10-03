--- config_features.lua(Config.FeaturePreset)를 실제 Config.Features/Config.Timeline/
--- Config.Circle에 적용하고, 게임 시작 전(PRE_GAME/ENDED)에 SERVER_OWNER가 즉석에서
--- 시각을 조정할 수 있는 `/featuretime` 명령을 제공한다.
---
--- on/off는 이미 `/feature`(server/features.lua)로 언제든 바꿀 수 있어 여기서 다루지
--- 않는다. 여기서 새로 다루는 것은 "언제 발동할지"(분 단위 시각)뿐이다 — RUNNING
--- 중에는 이미 지나간 MarkTimelineEventOnce 플래그를 되돌릴 방법이 없으므로, 시각
--- 변경은 세션이 없거나(PRE_GAME) 끝난(ENDED) 상태로 제한한다.

local U = SecretBagMode.Util

--- Config.FeaturePreset의 각 필드가 실제로 어느 Config 경로에 대응하는지의 지도.
--- 점(.) 구분 경로 문자열로 표현해 Config.Circle.circle1500.atMinute처럼 중첩된
--- 경로도 같은 방식으로 다룰 수 있게 했다.
local timingFieldPath = {
    cheapAppraiser = {
        spawnAt = 'Timeline.cheapAppraiserSpawnAt',
    },
    -- 사용자 확정 규칙(2026): 진짜 감정사는 디스폰 없이 영구 유지되어 End 필드가 없고,
    -- 두 번째 진짜 감정사는 완전히 삭제됐다.
    trueAppraiser = {
        spawnAt = 'Timeline.trueAppraiserSpawnAt',
        finalTrueStart = 'Timeline.finalTrueStart',
    },
    forger = {
        spawnAt = 'Timeline.forgerSpawnAt',
    },
    police = {
        ambientStartAt = 'Timeline.policeAmbientStartAt',
        infoShutdownAt = 'Timeline.policeInfoShutdownAt',
        despawnAt = 'Timeline.policeDespawnAt',
    },
    trace = {
        bumpAt = 'Timeline.traceBumpAt',
    },
    liveReveal = {
        circle1500At = 'Circle.circle1500.atMinute',
        circle100At = 'Circle.circle100.atMinute',
        finalZonePreviewAt = 'Circle.finalZonePreview.atMinute',
    },
    -- FinalZoneCheck 최초 실행 시각/재시도 간격. 원래 timingFieldPath에 빠져 있어
    -- /featuretime으로 손댈 수 없었다(사용자 요청: "수동으로 이벤트 시간들을 손 볼 수 있게").
    finalCheck = {
        firstAt = 'Timeline.finalCheckFirstAt',
        intervalMin = 'Timeline.finalCheckIntervalMin',
    },
}

local function splitPath(path)
    local parts = {}
    for part in path:gmatch('[^.]+') do
        table.insert(parts, part)
    end
    return parts
end

local function setConfigPath(path, value)
    local parts = splitPath(path)
    local t = Config
    for i = 1, #parts - 1 do
        t = t[parts[i]]
        if type(t) ~= 'table' then return false end
    end
    t[parts[#parts]] = value
    return true
end

local function getConfigPath(path)
    local parts = splitPath(path)
    local t = Config
    for i = 1, #parts - 1 do
        t = t[parts[i]]
        if type(t) ~= 'table' then return nil end
    end
    return t[parts[#parts]]
end

--- Config.FeaturePreset 전체를 Config.Features/Config.Timeline/Config.Circle에 반영한다.
--- 리소스 시작 시 1회 자동 호출되며, `/featurereset`으로 수동 재적용도 가능하다
--- (런타임 중 /featuretime으로 바꾼 값을 파일 기본값으로 되돌리고 싶을 때).
local function applyFeaturePreset()
    if not Config.FeaturePreset then return end
    for name, preset in pairs(Config.FeaturePreset) do
        if preset.enabled ~= nil and Config.Features[name] ~= nil then
            Config.Features[name] = preset.enabled
        end
        local fieldPaths = timingFieldPath[name]
        if fieldPaths then
            for presetField, configPath in pairs(fieldPaths) do
                if preset[presetField] ~= nil then
                    setConfigPath(configPath, preset[presetField])
                end
            end
        end
    end
end

SecretBagMode.ApplyFeaturePreset = applyFeaturePreset

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    applyFeaturePreset()
end)

--- 게임 시작 전(세션 없음 또는 ENDED+cleanup 완료)에만 시각 변경을 허용한다.
local function requireBeforeGame(source)
    if not SecretBagMode.CanStartGame() then
        U.NotifyPlayer(source, '게임이 진행 중일 때는 시각을 바꿀 수 없습니다 (게임 시작 전에만 가능).')
        return false
    end
    return true
end

RegisterCommand('featuretime', function(source, args)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end
    if not requireBeforeGame(source) then return end

    local name, field, minutesArg = args[1], args[2], args[3]
    local fieldPaths = name and timingFieldPath[name]
    if not fieldPaths then
        U.NotifyPlayer(source, '사용법: /featuretime <이름> <필드> <분> (목록은 /featuretimes)')
        return
    end

    local configPath = field and fieldPaths[field]
    if not configPath then
        local fieldNames = {}
        for f in pairs(fieldPaths) do table.insert(fieldNames, f) end
        table.sort(fieldNames)
        U.NotifyPlayer(source, ('%s의 필드 목록: %s'):format(name, table.concat(fieldNames, ', ')))
        return
    end

    -- Lua 5.4의 string.format('%d', ...)는 정수로 정확히 표현 안 되는 값(예: 5.5)을 주면
    -- "number has no integer representation" 런타임 에러를 던진다 — 아래 %d 포맷 호출 전에
    -- 정수인지 반드시 확인해야 한다 (그냥 소수를 받아주면 여기서 그대로 에러가 났었다).
    local minutes = tonumber(minutesArg)
    if not minutes or minutes < 0 or minutes ~= math.floor(minutes) then
        U.NotifyPlayer(source, '분은 0 이상의 정수로 입력해야 합니다 (예: 5, 90).')
        return
    end

    setConfigPath(configPath, minutes)
    U.NotifyPlayer(source, ('%s.%s -> %d분으로 설정했습니다.'):format(name, field, minutes))
end, false)

RegisterCommand('featuretimes', function(source)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end

    print('[SecretBag] 발동 시각 설정:')
    U.NotifyPlayer(source, '발동 시각(분) 설정 (서버 콘솔에도 출력):')
    local names = {}
    for name in pairs(timingFieldPath) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local fieldNames = {}
        for f in pairs(timingFieldPath[name]) do table.insert(fieldNames, f) end
        table.sort(fieldNames)
        for _, field in ipairs(fieldNames) do
            local value = getConfigPath(timingFieldPath[name][field])
            local line = ('  %s.%s = %s'):format(name, field, tostring(value))
            print('[SecretBag] ' .. line)
            U.NotifyPlayer(source, line)
        end
    end
end, false)

--- config_features.lua의 파일 기본값으로 되돌린다 (실수로 /featuretime을 잘못 쓴 경우 등).
RegisterCommand('featurereset', function(source)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end
    if not requireBeforeGame(source) then return end

    applyFeaturePreset()
    U.NotifyPlayer(source, 'config_features.lua의 프리셋 값으로 전부 되돌렸습니다.')
end, false)
