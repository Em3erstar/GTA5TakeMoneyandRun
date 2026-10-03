--- 감정 시스템 (기획서 6장 / 사양서 REQ 9 Appraiser API 표).
--- CheapAppraiser, 진짜 감정사(구 True#1 — 두 번째 진짜 감정사는 사용자 확정 규칙(2026)으로
--- 삭제됨), FinalTrue(pre-lock/post-lock) 전부 구현 완료.

local U = SecretBagMode.Util
local Role = SecretBagMode.Role
local BagState = SecretBagMode.BagState
local SessionState = SecretBagMode.SessionState
local HistEvt = SecretBagMode.HistoryEventType

SecretBagMode.Appraiser = SecretBagMode.Appraiser or {}
local A = SecretBagMode.Appraiser

--- Score 고정 대사 (기획서 6.1 표). 낮은 max부터 순서대로 검사한다.
A.CheapDialogueTiers = {
    { max = 14, text = '이건 너무 티가 나는데. 거의 가짜라고 봐도 되겠어.' },
    { max = 29, text = '가짜 쪽에 가까워 보여. 안쪽 마감도 좀 이상하고.' },
    { max = 44, text = '수상한 부분이 꽤 있군. 난 별로 믿음이 안 가.' },
    { max = 55, text = '애매해. 이 정도로는 나도 확신 못 하겠어.' },
    { max = 70, text = '제법 잘 만들어졌어. 진짜일 가능성도 있겠는데.' },
    { max = 85, text = '상태가 꽤 괜찮아. 진짜 쪽에 더 가까워 보여.' },
    { max = 100, text = '딱히 흠이 안 보여. 진짜라고 해도 이상하지 않겠어.' },
}

