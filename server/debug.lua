--- 솔로 디버깅용 도구 모음. Config.Debug.enabled=false면 이 파일 전체가 조용히 스킵된다
--- (커맨드 자체가 등록되지 않음). SERVER_OWNER 또는 PLAYER(참가자) 역할이 배정된 사람만
--- 사용 가능 — HELPER/미배정/늦참가자는 여전히 막는다.
---
--- 왜 SERVER_OWNER만이 아닌가: /sbforceinfo, /sbpolicerelation 등 정보경제/경찰 관련
--- 명령은 PLAYER 참가자에게만 의미 있는 상태(playerSessions)를 건드린다. 혼자 테스트할 때
--- 한 캐릭터가 SERVER_OWNER와 PLAYER를 동시에 가질 수 없으므로(같은 ID에 역할은 하나만),
--- SERVER_OWNER 전용으로 막아두면 PLAYER 쪽 디버그 명령을 아예 쓸 수 없게 된다. 어차피
--- Config.Debug.enabled로 전체를 끌 수 있어 프로덕션에서는 문제가 안 된다.
---
--- 전체 명령어 설명/시나리오는 DEBUG_COMMANDS.md 참고. 이 파일은 코드 자체이며,
--- 문서와 명령어 목록이 어긋나지 않도록 새 명령을 추가하면 그 파일도 같이 갱신할 것.

if not (Config.Debug and Config.Debug.enabled) then
    return
end

local U = SecretBagMode.Util
local Role = SecretBagMode.Role
local BagState = SecretBagMode.BagState
local SessionState = SecretBagMode.SessionState
local PoliceState = SecretBagMode.PoliceState

local function requireOwner(source)
    local role = SecretBagMode.GetRole(source)
    if not (SecretBagMode.IsServerOwner(source) or role == Role.PLAYER) then
        U.NotifyPlayer(source, '디버그 명령은 SERVER_OWNER 또는 PLAYER 참가자만 사용할 수 있습니다.')
        return false
    end
    return true
end

local function currentSession(source)
    local session = SecretBagMode.CurrentSession
    if not session then
        U.NotifyPlayer(source, '진행 중인 세션이 없습니다.')
        return nil
    end
    return session
end

--- 서버 콘솔 + 호출자 채팅 동시 출력. chat 리소스가 없는 테스트 서버에서도
--- 서버 콘솔에서는 항상 확인 가능하다.
local function debugPrint(source, text)
    print('[SecretBag DEBUG] ' .. text)
    U.NotifyPlayer(source, text)
end

local function tableCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- 플레이어/가짜ID/점수처럼 원래 정수인 인자를 파싱한다. tonumber(args[N])을 그대로 쓰면
--- 사용자가 "5.5" 같은 소수를 입력했을 때 값 자체는 받아들여지고, 한참 뒤 그 값을
--- string.format('%d', ...)으로 출력하는 시점에야 Lua 5.4가 "number has no integer
--- representation" 런타임 에러를 던지며 명령어 전체가 죽는다 — 디버그 도구가 예상 밖
--- 입력에 죽어버리면 본래 목적(혼자서도 안정적으로 테스트)에 어긋나므로, 입력받는
--- 시점에 정수로 floor해 애초에 그런 값이 만들어지지 않게 막는다.
local function toIntArg(raw)
    local n = tonumber(raw)
    if not n then return nil end
    return math.floor(n)
end

-- ============================================================
-- 상태 조회
-- ============================================================

RegisterCommand('sbdump', function(source)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end

    print('========== SecretBag session dump ==========')
    print(('state=%s mainElapsed=%.1fmin P=%d winnerLocked=%s finalZoneLocked=%s'):format(
        session.state, SecretBagMode.MainElapsedMinutes(session) or -1, session.P,
        tostring(session.winnerLocked), tostring(session.finalZoneLocked)))

    local genuine = SecretBagMode.Bag.GetGenuine(session)
    if genuine then
        print(('genuine bagId=%s score=%d state=%s owner=%s'):format(
            genuine.bagId, genuine.appearanceScore, genuine.state, tostring(genuine.currentOwnerId)))
    else
        print('genuine: none')
    end

    print('-- bags --')
    for bagId, bag in pairs(session.bags) do
        print(('  %s isGenuine=%s score=%d owner=%s state=%s'):format(
            bagId, tostring(bag.isGenuine), bag.appearanceScore, tostring(bag.currentOwnerId), bag.state))
    end

    print('-- notes --')
    for noteId, note in pairs(session.noteItems) do
        print(('  %s hintId=%s owner=%s issuedTo=%s'):format(
            noteId, note.hintId, tostring(note.currentOwnerId), tostring(note.issuedRecipientId)))
    end

    print('-- players --')
    for pid in pairs(session.sessionParticipantIds) do
        local ps = session.playerSessions[pid]
        if ps then
            print(('  %s traceCount=%d policeRelation=%s infoLootCount=%d forgedOnce=%s revealedHints=%d'):format(
                tostring(pid), ps.traceCount, ps.policeRelation, ps.infoLootCount, tostring(ps.forgedOnce),
                tableCount(ps.revealedHintIds)))
        end
    end

    print('-- NPC --')
    if SecretBagMode.Appraiser then
        for id, npc in pairs(SecretBagMode.Appraiser.CheapNpcs) do
            print(('  cheap:%s alive=%s'):format(id, tostring(npc.ped and DoesEntityExist(npc.ped))))
        end
        -- 사용자 확정 규칙(2026): 두 번째 진짜 감정사 삭제, 진짜 감정사/최종 감정사 둘 다
        -- 서버 전체 사용 한도가 없어져(무제한) remainingUses 필드 자체가 없다.
        print(('  true active=%s'):format(tostring(SecretBagMode.Appraiser.TrueState.true1.active)))
        print(('  finaltrue active=%s'):format(tostring(SecretBagMode.Appraiser.FinalTrueState.active)))
    end
    if SecretBagMode.Forger then
        print(('  forger active=%s'):format(tostring(SecretBagMode.Forger.State.active)))
    end
    if SecretBagMode.Police then
        print(('  police active count=%d'):format(tableCount(SecretBagMode.Police.ActivePeds)))
    end
    print('==============================================')

    U.NotifyPlayer(source, '서버 콘솔에 전체 상태를 출력했습니다.')
end, false)

-- ============================================================
-- 시간 조작
-- ============================================================

--- 게임 경과 시간을 강제로 이동시킨다. 스케줄러가 전부 폴링 방식(3~5초 간격)이라
--- 다음 tick에 그 시점 이벤트가 자동으로 발동한다.
RegisterCommand('sbtime', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    if not session.mainStartedAt then
        U.NotifyPlayer(source, 'PREP이 아직 끝나지 않았습니다 (mainStartedAt 없음). PREP 종료까지 기다리거나 Config.PrepDurationMs를 줄이세요.')
        return
    end
    local minutes = tonumber(args[1])
    if not minutes then
        U.NotifyPlayer(source, '사용법: /sbtime <분>')
        return
    end
    session.mainStartedAt = U.Now() - math.floor(minutes * 60000)
    -- minutes 자체는 소수도 허용한다(예: 62.5분) — 실제 이동은 위에서 그대로 반영된다.
    -- 다만 %d 포맷은 정수가 아니면 런타임 에러를 던지므로 표시용으로만 floor한다.
    debugPrint(source, ('mainElapsed을 %d분으로 이동했습니다. 몇 초 내로 스케줄러가 반응합니다.'):format(math.floor(minutes)))
end, false)

-- ============================================================
-- 가짜 참가자 (다른 사람 없이 "다른 사람" 역할이 필요한 걸 테스트하기 위함)
-- ============================================================

