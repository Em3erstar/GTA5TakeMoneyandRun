--- Standalone 인벤토리 코어 (사양서 1장 "구현범위" 전제: 서버 권위형).
--- 프레임워크가 없으므로 이 모드가 직접 SecretBag/NoteItem 소지 슬롯을 관리한다.
--- 다른 일반 아이템(무기/탄약 등)은 건드리지 않으며, 이 모드가 추적하는
--- 아이템(SecretBag, 추후 NoteItem)의 개수만 슬롯으로 카운트한다.
--- 월드 드롭은 실제 네트워크 오브젝트(hei_prop_heist_bag_var22)로 구현해
--- 근접 상호작용(E키)으로 pickup/drop이 가능하다.

local U = SecretBagMode.Util
local BagState = SecretBagMode.BagState
local Role = SecretBagMode.Role
local SessionState = SecretBagMode.SessionState
local ErrorCode = SecretBagMode.ErrorCode

SecretBagMode.Inventory = SecretBagMode.Inventory or {}
local Inv = SecretBagMode.Inventory

-- 사용자 요청: 007 가방(금속 서류 가방) 스타일로 변경. 'prop_attache_case_01'은 DLC
-- 의존성 없는 베이스 게임 오브젝트로 실존 확인됨(gtahash.com — hash 0xA09B3816,
-- texture dict prop_attache_case).
Inv.BagPropModel = GetHashKey('prop_attache_case_01')
Inv.PickupDistance = 3.0

-- 세션 경계와 무관한 전역 레지스트리. StartGame의 PurgeAllExisting 안전망과
-- EndGame cleanup이 세션 존재 여부와 상관없이 잔존 엔티티를 지울 수 있어야 한다.
Inv.WorldEntities = {} -- [bagId] = entity handle

--- 이 모드가 관리하는 아이템(SecretBag + NoteItem) 보유 개수.
function Inv.CountHeld(session, playerId)
    local count = 0
    for _, bag in pairs(session.bags) do
        if bag.currentOwnerId == playerId and bag.state == BagState.INVENTORY then
            count = count + 1
        end
    end
    for _, note in pairs(session.noteItems or {}) do
        if note.currentOwnerId == playerId then
            count = count + 1
        end
    end
    return count
end

function Inv.HasFreeSlot(session, playerId)
    local maxSlots = (Config.Inventory and Config.Inventory.maxModSlots) or 5
    return Inv.CountHeld(session, playerId) < maxSlots
end

--- Appraiser/Forger 검증에 쓰는 "SecretBag 정확히 1개" 카운트 (NoteItem 제외).
function Inv.CountBags(session, playerId)
    local count = 0
    for _, bag in pairs(session.bags) do
        if bag.currentOwnerId == playerId and bag.state == BagState.INVENTORY then
            count = count + 1
        end
    end
    return count
end

--- z 보정: 드롭/사망 시점의 coords는 실제 플레이어 위치 기반이라 이미 정확해서 원격 지면
--- 높이 조회(U.ResolveGroundZ)가 애초에 필요 없다.
---
--- 진짜 근본 원인은 /sbminimalobjecttest 실측으로 확인됐다: 서버 쪽 CreateObject는 핸들을
--- 즉시 반환하지만 그 엔티티가 실제로 "존재하는" 상태가 되는 건 몇 틱 뒤다 — 생성 직후
--- 같은 틱에 SetEntityDistanceCullingRadius 등 후속 native를 부르면 항상
--- "Tried to access invalid entity"로 죽는다(모델/호출 경로와 무관, 순수 타이밍 문제).
--- U.CreateEntitySafely가 이제 이 대기를 전담하므로 여기서는 그냥 호출만 하면 된다.
function Inv.SpawnWorldBag(bag, coords)
    if bag.state ~= BagState.WORLD_DROP then return end

    local netId = nil
    local entity = U.CreateEntitySafely(3, 300,
        function()
            return CreateObject(Inv.BagPropModel, coords.x, coords.y, coords.z, true, true, false)
        end,
        function(e)
            SetEntityDistanceCullingRadius(e, 500.0)
            netId = NetworkGetNetworkIdFromEntity(e)
        end)
    if not entity or not netId then
        print('[SecretBag] 경고: 월드 가방 오브젝트 생성 실패')
        return
    end
    Inv.WorldEntities[bag.bagId] = entity
    bag.worldCoords = coords
    TriggerClientEvent('secretbag:worldBagSpawned', -1, bag.bagId, netId)
end

function Inv.DespawnWorldBag(bag)
    local entity = Inv.WorldEntities[bag.bagId]
    if entity and DoesEntityExist(entity) then
        DeleteEntity(entity)
    end
    Inv.WorldEntities[bag.bagId] = nil
    TriggerClientEvent('secretbag:worldBagRemoved', -1, bag.bagId)
end

