local U = SecretBagMode.Util
local BagState = SecretBagMode.BagState
local HistEvt = SecretBagMode.HistoryEventType
local ErrorCode = SecretBagMode.ErrorCode

SecretBagMode.Bag = {}
local Bag = SecretBagMode.Bag

--- REQ-START-003: 모든 검증 성공 후, initial bag 생성 직전에 기존 SecretBag을
--- inventory/world 양쪽에서 완전 삭제한다. inventory 쪽은 다음 NewSession()이
--- session.bags를 새로 만들며 자연히 리셋되므로, 여기서는 월드 잔존 엔티티만
--- 정리하면 된다 (server/inventory.lua).
function Bag.PurgeAllExisting()
    SecretBagMode.Inventory.PurgeAll()
    if SecretBagMode.Hint and SecretBagMode.Hint.PurgeAllNotes then
        SecretBagMode.Hint.PurgeAllNotes()
    end
end

--- REQ-START-004 / REQ-BAG-001: 초기 genuine 1개 + fake P-1개 생성.
--- fake 중 score>=60 이 최소 2개가 될 때까지 전체 세트를 재추첨(rejection sampling)한다.
function Bag.GenerateInitialFakeScores(count)
    local cfg = Config.SecretBag

    -- count가 fakeRealLikeMinCount보다 작으면(P<=cfg.fakeRealLikeMinCount, 정식 규칙상
    -- MinPlayers=4·기본 fakeRealLikeMinCount=2에서는 발생하지 않지만 Config.MinPlayers를
    -- 낮춰 솔로 테스트할 때는 count=0/1이 될 수 있다) qualifyCount가 그 값에 절대 도달할 수
    -- 없어 아래 rejection sampling 루프가 무한 루프에 빠진다 — 제약을 만족할 방법이 아예
    -- 없는 경우이므로 제약 없이 최선의 무작위 점수만 생성하고 반환한다.
    if count < cfg.fakeRealLikeMinCount then
        local scores = {}
        for i = 1, count do
            scores[i] = U.RandomInt(cfg.fakeScoreMin, cfg.fakeScoreMax)
        end
        return scores
    end

    while true do
        local scores = {}
        local qualifyCount = 0
        for i = 1, count do
            local s = U.RandomInt(cfg.fakeScoreMin, cfg.fakeScoreMax)
            scores[i] = s
            if s >= cfg.fakeRealLikeThreshold then
                qualifyCount = qualifyCount + 1
            end
        end
        if qualifyCount >= cfg.fakeRealLikeMinCount then
            return scores
        end
        -- 미충족: 전체 세트 재추첨
    end
end

