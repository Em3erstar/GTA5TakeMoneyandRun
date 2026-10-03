--- NoteItem / Hint Engine (기획서 10장 / 사양서 REQ-HINT-001~003, REQ-NOTE-001).
---
--- 참고: NoteItem 월드 프롭 모델(`prop_notepad_01`)은 존재 여부를 실서버에서 검증하지
--- 않았다 — 잘못됐어도 기능(픽업/사용/전달)에는 영향 없고 단지 안 보이거나 다른
--- 모양으로 보일 뿐이므로, 인게임 확인 후 필요하면 교체할 것.

local U = SecretBagMode.Util
local Role = SecretBagMode.Role

SecretBagMode.Hint = SecretBagMode.Hint or {}
local H = SecretBagMode.Hint

local noteEntities = {} -- [noteId] = entity handle (세션 경계 무관, Inventory.WorldEntities와 동일 패턴)
local notePropModel = GetHashKey('prop_notepad_01')

-- ============================================================
-- Hint 계산 (기획서 10장 "힌트 유형 ID 예시/정의" 표)
-- ============================================================

--- 현재 게임 상태에서 "이론상 발급 가능한" 모든 hintId를 계산한다.
--- count류(realLikeFakeCount/higherThanGenuineCount)와 cheap/ownership은 상태가 바뀔 때마다
--- 다른 문자열이 나오므로, "이미 받은 것과 문자열이 다르면 새 힌트"라는 규칙만으로
--- REQ-HINT-003의 dynamic reopen이 자연히 성립한다.
function H.ComputeAllPossibleHintIds(session)
    local ids = {}
    local genuine = SecretBagMode.Bag.GetGenuine(session)

    if genuine then
        if #genuine.cheapVisitHistory == 0 then
            table.insert(ids, 'cheap:none')
        else
            local seen = {}
            for _, appraiserId in ipairs(genuine.cheapVisitHistory) do
                if not seen[appraiserId] then
                    seen[appraiserId] = true
                    table.insert(ids, 'cheap:' .. appraiserId)
                end
            end
        end
        table.insert(ids, genuine.ownershipChanged and 'ownership:true' or 'ownership:false')
    end

    -- initialFakeOwner: 초기 배포된 fake만 (위조업자 생성물은 forgedFrom이 있어 제외).
    for _, bag in pairs(session.bags) do
        if not bag.isGenuine and bag.originalOwnerId and not bag.forgedFrom then
            table.insert(ids, 'initialFakeOwner:' .. tostring(bag.originalOwnerId))
        end
    end

    local realLikeCount, higherThanGenuineCount = 0, 0
    local genuineScore = genuine and genuine.appearanceScore or nil
    for _, bag in pairs(session.bags) do
        if not bag.isGenuine then
            if bag.appearanceScore >= 56 then realLikeCount = realLikeCount + 1 end
            if genuineScore and bag.appearanceScore > genuineScore then higherThanGenuineCount = higherThanGenuineCount + 1 end
        end
    end
    table.insert(ids, 'realLikeFakeCount:' .. realLikeCount)
    if genuineScore then
        table.insert(ids, 'higherThanGenuineCount:' .. higherThanGenuineCount)
    end

    return ids
end

--- REQ-HINT-001 dedup: recipient가 아직 못 받은 hintId만. initialFakeOwner류는
--- recipient별 최대 floor(P/2) distinct까지만 (기획서 10장 "recipient별 최대" 규칙).
--- "중복 기준은 최초 발급 recipient" — 전달받은 유저는 자신의 기록에 영향 없음(설계상 자연히 성립).
function H.ComputeEligibleForRecipient(session, recipientId)
    local ps = session.playerSessions[recipientId]
    if not ps then return {} end

    local cap = math.floor(session.P / 2)
    local fakeOwnerRevealedCount = 0
    for hintId in pairs(ps.revealedHintIds) do
        if hintId:find('^initialFakeOwner:') then
            fakeOwnerRevealedCount = fakeOwnerRevealedCount + 1
        end
    end

    local eligible = {}
    for _, hintId in ipairs(H.ComputeAllPossibleHintIds(session)) do
        if not ps.revealedHintIds[hintId] then
            if hintId:find('^initialFakeOwner:') then
                if fakeOwnerRevealedCount < cap then
                    table.insert(eligible, hintId)
                end
            else
                table.insert(eligible, hintId)
            end
        end
    end
    return eligible