local function dialogueForScore(score)
    for _, tier in ipairs(A.CheapDialogueTiers) do
        if score <= tier.max then return tier.text end
    end
    return A.CheapDialogueTiers[#A.CheapDialogueTiers].text
end

-- 's_m_y_business_01'은 실재하지 않는 ped 모델명이었다(docs.fivem.net ped-models 목록에
-- 없음 — 실존하는 's_m_y_busboy_01'/'a_m_y_business_01'과 혼동된 이름으로 보인다).
-- CreatePed 자체는 무효 모델에도 핸들을 반환해(DoesEntityExist도 true) 서버 쪽 실패
-- 감지에는 걸리지 않지만, 클라이언트가 그 모델을 렌더링할 수 없어 사실상 안 보이는
-- ped가 되는 것으로 보인다("NPC가 안 보인다" 보고의 실제 원인) — forger.lua가 이미 쓰고
-- 있는 것과 같은 계열의 실존 모델 'a_m_y_business_01'로 교체.
local appraiserPedModel = GetHashKey('a_m_y_business_01')

-- 원본 좌표 데이터(npc_spawn_place.txt)에 heading이 없어 스폰마다 랜덤으로 준다.
-- SetEntityInvincible/SetBlockingOfNonTemporaryEvents는 FiveM API set이 client 전용이라
-- 서버에서 직접 호출하면 "attempt to call a nil value"로 죽는다(client/main.lua의
-- secretbag:setupNpc 핸들러 주석 참고) — 클라이언트에 위임한다. FreezeEntityPosition/
-- SetPedCanRagdoll은 서버 native(API set: server)가 따로 있어 그대로 둔다.
-- z 보정: config.lua의 Config.NpcSpawnPools 좌표는 예전엔 NPC_Z_DEFAULT(=30.0) 추정치라
-- 실제 지형과 안 맞아 NPC가 파묻히거나 공중에 떠서 사실상 안 보이는(=스폰 안 된 것처럼
-- 보이는) 문제가 있었다 — 원격 GetGroundZFor_3dCoord 자동 보정도 시도했으나 콜리전
-- 스트리밍이 25초를 줘도 실패하는 좌표가 있어 신뢰할 수 없었다. 결국 관리자가 직접
-- 해당 좌표로 이동해 실측한 값을 config.lua에 영구히 박아넣는 것으로 근본 해결했다
-- (server/debug.lua /sbmeasureallgroundz, /sbrecordground) — 이제 이 좌표들은 전부
-- 실측값이라 런타임에 더 이상 지면 높이를 구할 필요가 없다.
-- SetEntityDistanceCullingRadius(API set: server, docs.fivem.net 확인): 이걸 안 걸면
-- OneSync가 "이 엔티티가 더 이상 relevant하지 않다"고 판단해 스폰 직후 서버가 조용히
-- 정리해버릴 수 있다. deprecated 경고가 있지만 실제 크래시 원인은 이 native가 아니었다 —
-- /sbminimalobjecttest로 실측 확인한 진짜 원인은 "서버 쪽 CreatePed/CreateObject는 핸들을
-- 즉시 반환하지만 실제 등록은 몇 틱 뒤에 끝난다"는 것이었다. 생성 직후 같은 틱에 아무
-- 후속 native나 부르면 (SetEntityDistanceCullingRadius든 대체 native든 무엇이든) 항상
-- "Tried to access invalid entity"로 죽었다. U.CreateEntitySafely가 DoesEntityExist가
-- true가 될 때까지 Wait(0)로 기다린 뒤에만 아래 setupFn을 호출하므로 여기서는 신경 쓸
-- 필요 없다.
local function spawnAppraiserPed(coords, callback)
    local heading = math.random(0, 359)
    local ped = SecretBagMode.Util.CreateEntitySafely(5, 300,
        function()
            return CreatePed(4, appraiserPedModel, coords.x, coords.y, coords.z, heading, true, true)
        end,
        function(p)
            SetEntityDistanceCullingRadius(p, 500.0)
            FreezeEntityPosition(p, true)
            SetPedCanRagdoll(p, false)
        end)
    if not ped then
        print('[SecretBag] 경고: 감정사 ped 생성 실패 (5회 재시도 후에도 실패)')
        callback(nil, coords)
        return
    end
    TriggerClientEvent('secretbag:setupNpc', -1, NetworkGetNetworkIdFromEntity(ped), { invincible = true, blockEvents = true })
    callback(ped, coords)
end

local function despawnPed(ped)
    if ped and DoesEntityExist(ped) then
        DeleteEntity(ped)
    end
end

--- 사용자 요청: 싸구려/진짜 감정사는 지도에 표시되어야 한다(경찰 정보 핑 등과 달리
--- 원래는 마커 없이 직접 찾아다니는 설계였으나, 요청에 따라 여기서만 예외적으로 추가).
--- npcId(예: 'cheap_1', 'true1')를 key로 클라이언트가 블립을 추적·정리한다.
local function addNpcBlip(npcId, coords, label, colour)
    TriggerClientEvent('secretbag:npcBlipAdd', -1, npcId, coords, label, 1, colour)
end

local function removeNpcBlip(npcId)
    TriggerClientEvent('secretbag:npcBlipRemove', -1, npcId)
end

--- role/participant 접근권한 검사 공통 (모든 Appraiser 공통, REQ 9 표 "participant" 열).
local function checkAccessRole(session, playerId)
    local role = SecretBagMode.GetRole(playerId)
    if role == nil or role == Role.HELPER or role == Role.LATE_NONPARTICIPANT then
        return nil, SecretBagMode.ErrorCode.NO_ACCESS
    end
    if role == Role.PLAYER and not SecretBagMode.IsParticipant(session, playerId) then
        return nil, SecretBagMode.ErrorCode.NO_ACCESS
    end
    local ps = session.playerSessions[playerId]
    if ps and ps.awaitingRespawn then
        return nil, SecretBagMode.ErrorCode.AWAITING_RESPAWN
    end
    return role
end

local function findHeldSingleBag(session, playerId)
    for _, bag in pairs(session.bags) do
        if bag.currentOwnerId == playerId and bag.state == BagState.INVENTORY then
            return bag
        end
    end
    return nil
end

-- ============================================================
-- CheapAppraiser
-- ============================================================

A.CheapNpcs = {} -- [npcId] = { ped = entity, coords = vector3 }

--- npc_spawn_place.txt의 [싸구려 감정사 1]/[싸구려 감정사 2] 후보 풀에서 각각 랜덤으로 하나씩 고른다.
--- 두 NPC가 같은 좌표에 겹쳐 스폰되지 않도록 애초에 풀을 분리해뒀다.
function A.SpawnCheap(session)
    if not Config.Features.cheapAppraiser then return end
    SecretBagMode.LogTimelineEvent(session, '싸구려 감정사 등장')
    A.CheapNpcs = {}
    local pools = { cheap_1 = Config.NpcSpawnPools.cheapAppraiser1, cheap_2 = Config.NpcSpawnPools.cheapAppraiser2 }
    for npcId, pool in pairs(pools) do
        local coords = U.PickRandom(pool)
        if coords then
            A.CheapNpcs[npcId] = { ped = nil, coords = coords }
            spawnAppraiserPed(coords, function(ped, spawnCoords)
                -- 그 사이 DespawnCheap(예: /feature cheapAppraiser off)이 호출됐으면
                -- A.CheapNpcs가 통째로 교체돼 이 npcId 키가 더 이상 없다 — 취소 처리.
                if not A.CheapNpcs[npcId] then return end
                A.CheapNpcs[npcId].ped = ped
                A.CheapNpcs[npcId].coords = spawnCoords
                addNpcBlip(npcId, spawnCoords, '싸구려 감정사', 5)
            end)
        end
    end
end

--- server/features.lua에서 끌 때 사용 (켤 때는 다른 요소들과 동일하게 StartScheduler
--- 폴링 루프가 MarkTimelineEventOnce 미소비 플래그로 알아서 "뒤늦게" 다시 스폰한다).
function A.DespawnCheap()
    for npcId, npc in pairs(A.CheapNpcs) do
        despawnPed(npc.ped)
        removeNpcBlip(npcId)
    end
    A.CheapNpcs = {}
end

local function findNearestCheapNpc(ped)
    local playerCoords = GetEntityCoords(ped)
    local nearestId, nearestDist = nil, Config.Appraiser.interactDistance
    for npcId, npc in pairs(A.CheapNpcs) do
        if npc.ped and DoesEntityExist(npc.ped) then
            local dist = #(playerCoords - GetEntityCoords(npc.ped))
            if dist < nearestDist then
                nearestId, nearestDist = npcId, dist
            end
        end
    end
    return nearestId
end

--- REQ 9 Cheap 행: participant, NPC active, distance, bagCount==1, cooldown elapsed.
--- SERVER_OWNER는 bagCount==1만 적용, cooldown 면제, genuine cheapVisitHistory에는 미기록.
RegisterCommand('usecheap', function(source)
    local playerId = source
    local session = SecretBagMode.CurrentSession
    if not session then return end

    local role, accessErr = checkAccessRole(session, playerId)
    if not role then
        U.NotifyPlayer(playerId, SecretBagMode.Message[accessErr])
        return
    end

    local ped = GetPlayerPed(tostring(playerId))
    if not ped or ped == 0 then return end

    local npcId = findNearestCheapNpc(ped)
    if not npcId then
        U.NotifyPlayer(playerId, '근처에 감정사가 없습니다.')
        return
    end

    if SecretBagMode.Inventory.CountBags(session, playerId) ~= 1 then
        U.NotifyPlayer(playerId, 'SecretBag을 정확히 1개 소지하고 있어야 합니다.')
        return
    end

    local isOwner = (role == Role.SERVER_OWNER)
    local ps = session.playerSessions[playerId]

    if not isOwner then
        local cd = ps and ps.cooldowns.cheap
        if cd and U.Now() < cd then
            U.NotifyPlayer(playerId, ('아직 쿨다운 중입니다. (%d분 남음)'):format(math.ceil((cd - U.Now()) / 60000)))
            return
        end
    end

    local heldBag = findHeldSingleBag(session, playerId)
    if not heldBag then
        U.NotifyPlayer(playerId, 'SecretBag을 소지하고 있어야 합니다.')
        return
    end

    if isOwner then
        if heldBag.isGenuine then
            SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.ADMIN_CHEAP_APPRAISAL, playerId, {
                appraiserId = npcId,
                bagId = heldBag.bagId,
            })
        end
    else
        ps.cooldowns.cheap = U.Now() + Config.Appraiser.cheapCooldownMs
        table.insert(heldBag.cheapVisitHistory, npcId)
        if heldBag.isGenuine then
            SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.CHEAP_APPRAISAL, playerId, {
                appraiserId = npcId,
                bagId = heldBag.bagId,
            })
        end
    end

    TriggerClientEvent('secretbag:appraiserDialogue', playerId, npcId, dialogueForScore(heldBag.appearanceScore))
