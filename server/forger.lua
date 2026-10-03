--- 위조업자 (기획서 7장 / 사양서 REQ 9 Forger 행).

local U = SecretBagMode.Util
local Role = SecretBagMode.Role
local BagState = SecretBagMode.BagState
local SessionState = SecretBagMode.SessionState

SecretBagMode.Forger = SecretBagMode.Forger or {}
local F = SecretBagMode.Forger

local forgerPedModel = GetHashKey('a_m_y_business_02')

F.State = { ped = nil, active = false }

--- 120분 스폰(추적 강화와 동시), EndGame까지 유지. npc_spawn_place.txt [위조] 후보 중 랜덤 1개.
--- z 보정: appraiser.lua spawnAppraiserPed와 동일한 이유 — Config.NpcSpawnPools.forger 좌표는
--- 전부 관리자가 직접 실측한 값이라(server/debug.lua /sbmeasureallgroundz, /sbrecordground)
--- 더 이상 런타임에 지면 높이를 구할 필요가 없다(원격 GetGroundZFor_3dCoord는 위조업자
--- 후보 3곳 전부에서 25초를 줘도 계속 실패해 신뢰할 수 없었다).
function F.Spawn(session)
    local coords = U.PickRandom(Config.NpcSpawnPools.forger)
    if not coords then return end
    F.State.active = true

    -- SetEntityInvincible/SetBlockingOfNonTemporaryEvents는 client 전용 API라 서버에서
    -- 직접 호출하면 죽는다(client/main.lua secretbag:setupNpc 참고) — 클라이언트에 위임.
    -- U.CreateEntitySafely: 생성 직후 바로 다음 native 호출에서 "Tried to access invalid
    -- entity"로 죽는 레이스가 실제 재현됐다(appraiser.lua 참고) — pcall로 감싸 실패하면
    -- 통째로 재시도한다.
    local heading = math.random(0, 359)
    local ped = U.CreateEntitySafely(5, 300,
        function()
            return CreatePed(4, forgerPedModel, coords.x, coords.y, coords.z, heading, true, true)
        end,
        function(p)
            -- appraiser.lua와 동일한 이유로 SetEntityDistanceCullingRadius로 되돌림
            -- (SetEntityOrphanMode는 "원본 소유자 미지정" 상태에서 100% 재현되는
            -- 크래시를 일으켰다).
            SetEntityDistanceCullingRadius(p, 500.0)
            FreezeEntityPosition(p, true)
            SetPedCanRagdoll(p, false)
        end)
    if not ped then
        print('[SecretBag] 경고: 위조업자 ped 생성 실패 (5회 재시도 후에도 실패)')
        return
    end
    F.State.ped = ped
    TriggerClientEvent('secretbag:setupNpc', -1, NetworkGetNetworkIdFromEntity(ped), { invincible = true, blockEvents = true })
    F.State.coords = coords
    -- 감정사와 동일하게 지도 표시 + client/main.lua의 근접 자동 상호작용(E키) 프롬프트가
    -- npcCoords['forger']를 이 이벤트로만 채운다 — 이게 없으면 /useforger 명령은 여전히
    -- 되지만 E키 프롬프트는 절대 뜨지 않는다.
    TriggerClientEvent('secretbag:npcBlipAdd', -1, 'forger', coords, '위조업자', 1, 3)
    SecretBagMode.LogTimelineEvent(session, '위조업자 등장')
    U.NotifyAll('위조업자가 도착했습니다.')
end

--- server/features.lua에서 켜고 끌 때 사용.
function F.Despawn()
    if F.State.ped and DoesEntityExist(F.State.ped) then
        DeleteEntity(F.State.ped)
    end
    TriggerClientEvent('secretbag:npcBlipRemove', -1, 'forger')
    F.State = { ped = nil, active = false }
end

--- appraiser.lua와 동일한 이유: npcBlipAdd는 스폰 시점에 접속해 있던 클라이언트에게만
--- 1회 방송되므로, 늦게 접속/재접속한 클라이언트는 블립도 E키 프롬프트도 영영 못 받는다 —
--- clientReady마다 이미 활성 상태면 그 클라이언트에게만 다시 쏴준다.
RegisterNetEvent('secretbag:clientReady', function()
    if F.State.active and F.State.coords then
        TriggerClientEvent('secretbag:npcBlipAdd', source, 'forger', F.State.coords, '위조업자', 1, 3)
    end
end)