--- 실제 접속 없이 세션 참가자로 등록한다. session.P는 바뀌지 않는다(REQ-STATE-001상
--- P는 세션 종료까지 불변이어야 하므로 — 가짜 참가자는 어디까지나 테스트 편의용 추가 항목).
--- ped가 없으므로 좌표 기반 로직(FinalZone inside 판정 등)에서는 항상 "없음"으로 처리된다.
RegisterCommand('sbaddfakeplayer', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local fakeId = toIntArg(args[1])
    if not fakeId then
        U.NotifyPlayer(source, '사용법: /sbaddfakeplayer <임의ID, 예: 9001>')
        return
    end
    if session.sessionParticipantIds[fakeId] then
        U.NotifyPlayer(source, '이미 등록된 ID입니다.')
        return
    end
    session.sessionParticipantIds[fakeId] = true
    session.playerSessions[fakeId] = SecretBagMode.NewPlayerSession()
    debugPrint(source, ('가짜 참가자 %d를 등록했습니다 (P는 그대로 %d). 이제 killerId/targetId 인자로 쓸 수 있습니다.'):format(fakeId, session.P))
end, false)

--- 가짜 참가자를 제거한다. 들고 있던 가방은 고아 방지를 위해 내 위치에 world_drop 처리한다.
RegisterCommand('sbremovefakeplayer', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local fakeId = toIntArg(args[1])
    if not fakeId or not session.sessionParticipantIds[fakeId] then
        U.NotifyPlayer(source, '등록된 가짜 참가자가 아닙니다.')
        return
    end
    local ped = GetPlayerPed(tostring(source))
    local fallbackCoords = (ped and ped ~= 0) and GetEntityCoords(ped) or Config.DefaultSafeCoord
    for _, bag in pairs(session.bags) do
        if bag.currentOwnerId == fakeId then
            bag.currentOwnerId = nil
            bag.state = BagState.WORLD_DROP
            bag.worldCoords = fallbackCoords
        end
    end
    session.sessionParticipantIds[fakeId] = nil
    session.playerSessions[fakeId] = nil
    debugPrint(source, ('가짜 참가자 %d를 제거했습니다.'):format(fakeId))
end, false)

-- ============================================================
-- 가방 / 인벤토리
-- ============================================================

--- 즉시 SecretBag을 지급한다 (RNG/StartGame 없이 감정사·위조 테스트용).
--- genuine을 지정하면 기존 genuine을 먼저 제거한다(REQ-BAG-004: genuine 2개 동시 존재 금지).
RegisterCommand('sbgive', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end

    local kind = args[1]
    local score = toIntArg(args[2])
    if kind ~= 'genuine' and kind ~= 'fake' then
        U.NotifyPlayer(source, '사용법: /sbgive <genuine|fake> [score]')
        return
    end

    local playerId = source
    local bag = {
        bagId = U.NewId('bag'),
        isGenuine = (kind == 'genuine'),
        appearanceScore = score or U.RandomInt(10, 99),
        originalOwnerId = playerId,
        currentOwnerId = playerId,
        lastPlayerOwnerId = playerId,
        state = BagState.INVENTORY,
        worldCoords = nil,
        finalZoneLock = false,
        cheapVisitHistory = {},
        ownershipChanged = false,
        forgedFrom = nil,
    }

    if kind == 'genuine' then
        local existing = SecretBagMode.Bag.GetGenuine(session)
        if existing then
            session.bags[existing.bagId] = nil
            SecretBagMode.Inventory.DespawnWorldBag(existing)
        end
        session.genuineBagId = bag.bagId
        if not session.logicalGenuineId then
            session.logicalGenuineId = U.NewId('genuine')
        end
    end

    session.bags[bag.bagId] = bag
    TriggerClientEvent('secretbag:heldBagAdded', playerId, bag.bagId)
    debugPrint(source, ('%s(score=%d) 지급 완료. bagId=%s'):format(kind, bag.appearanceScore, bag.bagId))
end, false)

--- 내가 들고 있는 가방을 전부 제거한다(재테스트용 초기화). genuine이 포함되어 있었다면
--- session.genuineBagId도 같이 비운다 — 이후 /sbgive genuine으로 깨끗하게 다시 만들 수 있다.
RegisterCommand('sbclearbags', function(source)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end

    local removed = 0
    for bagId, bag in pairs(session.bags) do
        if bag.currentOwnerId == source then
            TriggerClientEvent('secretbag:heldBagRemoved', source, bagId)
            if bag.isGenuine then session.genuineBagId = nil end
            session.bags[bagId] = nil
            removed = removed + 1
        end
    end
    debugPrint(source, removed .. '개 가방을 제거했습니다.')
end, false)

--- 가방을 임의의 playerId(가짜 참가자 포함)가 주운 것으로 강제 처리한다. A→floor→B(다른 사람이
--- 주움, ownershipChanged=true)와 A→floor→A(같은 사람, false 유지)를 둘 다 검증할 수 있다.
--- deathEventId가 걸린 가방이면 Trace 지급 로직(REQ-TRACE-001)까지 그대로 탄다.
RegisterCommand('sbforcepickup', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local bagId = args[1]
    local asId = toIntArg(args[2]) or source
    local bag = bagId and session.bags[bagId]
    if not bag or bag.state ~= BagState.WORLD_DROP then
        U.NotifyPlayer(source, '월드에 드롭된 가방이 아니거나 존재하지 않습니다. /sbdump로 bagId 확인. 사용법: /sbforcepickup <bagId> [asPlayerId]')
        return
    end
    -- FINAL_LOCKED_CONTEST 중 genuine을 Bag.OnPickup으로 직접 주워버리면(원자적 승자 확정
    -- 경로인 TryContestPickup을 건너뛰므로) winner_pickup 잠금/FinalizeWinnerState가 전혀
    -- 실행되지 않는다. 그러면 bag.state만 WORLD_DROP에서 빠져나가고 session.winnerLocked는
    -- 계속 false로 남아, 그 뒤로는 진짜 TryContestPickup이 항상 "WORLD_DROP 아님"으로 실패해
    -- 아무도 영구히 승자가 될 수 없는 상태로 세션이 고착되는 버그가 있었다 — 실전과 동일하게
    -- TryContestPickup으로 위임한다.
    if session.state == SessionState.FINAL_LOCKED_CONTEST and bag.isGenuine then
        local ok, err = SecretBagMode.FinalZone.TryContestPickup(session, asId)
        debugPrint(source, ('FINAL_LOCKED_CONTEST 중이라 TryContestPickup으로 위임했습니다: %s(%s)'):format(tostring(ok), tostring(err)))
        return
    end
    SecretBagMode.Bag.OnPickup(session, bag, asId, Role.PLAYER)
    debugPrint(source, ('bagId=%s를 %d(으)로 픽업 처리. ownershipChanged=%s lastPlayerOwnerId=%s'):format(
        bagId, asId, tostring(bag.ownershipChanged), tostring(bag.lastPlayerOwnerId)))
end, false)

--- NoteItem을 온라인/거리 체크 없이 임의의 targetId에게 강제 전달한다. "중복 기준은 최초 발급
--- recipient" 규칙(전달받은 쪽 revealedHintIds는 안 바뀜)을 /sbdump의 issuedTo 필드로 확인할 수 있다.
RegisterCommand('sbforcetransfer', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local noteId = args[1]
    local targetId = toIntArg(args[2])
    local note = noteId and session.noteItems[noteId]
    if not note or note.currentOwnerId ~= source then
        U.NotifyPlayer(source, '소지한 쪽지가 아닙니다. 사용법: /sbforcetransfer <noteId> <targetId>')
        return
    end
    if not targetId then
        U.NotifyPlayer(source, '사용법: /sbforcetransfer <noteId> <targetId>')
        return
    end
    note.currentOwnerId = targetId
    TriggerClientEvent('secretbag:heldNoteRemoved', source, note.noteId)
    if U.IsPlayerOnline(targetId) then
        TriggerClientEvent('secretbag:heldNoteAdded', targetId, note.noteId, note.hintText)
    end
    debugPrint(source, ('쪽지를 %d에게 강제 전달했습니다 (원 발급자=%s — /sbdump의 issuedTo는 안 바뀌어야 정상).'):format(targetId, tostring(note.issuedRecipientId)))
end, false)