end, false)

-- ============================================================
-- 진짜 감정사 — 가방 1개 진위 확정 (사용자 확정 규칙: 60분 등장, 디스폰 없이 게임 종료까지
-- 영구 유지, 서버 전체 무제한 이용, 개인 쿨다운만 존재). 원래 있던 두 번째 진짜 감정사는
-- 완전히 삭제됐다 — npcId는 기존 코드/문서와의 호환을 위해 'true1'을 그대로 쓴다.
-- ============================================================

A.TrueState = {
    true1 = { ped = nil, active = false },
}

function A.SpawnTrue(session)
    local coords = U.PickRandom(Config.NpcSpawnPools.trueAppraiser)
    if not coords then return end
    A.TrueState.true1.active = true
    spawnAppraiserPed(coords, function(ped, spawnCoords)
        if not A.TrueState.true1.active then return end -- 그 사이 DespawnTrue로 취소됐으면 무시
        A.TrueState.true1.ped = ped
        addNpcBlip('true1', spawnCoords, '진짜 감정사', 2)
    end)
    SecretBagMode.LogTimelineEvent(session, '진짜 감정사 등장')
    U.NotifyAll('진짜 감정사가 도착했습니다.')
end

local function findNearestTrueNpc(ped)
    local playerCoords = GetEntityCoords(ped)
    local npc = A.TrueState.true1
    if npc.active and npc.ped and DoesEntityExist(npc.ped) then
        local dist = #(playerCoords - GetEntityCoords(npc.ped))
        if dist < Config.Appraiser.interactDistance then
            return 'true1'
        end
    end
    return nil