--- REQ-START-003 안전망: 세션 유무와 무관하게 잔존 월드 엔티티를 전부 제거.
--- 인벤토리 쪽(held bag 카운트)은 세션이 교체되며 자연히 리셋된다.
function Inv.PurgeAll()
    for bagId, entity in pairs(Inv.WorldEntities) do
        if DoesEntityExist(entity) then
            DeleteEntity(entity)
        end
        Inv.WorldEntities[bagId] = nil
    end
    TriggerClientEvent('secretbag:resetInventoryState', -1)
end

local function requireCanTouchBag(session, playerId)
    local role = SecretBagMode.GetRole(playerId)
    if role == nil or role == Role.HELPER or role == Role.LATE_NONPARTICIPANT then
        return nil, ErrorCode.NO_ACCESS
    end
    if role == Role.PLAYER and not SecretBagMode.IsParticipant(session, playerId) then
        return nil, ErrorCode.NO_ACCESS
    end
    if session.mutationLocked then
        return nil, ErrorCode.MUTATION_LOCKED
    end
    local ps = session.playerSessions[playerId]
    if ps and ps.awaitingRespawn then
        return nil, ErrorCode.AWAITING_RESPAWN
    end
    return role
end

--- PickupSecretBag API (사양서 19장). role/session/zone/winner lock을 순서대로 검증하고,
--- FINAL_LOCKED_CONTEST에서 genuine이면 finalzone.lua의 원자적 contest pickup으로 위임한다.
function Inv.RequestPickup(session, playerId, bagId)
    local role, err = requireCanTouchBag(session, playerId)
    if not role then return false, err end

    local bag = session.bags[bagId]
    if not bag or bag.state ~= BagState.WORLD_DROP then
        return false, ErrorCode.NOT_ON_GROUND
    end

    local ped = GetPlayerPed(tostring(playerId))
    if not ped or ped == 0 then return false, ErrorCode.NO_PED end
    if bag.worldCoords and #(GetEntityCoords(ped) - bag.worldCoords) > Inv.PickupDistance then
        return false, ErrorCode.TOO_FAR
    end

    if session.state == SessionState.FINAL_LOCKED_CONTEST and bag.isGenuine then
        local won, contestErr = SecretBagMode.FinalZone.TryContestPickup(session, playerId)
        if won then Inv.DespawnWorldBag(bag) end
        return won, contestErr
    end

    if not Inv.HasFreeSlot(session, playerId) then
        return false, ErrorCode.NO_SLOT
    end

    SecretBagMode.Bag.OnPickup(session, bag, playerId, role)
    Inv.DespawnWorldBag(bag)
    return true
end

function Inv.RequestDrop(session, playerId, bagId)
    local role, err = requireCanTouchBag(session, playerId)
    if not role then return false, err end

    local bag = session.bags[bagId]
    if not bag or bag.currentOwnerId ~= playerId then
        return false, ErrorCode.NOT_OWNER
    end

    local ped = GetPlayerPed(tostring(playerId))
    if not ped or ped == 0 then return false, ErrorCode.NO_PED end
    local coords = GetEntityCoords(ped)

    SecretBagMode.Bag.OnDrop(session, bag, playerId, coords, 'manual')
    Inv.SpawnWorldBag(bag, coords)
    return true
end

RegisterNetEvent('secretbag:tryPickupBag', function(bagId)
    local src = source
    local session = SecretBagMode.CurrentSession
    if not session then return end
    local ok, err = Inv.RequestPickup(session, src, bagId)
    if not ok then
        U.NotifyPlayer(src, SecretBagMode.Message[err] or (err and tostring(err)) or '픽업할 수 없습니다.')
    end
end)

RegisterNetEvent('secretbag:tryDropBag', function(bagId)
    local src = source
    local session = SecretBagMode.CurrentSession
    if not session then return end
    local ok, err = Inv.RequestDrop(session, src, bagId)
    if not ok then
        U.NotifyPlayer(src, SecretBagMode.Message[err] or (err and tostring(err)) or '드롭할 수 없습니다.')
    end
end)

--- REQ-DISC-001: winner 미확정 시 participant 보유 SecretBag을 lastValidCoords에 world_drop.
AddEventHandler('playerDropped', function()
    local playerId = tonumber(source)
    local session = SecretBagMode.CurrentSession
    if not session or session.winnerLocked then return end
    if not SecretBagMode.IsParticipant(session, playerId) then return end

    -- playerDropped 시점에는 ped가 이미 정리됐을 수 있다(FiveM 버전에 따라 다름) — 그 경우
    -- Config.DefaultSafeCoord로 폴백한다. 폴백 없이 coords=nil로 드롭하면 가방이 world_drop
    -- 상태인데 좌표도 없고 실제 엔티티도 없는 "고아" 상태가 되어 영구히 주울 수 없게 된다.
    local ped = GetPlayerPed(tostring(playerId))
    local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or Config.DefaultSafeCoord

    for _, bag in pairs(session.bags) do
        if bag.currentOwnerId == playerId and bag.state == BagState.INVENTORY then
            SecretBagMode.Bag.OnDrop(session, bag, playerId, coords, 'disconnect')
            Inv.SpawnWorldBag(bag, coords)
        end
    end
end)