-- ============================================================
-- 경찰 / 정보강탈 / Hint
-- ============================================================

--- 실제 사망 없이 PK 경찰 페널티를 즉시 트리거한다. killerId를 생략하면 자기 자신
--- (/sbaddfakeplayer로 만든 가짜 참가자를 killerId로 줄 수도 있다).
--- 사용자 확정 규칙(2026)으로 실제 PK 페널티는 커스텀 경찰(현재 미사용)이 아니라
--- server/wanted.lua의 수배 시스템이다 — 그쪽을 같이 발동해야 실제로 검증 가능하다.
RegisterCommand('sbforcepk', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local killerId = toIntArg(args[1]) or source
    if SecretBagMode.Police and SecretBagMode.Police.OnPlayerKilledPlayer then
        SecretBagMode.Police.OnPlayerKilledPlayer(session, killerId)
    end
    SecretBagMode.Wanted.OnPlayerKill(killerId)
    debugPrint(source, ('PK 페널티(수배 2단계, 15분)를 강제 발동했습니다 (대상=%d).'):format(killerId))
end, false)

--- 실제 경찰 사살 없이 정보 강탈을 즉시 트리거한다 (targetId 생략 시 자기 자신).
--- policeRelation==NEUTRAL이어야 동작. eligible hint가 없으면(=이미 다 받음) ALERT_SHUTDOWN으로만
--- 전환되고 hostile은 안 걸린다 — 정상 동작.
RegisterCommand('sbforceinfo', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local targetId = toIntArg(args[1]) or source
    if SecretBagMode.Police and SecretBagMode.Police.OnPoliceKilled then
        SecretBagMode.Police.OnPoliceKilled(session, targetId)
        debugPrint(source, ('정보 강탈을 강제 발동했습니다 (대상=%d, 콘솔/채팅에서 결과 확인).'):format(targetId))
    end
end, false)

--- policeRelation을 직접 강제 설정한다 (타이머 대기 없이 UI/추격 로직 확인용). targetId 생략 시 자기 자신.
RegisterCommand('sbpolicerelation', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local state = args[1]
    local targetId = toIntArg(args[2]) or source
    local ps = session.playerSessions[targetId]
    if not ps then
        U.NotifyPlayer(source, '대상이 참가자(PLAYER)가 아니면 policeRelation이 없습니다 (/sbaddfakeplayer로 먼저 등록).')
        return
    end
    if not state or not PoliceState[state] then
        U.NotifyPlayer(source, '사용법: /sbpolicerelation <NEUTRAL|ALERT_TO_HOSTILE|HOSTILE|ALERT_TO_NEUTRAL|ALERT_SHUTDOWN|DISABLED> [targetId]')
        return
    end
    ps.policeRelation = PoliceState[state]
    TriggerClientEvent('secretbag:policeRelationChanged', targetId, ps.policeRelation)
    debugPrint(source, ('%d의 policeRelation을 %s로 강제 설정했습니다.'):format(targetId, state))
end, false)

--- infoLootCount/hostile 타이머/힌트 이력을 전부 초기화하고 NEUTRAL로 되돌린다. targetId 생략 시 자기 자신.
--- /sbforceinfo를 반복 테스트하고 싶을 때 사용.
RegisterCommand('sbresetinfo', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local targetId = toIntArg(args[1]) or source
    local ps = session.playerSessions[targetId]
    if not ps then
        U.NotifyPlayer(source, '대상이 참가자(PLAYER)가 아니면 초기화할 상태가 없습니다.')
        return
    end
    ps.infoLootCount = 0
    ps.infoHostileUntil = nil
    ps.pkHostileUntil = nil
    ps.personalInfoClosed = false
    ps.revealedHintIds = {}
    ps.policeRelation = PoliceState.NEUTRAL
    TriggerClientEvent('secretbag:policeRelationChanged', targetId, ps.policeRelation)
    debugPrint(source, ('%d의 경찰/힌트 상태를 초기화했습니다 (NEUTRAL, infoLootCount=0, 힌트 이력 리셋).'):format(targetId))
end, false)

--- 감정사(싸구려/진짜) 상호작용 쿨다운을 전부 초기화한다. targetId 생략 시 자기 자신.
--- ps.cooldowns.* 은 U.Now()(=서버 가동시간 실시간 ms) 기준이라 /sbtime으로 게임 내
--- 타임라인을 앞당겨도 전혀 영향을 받지 않는다 — 혼자 CheapAppraiser 2곳(공유 5초 쿨다운)이나
--- 진짜 감정사/FinalTrue를 반복 테스트하려면 이 커맨드로 우회해야 한다.
RegisterCommand('sbresetcooldowns', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local targetId = toIntArg(args[1]) or source
    local ps = session.playerSessions[targetId]
    if not ps then
        U.NotifyPlayer(source, '대상이 참가자(PLAYER)가 아니면 초기화할 상태가 없습니다.')
        return
    end
    ps.cooldowns = {}
    debugPrint(source, ('%d의 감정사 쿨다운을 전부 초기화했습니다 (cheap/finalTrue/true1 전부 해제).'):format(targetId))
end, false)

--- 특정 target이 관찰자인 나에게 보내는 Trace ping을 시뮬레이션한다(targetId 생략 시 임의 테스트용
--- ID 사용). 원래 T.SendPing은 target 본인은 제외하고 다른 관찰자에게만 보내는데, 그 "다른 관찰자가
--- 보는 화면"을 내 화면에 강제로 띄워서 렌더링을 확인하고, hiddenTraceTargets(= /deletetraceping)
--- 로직은 내가 진짜 관찰자 입장에서 그대로 재검증한다 — 숨긴 대상이면 여기서도 안 와야 정상이다.
RegisterCommand('sbtracetest', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local targetId = toIntArg(args[1])
    if not targetId then
        U.NotifyPlayer(source, '사용법: /sbtracetest <targetId> — /deletetraceping으로 숨긴 대상이면 핑이 안 와야 정상')
        return
    end
    local ps = session.playerSessions[source]
    if ps and ps.hiddenTraceTargets[targetId] then
        debugPrint(source, ('targetId=%d는 내가 숨김 처리해서 핑을 못 받습니다 (정상 — /deletetraceping 동작 확인됨).'):format(targetId))
        return
    end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    TriggerClientEvent('secretbag:tracePing', source, targetId, ('DEBUG-%d'):format(targetId), coords)
    debugPrint(source, ('targetId=%d 핑을 내 화면에 강제로 띄웠습니다 (원래는 다른 관찰자 전용 — 렌더링 확인용 시뮬레이션).'):format(targetId))
end, false)

