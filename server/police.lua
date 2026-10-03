--- 경찰 시스템 / 정보경제 (기획서 9장 / 사양서 REQ-POLICE-001~003).
---
--- 스폰 방식: 고정 좌표 목록이 아니라 일반 시민 앰비언트 스폰처럼, 온라인 참가자 근처에
--- 낮은 빈도로 트리클 스폰된다(Config.Police.ambientSpawnCheckIntervalMs/ambientSpawnChance/
--- maxActive). 서버는 콜리전/지형 데이터가 없어 안전한 지면 z를 알 수 없으므로, 스폰 지점
--- 후보를 클라이언트(그 순간 고른 참가자)에게 보내 GetGroundZFor_3dCoord로 확인받은 뒤에만
--- CreatePed한다 — 다른 NPC들(감정사/위조업자)처럼 z를 추정해둘 필요가 아예 없다.
--- 모든 참가자로부터 멀어지면 앰비언트 디스폰(despawnDistance)되고, 죽으면 그 자리에 다시
--- 스폰하지 않는다 — 앰비언트 루프가 자연스럽게 다른 곳에서 다시 채운다.
---
--- 신뢰 경계 주의 1: 경찰 NPC의 "누가 죽였는가"는 서버가 `GetPedSourceOfDeath`를
--- 직접 호출해 판정한다. 이 네이티브가 서버사이드에서 항상 정확히 동작하는지는
--- 빌드에 따라 달라질 수 있어 미검증이다 — 실패(0 반환) 시에는 안전하게 "귀속 없음"
--- 으로 처리하고(정보 강탈 미발급) 크래시나 오귀속은 나지 않는다.
--- 신뢰 경계 주의 2: 앰비언트 스폰 좌표도 클라이언트가 보고한다(death.lua의 reportDeath와
--- 같은 부류의 신뢰 경계). requestId는 서버가 생성한 1회용 랜덤 값이고, 요청받은 바로
--- 그 클라이언트(source)만 응답을 수락하도록 검증한다 — 그래도 악의적인 본인 클라이언트가
--- 좌표값 자체를 조작해 경찰을 엉뚱한 곳에 스폰시키는 것까지는 막지 못한다. 게임 밸런스에
--- 큰 영향은 없어 보강은 후순위로 남겨둔다.
---
--- REQ-POLICE-003의 "eligible hint 발급"은 hint.lua의 Hint.IssueRandomHint로 완전히 연결되어 있다.
---
--- 타이밍은 전부 Config.Timeline.policeAmbientStartAt(앰비언트 시작, 기본 0분)/
--- policeInfoShutdownAt(신규 스폰 금지 + 정보경제 종료, 기본 195분)/policeDespawnAt(전원 철수,
--- 기본 210분)을 직접 참조한다 — 하드코딩된 195/210 숫자가 아니다. /featuretime(server/
--- featurepreset.lua)으로 게임 시작 전에 조정 가능.

local U = SecretBagMode.Util
local PoliceState = SecretBagMode.PoliceState
local SessionState = SecretBagMode.SessionState

SecretBagMode.Police = SecretBagMode.Police or {}
local P = SecretBagMode.Police

local policePedModel = GetHashKey('s_m_y_cop_01')
local policeWeapon = GetHashKey('WEAPON_PISTOL')

local pendingSpawnRequests = {} -- [requestId] = { sessionId = ..., requestedAt = ms }
local ambientSpawnCounter = 0

local function tableCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- SetPedAccuracy/TaskWanderStandard는 client 전용 API라(TaskCombatPed는 반대로 서버
-- native가 따로 있어 updatePursuit에서 그대로 쓸 수 있다) 서버에서 직접 호출하면 죽는다
-- (client/main.lua secretbag:setupNpc 참고) — 클라이언트에 위임한다.
local function spawnPolicePed(coords, heading)
    -- U.CreateEntitySafely: appraiser.lua와 동일한 이유(CreatePed 자체의 드문 실패뿐 아니라
    -- 생성 직후 다음 native에서 "Tried to access invalid entity"로 죽는 레이스까지 방어).
    local ped = SecretBagMode.Util.CreateEntitySafely(5, 300,
        function()
            return CreatePed(4, policePedModel, coords.x, coords.y, coords.z, heading or 0.0, true, true)
        end,
        function(p)
            -- appraiser.lua와 동일한 이유로 SetEntityDistanceCullingRadius로 되돌림.
            SetEntityDistanceCullingRadius(p, 500.0)
        end)
    if not ped then
        print('[SecretBag] 경고: 경찰 ped 생성 실패 (5회 재시도 후에도 실패)')
        return nil
    end
    SetPedArmour(ped, 25)
    GiveWeaponToPed(ped, policeWeapon, 250, false, true)
    -- 일반 시민 경찰처럼 순찰하게 둔다. HOSTILE 타겟이 감지되면 updatePursuit가
    -- TaskCombatPed로 덮어써 이 태스크를 대체한다.
    TriggerClientEvent('secretbag:setupNpc', -1, NetworkGetNetworkIdFromEntity(ped), { accuracy = 40, wander = true })
    return ped
