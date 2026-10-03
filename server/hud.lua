--- 상단 HUD(시계 + 다음 이벤트) 동기화. 사용자 제공 목업(상단 중앙 "00:00" 시계 + 작은
--- 안내문, 그 오른쪽에 다음 이벤트 시각/이름)을 구현한다. 실제 렌더링은 html/index.html이
--- 하고, 이 파일은 "지금이 몇 분째인지, 다음에 뭐가 남았는지"만 계산해 클라이언트에 보낸다.
---
--- 매초 브로드캐스트하지 않는다: RUNNING 시작/재접속/기능 on-off 시점에만 스냅샷
--- (elapsedMs + 남은 이벤트 목록)을 1회 보내고, 그 사이 초 단위 흐름은 각 클라이언트의
--- html/index.html이 자체 타이머(performance.now() 기준)로 채운다 — 매초 전원에게 쏘는
--- 것보다 트래픽이 훨씬 적고, HUD 표시 목적상 클라 자체 계산과 서버 값의 오차는 무시할
--- 수준이다.

local U = SecretBagMode.Util
local SessionState = SecretBagMode.SessionState

--- {field, featureName|nil, label} 형태로 정의. featureName이 있으면 Config.Features[featureName]
--- 이 꺼져 있는 동안은 목록에서 제외한다(꺼진 요소의 "다음 이벤트"를 카운트다운해봐야 실제로
--- 발동하지 않으므로 HUD 상 의미가 없다).
-- 사용자 확정 규칙(2026): 진짜 감정사는 디스폰 없이 영구 유지되어 "퇴장" 시각이 없고,
-- 두 번째 진짜 감정사는 완전히 삭제됐다.
local TIMELINE_POINTS = {
    { field = 'cheapAppraiserSpawnAt', feature = 'cheapAppraiser', label = '싸구려 감정사 등장' },
    { field = 'trueAppraiserSpawnAt', feature = 'trueAppraiser', label = '진짜 감정사 등장' },
    { field = 'traceBumpAt', feature = 'trace', label = '추적 강화' },
    { field = 'forgerSpawnAt', feature = 'forger', label = '위조업자 등장' },
    { field = 'policeInfoShutdownAt', feature = 'police', label = '경찰 정보경제 종료' },
    { field = 'policeDespawnAt', feature = 'police', label = '경찰 철수' },
    { field = 'finalTrueStart', feature = 'trueAppraiser', label = '최종 감정사 등장' },
    { field = 'finalCheckFirstAt', feature = nil, label = '최종 구역 판정 시작' }, -- 끌 수 없는 핵심 로직
}

local CIRCLE_POINTS = {
    { key = 'circle1500', feature = 'liveReveal', label = '위치원 공개 (넓음)' },
    { key = 'circle100', feature = 'liveReveal', label = '위치원 공개 (좁음)' },
}

--- 현재 Config.Timeline/Config.Circle/Config.Features 상태 기준으로 "발동 예정" 타임라인
--- 이벤트 목록을 만든다. 세션 진행 여부와 무관하게 Config 값만 본다 — RUNNING 시작 시점의
--- 스냅샷으로 한 번 보내고, /feature on-off가 생기면 그때 다시 계산해 재전송한다.
local function buildTimelineEvents()
    local events = {}
    for _, point in ipairs(TIMELINE_POINTS) do
        if not point.feature or Config.Features[point.feature] then
            local atMinute = Config.Timeline[point.field]
            if atMinute then
                table.insert(events, { atMinute = atMinute, label = point.label })
            end
        end
    end
    for _, point in ipairs(CIRCLE_POINTS) do
        if not point.feature or Config.Features[point.feature] then
            local cfg = Config.Circle[point.key]
            if cfg then
                table.insert(events, { atMinute = cfg.atMinute, label = point.label })
            end
        end
    end
    table.sort(events, function(a, b) return a.atMinute < b.atMinute end)
    return events
end

--- targetId를 생략하면 전원에게, 지정하면 그 클라이언트에게만 보낸다(재접속 동기화용).
function SecretBagMode.BroadcastTimelineSync(session, targetId)
    if not session or not session.mainStartedAt or session.state == SessionState.ENDED then return end
    local elapsedMs = U.Now() - session.mainStartedAt
    -- 사용자 요청: 경찰 시스템을 더 이상 쓰지 않으므로, 시계 아래 안내문(#status)을
    -- "진짜 감정사" 출근/이용 가능 상태로 대체한다(html/index.html이 매초 자체 계산).
    -- trueAppraiser 기능이 꺼져 있으면 nil을 보내 안내문을 비운다.
    local trueApprSpawnAtMin = Config.Features.trueAppraiser and Config.Timeline.trueAppraiserSpawnAt or nil
    TriggerClientEvent('secretbag:timelineSync', targetId or -1, elapsedMs, buildTimelineEvents(), trueApprSpawnAtMin)
end

--- 이미 RUNNING(이후)인 세션에 새로 접속/리스폰한 클라이언트를 위한 재동기화.
--- trace.lua도 같은 이벤트를 별도로 듣고 있다 — 여러 핸들러가 각자 독립적으로 반응하는
--- 기존 패턴(state.lua의 onResourceStart 등)과 동일하다.
---
--- stateChanged를 다시 보내는 이유: client/main.lua의 HUD show/hide는 상태가 "바뀔 때"만
--- 브로드캐스트되므로(TransitionTo), 전이 시점에 아직 접속하지 않았던 클라이언트(늦은 접속,
--- 재접속, 리스폰)는 그 신호를 영영 못 받는다 — timelineSync만 보내면 내부 타이머는 정확해도
--- 패널이 계속 display:none으로 숨겨진 채 남는다. 같은 이유로 policeRelationChanged도
--- 재전송한다 — 이 이벤트 역시 "바뀔 때"만 브로드캐스트돼 재접속 시 갱신되지 않던 기존 gap이다
--- (예전에는 채팅 메시지만 놓치는 정도였지만, 이제 HUD 상태줄도 같은 이벤트로 채워지므로 빈
--- 줄로 계속 남는다).
RegisterNetEvent('secretbag:clientReady', function()
    local playerId = tonumber(source)
    local session = SecretBagMode.CurrentSession
    if not session then return end

    TriggerClientEvent('secretbag:stateChanged', playerId, session.state)
    SecretBagMode.BroadcastTimelineSync(session, playerId)

    local ps = session.playerSessions[playerId]
    if ps then
        TriggerClientEvent('secretbag:policeRelationChanged', playerId, ps.policeRelation)

        -- 진짜 감정사 개인 재이용 쿨다운 재동기화(재접속/리스폰 시 #status가 끊기지 않도록).
        local cd = ps.cooldowns and ps.cooldowns.true1
        local endElapsedMs = (cd and cd > U.Now()) and (cd - session.mainStartedAt) or nil
        TriggerClientEvent('secretbag:trueApprCooldown', playerId, endElapsedMs)
    end
end)