--- 가장 가까운 경찰 NPC를 즉사시킨다. 앰비언트 스폰 루프가 다시 채우는지 확인용도로 쓸 수 있다
--- (고정 좌표 재스폰이 아니므로 "이 자리에 다시 뜬다"가 아니라 "언젠가 참가자 근처에 다시 뜬다").
--- 주의: SetEntityHealth로 직접 죽이면 GetPedSourceOfDeath가 킬러를 못 잡을 수 있어
--- 정보강탈까지 같이 테스트하려면 /sbforceinfo를 따로 쓸 것.
RegisterCommand('sbkillpolice', function(source)
    if not requireOwner(source) then return end
    local P = SecretBagMode.Police
    if not P then return end
    local playerPed = GetPlayerPed(tostring(source))
    if not playerPed or playerPed == 0 then return end
    local playerCoords = GetEntityCoords(playerPed)

    local nearestPed, nearestDist = nil, nil
    for _, npc in pairs(P.ActivePeds) do
        if not npc.dead and npc.ped and DoesEntityExist(npc.ped) then
            local dist = #(playerCoords - GetEntityCoords(npc.ped))
            if not nearestDist or dist < nearestDist then
                nearestPed, nearestDist = npc.ped, dist
            end
        end
    end

    if not nearestPed then
        U.NotifyPlayer(source, '활성 경찰 NPC가 없습니다. /sbforceambientpolice로 먼저 스폰시키세요.')
        return
    end

    -- SetEntityHealth는 client 전용 API라 서버에서 직접 호출하면 죽는다
    -- (client/main.lua secretbag:setupNpc 참고) — 클라이언트에 위임한다. police.lua의
    -- 스케줄러가 GetEntityHealth(서버 native)로 폴링하다가 0 이하가 되면 정상적으로
    -- handlePoliceDeath 경로(킬러 귀속/정보강탈 포함)를 그대로 탄다.
    TriggerClientEvent('secretbag:setupNpc', -1, NetworkGetNetworkIdFromEntity(nearestPed), { health = 0 })
    debugPrint(source, '가장 가까운 경찰을 즉사시켰습니다.')
end, false)

--- 앰비언트 스폰 확률 굴림을 기다리지 않고, 내 근처에 경찰 스폰을 즉시 강제 시도한다.
--- Config.Timeline.policeInfoShutdownAt 이후이거나 이미 maxActive에 도달했으면 요청 자체를
--- 보내지 않고 이유를 알려준다(프로덕션 조건과 동일하게 거부되므로, 실패를 성공처럼
--- 보고하면 디버깅에 혼란을 준다).
RegisterCommand('sbforceambientpolice', function(source)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    if not (SecretBagMode.Police and SecretBagMode.Police.RequestAmbientSpawnNear) then return end

    local ok, err = SecretBagMode.Police.RequestAmbientSpawnNear(session, source)
    if not ok then
        local reasons = {
            -- 하드코딩된 "195분"이 있었다 — 실제 값은 Config.Timeline.policeInfoShutdownAt이라
            -- 규칙이 바뀌면(사용자 확정 규칙: 165분) 이 메시지만 예전 값 그대로 남는 버그였다.
            TOO_LATE = ('%d분 이후라 신규 스폰이 금지됩니다.'):format(Config.Timeline.policeInfoShutdownAt),
            MAX_ACTIVE = '이미 maxActive(동시 활성 상한)에 도달했습니다.',
            OFFLINE = '대상이 온라인이 아닙니다.',
            DISABLED = 'Config.Features.police가 꺼져 있습니다 (/feature police on으로 켜세요).',
        }
        debugPrint(source, '경찰 스폰 요청이 거부됐습니다: ' .. (reasons[err] or tostring(err)))
        return
    end
    debugPrint(source, '내 근처에 경찰 앰비언트 스폰을 강제 요청했습니다 (클라 응답까지 몇 초 소요).')
end, false)

-- ============================================================
-- FinalZone / 승자 / Live Reveal
-- ============================================================

--- FinalZoneCheck를 대기 없이 즉시 1회 실행한다. RUNNING 상태이고 scheduledCloseAt이
--- 이미 설정된 뒤(=RUNNING 진입 이후)에만 동작한다.
RegisterCommand('sbforcecheck', function(source)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    if session.state ~= SessionState.RUNNING or not session.scheduledCloseAt then
        U.NotifyPlayer(source, 'RUNNING 상태가 아니거나 FinalZone 스케줄러가 아직 시작되지 않았습니다.')
        return
    end
    if SecretBagMode.FinalZone and SecretBagMode.FinalZone.RunCheckNow then
        SecretBagMode.FinalZone.RunCheckNow(session)
        debugPrint(source, 'FinalZoneCheck를 강제 실행했습니다.')
    end
end, false)

--- 승자를 즉시 확정한다(=나 자신). FINISHING 전이, 보호 적용, mutationLocked 확인용.
--- 이미 승자가 있으면 idempotent라 아무 일도 없다.
--- FinalizeWinnerState만 단독 호출하면 실전 4A 경로(finalzone.lua runCheck)가 항상 먼저 거치는
--- lockZone을 건너뛰어, session.finalZoneLocked가 계속 false로 남는다 — 그러면 게임이 사실상
--- 끝난 뒤에도 Trace 스케줄러가 멈추지 않고 계속 도는 버그가 있었다. genuine이 있으면 실전과
--- 동일하게 lockZone부터 거친다.
RegisterCommand('sbforcewin', function(source)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local bag = SecretBagMode.Bag.GetGenuine(session)
    if bag and SecretBagMode.FinalZone and SecretBagMode.FinalZone.LockZone then
        SecretBagMode.FinalZone.LockZone(session, bag)
    end
    local ok = SecretBagMode.FinalizeWinnerState(session, source, 'debug')
    debugPrint(source, ok and '승자를 강제로 확정했습니다 (FINISHING 진입).' or '이미 승자가 확정되어 있어 아무 것도 하지 않았습니다.')
end, false)

--- FINAL_LOCKED_CONTEST에서 "동시 pickup"을 시뮬레이션한다. 나와 가짜 ID로 같은 tick에
--- TryContestPickup을 연속 호출해 정확히 1건만 성공하는지 확인한다 — 실제 두 클라이언트의
--- 네트워크 타이밍에 의존하지 않고, 원자성 보장 코드 자체(U.WithLock + winnerLocked 체크)를
--- 결정적으로 검증할 수 있어 오히려 실전 동시접속 테스트보다 더 확실하다.
RegisterCommand('sbracetest', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    if session.state ~= SessionState.FINAL_LOCKED_CONTEST then
        U.NotifyPlayer(source, 'FINAL_LOCKED_CONTEST 상태가 아닙니다. DEBUG_COMMANDS.md 시나리오 E로 먼저 그 상태를 만드세요.')
        return
    end
    local fakeId = toIntArg(args[1]) or (900000 + source)
    local ok1, err1 = SecretBagMode.FinalZone.TryContestPickup(session, source)
    local ok2, err2 = SecretBagMode.FinalZone.TryContestPickup(session, fakeId)
    debugPrint(source, ('동시 pickup 시뮬레이션 — 나: %s(%s) / 가짜(%d): %s(%s). 정확히 하나만 true여야 정상.'):format(
        tostring(ok1), tostring(err1), fakeId, tostring(ok2), tostring(err2)))
end, false)

--- 150/180/210분 위치원을 대기 없이 즉시 공개한다. 1500/100은 genuine이 있어야 동작하고,
--- finalzone(210분 최종 구역 미리 공개)은 고정 좌표라 genuine 여부와 무관하게 항상 된다.
RegisterCommand('sbforcecircle', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    if args[1] == 'finalzone' then
        if SecretBagMode.LiveReveal and SecretBagMode.LiveReveal.RevealFinalZonePreviewNow then
            SecretBagMode.LiveReveal.RevealFinalZonePreviewNow(session)
            debugPrint(source, '최종 구역 미리 공개를 강제 실행했습니다.')
        end
        return
    end
    local kind = (args[1] == '100' and 'circle100') or (args[1] == '1500' and 'circle1500') or nil
    if not kind then
        U.NotifyPlayer(source, '사용법: /sbforcecircle <1500|100|finalzone>')
        return
    end
    if SecretBagMode.LiveReveal and SecretBagMode.LiveReveal.RevealCircleNow then
        local ok = SecretBagMode.LiveReveal.RevealCircleNow(session, kind)
        debugPrint(source, ok and (kind .. ' 원 공개를 강제 실행했습니다.') or 'genuine이 없어 실행할 수 없습니다 (/sbgive genuine 먼저).')
    end
end, false)