end

--- REQ 9 True 행: participant, active, bagCount==1, personal cooldown. 서버 전체 사용
--- 한도는 없다(무제한). SERVER_OWNER는 bagCount==1만 적용, cooldown 면제.
RegisterCommand('usetrue', function(source)
    local playerId = source
    local session = SecretBagMode.CurrentSession
    if not session then return end

    local role, accessErr = checkAccessRole(session, playerId)
    if not role then
        U.NotifyPlayer(playerId, SecretBagMode.Message[accessErr])
        return
    end

    local ped = GetPlayerPed(tostring(playerId))
    if not ped or ped == 0 then return end

    local npcId = findNearestTrueNpc(ped)
    if not npcId then
        U.NotifyPlayer(playerId, '근처에 진짜 감정사가 없습니다.')
        return
    end

    if SecretBagMode.Inventory.CountBags(session, playerId) ~= 1 then
        U.NotifyPlayer(playerId, 'SecretBag을 정확히 1개 소지하고 있어야 합니다.')
        return
    end

    local isOwner = (role == Role.SERVER_OWNER)
    local ps = session.playerSessions[playerId]
    if not isOwner then
        local cd = ps and ps.cooldowns[npcId]
        if cd and U.Now() < cd then
            U.NotifyPlayer(playerId, ('아직 쿨다운 중입니다. (%d분 남음)'):format(math.ceil((cd - U.Now()) / 60000)))
            return
        end
    end

    local heldBag = findHeldSingleBag(session, playerId)
    if not heldBag then
        U.NotifyPlayer(playerId, 'SecretBag을 소지하고 있어야 합니다.')
        return
    end

    if not isOwner then
        ps.cooldowns[npcId] = U.Now() + Config.Appraiser.trueCooldownMs
        -- HUD 시계 아래 안내문(#status) 갱신용 — hud.lua BroadcastTimelineSync의 재접속
        -- 동기화와 동일한 필드(elapsedMs 기준 만료 시각)를 쓴다.
        TriggerClientEvent('secretbag:trueApprCooldown', playerId, ps.cooldowns[npcId] - session.mainStartedAt)
    end

    if heldBag.isGenuine then
        SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.TRUE_APPRAISAL, playerId, {
            appraiser = npcId,
            bagId = heldBag.bagId,
            result = true,
        })
    end

    TriggerClientEvent('secretbag:trueAppraisalResult', playerId, npcId, heldBag.bagId, heldBag.isGenuine)
end, false)

-- ============================================================
-- Final True — pre-lock(가방 1개 진위 확정) / post-lock(보유 가방 전체 genuine 존재 여부).
-- 사용자 확정 규칙: 서버 전체 사용 한도 없음(무제한, 기존 255회 제한 삭제).
-- ============================================================

A.FinalTrueState = { ped = nil, active = false }