end

function H.TextFor(hintId)
    local kind, value = hintId:match('^([^:]+):(.+)$')
    if kind == 'cheap' then
        if value == 'none' then return '진짜 가방은 아직 어떤 싸구려 감정사에게도 감정받지 않았다.' end
        return ('진짜 가방은 싸구려 감정사(%s)에게 감정받은 적이 있다.'):format(value)
    elseif kind == 'ownership' then
        return value == 'true' and '진짜 가방은 소유자가 바뀐 적이 있다.' or '진짜 가방은 아직 소유자가 바뀐 적이 없다.'
    elseif kind == 'initialFakeOwner' then
        local name = GetPlayerName(value) or ('ID ' .. value)
        return ('%s는(은) 처음에 가짜 가방을 받았다.'):format(name)
    elseif kind == 'realLikeFakeCount' then
        return ('현재 "진짜 같은 가짜"(감정 56점 이상)가 %s개 있다.'):format(value)
    elseif kind == 'higherThanGenuineCount' then
        return ('진짜보다 감정 점수가 높은 가짜가 %s개 있다.'):format(value)
    end
    return '알 수 없는 정보.'
end

-- ============================================================
-- NoteItem 월드 엔티티
-- ============================================================

-- z 보정: inventory.lua Inv.SpawnWorldBag과 동일한 이유로 U.ResolveGroundZ가 필요 없다 —
-- 진짜 근본 원인(서버 쪽 엔티티 생성이 같은 틱에 안 끝남)은 U.CreateEntitySafely가 전담한다.
local function spawnNoteEntity(noteId, coords)
    local note = SecretBagMode.CurrentSession and SecretBagMode.CurrentSession.noteItems[noteId]
    if not note or note.currentOwnerId then return end

    local netId = nil
    local entity = U.CreateEntitySafely(3, 300,
        function()
            return CreateObject(notePropModel, coords.x, coords.y, coords.z, true, true, false)
        end,
        function(e)
            SetEntityDistanceCullingRadius(e, 500.0)
            netId = NetworkGetNetworkIdFromEntity(e)
        end)
    if not entity or not netId then
        print('[SecretBag] 경고: 월드 쪽지 오브젝트 생성 실패')
        return
    end
    noteEntities[noteId] = entity
    note.worldCoords = coords
    TriggerClientEvent('secretbag:worldNoteSpawned', -1, noteId, netId)
end

local function despawnNoteEntity(noteId)
    local entity = noteEntities[noteId]
    if entity and DoesEntityExist(entity) then
        DeleteEntity(entity)
    end
    noteEntities[noteId] = nil
    TriggerClientEvent('secretbag:worldNoteRemoved', -1, noteId)
end

function H.PurgeAllNotes()
    for noteId in pairs(noteEntities) do
        despawnNoteEntity(noteId)
    end
end

--- REQ-POLICE-003 / REQ-NOTE-001: eligible 1개 균등 랜덤 발급.
--- entity/기록 생성이 성공하는 이 시점에만 issuance commit(= revealedHintIds 반영)한다.
--- 인벤토리 full이면 recipient 발밑에 world_drop.
function H.IssueRandomHint(session, recipientId)
    local eligible = H.ComputeEligibleForRecipient(session, recipientId)
    if #eligible == 0 then return nil end

    local hintId = U.PickRandom(eligible)
    local note = {
        noteId = U.NewId('note'),
        hintId = hintId,
        hintText = H.TextFor(hintId),
        issuedRecipientId = recipientId,
        currentOwnerId = recipientId,
        worldCoords = nil,
    }

    if not SecretBagMode.Inventory.HasFreeSlot(session, recipientId) then
        note.currentOwnerId = nil
        local ped = GetPlayerPed(tostring(recipientId))
        local coords = (ped and ped ~= 0) and GetEntityCoords(ped) or Config.DefaultSafeCoord
        note.worldCoords = coords
        spawnNoteEntity(note.noteId, coords)
    end

    session.noteItems[note.noteId] = note

    local ps = session.playerSessions[recipientId]
    ps.revealedHintIds[hintId] = true

    if note.currentOwnerId then
        TriggerClientEvent('secretbag:heldNoteAdded', recipientId, note.noteId, note.hintText)
    else
        U.NotifyPlayer(recipientId, '인벤토리가 가득 차 쪽지가 발밑에 떨어졌습니다.')
    end

    return note