--- 사용자 요청: 최종 구역이 지도에 원형으로 표시되지 않는다는 보고 — 원래 봉쇄
--- (FINAL_LOCKED_CONTEST) 시점에만 표시되도록 했는데(finalzone.lua lockZone 참고),
--- 그 전에 미리 경계를 확인해보고 싶을 때 대기 없이 즉시 표시한다.
RegisterCommand('sbforcefinalzonecircle', function(source)
    if not requireOwner(source) then return end
    TriggerClientEvent('secretbag:circleReveal', -1, 'finalzone', Config.FinalZoneCenter, Config.FinalZone.radius)
    debugPrint(source, ('최종 구역 경계 원을 지도에 표시했습니다 (중심 %.2f, %.2f / 반경 %.0fm).'):format(
        Config.FinalZoneCenter.x, Config.FinalZoneCenter.y, Config.FinalZone.radius))
end, false)

-- ============================================================
-- 사망 / 부활
-- ============================================================

--- 실제로 죽지 않고 사망 이벤트를 강제 발동한다(가방 드롭 + 60초 후 부활 예약, 대상=자기 자신).
--- 인자로 서버ID를 주면 그 사람이 나를 죽인 것으로 처리되어 PK 페널티까지 같이 테스트된다.
--- 디버그 호출은 5초 스팸방지 쿨다운을 우회한다(반복 테스트 편의).
RegisterCommand('sbforcedeath', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local killerServerId = tonumber(args[1])
    if SecretBagMode.Death and SecretBagMode.Death.ProcessDeath then
        SecretBagMode.Death.ProcessDeath(session, source, coords, killerServerId, true)
        debugPrint(source, '사망 이벤트를 강제 발동했습니다 (60초 후 부활 예약됨, killer=' .. tostring(killerServerId) .. ').')
    end
end, false)

--- 임의의 victimId(보통 /sbaddfakeplayer로 만든 가짜 참가자)가 사망한 것으로 강제 처리한다.
--- 가짜 참가자에게 먼저 /sbforcepickup으로 가방을 쥐어준 뒤 이 명령을 쓰면, "다른 사람이 죽어서
--- 내가 그 가방을 주웠을 때 Trace가 오르는지"(REQ-TRACE-001)까지 혼자서 전부 검증할 수 있다.
RegisterCommand('sbforcevictimdeath', function(source, args)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local victimId = toIntArg(args[1])
    local killerId = toIntArg(args[2]) or source
    if not victimId then
        U.NotifyPlayer(source, '사용법: /sbforcevictimdeath <victimId> [killerId]')
        return
    end
    local ped = GetPlayerPed(tostring(source))
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or Config.DefaultSafeCoord
    if SecretBagMode.Death and SecretBagMode.Death.ProcessDeath then
        SecretBagMode.Death.ProcessDeath(session, victimId, coords, killerId, true)
        debugPrint(source, ('victimId=%d가 killerId=%d에게 사망 처리됐습니다 (내 좌표에 가방 드롭).'):format(victimId, killerId))
    end
end, false)

-- ============================================================
-- 이동 / 좌표
-- ============================================================

--- 현재 좌표+헤딩 출력. NPC 스폰 좌표 z값을 실측할 때 이 좌표로 이동해서 찍으면 된다.
RegisterCommand('sbcoords', function(source)
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local c = GetEntityCoords(ped)
    local h = GetEntityHeading(ped)
    debugPrint(source, ('coords: %.4f, %.4f, %.4f heading: %.1f'):format(c.x, c.y, c.z, h))
end, false)

--- 지정 좌표로 순간이동한다.
RegisterCommand('sbtp', function(source, args)
    if not requireOwner(source) then return end
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not (x and y and z) then
        U.NotifyPlayer(source, '사용법: /sbtp <x> <y> <z>')
        return
    end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    SetEntityCoords(ped, x, y, z, false, false, false, true)
    debugPrint(source, ('%.2f, %.2f, %.2f 로 이동했습니다.'):format(x, y, z))
end, false)

local namedLocations = {
    finalzone = function() return Config.FinalZoneCenter end,
    gamearea = function() return Config.GameArea.center end,
    safe = function() return Config.DefaultSafeCoord end,
    cheap1 = function() return Config.NpcSpawnPools.cheapAppraiser1[1] end,
    cheap2 = function() return Config.NpcSpawnPools.cheapAppraiser2[1] end,
    trueappraiser = function() return Config.NpcSpawnPools.trueAppraiser[1] end,
    forger = function() return Config.NpcSpawnPools.forger[1] end,
    -- 경찰은 고정 스폰 지점이 없다(앰비언트 방식) — /sbforceambientpolice로 내 근처에
    -- 강제 스폰시키거나, 스폰된 뒤 /sbpull police로 끌어올 것.
}

--- 좌표를 몰라도 이름으로 주요 지점(FinalZone, GameArea 중심, NPC 후보지 등)에 순간이동한다.
RegisterCommand('sbtploc', function(source, args)
    if not requireOwner(source) then return end
    local name = args[1]
    local fn = name and namedLocations[name]
    if not fn then
        local names = {}
        for k in pairs(namedLocations) do table.insert(names, k) end
        table.sort(names)
        U.NotifyPlayer(source, '사용법: /sbtploc <' .. table.concat(names, '|') .. '>')
        return
    end
    local coords = fn()
    if not coords then
        U.NotifyPlayer(source, '해당 좌표가 아직 설정되지 않았습니다.')
        return
    end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, true)
    debugPrint(source, name .. '로 이동했습니다.')
end, false)

