local U = SecretBagMode.Util
local Role = SecretBagMode.Role
local Msg = SecretBagMode.Message

--- REQ-BAG-001: 인벤토리 빈 슬롯 확인. StartGame 시점엔 직전 세션이 이미
--- ENDED+cleanup 완료 상태라 session.bags가 비어있는 게 정상이지만,
--- 방어적으로 Inventory.HasFreeSlot을 그대로 사용한다.
function SecretBagMode.HasFreeInventorySlot(playerId)
    local session = SecretBagMode.CurrentSession
    if not session then return true end
    return SecretBagMode.Inventory.HasFreeSlot(session, playerId)
end

--- REQ-TIMELINE: PREP 종료 시 CheapAppraiser x2 + Police spawn.
--- 실제 스폰 좌표는 Config.NpcSpawnPools 확정 후 appraiser.lua/police.lua에서 구현.
local function onMainStart(session)
    session.mainStartedAt = U.Now()
    SecretBagMode.TransitionTo(session, SecretBagMode.SessionState.RUNNING)
    SecretBagMode.OnPrepEnd(session)
    SecretBagMode.LogTimelineEvent(session, '게임 시작 (PREP 종료)')

    if SecretBagMode.Appraiser and SecretBagMode.Appraiser.StartScheduler then
        SecretBagMode.Appraiser.StartScheduler(session)
    end
    if SecretBagMode.Police and SecretBagMode.Police.SpawnInitial then
        SecretBagMode.Police.SpawnInitial(session)
    end
    if SecretBagMode.Police and SecretBagMode.Police.StartScheduler then
        SecretBagMode.Police.StartScheduler(session)
    end
    if SecretBagMode.FinalZone and SecretBagMode.FinalZone.StartScheduler then
        SecretBagMode.FinalZone.StartScheduler(session)
    end
    if SecretBagMode.Trace and SecretBagMode.Trace.StartScheduler then
        SecretBagMode.Trace.StartScheduler(session)
    end
    if SecretBagMode.Forger and SecretBagMode.Forger.StartScheduler then
        SecretBagMode.Forger.StartScheduler(session)
    end
    if SecretBagMode.LiveReveal and SecretBagMode.LiveReveal.StartScheduler then
        SecretBagMode.LiveReveal.StartScheduler(session)
    end
    if SecretBagMode.GameArea and SecretBagMode.GameArea.StartScheduler then
        SecretBagMode.GameArea.StartScheduler(session)
    end
    if SecretBagMode.BroadcastTimelineSync then
        SecretBagMode.BroadcastTimelineSync(session)
    end

    -- police.lua는 policeRelation이 실제로 "바뀔 때"만 secretbag:policeRelationChanged를
    -- 쏜다. NewPlayerSession()의 초기값(NEUTRAL)은 한 번도 방송되지 않아, 아무 일도 없었던
    -- 참가자는 HUD 상태줄(html/index.html, client/main.lua)이 게임 내내 빈 채로 남는다 —
    -- RUNNING 시작 시 1회 전원에게 현재 값을 그대로 쏴서 초기화한다.
    for pid in pairs(session.sessionParticipantIds) do
        local ps = session.playerSessions[pid]
        if ps then
            TriggerClientEvent('secretbag:policeRelationChanged', pid, ps.policeRelation)
        end
    end

    U.NotifyAll('싸구려 감정사와 경찰들이 출근했습니다.')
end

local function startPrepCountdown(session)
    SetTimeout(Config.PrepDurationMs, function()
        -- 세션이 그 사이 강제 종료됐다면 진행하지 않는다.
        if SecretBagMode.CurrentSession ~= session or session.state ~= SecretBagMode.SessionState.PREP then
            return
        end
        onMainStart(session)
    end)
end

--- StartGame 운영절차 (기획서 3장 1~9단계 / 사양서 REQ-START-001~004).
--- 검증 순서: state/cleanupInProgress -> caller owner 권한 -> participant snapshot/P>=4 -> freeSlot.
RegisterCommand('startgame', function(source)
    local callerId = source

    if not SecretBagMode.CanStartGame() then
        U.NotifyPlayer(callerId, '지금은 게임을 시작할 수 없습니다 (진행 중이거나 정리 중).')
        return
    end

    if not SecretBagMode.IsServerOwner(callerId) then
        U.NotifyPlayer(callerId, Msg.NO_ACCESS)
        return
    end

    local participantIds = {}
    for _, pidStr in ipairs(GetPlayers()) do
        local pid = tonumber(pidStr)
        if SecretBagMode.GetRole(pid) == Role.PLAYER then
            table.insert(participantIds, pid)
        end
    end

    if #participantIds < Config.MinPlayers then
        U.NotifyPlayer(callerId, ('최소 참가 PLAYER %d명이 필요합니다 (현재 %d명).'):format(Config.MinPlayers, #participantIds))
        return
    end

    for _, pid in ipairs(participantIds) do
        if not SecretBagMode.HasFreeInventorySlot(pid) then
            -- REQ-START-002: 검증 실패 시 기존 SecretBag은 삭제하지 않는다.
            U.NotifyAll(Msg.START_NO_SLOT)
            return
        end
    end

    -- REQ-START-003: 검증 성공 후에만 기존 SecretBag 완전 삭제.
    SecretBagMode.Bag.PurgeAllExisting()

    local session = SecretBagMode.NewSession(participantIds)
    SecretBagMode.Bag.CreateInitialBags(session)

    -- GameArea 경계 감시(server/gamearea.lua)는 RUNNING부터 적용되므로 onMainStart에서 시작한다
    -- (PREP 동안은 이동 자체가 자유로워도 문제없다 — 본 게임 시작 전이라 아직 "무대 밖"이라는
    -- 개념이 의미가 없다).
    SecretBagMode.ApplyPrepProtections(session)

    startPrepCountdown(session)

    -- 하드코딩된 "10분" 문자열이 있었다 — Config.PrepDurationMs가 바뀌어도(사용자 확정
    -- 규칙: 5분) 이 안내 메시지만 예전 값 그대로 남아있던 버그. 실제 설정값에서 계산한다.
    U.NotifyAll(('게임이 시작되었습니다. PREP %d분 카운트다운을 시작합니다. (참가자 %d명)'):format(
        math.ceil(Config.PrepDurationMs / 60000), session.P))
end, false)
