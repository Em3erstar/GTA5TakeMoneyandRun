--- FinalZoneCheck / 승자확정 (기획서 12장 / 사양서 REQ-FINAL-001~004, finalizeWinnerState()).
--- 좌표 로직은 완성되어 있으나 Config.FinalZoneCenter가 비어있는 동안은 항상
--- "genuine outside"로 판정되어 안전하게 +5분 연장만 반복한다 (좌표 확정 전 오판정 방지).

local U = SecretBagMode.Util
local BagState = SecretBagMode.BagState
local SessionState = SecretBagMode.SessionState
local HistEvt = SecretBagMode.HistoryEventType
local ErrorCode = SecretBagMode.ErrorCode

SecretBagMode.FinalZone = SecretBagMode.FinalZone or {}
local FZ = SecretBagMode.FinalZone

local function isInsideFinalZone(coords)
    if not Config.FinalZoneCenter or not coords then
        return false
    end
    local dx = coords.x - Config.FinalZoneCenter.x
    local dy = coords.y - Config.FinalZoneCenter.y
    return (dx * dx + dy * dy) <= (Config.FinalZone.radius * Config.FinalZone.radius)
end

--- death.lua REQ-DEATH-002에서 사용: "FinalZone lock 이후 내부 사망자"인지 판정하려면
--- 이 내부 판정 로직이 필요해서 공개해둔다.
FZ.IsInsideFinalZone = isInsideFinalZone

--- REQ-FINAL-002: connected && activeCharacterInside + FinalZone 내부 death respawn wait 참가자.
--- SERVER_OWNER/HELPER/nonparticipant 제외. NPC 없이 좌표 존재 여부에만 의존하는 최소 구현.
local function countValidParticipantsInside(session)
    local count = 0
    for pid in pairs(session.sessionParticipantIds) do
        if U.IsPlayerOnline(pid) then
            local ps = session.playerSessions[pid]
            if ps and ps.pendingFinalZoneRespawn then
                -- death.lua가 FinalZone 내부 사망 시 세팅한다: 사망 직후 60초 부활 대기 중인
                -- 참가자는 ped가 죽어있거나 좌표가 일시적으로 이상해도 "내부"로 계속 카운트한다
                -- (그렇지 않으면 사망 순간 카운트가 순간적으로 0이 되어 오판정이 날 수 있다).
                -- REQ-FINAL-002 원문이 "connected &&"를 전제로 하므로, 부활 대기 중이라도
                -- 접속이 끊겼으면(온라인 체크 실패) 카운트하지 않는다 — 위 U.IsPlayerOnline(pid)로 이미 보장됨.
                count = count + 1
            else
                local ped = GetPlayerPed(tostring(pid))
                if ped and ped ~= 0 and isInsideFinalZone(GetEntityCoords(ped)) then
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- 우선순위 1..4 평가 (기획서 12장 표).
local function evaluatePriority(session, bag)
    if bag.currentOwnerId ~= nil and bag.currentOwnerId == SecretBagMode.RoleState.activeServerOwnerId then
        return 1
    end

    local coords = SecretBagMode.Bag.ResolveCoords(bag)
    if not isInsideFinalZone(coords) then
        return 2
    end

    if countValidParticipantsInside(session) == 0 then
        return 3
    end

    if bag.state == BagState.INVENTORY then
        return '4A'
    end
    return '4B'
end