end

local function despawnPed(ped)
    if ped and DoesEntityExist(ped) then
        DeleteEntity(ped)
    end
end

P.ActivePeds = {} -- [npcId] = { ped = entity, dead = bool }

function P.SpawnOne(session, npcId, coords, heading)
    P.ActivePeds[npcId] = { ped = spawnPolicePed(coords, heading), dead = false }
end

--- 고정 스폰 풀이 없으므로 RUNNING 시작 시점엔 아무도 없다. StartScheduler의 앰비언트 굴림이
--- 첫 tick부터 바로 시작되어 "출근했습니다" 공지와 거의 동시에 자연스럽게 등장한다.
function P.SpawnInitial(session)
    P.ActivePeds = {}
end

function P.DespawnAll()
    for npcId, npc in pairs(P.ActivePeds) do
        despawnPed(npc.ped)
    end
    P.ActivePeds = {}
end

local function stillValidSession(session)
    return SecretBagMode.CurrentSession == session and session.state ~= SessionState.ENDED
end

--- 지정한 참가자 근처의 안전한 스폰 좌표를 그 클라이언트에게 요청한다.
local function requestAmbientSpawnFrom(session, pid)
    local requestId = U.NewId('policespawn')
    pendingSpawnRequests[requestId] = { sessionId = session.sessionId, requestedAt = U.Now(), pid = pid }

    TriggerClientEvent('secretbag:requestAmbientSpawnPoint', pid, requestId,
        Config.Police.spawnMinDistance, Config.Police.spawnMaxDistance)

    SetTimeout(Config.Police.spawnRequestTimeoutMs, function()
        pendingSpawnRequests[requestId] = nil -- 응답이 없었으면 조용히 버림 (메모리 누수 방지)
    end)
end