--- 지정 NPC를 내 앞 2m로 끌고 온다. 실측 좌표가 도시 전역에 흩어져 있어 걸어가지 않고도
--- 근접 상호작용(/usecheap 등)을 바로 테스트할 수 있게 해준다.
local function pullPedToPlayer(source, ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end
    local playerPed = GetPlayerPed(tostring(source))
    if not playerPed or playerPed == 0 then return false end
    local pc = GetEntityCoords(playerPed)
    local heading = GetEntityHeading(playerPed)
    local rad = math.rad(heading)
    local x = pc.x + math.sin(rad) * 2.0
    local y = pc.y + math.cos(rad) * 2.0
    SetEntityCoords(ped, x, y, pc.z, false, false, false, true)
    return true
end

--- 실제 프로덕션 스폰 함수(A.SpawnCheap/A.SpawnTrue/A.SpawnFinalTrue/F.Spawn)를 타임라인
--- 경과 시간 조건 없이 그대로 즉시 호출한다 — /sbtime으로 일일이 시간을 맞추지 않고도
--- NPC 스폰 로직(모델/좌표/재시도/culling 등)만 빠르게 검증하고 싶을 때 사용. 이미
--- 스폰된 개체가 있으면 그 위에 덮어써 중복이 생길 수 있으니 새 세션 시작 직후 사용 권장.
RegisterCommand('sbforceallnpcs', function(source)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    local A = SecretBagMode.Appraiser
    local F = SecretBagMode.Forger
    if A then
        A.SpawnCheap(session)
        A.SpawnTrue(session)
        A.SpawnFinalTrue(session)
    end
    if F then
        F.Spawn(session)
    end
    debugPrint(source, '싸구려 감정사 2명 + 진짜 감정사 + 최종 감정사 + 위조업자를 실제 스폰 로직으로 즉시 스폰했습니다.')
end, false)

RegisterCommand('sbpull', function(source, args)
    if not requireOwner(source) then return end
    local kind = args[1]
    local A = SecretBagMode.Appraiser
    local F = SecretBagMode.Forger
    local P = SecretBagMode.Police
    local ped = nil

    if kind == 'cheap1' and A then
        ped = A.CheapNpcs.cheap_1 and A.CheapNpcs.cheap_1.ped
    elseif kind == 'cheap2' and A then
        ped = A.CheapNpcs.cheap_2 and A.CheapNpcs.cheap_2.ped
    elseif kind == 'true1' and A then
        ped = A.TrueState.true1.ped
    elseif kind == 'finaltrue' and A then
        ped = A.FinalTrueState.ped
    elseif kind == 'forger' and F then
        ped = F.State.ped
    elseif kind == 'police' and P then
        for _, npc in pairs(P.ActivePeds) do
            if not npc.dead then
                ped = npc.ped
                break
            end
        end
    end

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        U.NotifyPlayer(source, '해당 NPC가 아직 스폰되지 않았습니다. 사용법: /sbpull <cheap1|cheap2|true1|finaltrue|forger|police>')
        return
    end

    pullPedToPlayer(source, ped)
    debugPrint(source, kind .. ' NPC를 내 앞으로 이동시켰습니다.')
end, false)

--- 진단 전용: culling radius/freeze/invincible 등 부가 native 호출을 전부 빼고
--- CreatePed 하나만 순수하게 호출해 내 바로 앞에 스폰한다. 이래도 안 보이면 문제가
--- 이 프로젝트 코드가 아니라 이 서버 환경에서 스크립트가 만드는 ped 자체에 있다는 뜻.
RegisterCommand('sbminimalpedtest', function(source)
    if not requireOwner(source) then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)
    local x = coords.x + math.sin(rad) * 2.0
    local y = coords.y + math.cos(rad) * 2.0
    local model = GetHashKey('a_m_y_business_01')
    local testPed = CreatePed(4, model, x, y, coords.z, heading, true, true)
    local ok = testPed and testPed ~= 0 and DoesEntityExist(testPed)
    U.NotifyPlayer(source, ('결과: handle=%s exist=%s (내 바로 앞 2m에 스폰 시도함)'):format(tostring(testPed), tostring(ok)))
end, false)

--- 진단 전용 2단계: 순수 CreatePed에 SetEntityDistanceCullingRadius만 추가해본다.
RegisterCommand('sbminimalpedtest2', function(source)
    if not requireOwner(source) then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)
    local x = coords.x + math.sin(rad) * 2.0
    local y = coords.y + math.cos(rad) * 2.0
    local model = GetHashKey('a_m_y_business_01')
    local testPed = CreatePed(4, model, x, y, coords.z, heading, true, true)
    if testPed and testPed ~= 0 then
        SetEntityDistanceCullingRadius(testPed, 500.0)
    end
    local ok = testPed and testPed ~= 0 and DoesEntityExist(testPed)
    U.NotifyPlayer(source, ('결과(culling radius 추가): handle=%s exist=%s'):format(tostring(testPed), tostring(ok)))
end, false)

--- 진단 전용 3단계: 순수 CreatePed에 secretbag:setupNpc(invincible+blockEvents) 위임만 추가해본다.
RegisterCommand('sbminimalpedtest3', function(source)
    if not requireOwner(source) then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)
    local x = coords.x + math.sin(rad) * 2.0
    local y = coords.y + math.cos(rad) * 2.0
    local model = GetHashKey('a_m_y_business_01')
    local testPed = CreatePed(4, model, x, y, coords.z, heading, true, true)
    local ok = testPed and testPed ~= 0 and DoesEntityExist(testPed)
    if ok then
        TriggerClientEvent('secretbag:setupNpc', -1, NetworkGetNetworkIdFromEntity(testPed), { invincible = true, blockEvents = true })
    end
    U.NotifyPlayer(source, ('결과(setupNpc 위임 추가): handle=%s exist=%s'):format(tostring(testPed), tostring(ok)))
end, false)

--- 진단 전용 4단계: 실제 spawnAppraiserPed와 완전히 동일한 조합(culling+freeze+ragdoll
--- 비활성화+setupNpc)을 내 위치에서 동기적으로(비동기 지면높이 체인 없이) 재현해본다.
RegisterCommand('sbminimalpedtest4', function(source)
    if not requireOwner(source) then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)
    local x = coords.x + math.sin(rad) * 2.0
    local y = coords.y + math.cos(rad) * 2.0
    local model = GetHashKey('a_m_y_business_01')
    local testPed = CreatePed(4, model, x, y, coords.z, heading, true, true)
    local ok = testPed and testPed ~= 0 and DoesEntityExist(testPed)
    if ok then
        SetEntityDistanceCullingRadius(testPed, 500.0)
        FreezeEntityPosition(testPed, true)
        SetPedCanRagdoll(testPed, false)
        TriggerClientEvent('secretbag:setupNpc', -1, NetworkGetNetworkIdFromEntity(testPed), { invincible = true, blockEvents = true })
    end
    U.NotifyPlayer(source, ('결과(전체 조합): handle=%s exist=%s'):format(tostring(testPed), tostring(ok)))
end, false)

--- 진단 전용 5단계: 진짜 감정사 스폰 파이프라인 전체(U.ResolveGroundZ 비동기 왕복 포함)를
--- 그대로 타되, 대상 좌표만 랜덤 풀 대신 내 현재 위치로 바꿔서 재현해본다. 이게 안 보이면
--- 비동기 지면높이 왕복 체인 자체가 원인, 보이면 원거리 랜덤 풀 좌표 쪽이 원인이다.
RegisterCommand('sbminimalpedtest5', function(source)
    if not requireOwner(source) then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)
    local x = coords.x + math.sin(rad) * 2.0
    local y = coords.y + math.cos(rad) * 2.0
    local model = GetHashKey('a_m_y_business_01')

    U.NotifyPlayer(source, '지면 높이 비동기 조회 시작...')
    U.ResolveGroundZ(x, y, coords.z, function(z)
        local testPed = CreatePed(4, model, x, y, z, heading, true, true)
        local ok = testPed and testPed ~= 0 and DoesEntityExist(testPed)
        if ok then
            SetEntityDistanceCullingRadius(testPed, 500.0)
            FreezeEntityPosition(testPed, true)
            SetPedCanRagdoll(testPed, false)
            TriggerClientEvent('secretbag:setupNpc', -1, NetworkGetNetworkIdFromEntity(testPed), { invincible = true, blockEvents = true })
        end
        U.NotifyPlayer(source, ('결과(비동기 체인 포함, 내 위치): handle=%s exist=%s z=%.2f'):format(tostring(testPed), tostring(ok), z))
    end)
end, false)

--- 진단 전용 6단계: 실제 싸구려 감정사1 후보 좌표 중 하나(-151.9629,-447.0154)에
--- 정확히 같은 파이프라인으로 스폰해본다. test5(내 위치, 정상 렌더링)와 대조해
--- "원거리의 실제 스폰 후보 좌표 자체"가 문제인지 최종 확인한다.
RegisterCommand('sbminimalpedtest6', function(source)
    if not requireOwner(source) then return end
    local x, y = -151.9629, -447.0154
    local model = GetHashKey('a_m_y_business_01')

    U.NotifyPlayer(source, '실제 후보 좌표로 지면 높이 비동기 조회 시작...')
    U.ResolveGroundZ(x, y, 30.0, function(z)
        local testPed = CreatePed(4, model, x, y, z, 0.0, true, true)
        local ok = testPed and testPed ~= 0 and DoesEntityExist(testPed)
        if ok then
            SetEntityDistanceCullingRadius(testPed, 500.0)
            FreezeEntityPosition(testPed, true)
            SetPedCanRagdoll(testPed, false)
            TriggerClientEvent('secretbag:setupNpc', -1, NetworkGetNetworkIdFromEntity(testPed), { invincible = true, blockEvents = true })
        end
        U.NotifyPlayer(source, ('결과(실제 후보 좌표): handle=%s exist=%s z=%.2f (/sbtp %.4f %.4f %.2f 로 가서 확인)'):format(tostring(testPed), tostring(ok), z, x, y, z))
    end)
end, false)