--- 세션에 initial SecretBag 세트를 생성하고 참가자에게 1개씩 지급한다.
--- genuine 수령자는 참가자 중 균등 랜덤 (REQ-START-004).
function Bag.CreateInitialBags(session)
    local participantIds = {}
    for pid in pairs(session.sessionParticipantIds) do
        table.insert(participantIds, pid)
    end
    table.sort(participantIds)

    local genuineIndex = U.RandomInt(1, #participantIds)
    local fakeScores = Bag.GenerateInitialFakeScores(#participantIds - 1)

    local logicalGenuineId = U.NewId('genuine')
    session.logicalGenuineId = logicalGenuineId

    local fakeCursor = 1
    for i, pid in ipairs(participantIds) do
        local isGenuine = (i == genuineIndex)
        local bag = {
            bagId = U.NewId('bag'),
            isGenuine = isGenuine,
            appearanceScore = isGenuine
                and U.RandomInt(Config.SecretBag.genuineScoreMin, Config.SecretBag.genuineScoreMax)
                or fakeScores[fakeCursor],
            originalOwnerId = pid,
            currentOwnerId = pid,
            lastPlayerOwnerId = pid,
            state = BagState.INVENTORY,
            worldCoords = nil,
            finalZoneLock = false,
            cheapVisitHistory = {},
            ownershipChanged = false,
            forgedFrom = nil,
        }
        if not isGenuine then
            fakeCursor = fakeCursor + 1
        else
            session.genuineBagId = bag.bagId
        end
        session.bags[bag.bagId] = bag

        -- 표준 인벤토리 프레임워크가 없으므로, 소지 여부는 currentOwnerId/state로
        -- 충분하다 (server/inventory.lua Inv.CountHeld 참고). 클라이언트에는 UI 동기화용
        -- 이벤트 + 알림만 전송.
        TriggerClientEvent('secretbag:heldBagAdded', pid, bag.bagId)
        U.NotifyPlayer(pid, '비밀 가방을 지급받았습니다.')

        if isGenuine then
            SecretBagMode.AppendHistoryEvent(session, logicalGenuineId, HistEvt.INITIAL_CREATED, nil, {
                recipientId = pid,
                bagId = bag.bagId,
                score = bag.appearanceScore,
            })
        end
    end
end

--- REQ-BAG-003: PLAYER pickup 시 lastPlayerOwnerId가 non-null이고 pickup PLAYER와
--- 다르면 ownershipChanged=true. SERVER_OWNER 보유는 lastPlayerOwnerId를 바꾸지 않는다.
function Bag.OnPickup(session, bag, pickerId, pickerRole)
    local ownerBefore = bag.currentOwnerId
    bag.currentOwnerId = pickerId
    bag.state = BagState.INVENTORY

    if pickerRole == SecretBagMode.Role.PLAYER then
        if bag.lastPlayerOwnerId ~= nil and bag.lastPlayerOwnerId ~= pickerId then
            bag.ownershipChanged = true
        end
        bag.lastPlayerOwnerId = pickerId
    end

    TriggerClientEvent('secretbag:heldBagAdded', pickerId, bag.bagId)

    -- REQ-TRACE-001: 킬러가 자신이 죽인 death event에서 드롭된 가방을 "직접" pickup하면 death당 최대 +1.
    -- deathEventId는 이번 pickup 한 번에만 유효하다 — 그대로 남겨두면, 이 가방이 이후 전혀
    -- 무관한 경로로(예: 다른 사람이 주웠다가 나중에 일반 드롭) 떠돌다가 한참 뒤에 원래 그
    -- death의 킬러가 우연히 다시 주웠을 때도 "직접 pickup"으로 오판정돼 부당하게 Trace가
    -- 오르는 버그가 있었다. 그래서 결과(지급 여부)와 무관하게 이번 pickup에서 항상 소비한다.
    if bag.deathEventId and SecretBagMode.Trace then
        SecretBagMode.Trace.OnBagPickedFromDeathEvent(session, pickerId, bag.deathEventId)
        bag.deathEventId = nil
    end

    if bag.isGenuine then
        SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.PICKUP, pickerId, {
            ownerBeforeId = ownerBefore,
            ownerAfterId = pickerId,
            ownershipChanged = bag.ownershipChanged,
        })
    end
end

--- REQ-BAG-002: 일반 폐기/드롭은 destroy가 아니라 world_drop. TTL 없음.
function Bag.OnDrop(session, bag, dropperId, coords, reason)
    local previousOwner = bag.currentOwnerId
    bag.currentOwnerId = nil
    bag.state = BagState.WORLD_DROP
    bag.worldCoords = coords

    if previousOwner then
        TriggerClientEvent('secretbag:heldBagRemoved', previousOwner, bag.bagId)
    end

    if bag.isGenuine then
        local evtType = HistEvt.DROP_MANUAL
        if reason == 'death' then evtType = HistEvt.DROP_DEATH
        elseif reason == 'disconnect' then evtType = HistEvt.DROP_DISCONNECT end

        SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, evtType, dropperId, {
            coords = coords,
        })
    end
end

