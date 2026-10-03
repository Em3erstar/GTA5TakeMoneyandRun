local U = SecretBagMode.Util
local HistEvt = SecretBagMode.HistoryEventType
local SessionState = SecretBagMode.SessionState

--- EndGame / Cleanup 계약 (기획서 14장, 사양서 REQ-END-001~005).
local function performEndGame(session, callerId)
    -- REQ-END-001/002: winner 없어도 forcedEnd=true, winner=null로 종료 가능.
    -- ResultStore(commit)를 cleanup보다 먼저 확정하고 이후 winner 재계산 금지.
    local isForced = session.finalWinnerPlayerId == nil
    session.forcedEnd = isForced

    SecretBagMode.LastResult = {
        sessionId = session.sessionId,
        winner = session.finalWinnerPlayerId,
        forcedEnd = session.forcedEnd,
        endTime = os.time(),
    }

    SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.END_GAME, callerId, {
        forcedEnd = session.forcedEnd,
        winnerId = session.finalWinnerPlayerId,
    })

    session.state = SessionState.ENDED
    session.cleanupInProgress = true
    TriggerClientEvent('secretbag:stateChanged', -1, session.state)

    -- REQ-END-003: 모든 scheduler/respawn/Trace/final check/live reveal 중단 (각 모듈 cleanup hook).
    for _, moduleName in ipairs({ 'Trace', 'Police', 'FinalZone', 'Appraiser', 'Forger', 'Hint', 'LiveReveal', 'GameArea' }) do
        local mod = SecretBagMode[moduleName]
        if mod and mod.Cleanup then
            mod.Cleanup(session)
        end
    end

    -- 서버장 임시 플레이어 모드(server/ownerplaymode.lua) 자동 회수: 여기서 되돌리지 않으면
    -- roles[id]=PLAYER가 다음 게임까지 새어나가 startgame.lua의 참가자 스캔에 의도치 않게
    -- 다시 포함되어 버린다. 아래 protection=true 복원은 곧이어 ClearAllProtections()가
    -- 다시 false로 덮어쓰지만(REQ-END-004: 전원 보호 해제) 순서상 문제는 없다.
    if SecretBagMode.RoleState.tempPlayerMode then
        for playerId in pairs(SecretBagMode.RoleState.tempPlayerMode) do
            SecretBagMode.DisableTempPlayerMode(playerId)
        end
    end

    -- REQ-END-003: 모든 SecretBag/NoteItem을 inventory/world에서 완전 삭제.
    -- SERVER_OWNER 수동 생성 vehicle/weapon/ammo는 유지 (REQ-END-005).
    for bagId, bag in pairs(session.bags) do
        SecretBagMode.Inventory.DespawnWorldBag(bag)
        session.bags[bagId] = nil
    end
    session.genuineBagId = nil
    session.noteItems = {}

    -- 세션 생성 system NPC(감정사/위조업자/경찰)는 위 for-loop의 각 모듈 Cleanup이 이미
    -- despawn한다. GameArea 경계 감시(gamearea.lua)와 FinalBarrier(finalzone.lua)는 각자
    -- CreateThread 루프 조건이 session.state == ENDED가 되는 즉시(다음 tick, 최대 2초/0.5초
    -- 이내) 스스로 종료된다 — 별도 정지 호출이 필요 없다. 남은 건 클라이언트 화면의 블립류
    -- (Trace ping·경찰 정보강탈 ping·위치원)뿐이라, inventory.lua가 이미 갖고 있는 "전체
    -- 리셋" 이벤트를 그대로 재사용해 즉시 지운다 (LiveReveal.Cleanup은 위 for-loop에서
    -- 위치원을 이미 지웠으므로 중복 호출이지만 idempotent해 문제없다).
    TriggerClientEvent('secretbag:resetInventoryState', -1)

    -- REQ-END-004: 모든 유저의 invincible/non-collision/damage override 완전 해제.
    SecretBagMode.ClearAllProtections()

    -- 역할 잠금만 해제. role/activeServerOwnerId는 유지 (REQ-END-005).
    session.cleanupInProgress = false

    U.NotifyAll(session.forcedEnd
        and '게임이 강제 종료되었습니다.'
        or '게임이 종료되었습니다.')
end

RegisterCommand('endgame', function(source)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end

    local session = SecretBagMode.CurrentSession
    if not session or session.state == SessionState.ENDED then
        U.NotifyPlayer(source, '진행 중인 세션이 없습니다.')
        return
    end

    performEndGame(session, source)
end, false)

SecretBagMode.PerformEndGame = performEndGame