function F.StartScheduler(session)
    CreateThread(function()
        while SecretBagMode.CurrentSession == session and session.state ~= SessionState.ENDED do
            local elapsed = SecretBagMode.MainElapsedMinutes(session)
            -- Config.Features.forger를 먼저 확인해야 한다 — 꺼져있는 동안은 MarkTimelineEventOnce가
            -- 호출조차 안 되어 플래그가 소모되지 않고, 나중에 다시 켜지면 그 시점에 "뒤늦게" 스폰된다.
            if Config.Features.forger and elapsed and elapsed >= Config.Timeline.forgerSpawnAt
                and SecretBagMode.MarkTimelineEventOnce(session, 'forger_spawn') then
                F.Spawn(session)
            end
            Wait(5000)
        end
    end)
end

--- REQ 9 Forger 행: participant, bagCount==1, freeSlot>=1, forgedOnce=false.
--- SERVER_OWNER는 bagCount/freeSlot만 적용하고 forgedOnce/쿨다운 면제.
--- winner 확정 후 Forger API 비활성화.
RegisterCommand('useforger', function(source)
    local playerId = source
    local session = SecretBagMode.CurrentSession
    if not session then return end

    if session.winnerLocked then
        U.NotifyPlayer(playerId, '더 이상 위조할 수 없습니다.')
        return
    end

    local role = SecretBagMode.GetRole(playerId)
    if role == nil or role == Role.HELPER or role == Role.LATE_NONPARTICIPANT then
        U.NotifyPlayer(playerId, SecretBagMode.Message.NO_ACCESS)
        return
    end
    if role == Role.PLAYER and not SecretBagMode.IsParticipant(session, playerId) then
        U.NotifyPlayer(playerId, SecretBagMode.Message.NO_ACCESS)
        return
    end
    local ps = session.playerSessions[playerId]
    if ps and ps.awaitingRespawn then
        U.NotifyPlayer(playerId, SecretBagMode.Message[SecretBagMode.ErrorCode.AWAITING_RESPAWN])
        return
    end

    if not F.State.active or not F.State.ped or not DoesEntityExist(F.State.ped) then
        U.NotifyPlayer(playerId, '위조업자가 아직 오지 않았습니다.')
        return
    end

    local ped = GetPlayerPed(tostring(playerId))
    if not ped or ped == 0 then return end
    if #(GetEntityCoords(ped) - GetEntityCoords(F.State.ped)) > Config.Appraiser.interactDistance then
        U.NotifyPlayer(playerId, '위조업자와 너무 멉니다.')
        return
    end

    if SecretBagMode.Inventory.CountBags(session, playerId) ~= 1 then
        U.NotifyPlayer(playerId, 'SecretBag을 정확히 1개 소지하고 있어야 합니다.')
        return
    end
    if not SecretBagMode.Inventory.HasFreeSlot(session, playerId) then
        U.NotifyPlayer(playerId, '빈 슬롯이 없습니다.')
        return
    end

    local isOwner = (role == Role.SERVER_OWNER)
    local ps = session.playerSessions[playerId]
    if not isOwner and ps and ps.forgedOnce then
        U.NotifyPlayer(playerId, '이미 위조를 사용했습니다.')
        return
    end

    local sourceBag = nil
    for _, bag in pairs(session.bags) do
        if bag.currentOwnerId == playerId and bag.state == BagState.INVENTORY then
            sourceBag = bag
            break
        end
    end
    if not sourceBag then
        U.NotifyPlayer(playerId, 'SecretBag을 소지하고 있어야 합니다.')
        return
    end

    if not isOwner then
        ps.forgedOnce = true
    end

    local newBag = SecretBagMode.Bag.CreateForgedFake(session, sourceBag.appearanceScore, playerId)
    U.NotifyPlayer(playerId, ('위조 가방을 획득했습니다. (품질 %d)'):format(newBag.appearanceScore))
end, false)

function F.Cleanup(session)
    F.Despawn()
end
