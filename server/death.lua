--- 사망/부활 (기획서 5장 / 사양서 REQ-DEATH-001/002, REQ-DISC-001은 inventory.lua에 있음).
---
--- 신뢰 경계 주의: 사망/킬러 정보는 클라이언트(`secretbag:reportDeath`)가 보고한다.
--- FiveM에 서버 권위형 사망/킬러 감지 표준 API가 없어(CEventNetworkEntityDamage의
--- 페이로드 포맷이 빌드마다 달라 신뢰하기 어렵다) 안정적인 네이티브
--- (IsEntityDead/GetPedSourceOfDeath/GetPedCauseOfDeath)만으로 클라 탐지 후 보고하는
--- 방식을 택했다. 즉 "킬러 귀속"은 클라이언트 자가 신고를 서버가 참가자 여부만
--- 재검증하는 수준이라, 악의적 클라이언트가 킬러를 조작해 Trace를 회피/유도할 여지가
--- 남는다 — 프로덕션 전에는 서버 측 피해 로그 대조 등으로 보강 필요 (README에도 명시).

local U = SecretBagMode.Util
local BagState = SecretBagMode.BagState
local SessionState = SecretBagMode.SessionState

SecretBagMode.Death = SecretBagMode.Death or {}
local D = SecretBagMode.Death

local lastReportAt = {} -- [playerId] = ms, 리포트 스팸 방지용 (세션과 무관하게 전역 유지)

--- REQ-DEATH-001: winner lock 전 participant death 시 SecretBag만 전부 deathCoords에
--- world_drop. 기타 아이템은 관여하지 않는다(이 모드가 관리하지 않으므로 애초에 손대지 않음).
--- server/debug.lua의 /sbforcedeath가 실제 사망 없이 이 로직을 그대로 재사용할 수 있도록
--- 별도 함수로 뽑아뒀다(클라 리포트 경로와 완전히 같은 코드를 탄다 = 디버그와 실전이 다르게
--- 동작할 위험이 없다).
--- bypassCooldown: server/debug.lua 전용. 실제 클라 리포트 경로는 항상 false로 호출해
--- 쿨다운을 그대로 적용받는다 — 디버그 반복 테스트만 매번 5초씩 기다리지 않도록 예외를 둔다.
function D.ProcessDeath(session, victimId, coords, killerServerId, bypassCooldown)
    if not session or session.winnerLocked then return end
    if not SecretBagMode.IsParticipant(session, victimId) then return end

    local now = U.Now()
    if not bypassCooldown and lastReportAt[victimId] and (now - lastReportAt[victimId]) < Config.Death.reportCooldownMs then
        return
    end
    lastReportAt[victimId] = now

    local deathEventId = U.NewId('death')
    local droppedBagIds = {}

    for _, bag in pairs(session.bags) do
        if bag.currentOwnerId == victimId and bag.state == BagState.INVENTORY then
            SecretBagMode.Bag.OnDrop(session, bag, victimId, coords, 'death')
            bag.deathEventId = deathEventId
            SecretBagMode.Inventory.SpawnWorldBag(bag, coords)
            table.insert(droppedBagIds, bag.bagId)
        end
    end

    local killerId = nil
    if killerServerId and killerServerId ~= victimId and SecretBagMode.IsParticipant(session, killerServerId) then
        killerId = killerServerId
        if SecretBagMode.Police and SecretBagMode.Police.OnPlayerKilledPlayer then
            SecretBagMode.Police.OnPlayerKilledPlayer(session, killerId)
        end
        -- 사용자 확정 규칙(2026): 참가자 간 PK는 항상 정확히 수배 2단계를 부여하고
        -- (증가 방식 아님), 15분간 유지하며 재킬 시 15분씩 누적된다. 세부 로직/만료 처리는
        -- server/wanted.lua 참고.
        SecretBagMode.Wanted.OnPlayerKill(session, killerId)
    end

    session.deathEvents[deathEventId] = {
        deathEventId = deathEventId,
        victimId = victimId,
        killerId = killerId,
        coords = coords,
        droppedBagIds = droppedBagIds,
        traceAwarded = false,
    }

    -- REQ-DEATH-002: 60초 후 deathCoords if safe else nearestSafeCoord.
    -- 단순화: 실제 안전좌표(navmesh/충돌) 판정은 미구현. "FinalZone lock 이후 내부 사망자는
    -- 반드시 내부 안전 좌표에 부활"은 사망 시점 좌표가 실제로 FinalZone 내부였을 때만 적용한다
    -- (락 이후 구역 밖에서 죽은 사람까지 안으로 끌어들이면 안 된다).
    local wasInsideFinalZoneAtDeath = SecretBagMode.FinalZone
        and SecretBagMode.FinalZone.IsInsideFinalZone
        and SecretBagMode.FinalZone.IsInsideFinalZone(coords)

    -- finalzone.lua REQ-FINAL-002 "FinalZone 내부 death respawn wait 참가자": 사망 직후
    -- ped가 죽어있는 상태라 좌표 기반 판정(countValidParticipantsInside)이 순간적으로
    -- "내부 아님"으로 오판할 수 있다. 부활 전까지는 이 플래그로 계속 "내부"로 카운트한다.
    local ps = session.playerSessions[victimId]
    if ps and wasInsideFinalZoneAtDeath then
        ps.pendingFinalZoneRespawn = true
    end
    if ps then ps.awaitingRespawn = true end

    SetTimeout(Config.Death.respawnDelayMs, function()
        if ps then
            ps.pendingFinalZoneRespawn = false
            ps.awaitingRespawn = false
        end
        if SecretBagMode.CurrentSession ~= session or session.state == SessionState.ENDED then return end
        local respawnCoords = coords
        if session.finalZoneLocked and wasInsideFinalZoneAtDeath and Config.FinalZoneCenter then
            respawnCoords = Config.FinalZoneCenter
        end
        TriggerClientEvent('secretbag:respawnAt', victimId, respawnCoords)
    end)
end

RegisterNetEvent('secretbag:reportDeath', function(coords, killerServerId)
    local victimId = tonumber(source)
    D.ProcessDeath(SecretBagMode.CurrentSession, victimId, coords, killerServerId)
end)