--- 사용자 요청: 최종 감정사는 랜덤 풀이 아니라 최종 구역(FinalZone) 중심에 고정 등장한다
--- ("최종 감정사는 최종 목적지 중심에 나타납니다") — 어차피 후반부엔 다들 그쪽으로
--- 모이므로 자연스럽다.
function A.SpawnFinalTrue(session)
    local coords = Config.FinalZoneCenter
    if not coords then return end
    A.FinalTrueState.active = true
    spawnAppraiserPed(coords, function(ped, spawnCoords)
        if not A.FinalTrueState.active then return end -- 그 사이 DespawnTrue로 취소됐으면 무시
        A.FinalTrueState.ped = ped
        addNpcBlip('finaltrue', spawnCoords, '진짜 감정사 (최종)', 2)
    end)
    SecretBagMode.LogTimelineEvent(session, '최종 감정사 등장')
    U.NotifyAll('최종 감정사가 도착했습니다.')
end

--- REQ 9 Final True 행 (pre-lock/post-lock 분기는 session.finalZoneLocked 기준).
RegisterCommand('usefinaltrue', function(source)
    local playerId = source
    local session = SecretBagMode.CurrentSession
    if not session then return end

    local role, accessErr = checkAccessRole(session, playerId)
    if not role then
        U.NotifyPlayer(playerId, SecretBagMode.Message[accessErr])
        return
    end

    if not A.FinalTrueState.active or not A.FinalTrueState.ped or not DoesEntityExist(A.FinalTrueState.ped) then
        U.NotifyPlayer(playerId, '최종 감정사가 아직 오지 않았습니다.')
        return
    end

    local ped = GetPlayerPed(tostring(playerId))
    if not ped or ped == 0 then return end
    if #(GetEntityCoords(ped) - GetEntityCoords(A.FinalTrueState.ped)) > Config.Appraiser.interactDistance then
        U.NotifyPlayer(playerId, '최종 감정사와 너무 멉니다.')
        return
    end

    local isOwner = (role == Role.SERVER_OWNER)

    local postLock = session.finalZoneLocked == true

    if postLock then
        -- REQ 9 "Final True post-lock": 전체 owned SecretBag scan -> bool genuineExists.
        local genuineExists = false
        for _, bag in pairs(session.bags) do
            if bag.currentOwnerId == playerId and bag.state == BagState.INVENTORY and bag.isGenuine then
                genuineExists = true
                break
            end
        end

        if not isOwner then
            local ps = session.playerSessions[playerId]
            local cd = ps and ps.cooldowns.finalTrue
            if cd and U.Now() < cd then
                U.NotifyPlayer(playerId, '아직 쿨다운 중입니다.')
                return
            end
            if ps then
                ps.cooldowns.finalTrue = U.Now() + Config.Appraiser.finalTruePostLockCooldownMs
            end
        end

        SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.TRUE_APPRAISAL, playerId, {
            appraiser = 'finalTrue',
            postLock = true,
            result = genuineExists,
        })

        TriggerClientEvent('secretbag:trueAppraisalResult', playerId, 'finalTrue', nil, genuineExists)
        return
    end

    -- pre-lock: 진짜 감정사와 동일하게 단일 bag 진위 확정.
    if SecretBagMode.Inventory.CountBags(session, playerId) ~= 1 then
        U.NotifyPlayer(playerId, 'SecretBag을 정확히 1개 소지하고 있어야 합니다.')
        return
    end

    local ps = session.playerSessions[playerId]
    if not isOwner then
        local cd = ps and ps.cooldowns.finalTrue
        if cd and U.Now() < cd then
            U.NotifyPlayer(playerId, '아직 쿨다운 중입니다.')
            return
        end
    end

    local heldBag = findHeldSingleBag(session, playerId)
    if not heldBag then
        U.NotifyPlayer(playerId, 'SecretBag을 소지하고 있어야 합니다.')
        return
    end

    if not isOwner then
        -- 이 지점은 이미 postLock 분기(위)에서 걸러지고 남은 pre-lock 경로이므로, 쿨다운은
        -- 항상 pre-lock 값을 쓴다(elapsed 시각으로 근사 판정하던 예전 방식은 session.finalZoneLocked
        -- 라는 더 정확한 값이 바로 위에서 이미 쓰이고 있어 불필요했다).
        ps.cooldowns.finalTrue = U.Now() + Config.Appraiser.finalTruePreLockCooldownMs
    end

    if heldBag.isGenuine then
        SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.TRUE_APPRAISAL, playerId, {
            appraiser = 'finalTrue',
            postLock = false,
            bagId = heldBag.bagId,
            result = true,
        })
    end

    TriggerClientEvent('secretbag:trueAppraisalResult', playerId, 'finalTrue', heldBag.bagId, heldBag.isGenuine)
