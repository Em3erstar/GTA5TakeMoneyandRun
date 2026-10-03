--- SERVER_OWNER Genuine Observer / History Service
--- 사양서 12~15장 (진짜가방 관리자 조회 및 이력 열람) 구현.
--- REQ 없이 섹션 번호로만 명시되어 있으나, 요구사항은 QA-GEN-01~12로 매핑된다.

local U = SecretBagMode.Util
local BagState = SecretBagMode.BagState

--- 논리적 genuine 이력 스트림에 이벤트를 append한다.
--- seq는 세션 내 atomic increment로 부여해 동일 timestamp에서도 절대 순서를 보장한다.
function SecretBagMode.AppendHistoryEvent(session, logicalGenuineId, eventType, actorId, fields)
    session.historySeq = session.historySeq + 1
    local event = {
        eventId = U.NewId('evt'),
        logicalGenuineId = logicalGenuineId,
        seq = session.historySeq,
        serverTime = os.time(),
        mainElapsedMs = session.mainStartedAt and (U.Now() - session.mainStartedAt) or nil,
        phase = session.state,
        type = eventType,
        actorId = actorId,
        ownerBeforeId = fields and fields.ownerBeforeId or nil,
        ownerAfterId = fields and fields.ownerAfterId or nil,
        lastPlayerOwnerId = fields and fields.lastPlayerOwnerId or nil,
        bagIdBefore = fields and fields.bagIdBefore or nil,
        bagIdAfter = fields and fields.bagIdAfter or nil,
        coords = fields and fields.coords or nil,
        metadata = fields or {},
    }
    table.insert(session.genuineHistory, event)
    return event
end

local resolveCoords = SecretBagMode.Bag.ResolveCoords

local function getPlayerName(playerId)
    if not playerId then return nil end
    local p = tostring(playerId)
    return GetPlayerName(p)
end

--- GET GenuineInfo(callerId) -> GenuineAdminSnapshot
function SecretBagMode.BuildGenuineAdminSnapshot(session)
    local bag = SecretBagMode.Bag.GetGenuine(session)
    if not bag then
        return nil, SecretBagMode.ErrorCode.NO_ACTIVE_GENUINE
    end

    local recent = {}
    local histLen = #session.genuineHistory
    for i = math.max(1, histLen - 9), histLen do
        table.insert(recent, session.genuineHistory[i])
    end

    -- and/or로 직접 삼항 연산을 흉내 내면, IsInsideFinalZone이 정상적으로 false를 반환하는
    -- (genuine이 구역 밖에 있는, 흔한) 경우까지 "false or nil" = nil로 뭉개져서 "모듈 없음"과
    -- 구분이 안 되는 버그가 있었다 — if문으로 명시적으로 분기해 고쳤다.
    local finalZoneInside = nil
    if SecretBagMode.FinalZone and SecretBagMode.FinalZone.IsInsideFinalZone then
        finalZoneInside = SecretBagMode.FinalZone.IsInsideFinalZone(resolveCoords(bag))
    end

    return {
        logicalGenuineId = session.logicalGenuineId,
        activeBagId = bag.bagId,
        state = bag.state,
        currentOwnerId = bag.currentOwnerId,
        currentOwnerName = getPlayerName(bag.currentOwnerId),
        lastPlayerOwnerId = bag.lastPlayerOwnerId,
        lastPlayerOwnerName = getPlayerName(bag.lastPlayerOwnerId),
        currentCoords = resolveCoords(bag),
        appearanceScore = bag.appearanceScore,
        ownershipChanged = bag.ownershipChanged,
        cheapVisitHistory = bag.cheapVisitHistory,
        finalZoneInside = finalZoneInside,
        finalZoneLocked = bag.finalZoneLock,
        scheduledCloseAt = session.scheduledCloseAt,
        finalWinnerPlayerId = session.finalWinnerPlayerId,
        winnerLocked = session.winnerLocked,
        recentHistory = recent,
    }
end

local function requireServerOwner(playerId)
    if not SecretBagMode.IsServerOwner(playerId) then
        return false, SecretBagMode.ErrorCode.NOT_SERVER_OWNER
    end
    return true
end