--- 온라인 참가자 중 무작위 한 명을 골라 그 근처에 스폰을 시도한다 (일반 앰비언트 굴림용).
local function requestAmbientSpawn(session)
    local onlineParticipants = {}
    for pid in pairs(session.sessionParticipantIds) do
        if U.IsPlayerOnline(pid) then table.insert(onlineParticipants, pid) end
    end
    if #onlineParticipants == 0 then return end
    requestAmbientSpawnFrom(session, onlineParticipants[math.random(1, #onlineParticipants)])
end

--- server/debug.lua의 /sbforceambientpolice 전용: 195분 이전 + maxActive 미만이면
--- 확률 굴림 없이 즉시 특정 플레이어(targetId) 근처에 스폰을 시도한다.
function P.RequestAmbientSpawnNear(session, targetId)
    if not Config.Features.police then return false, 'DISABLED' end
    local elapsed = SecretBagMode.MainElapsedMinutes(session)
    if elapsed and elapsed >= Config.Timeline.policeInfoShutdownAt then return false, 'TOO_LATE' end
    if tableCount(P.ActivePeds) >= Config.Police.maxActive then return false, 'MAX_ACTIVE' end
    if not U.IsPlayerOnline(targetId) then return false, 'OFFLINE' end
    requestAmbientSpawnFrom(session, targetId)
    return true
end

RegisterNetEvent('secretbag:ambientSpawnPointResult', function(requestId, x, y, z, heading)
    local pending = pendingSpawnRequests[requestId]
    if not pending then return end -- 이미 타임아웃됐거나 알 수 없는 requestId
    if pending.pid ~= source then return end -- 요청받은 클라이언트 본인만 응답할 수 있다
    pendingSpawnRequests[requestId] = nil

    local session = SecretBagMode.CurrentSession
    if not session or session.sessionId ~= pending.sessionId or session.state ~= SessionState.RUNNING then return end
    local elapsed = SecretBagMode.MainElapsedMinutes(session)
    if elapsed and elapsed >= Config.Timeline.policeInfoShutdownAt then return end
    if tableCount(P.ActivePeds) >= Config.Police.maxActive then return end
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return end

    ambientSpawnCounter = ambientSpawnCounter + 1
    P.SpawnOne(session, 'police_' .. ambientSpawnCounter, vector3(x, y, z), heading)
end)

--- HOSTILE에서 빠져나갈 수 있는지 판정: infoHostileUntil/pkHostileUntil 둘 다 만료된 경우에만
--- ALERT_TO_NEUTRAL로 전이한다 (REQ: "all causes end -> ALERT_TO_NEUTRAL").
function P.CheckHostilityEnd(session, playerId)
    if not stillValidSession(session) then return end
    local ps = session.playerSessions[playerId]
    if not ps or ps.policeRelation ~= PoliceState.HOSTILE then return end

    local now = U.Now()
    local infoActive = ps.infoHostileUntil and now < ps.infoHostileUntil
    local pkActive = ps.pkHostileUntil and now < ps.pkHostileUntil
    if infoActive or pkActive then return end

    ps.policeRelation = PoliceState.ALERT_TO_NEUTRAL
    TriggerClientEvent('secretbag:policeRelationChanged', playerId, ps.policeRelation)

    SetTimeout(Config.Police.alertToNeutralMs, function()
        if not stillValidSession(session) then return end
        if ps.policeRelation ~= PoliceState.ALERT_TO_NEUTRAL then return end -- 그 사이 재적대됨
        ps.policeRelation = ps.personalInfoClosed and PoliceState.ALERT_SHUTDOWN or PoliceState.NEUTRAL
        TriggerClientEvent('secretbag:policeRelationChanged', playerId, ps.policeRelation)
    end)
end

--- PK(참가 PLAYER가 다른 참가 PLAYER를 사살) 페널티. 개인 정보 폐쇄 중에도 작동한다.
--- death.lua의 killerId 결정 로직에서 호출된다.
function P.OnPlayerKilledPlayer(session, killerId)
    if not Config.Features.police then return end
    local ps = session.playerSessions[killerId]
    if not ps then return end

    -- 이미 HOSTILE이면(예: 연속 PK, 또는 정보 강탈로 이미 적대 중) 상태를 ALERT_TO_HOSTILE로
    -- 되돌리지 않는다 — 되돌리면 updatePursuit가 HOSTILE만 추격 대상으로 보기 때문에 1분간
    -- 경찰 추격이 끊기는 버그가 생긴다. 대신 pkHostileUntil만 갱신하고 새 만료 체크를 예약한다.
    if ps.policeRelation == PoliceState.HOSTILE then
        ps.pkHostileUntil = U.Now() + Config.Police.pkHostileMs
        SetTimeout(Config.Police.pkHostileMs, function()
            P.CheckHostilityEnd(session, killerId)
        end)
        return
    end

    ps.policeRelation = PoliceState.ALERT_TO_HOSTILE
    TriggerClientEvent('secretbag:policeRelationChanged', killerId, ps.policeRelation)

    SetTimeout(Config.Police.pkAlertMs, function()
        if not stillValidSession(session) then return end
        if ps.policeRelation ~= PoliceState.ALERT_TO_HOSTILE then return end
        ps.policeRelation = PoliceState.HOSTILE
        ps.pkHostileUntil = U.Now() + Config.Police.pkHostileMs
        TriggerClientEvent('secretbag:policeRelationChanged', killerId, ps.policeRelation)

        SetTimeout(Config.Police.pkHostileMs, function()
            P.CheckHostilityEnd(session, killerId)
        end)
    end)
end

--- REQ-POLICE-003: NEUTRAL participant가 경찰을 직접 사살 -> 정보 강탈.
--- 정보 적대 n회차 = n×5분 (n = infoLootCount, 이번 회차 포함).
--- entity 생성 성공(= NoteItem 발급 성공) 시에만 infoLootCount/hostile을 커밋한다.
--- eligible=0(더 줄 정보가 없음)이면 아무 것도 하지 않고 개인 ALERT_SHUTDOWN으로 전환한다.
function P.OnPoliceKilled(session, killerId)
    if not Config.Features.policeInfoLoot then return end
    local ps = session.playerSessions[killerId]
    if not ps or ps.policeRelation ~= PoliceState.NEUTRAL then return end

    local note = SecretBagMode.Hint and SecretBagMode.Hint.IssueRandomHint(session, killerId)
    if not note then
        ps.personalInfoClosed = true
        ps.policeRelation = PoliceState.ALERT_SHUTDOWN
        TriggerClientEvent('secretbag:policeRelationChanged', killerId, ps.policeRelation)
        return
    end

    ps.infoLootCount = ps.infoLootCount + 1
    local n = ps.infoLootCount
    local durationMs = n * Config.Police.infoHostileStepMinutes * 60 * 1000

    ps.infoHostileUntil = U.Now() + durationMs
    ps.policeRelation = PoliceState.HOSTILE
    TriggerClientEvent('secretbag:policeRelationChanged', killerId, ps.policeRelation)

    U.NotifyAll('누군가 경찰에게서 정보를 강탈했습니다.')

    local ped = GetPlayerPed(tostring(killerId))
    if ped and ped ~= 0 then
        local coords = GetEntityCoords(ped)
        local name = GetPlayerName(tostring(killerId))
        TriggerClientEvent('secretbag:policeInfoPing', -1, killerId, name, coords)
        SetTimeout(180 * 1000, function()
            TriggerClientEvent('secretbag:policeInfoPingExpire', -1, killerId)
        end)
    end

    SetTimeout(durationMs, function()
        P.CheckHostilityEnd(session, killerId)
    end)
end

local function handlePoliceDeath(session, npcId, npc)
    local killerId = nil
    local killerPed = GetPedSourceOfDeath(npc.ped)
    if killerPed and killerPed ~= 0 then
        local ownerServerId = NetworkGetEntityOwner(killerPed)
        if ownerServerId and ownerServerId > 0 then
            killerId = ownerServerId
        end
    end

    despawnPed(npc.ped)
    P.ActivePeds[npcId] = nil

    if killerId and SecretBagMode.IsParticipant(session, killerId) then
        P.OnPoliceKilled(session, killerId)
    end

    -- 죽은 그 자리에 고정 재스폰하지 않는다. 195분 전이라면 앰비언트 스폰 루프가
    -- 알아서 (다른 참가자 근처에) 다시 채워 넣는다 — REQ-POLICE-002의 "빈 자리를
    -- 다시 채운다"는 취지는 유지하되, 방식만 앰비언트 시민 스타일로 바꿨다.
end

--- REQ-POLICE-001: HOSTILE target이 50m 이내인 경찰만 pursuit/attack 시작.
--- 시작 후 50m 이탈만으로 즉시 해제하지 않음 — TaskCombatPed 이후 별도 취소 로직을 두지 않아
--- GTA 자체 AI가 교전을 이어가도록 둔다.
local function updatePursuit(session, policePed)
    local policeCoords = GetEntityCoords(policePed)
    for pid in pairs(session.sessionParticipantIds) do
        local ps = session.playerSessions[pid]
        if ps and ps.policeRelation == PoliceState.HOSTILE and U.IsPlayerOnline(pid) then
            local targetPed = GetPlayerPed(tostring(pid))
            if targetPed and targetPed ~= 0 then
                if #(policeCoords - GetEntityCoords(targetPed)) <= Config.Police.detectionRadius then
                    TaskCombatPed(policePed, targetPed, 0, 16)
                    return
                end
            end
        end
    end
end

--- 앰비언트 디스폰: 모든 온라인 참가자로부터 despawnDistance보다 멀어진 경찰은 정리한다.
--- (일반 GTA 앰비언트 인구가 플레이어에게서 멀어지면 사라지는 것과 같은 개념 — 방치된
--- 경찰이 쌓이지 않고, 지워진 자리만큼 maxActive 여유가 생겨 활동 지역 근처에 다시 채워진다.)
local function isFarFromAllParticipants(session, ped)
    local pedCoords = GetEntityCoords(ped)
    for pid in pairs(session.sessionParticipantIds) do
        if U.IsPlayerOnline(pid) then
            local targetPed = GetPlayerPed(tostring(pid))
            if targetPed and targetPed ~= 0 then
                if #(pedCoords - GetEntityCoords(targetPed)) <= Config.Police.despawnDistance then
                    return false
                end
            end
        end
    end
    return true
end

function P.StartScheduler(session)
    local lastAmbientCheckAt = 0

    CreateThread(function()
        while stillValidSession(session) do
            local elapsed = SecretBagMode.MainElapsedMinutes(session)

            if elapsed and elapsed >= Config.Timeline.policeInfoShutdownAt and SecretBagMode.MarkTimelineEventOnce(session, 'police_info_shutdown_195') then
                for pid in pairs(session.sessionParticipantIds) do
                    local ps = session.playerSessions[pid]
                    if ps and ps.policeRelation == PoliceState.NEUTRAL then
                        ps.policeRelation = PoliceState.ALERT_SHUTDOWN
                        ps.personalInfoClosed = true
                    end
                end
            end

            -- REQ-HINT-003 Dynamic reopen: eligible hint가 새로 생기면(게임 상태 변화로) 195분 전에
            -- ALERT_SHUTDOWN 상태를 NEUTRAL로 되돌린다. 단 PK 등 다른 원인으로 이미 HOSTILE/
            -- ALERT_TO_NEUTRAL이면 그 상태부터 먼저 끝나야 한다(personalInfoClosed는 그대로 두고
            -- CheckHostilityEnd가 알아서 ALERT_SHUTDOWN으로 되돌려보내므로 여기서는 건드리지 않는다).
            if elapsed and elapsed < Config.Timeline.policeInfoShutdownAt and SecretBagMode.Hint then
                for pid in pairs(session.sessionParticipantIds) do
                    local ps = session.playerSessions[pid]
                    if ps and ps.policeRelation == PoliceState.ALERT_SHUTDOWN and ps.personalInfoClosed then
                        if #SecretBagMode.Hint.ComputeEligibleForRecipient(session, pid) > 0 then
                            ps.personalInfoClosed = false
                            ps.policeRelation = PoliceState.NEUTRAL
                            TriggerClientEvent('secretbag:policeRelationChanged', pid, ps.policeRelation)
                        end
                    end
                end
            end

            if elapsed and elapsed >= Config.Timeline.policeDespawnAt and SecretBagMode.MarkTimelineEventOnce(session, 'police_despawn_180') then
                P.DespawnAll()
                if SecretBagMode.Wanted and SecretBagMode.Wanted.ClearAll then
                    SecretBagMode.Wanted.ClearAll() -- 사용자 확정 규칙: 180분부터 수배 레벨도 전부 해제(경찰 시스템 완전 종료)
                end
                for pid in pairs(session.sessionParticipantIds) do
                    local ps = session.playerSessions[pid]
                    if ps then
                        ps.policeRelation = PoliceState.DISABLED
                        TriggerClientEvent('secretbag:policeRelationChanged', pid, ps.policeRelation)
                    end
                end
                SecretBagMode.LogTimelineEvent(session, '경찰 디스폰')
                U.NotifyAll('경찰이 전부 철수했습니다.')
            end

            if not (elapsed and elapsed >= Config.Timeline.policeDespawnAt) then
                if Config.Features.police and elapsed and elapsed >= Config.Timeline.policeAmbientStartAt
                    and elapsed < Config.Timeline.policeInfoShutdownAt then
                    local now = U.Now()
                    if now - lastAmbientCheckAt >= Config.Police.ambientSpawnCheckIntervalMs then
                        lastAmbientCheckAt = now
                        if tableCount(P.ActivePeds) < Config.Police.maxActive
                            and math.random() < Config.Police.ambientSpawnChance then
                            requestAmbientSpawn(session)
                        end
                    end
                end

                for npcId, npc in pairs(P.ActivePeds) do
                    if not npc.dead and npc.ped and DoesEntityExist(npc.ped) then
                        -- IsEntityDead는 client 전용 API라 서버에서 호출하면 죽는다 —
                        -- GetEntityHealth(서버 native 있음)로 동등하게 판정한다(체력 0 이하 = 사망).
                        if GetEntityHealth(npc.ped) <= 0 then
                            npc.dead = true
                            handlePoliceDeath(session, npcId, npc)
                        else
                            updatePursuit(session, npc.ped)
                            if isFarFromAllParticipants(session, npc.ped) then
                                despawnPed(npc.ped)
                                P.ActivePeds[npcId] = nil
                            end
                        end
                    end
                end
            end

            Wait(3000)
        end
    end)
end

function P.Cleanup(session)
    P.DespawnAll()
    pendingSpawnRequests = {}
end