end, false)

-- ============================================================
-- 스케줄러 (사용자 확정 규칙(2026) 타임라인: 60(영구)/120/230분)
-- ============================================================

--- server/features.lua에서 trueAppraiser를 끌 때, 그리고 게임 종료 시 사용. 진짜 감정사는
--- 자체 디스폰 시각이 없어졌으므로(영구 유지) 이 함수가 유일한 정리 경로다.
function A.DespawnTrue()
    despawnPed(A.TrueState.true1.ped)
    A.TrueState.true1.ped = nil
    A.TrueState.true1.active = false
    removeNpcBlip('true1')

    despawnPed(A.FinalTrueState.ped)
    A.FinalTrueState = { ped = nil, active = false }
    removeNpcBlip('finaltrue')
end

function A.StartScheduler(session)
    CreateThread(function()
        while SecretBagMode.CurrentSession == session and session.state ~= SessionState.ENDED do
            local elapsed = SecretBagMode.MainElapsedMinutes(session)

            -- cheapAppraiser는 원래 RUNNING 시작과 동시에 즉시 스폰했지만, 다른 요소들과 동일한
            -- 폴링+MarkTimelineEventOnce 패턴으로 바꿔 Config.Timeline.cheapAppraiserSpawnAt으로
            -- 지연 스폰도 가능하게 했다 (기본값 0분이라 실질적으로는 이전과 거의 동일하게 즉시 스폰됨).
            if elapsed and Config.Features.cheapAppraiser
                and elapsed >= Config.Timeline.cheapAppraiserSpawnAt
                and SecretBagMode.MarkTimelineEventOnce(session, 'cheap_spawn') then
                A.SpawnCheap(session)
            end

            -- Config.Features.trueAppraiser를 먼저 확인해야 한다 — trace.lua/livereveal.lua와 동일하게,
            -- 꺼져있는 동안은 MarkTimelineEventOnce가 호출조차 안 되어 플래그가 소모되지 않고,
            -- 나중에 다시 켜지면 그 시점에 "뒤늦게" 스폰된다. 진짜 감정사는 디스폰 시각이 없어
            -- (영구 유지) spawn 이벤트만 존재한다.
            if elapsed and Config.Features.trueAppraiser then
                if elapsed >= Config.Timeline.trueAppraiserSpawnAt and SecretBagMode.MarkTimelineEventOnce(session, 'true_spawn') then
                    A.SpawnTrue(session)
                end

                if elapsed >= Config.Timeline.finalTrueStart and SecretBagMode.MarkTimelineEventOnce(session, 'finaltrue_spawn') then
                    A.SpawnFinalTrue(session)
                end
            end
            Wait(5000)
        end
    end)
end

function A.Cleanup(session)
    A.DespawnCheap()
    A.DespawnTrue()
end

--- npcBlipAdd는 스폰 시점에 그때 접속해 있던 클라이언트에게만 1회 방송된다 — 늦게
--- 접속/재접속한 클라이언트는 이미 스폰된 감정사 블립을 영영 못 본다(server/hud.lua의
--- HUD/policeRelation 재동기화와 동일한 부류의 gap). 그래서 clientReady마다 현재
--- 활성 상태인 것들을 그 클라이언트에게만 다시 쏴준다.
RegisterNetEvent('secretbag:clientReady', function()
    local playerId = tonumber(source)
    for npcId, npc in pairs(A.CheapNpcs) do
        if npc.ped and DoesEntityExist(npc.ped) then
            TriggerClientEvent('secretbag:npcBlipAdd', playerId, npcId, npc.coords, '싸구려 감정사', 1, 5)
        end
    end
    if A.TrueState.true1.active then
        TriggerClientEvent('secretbag:npcBlipAdd', playerId, 'true1', GetEntityCoords(A.TrueState.true1.ped), '진짜 감정사', 1, 2)
    end
    if A.FinalTrueState.active then
        TriggerClientEvent('secretbag:npcBlipAdd', playerId, 'finaltrue', GetEntityCoords(A.FinalTrueState.ped), '진짜 감정사 (최종)', 1, 2)
    end
end)