--- REQ-LIVE-001: 270분 이후 FinalZoneCheck 실패(우선순위 1/2/3) 시 genuine/owner coords를
--- 실시간 공개한다. Bag.ResolveCoords가 "owner 보유면 owner 좌표, 아니면 worldCoords" 규칙을
--- 이미 구현하므로 owner/outside/empty 세 경우 모두 같은 resolve 함수로 충분하다(문서의
--- 3가지 source 분기가 사실상 동일 로직). lock 전까지 몇 초 간격으로 계속 갱신해 방송한다.
function FZ.EnsureLiveReveal(session)
    if not Config.Features.liveReveal then return end
    if session.liveRevealActive then return end
    session.liveRevealActive = true

    CreateThread(function()
        while SecretBagMode.CurrentSession == session
            and not session.finalZoneLocked
            and session.state ~= SessionState.ENDED
            and Config.Features.liveReveal do
            local bag = SecretBagMode.Bag.GetGenuine(session)
            if bag then
                TriggerClientEvent('secretbag:liveReveal', -1, SecretBagMode.Bag.ResolveCoords(bag))
            end
            Wait(3000)
        end
        session.liveRevealActive = false
        TriggerClientEvent('secretbag:liveRevealClear', -1)
    end)
end

--- REQ-FINAL-003 FinalBarrier: lock 시점에 각 참가자가 있던 쪽("inside"/"outside")을 그대로
--- 고정해, 그 뒤로 경계를 넘어가려고 하면 넘어가기 직전(마지막으로 자기 쪽에서 확인된) 좌표로
--- 되돌린다. 서버가 직접 GetEntityCoords/SetEntityCoords를 쓰므로(이미 police.lua 추격
--- 판정·debug.lua /sbtp 등에서 검증된 방식) 별도 클라이언트 왕복이 필요 없다. z를 임의로
--- 계산하지 않고 "그 참가자 본인이 실제로 서 있었던" 마지막 좌표만 재사용하므로 지면에
--- 파묻히거나 공중에 뜨는 문제가 없다.
--- 한계: 이 방식은 "위치 이동(crossing)"만 막는다. "bullets/projectiles/explosions/ram
--- damage를 경계 너머로 양방향 차단"까지는 하지 못한다 — FiveM에 서버 권위형 피해 이벤트
--- 감지 표준 API가 없다는 문제는 death.lua 헤더에서 이미 다룬 동일한 신뢰 경계 한계라,
--- 이 프로젝트의 기존 접근 방식(불안정한 이벤트 가로채기 대신 명확히 구현 가능한 부분만
--- 구현)을 그대로 따른다. winner가 확정되면(FinalizeWinnerState) 전원에게 무적이 걸려
--- (ApplyProtection) 어차피 그 시점부터는 피해 자체가 발생하지 않는다 — 실질적으로 피해가
--- 문제되는 구간은 FINAL_LOCKED_CONTEST(승자 미확정) 상태뿐이며, 그 구간의 피해 차단은
--- 아직 미구현 상태로 남는다.
local barrierSide = {} -- [playerId] = 'inside' | 'outside' (lock 시점에 고정)
local barrierLastCoords = {} -- [playerId] = vector3, 자기 쪽에서 마지막으로 확인된 좌표

local function startFinalBarrier(session)
    barrierSide = {}
    barrierLastCoords = {}

    CreateThread(function()
        while SecretBagMode.CurrentSession == session
            and session.finalZoneLocked
            and not session.winnerLocked
            and session.state ~= SessionState.ENDED do
            for pid in pairs(session.sessionParticipantIds) do
                if U.IsPlayerOnline(pid) then
                    local ped = GetPlayerPed(tostring(pid))
                    if ped and ped ~= 0 then
                        local coords = GetEntityCoords(ped)
                        local nowInside = isInsideFinalZone(coords)
                        local side = barrierSide[pid]
                        if not side then
                            barrierSide[pid] = nowInside and 'inside' or 'outside'
                            barrierLastCoords[pid] = coords
                        elseif (side == 'inside') == nowInside then
                            barrierLastCoords[pid] = coords
                        else
                            local back = barrierLastCoords[pid]
                            if back then
                                SetEntityCoords(ped, back.x, back.y, back.z, false, false, false, true)
                            end
                        end
                    end
                end
            end
            Wait(500)
        end
        barrierSide = {}
        barrierLastCoords = {}
    end)
end