--- REQ-BAG-004: 기존 genuine을 모든 위치에서 제거 후 실행자(SERVER_OWNER) 전방 3m에
--- world_drop으로 새 genuine을 생성한다("owner 전방 3m에 생성" = 인벤토리 지급이 아니라
--- 물리적 배치). 기존 logical genuine metadata(appearanceScore, ownership history,
--- cheapVisitHistory 등)를 전부 승계한다.
function Bag.AdminSpawnGenuine(session, actorId, spawnCoords)
    local ok, newBag = U.WithLock('genuine_respawn', function()
        local oldBag = session.genuineBagId and session.bags[session.genuineBagId] or nil
        local oldBagId = oldBag and oldBag.bagId or nil

        local newBag = {
            bagId = U.NewId('bag'),
            isGenuine = true,
            appearanceScore = oldBag and oldBag.appearanceScore
                or U.RandomInt(Config.SecretBag.genuineScoreMin, Config.SecretBag.genuineScoreMax),
            originalOwnerId = oldBag and oldBag.originalOwnerId or nil,
            currentOwnerId = nil,
            lastPlayerOwnerId = oldBag and oldBag.lastPlayerOwnerId or nil,
            state = BagState.WORLD_DROP,
            worldCoords = spawnCoords,
            finalZoneLock = oldBag and oldBag.finalZoneLock or false,
            cheapVisitHistory = oldBag and oldBag.cheapVisitHistory or {},
            ownershipChanged = oldBag and oldBag.ownershipChanged or false,
        }

        if oldBag then
            if oldBag.currentOwnerId then
                TriggerClientEvent('secretbag:heldBagRemoved', oldBag.currentOwnerId, oldBag.bagId)
            end
            oldBag.state = BagState.REPLACED
            session.bags[oldBagId] = nil
            SecretBagMode.Inventory.DespawnWorldBag(oldBag)
        end

        session.bags[newBag.bagId] = newBag
        session.genuineBagId = newBag.bagId

        SecretBagMode.Inventory.SpawnWorldBag(newBag, spawnCoords)

        SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.ADMIN_RESPAWN_GENUINE, actorId, {
            bagIdBefore = oldBagId,
            bagIdAfter = newBag.bagId,
            coords = spawnCoords,
        })

        return newBag
    end)
    if not ok then
        return nil, ErrorCode.LOCKED
    end
    return newBag
end

--- 위조업자 결과물 (기획서 7장): newFake.score=randomInt(max(0,S-20),S) 양 끝 포함.
--- 원본 유지(호출자가 sourceBag을 건드리지 않는다), newFake는 인벤토리에 직접 지급되며
--- 일반 fake와 동일하게 취급된다(genuine 이력에는 영향 없음).
function Bag.CreateForgedFake(session, sourceScore, ownerId)
    local minScore = math.max(0, sourceScore - 20)
    local newBag = {
        bagId = U.NewId('bag'),
        isGenuine = false,
        appearanceScore = U.RandomInt(minScore, sourceScore),
        originalOwnerId = ownerId,
        currentOwnerId = ownerId,
        lastPlayerOwnerId = ownerId,
        state = BagState.INVENTORY,
        worldCoords = nil,
        finalZoneLock = false,
        cheapVisitHistory = {},
        ownershipChanged = false,
        forgedFrom = ownerId, -- initialFakeOwner 힌트 계산에서 "초기 배포 fake"와 구분하는 마커 (hint.lua)
    }
    session.bags[newBag.bagId] = newBag
    TriggerClientEvent('secretbag:heldBagAdded', ownerId, newBag.bagId)
    return newBag
end

function Bag.GetGenuine(session)
    if not session.genuineBagId then return nil end
    return session.bags[session.genuineBagId]
end

--- 현재 물리적 위치를 resolve한다: 소유자가 있으면 소유자 ped 좌표, 없으면 worldCoords.
--- 관리자 조회(admin_observer)와 FinalZoneCheck(finalzone) 양쪽에서 공유하는 규칙이다.
function Bag.ResolveCoords(bag)
    if bag.currentOwnerId then
        local ped = GetPlayerPed(tostring(bag.currentOwnerId))
        if ped and ped ~= 0 then
            return GetEntityCoords(ped)
        end
    end
    return bag.worldCoords
end