RegisterCommand('genuineinfo', function(source)
    local ok, err = requireServerOwner(source)
    if not ok then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS or '권한이 없습니다.')
        return
    end
    local session = SecretBagMode.CurrentSession
    if not session then
        U.NotifyPlayer(source, '진행 중인 세션이 없습니다.')
        return
    end
    local snapshot, snapErr = SecretBagMode.BuildGenuineAdminSnapshot(session)
    if not snapshot then
        U.NotifyPlayer(source, 'genuine이 존재하지 않습니다: ' .. tostring(snapErr))
        return
    end
    TriggerClientEvent('secretbag:adminGenuineInfo', source, snapshot)
end, false)

RegisterCommand('genuinewhere', function(source)
    local ok = requireServerOwner(source)
    if not ok then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS or '권한이 없습니다.')
        return
    end
    local session = SecretBagMode.CurrentSession
    local bag = session and SecretBagMode.Bag.GetGenuine(session) or nil
    if not bag then
        U.NotifyPlayer(source, 'genuine이 존재하지 않습니다.')
        return
    end
    local coords = resolveCoords(bag)
    TriggerClientEvent('secretbag:adminGenuinePing', source, coords)
end, false)

RegisterCommand('genuinehistory', function(source, args)
    local ok = requireServerOwner(source)
    if not ok then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS or '권한이 없습니다.')
        return
    end
    local session = SecretBagMode.CurrentSession
    if not session then
        U.NotifyPlayer(source, '진행 중인 세션이 없습니다.')
        return
    end
    local filterType = args[1]
    local events = {}
    for _, evt in ipairs(session.genuineHistory) do
        if not filterType or evt.type == filterType then
            table.insert(events, evt)
        end
    end
    TriggerClientEvent('secretbag:adminGenuineHistory', source, events, filterType)
end, false)

--- AdminSpawnGenuine (기획서 4.1 "관리자genuine 복구"). 언제든 사용 가능,
--- 실행자(SERVER_OWNER) 전방 3m에 world_drop으로 생성한다 (REQ-BAG-004).
RegisterCommand('spawngenuine', function(source)
    local ok = requireServerOwner(source)
    if not ok then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS or '권한이 없습니다.')
        return
    end
    local session = SecretBagMode.CurrentSession
    if not session then
        U.NotifyPlayer(source, '진행 중인 세션이 없습니다.')
        return
    end

    local ped = GetPlayerPed(tostring(source))
    if not ped or ped == 0 then
        U.NotifyPlayer(source, '캐릭터를 찾을 수 없습니다.')
        return
    end
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)
    local spawnCoords = vector3(
        coords.x + math.sin(-rad) * 3.0,
        coords.y + math.cos(-rad) * 3.0,
        coords.z
    )

    local newBag, err = SecretBagMode.Bag.AdminSpawnGenuine(session, source, spawnCoords)
    if not newBag then
        U.NotifyPlayer(source, 'genuine 재생성 실패: ' .. (SecretBagMode.Message[err] or tostring(err)))
        return
    end
    U.NotifyPlayer(source, ('새 genuine(%s)이 전방 3m에 생성되었습니다.'):format(newBag.bagId))
end, false)

--- 특정 유저가 현재 인벤토리로 소지 중인 SecretBag들의 진위 여부와 외형 점수를 조회한다
--- (사용자 요청). 다른 관리자 조회 명령과 동일하게 U.NotifyPlayer가 채팅+서버 콘솔에 동시 출력한다.
RegisterCommand('inspectbags', function(source, args)
    local ok = requireServerOwner(source)
    if not ok then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS or '권한이 없습니다.')
        return
    end
    local session = SecretBagMode.CurrentSession
    if not session then
        U.NotifyPlayer(source, '진행 중인 세션이 없습니다.')
        return
    end
    local targetId = tonumber(args[1])
    if not targetId then
        U.NotifyPlayer(source, '사용법: /inspectbags <targetId>')
        return
    end

    local found = {}
    for _, bag in pairs(session.bags) do
        if bag.currentOwnerId == targetId and bag.state == BagState.INVENTORY then
            table.insert(found, bag)
        end
    end

    if #found == 0 then
        U.NotifyPlayer(source, ('%d번은 현재 소지 중인 SecretBag이 없습니다.'):format(targetId))
        return
    end

    U.NotifyPlayer(source, ('%d번이 소지한 SecretBag %d개:'):format(targetId, #found))
    for _, bag in ipairs(found) do
        U.NotifyPlayer(source, ('  bagId=%s 진위=%s 외형점수=%d'):format(
            bag.bagId, bag.isGenuine and '진짜' or '가짜', bag.appearanceScore))
    end
end, false)