local function lockZone(session, bag)
    -- 현재 호출 경로(runCheck)는 session.state == RUNNING일 때만 도달하고, lockZone 자체가
    -- 그 즉시 state를 RUNNING에서 빠져나가게 만들어 이중 호출이 실제로 일어나진 않는다.
    -- 그래도 startFinalBarrier가 CreateThread를 새로 띄우는 부작용이 있어, 리팩터링 중
    -- 실수로 이중 호출 경로가 생기더라도 barrierSide/barrierLastCoords가 중간에 리셋되며
    -- 스레드가 중복 실행되는 사고를 막기 위해 idempotent 가드를 둔다.
    if session.finalZoneLocked then return end

    bag.finalZoneLock = true
    session.finalZoneLocked = true
    startFinalBarrier(session)

    -- 기획서 8장: "FinalZone lock 즉시 TraceService 종료 및 기존 ping 제거."
    -- trace.lua의 스케줄러는 session.finalZoneLocked를 보고 스스로 멈춘다.
    TriggerClientEvent('secretbag:traceClearAll', -1)

    -- 사용자 요청: 최종 구역이 지도에 원형으로 표시되지 않는다는 보고 — 봉쇄 확정
    -- (FINAL_LOCKED_CONTEST) 순간부터는 FinalBarrier가 실제로 이동을 막는 벽이 되므로,
    -- 그 시점부터는 참가자들도 경계를 볼 수 있어야 자연스럽다. livereveal.lua와 동일한
    -- circleReveal 이벤트를 재사용(TTL 없이 게임 종료까지 유지).
    TriggerClientEvent('secretbag:circleReveal', -1, 'finalzone', Config.FinalZoneCenter, Config.FinalZone.radius)
    SecretBagMode.LogTimelineEvent(session, '최종 구역 봉쇄 확정')
end

--- server/debug.lua의 /sbforcewin에서 재사용할 수 있도록 공개해둔다 — FinalizeWinnerState만
--- 단독 호출하면 session.finalZoneLocked가 계속 false로 남아 Trace 스케줄러(trace.lua의
--- 루프 조건 `not session.finalZoneLocked`)가 게임이 사실상 끝난 뒤에도 계속 돌아가는
--- 버그가 있었다 — 실전 4A 경로(runCheck)와 동일하게 lockZone을 먼저 거쳐야 한다.
FZ.LockZone = lockZone

--- finalizeWinnerState() (기획서 15장). idempotent: 이미 잠겼으면 아무 것도 하지 않는다.
function SecretBagMode.FinalizeWinnerState(session, winnerId, source)
    if session.winnerLocked or session.finalWinnerPlayerId ~= nil then
        return false
    end

    session.finalWinnerPlayerId = winnerId
    session.winnerLocked = true

    for _, playerId in ipairs(GetPlayers()) do
        SecretBagMode.ApplyProtection(tonumber(playerId), true)
    end

    session.mutationLocked = true -- inventory.lua의 pickup/drop 경로(requireCanTouchBag)가 이 플래그를 검사한다.

    SecretBagMode.TransitionTo(session, SessionState.FINISHING)

    local winnerName = GetPlayerName(tostring(winnerId)) or ('ID ' .. tostring(winnerId))
    -- 사용자 요청: 전원에게 자동 방송하지 않는다 — 기록만 남겨두고, 보고 싶은 사람이
    -- /sbtimeline으로 직접 조회한다(server/debug.lua).
    SecretBagMode.LogTimelineEvent(session, ('승자 확정 (%s)'):format(winnerName))
    U.NotifyAll('마무리')

    SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.WINNER_LOCKED, winnerId, {
        cause = source,
    })
    return true
end