end

-- ============================================================
-- 커맨드: pickup/read/drop/transfer
-- 기획서 10장: SERVER_OWNER는 pickup/use/re-read/transfer/drop 가능. HELPER/비참가자는 pickup 불가.
-- ============================================================

local function requireNoteAccess(playerId)
    local role = SecretBagMode.GetRole(playerId)
    if role == nil or role == Role.HELPER or role == Role.LATE_NONPARTICIPANT then
        return nil, SecretBagMode.ErrorCode.NO_ACCESS
    end
    return role
end

RegisterNetEvent('secretbag:tryPickupNote', function(noteId)
    local playerId = source
    local session = SecretBagMode.CurrentSession
    if not session then return end
    local role, err = requireNoteAccess(playerId)
    if not role then
        U.NotifyPlayer(playerId, SecretBagMode.Message[err])
        return
    end

    local note = session.noteItems[noteId]
    if not note or note.currentOwnerId then return end

    local ped = GetPlayerPed(tostring(playerId))
    if not ped or ped == 0 then return end
    if note.worldCoords and #(GetEntityCoords(ped) - note.worldCoords) > 3.0 then return end

    note.currentOwnerId = playerId
    note.worldCoords = nil
    despawnNoteEntity(noteId)
    TriggerClientEvent('secretbag:heldNoteAdded', playerId, note.noteId, note.hintText)
end)

RegisterCommand('readnote', function(source, args)
    local playerId = source
    local session = SecretBagMode.CurrentSession
    if not session then return end
    local noteId = args[1]
    local note = noteId and session.noteItems[noteId]
    if not note or note.currentOwnerId ~= playerId then
        U.NotifyPlayer(playerId, '소지한 쪽지가 아닙니다.')
        return
    end
    -- 재열람해도 소모되지 않는다 (REQ-NOTE-001 use non-consume).
    TriggerClientEvent('secretbag:noteText', playerId, note.hintText)
end, false)

RegisterCommand('dropnote', function(source, args)
    local playerId = source
    local session = SecretBagMode.CurrentSession
    if not session then return end
    local noteId = args[1]
    local note = noteId and session.noteItems[noteId]
    if not note or note.currentOwnerId ~= playerId then
        U.NotifyPlayer(playerId, '소지한 쪽지가 아닙니다.')
        return
    end
    local ped = GetPlayerPed(tostring(playerId))
    if not ped or ped == 0 then return end
    local coords = GetEntityCoords(ped)
    note.currentOwnerId = nil
    note.worldCoords = coords
    spawnNoteEntity(note.noteId, coords)
    TriggerClientEvent('secretbag:heldNoteRemoved', playerId, note.noteId)
end, false)

RegisterCommand('givenote', function(source, args)
    local playerId = source
    local session = SecretBagMode.CurrentSession
    if not session then return end
    local noteId = args[1]
    local targetId = tonumber(args[2])
    local note = noteId and session.noteItems[noteId]
    if not note or note.currentOwnerId ~= playerId then
        U.NotifyPlayer(playerId, '소지한 쪽지가 아닙니다.')
        return
    end
    if not targetId or not U.IsPlayerOnline(targetId) then
        U.NotifyPlayer(playerId, '대상을 찾을 수 없습니다.')
        return
    end
    local ped, targetPed = GetPlayerPed(tostring(playerId)), GetPlayerPed(tostring(targetId))
    if not ped or ped == 0 or not targetPed or targetPed == 0 then return end
    if #(GetEntityCoords(ped) - GetEntityCoords(targetPed)) > 3.0 then
        U.NotifyPlayer(playerId, '대상이 너무 멉니다.')
        return
    end

    note.currentOwnerId = targetId
    TriggerClientEvent('secretbag:heldNoteRemoved', playerId, note.noteId)
    TriggerClientEvent('secretbag:heldNoteAdded', targetId, note.noteId, note.hintText)
end, false)

function H.Cleanup(session)
    H.PurgeAllNotes()
    session.noteItems = {}
end
