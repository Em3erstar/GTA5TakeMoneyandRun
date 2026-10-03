--- 게임 시스템 개별 on/off (사용자 요청: "이벤터와 NPC 들을 기호에 맞게 켜고 끌 수 있게
--- 해주세요. 예를 들면, 서버장 유저가 위조업자 기능을 원치 않으면 위조 업자 이벤트가
--- 완전히 사라집니다. 경찰이 정보를 주는 것을 원치 않으면 더 이상 경찰을 죽여도 정보를
--- 주지 않습니다.").
---
--- appraiser/forger/police/trace/finalzone/livereveal 각 모듈은 이미 Config.Features.*를
--- 그때그때 직접 참조하도록 되어 있다(스케줄러 스폰 조건, 이벤트 발급 분기 등). 그래서
--- 이 파일이 할 일은 두 가지뿐이다: (1) Config.Features 값 자체를 덮어쓰고,
--- (2) 끌 때 이미 스폰돼 있던 NPC/UI를 즉시 정리한다. 켤 때는 모든 요소가 각자의
--- StartScheduler 폴링 루프에서 MarkTimelineEventOnce 미소비 플래그(또는 상시 폴링) 덕에
--- 다음 tick에 알아서 "뒤늦게" 다시 스폰하므로, 여기서 켤 때 따로 호출할 것이 없다
--- (cheapAppraiser도 appraiser.lua StartScheduler로 통합되며 예외가 아니게 됐다).
---
--- 게임 시작 전 프리셋(on/off + 발동 시각)은 config_features.lua의 Config.FeaturePreset +
--- server/featurepreset.lua(`/featuretime`)를 참고.

local U = SecretBagMode.Util

local featureNames = {
    'cheapAppraiser', 'trueAppraiser', 'forger', 'police', 'policeInfoLoot', 'trace', 'liveReveal',
}
local featureNameSet = {}
for _, name in ipairs(featureNames) do
    featureNameSet[name] = true
end

local featureLabel = {
    cheapAppraiser = '싸구려 감정사',
    trueAppraiser = '진짜 감정사 (영구) / FinalTrue',
    forger = '위조업자',
    police = '경찰',
    policeInfoLoot = '경찰 처치 시 정보 강탈',
    trace = 'TraceCount(추적 핑)',
    liveReveal = '실시간/원형 위치 공개',
}

local function onDisable(name)
    if name == 'cheapAppraiser' and SecretBagMode.Appraiser and SecretBagMode.Appraiser.DespawnCheap then
        SecretBagMode.Appraiser.DespawnCheap()
    elseif name == 'trueAppraiser' and SecretBagMode.Appraiser and SecretBagMode.Appraiser.DespawnTrue then
        SecretBagMode.Appraiser.DespawnTrue()
    elseif name == 'forger' and SecretBagMode.Forger and SecretBagMode.Forger.Despawn then
        SecretBagMode.Forger.Despawn()
    elseif name == 'police' and SecretBagMode.Police and SecretBagMode.Police.DespawnAll then
        SecretBagMode.Police.DespawnAll()
    elseif name == 'trace' then
        TriggerClientEvent('secretbag:traceClearAll', -1)
    end
    -- policeInfoLoot: 스폰 개체가 없는 순수 판정 분기라 정리할 것이 없다.
    -- liveReveal: FZ.EnsureLiveReveal의 폴링 루프가 Config.Features.liveReveal을 스스로
    -- 확인해 다음 tick에 종료되며 secretbag:liveRevealClear를 브로드캐스트하므로 여기서
    -- 따로 처리할 필요가 없다.
end

--- server/debug.lua 등 다른 서버 코드에서도 재사용할 수 있도록 공개 함수로 둔다.
function SecretBagMode.SetFeatureEnabled(name, enabled)
    if not featureNameSet[name] then
        return false, 'UNKNOWN_FEATURE'
    end
    enabled = enabled and true or false
    if Config.Features[name] == enabled then
        return true -- 이미 그 상태라 아무 것도 하지 않는다.
    end
    Config.Features[name] = enabled
    if not enabled then
        onDisable(name)
    end

    -- HUD(server/hud.lua)의 "다음 이벤트"는 RUNNING 시작 시점 스냅샷이라, 중간에 기능을
    -- 껐다 켜면 그 목록이 실제 상황과 어긋난다 — 세션이 있으면 즉시 재동기화한다.
    if SecretBagMode.BroadcastTimelineSync and SecretBagMode.CurrentSession then
        SecretBagMode.BroadcastTimelineSync(SecretBagMode.CurrentSession)
    end

    return true
end

RegisterCommand('feature', function(source, args)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end

    local name = args[1]
    local modeArg = args[2]
    if not name or (modeArg ~= 'on' and modeArg ~= 'off') then
        U.NotifyPlayer(source, '사용법: /feature <이름> <on|off> (이름 목록은 /features)')
        return
    end

    local ok, err = SecretBagMode.SetFeatureEnabled(name, modeArg == 'on')
    if not ok then
        if err == 'UNKNOWN_FEATURE' then
            U.NotifyPlayer(source, ('알 수 없는 기능입니다: %s (목록은 /features)'):format(name))
        else
            U.NotifyPlayer(source, '실패: ' .. tostring(err))
        end
        return
    end

    U.NotifyPlayer(source, ('%s (%s) -> %s'):format(name, featureLabel[name] or name, modeArg == 'on' and 'ON' or 'OFF'))
end, false)

RegisterCommand('features', function(source)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end

    print('[SecretBag] 기능 상태:')
    U.NotifyPlayer(source, '기능 상태 (서버 콘솔에도 출력):')
    for _, name in ipairs(featureNames) do
        local line = ('  %s (%s): %s'):format(name, featureLabel[name], Config.Features[name] and 'ON' or 'OFF')
        print('[SecretBag] ' .. line)
        U.NotifyPlayer(source, line)
    end
end, false)