-- ============================================================
-- 지면 높이 일괄 실측 (근본 대응)
-- ============================================================
-- 원격에서 RequestCollisionAtCoord로 콜리전을 강제 스트리밍하는 방식이 실제 스폰 후보
-- 좌표 다수에서 5초 예산 안에도 실패하는 것이 확인됐다("싸구려 감정사1 첫 후보"에서
-- 재현 — 기본 추정치 30.0으로 대체되어 실제 지면과 안 맞아 캐릭터가 맵 밖으로 떨어짐).
-- Config.NpcSpawnPools의 후보 좌표는 세션이 바뀌어도 고정값이라 매번 런타임에 힘들게
-- 원격 조회할 필요가 없다 — 관리자를 실제로 그 좌표로 순간이동시켜(카메라가 진짜 거기
-- 있으면 스트리밍이 훨씬 빠르고 확실함) 한 번만 실측한 뒤, 그 결과를 config.lua에
-- 영구히 하드코딩하는 것이 근본적인 해결책이다.
local measureGroundZWaiters = {}
local measureGroundZReqCounter = 0

local function measureGroundZ(playerId, x, y, callback)
    measureGroundZReqCounter = measureGroundZReqCounter + 1
    local requestId = measureGroundZReqCounter
    measureGroundZWaiters[requestId] = { pid = playerId, callback = callback }
    TriggerClientEvent('secretbag:measureGroundZ', playerId, requestId, x, y)
end

RegisterNetEvent('secretbag:measureGroundZResult', function(requestId, found, z)
    local waiter = measureGroundZWaiters[requestId]
    if not waiter or waiter.pid ~= source then return end
    measureGroundZWaiters[requestId] = nil
    waiter.callback(found, z)
end)