local function runCheck(session)
    U.WithLock('finalzonecheck', function()
        local bag = SecretBagMode.Bag.GetGenuine(session)
        if not bag then return end

        local priority = evaluatePriority(session, bag)

        SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.FINAL_CHECK, nil, {
            priorityReason = priority,
            genuinePos = SecretBagMode.Bag.ResolveCoords(bag),
            ownerId = bag.currentOwnerId,
            insideCount = countValidParticipantsInside(session),
        })

        if priority == 1 or priority == 2 or priority == 3 then
            session.scheduledCloseAt = session.scheduledCloseAt + Config.Timeline.finalCheckIntervalMin
            local codeByPriority = { [1] = ErrorCode.FINAL_OWNER_HOLD, [2] = ErrorCode.FINAL_OUTSIDE, [3] = ErrorCode.FINAL_EMPTY }
            U.NotifyAll(SecretBagMode.Message[codeByPriority[priority]])
            FZ.EnsureLiveReveal(session)
        elseif priority == '4A' then
            lockZone(session, bag)
            SecretBagMode.FinalizeWinnerState(session, bag.currentOwnerId, 'held')
        elseif priority == '4B' then
            lockZone(session, bag)
            SecretBagMode.TransitionTo(session, SessionState.FINAL_LOCKED_CONTEST)
            U.NotifyAll('돈가방을 확보하라!')
            SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.FINAL_LOCKED_CONTEST, nil, {
                coords = SecretBagMode.Bag.ResolveCoords(bag),
                scheduledCloseAt = session.scheduledCloseAt,
            })
        end
    end)
end

-- server/debug.lua의 /sbforcecheck에서 대기 없이 즉시 1회 실행할 수 있도록 공개해둔다.
FZ.RunCheckNow = runCheck

--- REQ-FINAL-001: 270분 최초, 실패 시 정확히 +5분. 중간 상태 변경으로 즉시 재검사하지 않는다.
function FZ.StartScheduler(session)
    session.scheduledCloseAt = Config.Timeline.finalCheckFirstAt

    CreateThread(function()
        while SecretBagMode.CurrentSession == session and session.state == SessionState.RUNNING do
            local elapsed = SecretBagMode.MainElapsedMinutes(session)
            if elapsed and session.scheduledCloseAt and elapsed >= session.scheduledCloseAt then
                runCheck(session)
            end
            Wait(5000)
        end
    end)
end

--- REQ-FINAL-004: FINAL_LOCKED_CONTEST에서 genuine pickup은 원자 처리.
--- inventory add commit -> winner ID set -> finalizeWinnerState. SERVER_OWNER pickup 거부.
--- 동시 pickup은 U.WithLock으로 1건만 성공.
--- winner_pickup 잠금 내부에서 인벤토리 체크까지 하면 U.WithLock이 pcall 결과값을 하나만
--- 전달해 실패 사유(NO_SLOT)를 구분해 돌려줄 수 없다. 그래서 슬롯 체크는 잠금 밖에서 먼저
--- 한다 — util.lua가 명시하듯 FiveM Lua는 yield 없는 한 이벤트 핸들러 사이에서 원자적이라
--- 체크와 잠금 획득 사이에 다른 pickup이 끼어들 수 없어 안전하다.
function FZ.TryContestPickup(session, playerId)
    if session.state ~= SessionState.FINAL_LOCKED_CONTEST then
        return false, ErrorCode.NOT_CONTEST
    end
    if SecretBagMode.IsServerOwner(playerId) then
        return false, ErrorCode.OWNER_DENIED
    end
    if not SecretBagMode.Inventory.HasFreeSlot(session, playerId) then
        return false, ErrorCode.NO_SLOT
    end

    local ok, won = U.WithLock('winner_pickup', function()
        if session.winnerLocked then return false end
        local bag = SecretBagMode.Bag.GetGenuine(session)
        if not bag or bag.state ~= BagState.WORLD_DROP then return false end

        SecretBagMode.Bag.OnPickup(session, bag, playerId, SecretBagMode.Role.PLAYER)
        SecretBagMode.FinalizeWinnerState(session, playerId, 'contestPickup')
        return true
    end)

    if not ok then return false, ErrorCode.RACE_LOST end
    return won
end

function FZ.Cleanup(session)
    session.scheduledCloseAt = nil
    -- StartScheduler의 CreateThread는 session.state ~= RUNNING이 되는 즉시 루프를 빠져나간다.
end