--- Config.NpcSpawnPools의 후보 좌표 전부를 순서대로 실측해 서버 콘솔에 config.lua에
--- 바로 붙여넣을 수 있는 형태로 출력한다. 완료 후 원래 위치로 복귀시킨다. 측정 도중
--- 이동하면 결과가 왜곡되니 완료될 때까지 가만히 있을 것(각 좌표당 약 2.5초 소요).
RegisterCommand('sbmeasureallgroundz', function(source)
    if not requireOwner(source) then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local originalCoords = GetEntityCoords(ped)

    local points = {}
    local poolOrder = { 'cheapAppraiser1', 'cheapAppraiser2', 'trueAppraiser', 'forger' }
    for _, poolName in ipairs(poolOrder) do
        local pool = Config.NpcSpawnPools[poolName]
        if pool then
            for i, coords in ipairs(pool) do
                table.insert(points, { label = poolName, index = i, x = coords.x, y = coords.y })
            end
        end
    end

    U.NotifyPlayer(source, ('총 %d개 후보 좌표 실측을 시작합니다. 완료될 때까지 이동하지 마세요 (좌표당 약 2.5초).'):format(#points))

    local results = {}
    local idx = 0

    local function measureNext()
        idx = idx + 1
        local p = points[idx]
        if not p then
            SetEntityCoords(ped, originalCoords.x, originalCoords.y, originalCoords.z, false, false, false, true)
            -- 사용자 요청: 서버 콘솔뿐 아니라 채팅창에서도 결과를 볼 수 있어야 한다 —
            -- U.NotifyPlayer는 콘솔 print와 클라이언트 채팅 전달을 동시에 해준다.
            U.NotifyPlayer(source, '===== 지면 높이 실측 결과 (config.lua NpcSpawnPools에 반영할 것) =====')
            for _, r in ipairs(results) do
                U.NotifyPlayer(source, ('%s[%d]: vector3(%.4f, %.4f, %.4f)  -- found=%s'):format(
                    r.label, r.index, r.x, r.y, r.z, tostring(r.found)))
            end
            U.NotifyPlayer(source, '===== 실측 종료 =====')
            return
        end
        U.NotifyPlayer(source, ('(%d/%d) %s[%d] 측정 중...'):format(idx, #points, p.label, p.index))
        measureGroundZ(source, p.x, p.y, function(found, z)
            table.insert(results, { label = p.label, index = p.index, x = p.x, y = p.y, z = z, found = found })
            measureNext()
        end)
    end

    measureNext()
end, false)

local function measureGroundZLong(playerId, x, y, callback)
    measureGroundZReqCounter = measureGroundZReqCounter + 1
    local requestId = measureGroundZReqCounter
    measureGroundZWaiters[requestId] = { pid = playerId, callback = callback }
    TriggerClientEvent('secretbag:measureGroundZLong', playerId, requestId, x, y)
end

--- /sbmeasureallgroundz 두 번 실행 결과 계속 실패하던 5곳(위조업자 3곳 전부 + 그 외 2곳)만
--- 훨씬 넉넉한 예산(약 25초/좌표)으로 재시도한다. 5곳 전부 하는데 최대 2분 정도 걸린다.
RegisterCommand('sbmeasureremaining', function(source)
    if not requireOwner(source) then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local originalCoords = GetEntityCoords(ped)

    local points = {
        { label = 'cheapAppraiser2', index = 1, x = 694.259, y = -931.2378 },
        { label = 'trueAppraiser', index = 2, x = -1018.7842, y = -1006.7688 },
        { label = 'forger', index = 1, x = 253.4792, y = -1977.5602 },
        { label = 'forger', index = 2, x = 56.1591, y = -1883.1729 },
        { label = 'forger', index = 3, x = 460.1215, y = -1735.9597 },
    }

    U.NotifyPlayer(source, ('지난번 계속 실패한 %d개 좌표를 훨씬 긴 예산으로 재시도합니다. 최대 2분 정도 걸립니다.'):format(#points))

    local results = {}
    local idx = 0

    local function measureNext()
        idx = idx + 1
        local p = points[idx]
        if not p then
            SetEntityCoords(ped, originalCoords.x, originalCoords.y, originalCoords.z, false, false, false, true)
            U.NotifyPlayer(source, '===== 재시도 결과 =====')
            for _, r in ipairs(results) do
                U.NotifyPlayer(source, ('%s[%d]: vector3(%.4f, %.4f, %.4f)  -- found=%s'):format(
                    r.label, r.index, r.x, r.y, r.z, tostring(r.found)))
            end
            U.NotifyPlayer(source, '===== 재시도 종료 =====')
            return
        end
        U.NotifyPlayer(source, ('(%d/%d) %s[%d] 측정 중... (최대 25초)'):format(idx, #points, p.label, p.index))
        measureGroundZLong(source, p.x, p.y, function(found, z)
            table.insert(results, { label = p.label, index = p.index, x = p.x, y = p.y, z = z, found = found })
            measureNext()
        end)
    end

    measureNext()
end, false)

--- 사용자 제안: 순간이동 방식은 콜리전 스트리밍이 불안정해 계속 실패하는 좌표가 있었다
--- (특히 위조업자 후보 3곳 전부). 대신 직접 걷거나 차로 이동하면 자연스럽게 스트리밍이
--- 끝난 상태가 되므로, 지도에 블립만 찍어주고 실제 도착 여부 확인 후 명령어로 현재
--- 위치를 그대로 기록받는 방식이 훨씬 안정적이다.
local remainingPoints = {
    { label = 'cheap2_1', x = 694.259, y = -931.2378 },
    { label = 'true2', x = -1018.7842, y = -1006.7688 },
    { label = 'forger1', x = 253.4792, y = -1977.5602 },
    { label = 'forger2', x = 56.1591, y = -1883.1729 },
    { label = 'forger3', x = 460.1215, y = -1735.9597 },
}

--- 계속 실패하던 5개 후보 좌표 전부에 지도 블립을 찍는다(z는 몰라도 블립 자체는 x,y만
--- 있으면 지도에 표시된다). 도착해서 /sbrecordground <label>로 현재 위치를 기록한다.
RegisterCommand('sbshowmissingblips', function(source)
    if not requireOwner(source) then return end
    local names = {}
    for _, p in ipairs(remainingPoints) do
        TriggerClientEvent('secretbag:npcBlipAdd', source, 'measure_' .. p.label, vector3(p.x, p.y, 30.0), p.label, 1, 5)
        table.insert(names, p.label)
    end
    U.NotifyPlayer(source, ('지도에 %d개 블립을 찍었습니다: %s'):format(#remainingPoints, table.concat(names, ', ')))
end, false)

--- 해당 블립 근처로 직접 이동한 뒤 실행 — 현재 위치를 그 label로 기록해 채팅/콘솔에 출력한다.
RegisterCommand('sbrecordground', function(source, args)
    if not requireOwner(source) then return end
    local label = args[1]
    if not label then
        U.NotifyPlayer(source, '사용법: /sbrecordground <label> (예: forger1)')
        return
    end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    U.NotifyPlayer(source, ('기록됨: %s -> vector3(%.4f, %.4f, %.4f)'):format(label, coords.x, coords.y, coords.z))
end, false)

--- 진단 전용: 지금까지 CreatePed(ped)로는 이 종류 크래시를 한 번도 못 봤는데
--- CreateObject(가방)에서는 계속 재현된다 — ped와 object가 실제로 다르게 동작하는지
--- 확인하는 마지막 분리 테스트. RegisterCommand에서 곧바로(비동기/CreateThread 없이)
--- 가방 프롭을 만들어본다.
--- existsAfterCreate=false로 확인됨 — CreateObject 직후 곧바로도 존재하지 않는다는 뜻이라
--- prop_attache_case_01 모델 자체가 문제일 가능성이 생겼다. 인자로 모델명을 받아 다른
--- (아주 흔히 쓰이는) 프롭과 비교해본다. 예: /sbminimalobjecttest prop_barrel_02a
--- 웹 검색으로 확인된 FiveM 커뮤니티 지식: "서버 쪽 엔티티 생성은 같은 틱에 끝나지 않는다
--- — CreateObject/CreatePed는 핸들을 즉시 반환하지만 실제 등록은 이후 틱에 완료된다."
--- 지금까지 DoesEntityExist를 생성 직후 곧바로(같은 틱에) 확인해온 것 자체가 성급했을
--- 수 있다 — Wait(0)로 틱을 넘기며 DoesEntityExist가 true가 될 때까지 기다려본다.
RegisterCommand('sbminimalobjecttest', function(source, args)
    if not requireOwner(source) then return end
    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local modelName = args[1] or 'prop_attache_case_01'
    local model = GetHashKey(modelName)
    local entity = CreateObject(model, coords.x, coords.y, coords.z, true, true, false)
    local existsImmediately = entity and entity ~= 0 and DoesEntityExist(entity)
    local tries = 0
    while entity and entity ~= 0 and not DoesEntityExist(entity) and tries < 50 do
        Wait(0)
        tries = tries + 1
    end
    local existsAfterWait = entity and entity ~= 0 and DoesEntityExist(entity)
    local ok, err = pcall(function()
        SetEntityDistanceCullingRadius(entity, 500.0)
    end)
    U.NotifyPlayer(source, ('모델=%s handle=%s existsImmediately=%s existsAfterWait(틱 %d회)=%s cullingOk=%s err=%s'):format(
        modelName, tostring(entity), tostring(existsImmediately), tries, tostring(existsAfterWait), tostring(ok), tostring(err)))
end, false)

--- 사용자 요청: 승자 확정 시 전원에게 자동 방송하지 않고, 원할 때 본인 채팅으로만
--- 조회한다. SecretBagMode.LogTimelineEvent(state.lua)가 기록해둔 현재 세션의 이벤트
--- 타임라인(경과 시각 + 라벨)을 그대로 보여준다 — 게임 진행 중에도, 끝난 뒤에도 쓸 수 있다.
RegisterCommand('sbtimeline', function(source)
    if not requireOwner(source) then return end
    local session = currentSession(source)
    if not session then return end
    if #session.timelineLog == 0 then
        U.NotifyPlayer(source, '아직 기록된 이벤트가 없습니다.')
        return
    end
    U.NotifyPlayer(source, '===== 이벤트 타임라인 =====')
    for _, entry in ipairs(session.timelineLog) do
        U.NotifyPlayer(source, ('%d분: %s'):format(entry.min, entry.label))
    end
    U.NotifyPlayer(source, '===== 타임라인 종료 =====')
end, false)

-- ============================================================
-- 전체 후보 지점 일괄 스폰 (좌표 검증용)
-- ============================================================
-- 평소엔 풀마다 랜덤으로 1곳만 골라 스폰하므로 나머지 후보는 실제 게임 중에 볼 일이
-- 없다 — 사용자 요청: "가능한 모든 지점에 NPC들을 스폰하는 명령어" — 게임 세션 유무와
-- 무관하게 Config.NpcSpawnPools의 12개 후보 좌표 전부에 한 번에 NPC를 띄워 한눈에
-- 검증할 수 있게 한다.
local allCandidatePeds = {}

RegisterCommand('sbspawnallcandidates', function(source)
    if not requireOwner(source) then return end
    for _, ped in ipairs(allCandidatePeds) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    allCandidatePeds = {}

    local appraiserModel = GetHashKey('a_m_y_business_01')
    local forgerModel = GetHashKey('a_m_y_business_02')
    local poolOrder = { 'cheapAppraiser1', 'cheapAppraiser2', 'trueAppraiser', 'forger' }
    local count = 0

    for _, poolName in ipairs(poolOrder) do
        local pool = Config.NpcSpawnPools[poolName]
        if pool then
            local model = (poolName == 'forger') and forgerModel or appraiserModel
            for i, coords in ipairs(pool) do
                local heading = math.random(0, 359)
                local ped = SecretBagMode.Util.CreateEntitySafely(3, 300,
                    function()
                        return CreatePed(4, model, coords.x, coords.y, coords.z, heading, true, true)
                    end,
                    function(p)
                        SetEntityDistanceCullingRadius(p, 500.0)
                        FreezeEntityPosition(p, true)
                        SetPedCanRagdoll(p, false)
                    end)
                if ped then
                    table.insert(allCandidatePeds, ped)
                    count = count + 1
                    local label = ('%s[%d]'):format(poolName, i)
                    TriggerClientEvent('secretbag:npcBlipAdd', -1, 'candidate_' .. label, coords, label, 1, 5)
                end
            end
        end
    end
    debugPrint(source, ('%d개 후보 지점 전부에 NPC를 스폰했습니다. 지도 블립으로 확인하세요. /sbdespawnallcandidates로 정리.'):format(count))
end, false)

RegisterCommand('sbdespawnallcandidates', function(source)
    if not requireOwner(source) then return end
    for _, ped in ipairs(allCandidatePeds) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    local removed = #allCandidatePeds
    allCandidatePeds = {}
    debugPrint(source, ('전체 후보 NPC %d개를 정리했습니다.'):format(removed))
end, false)

print('[SecretBag] Config.Debug.enabled=true — DEBUG_COMMANDS.md 참고. /sbdump로 전체 명령 동작 확인 가능')
