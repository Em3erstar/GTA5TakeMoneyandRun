--- 위치원 / Live Reveal (기획서 11장 / 사양서 REQ-CIRCLE-001).
--- 270분 이후 실시간 공개(REQ-LIVE-001)는 finalzone.lua의 EnsureLiveReveal에서 처리한다
--- (FinalZoneCheck 우선순위 1/2/3 실패와 직접 연결되어 있어 그쪽에 두는 게 자연스럽다).

local U = SecretBagMode.Util
local SessionState = SecretBagMode.SessionState
local HistEvt = SecretBagMode.HistoryEventType

SecretBagMode.LiveReveal = SecretBagMode.LiveReveal or {}
local LR = SecretBagMode.LiveReveal

local function randomOffsetCoord(center, maxDist)
    local angle = math.random() * 2 * math.pi
    local dist = math.random() * maxDist
    return vector3(center.x + math.cos(angle) * dist, center.y + math.sin(angle) * dist, center.z)
end

--- REQ-CIRCLE-001: center=genuine coords + randomOffset, genuine이 원 안에 반드시 들어가도록
--- 오프셋을 radius*0.7 이내로 제한한다. 생성 시점 snapshot이며 이후 genuine이 움직여도
--- 원은 갱신되지 않는다(그 시점 TTL 동안만 유효).
local function revealCircle(session, radius, ttlMs, label)
    local bag = SecretBagMode.Bag.GetGenuine(session)
    if not bag then return end
    local genuineCoords = SecretBagMode.Bag.ResolveCoords(bag)
    if not genuineCoords then return end

    local center = randomOffsetCoord(genuineCoords, radius * 0.7)

    SecretBagMode.AppendHistoryEvent(session, session.logicalGenuineId, HistEvt.LOCATION_REVEAL, nil, {
        actualCoords = genuineCoords,
        circleCenter = center,
        radius = radius,
        ttl = ttlMs,
    })

    TriggerClientEvent('secretbag:circleReveal', -1, label, center, radius)
    SecretBagMode.LogTimelineEvent(session, ('위치 공개 (반경 %.0fm)'):format(radius))
    SetTimeout(ttlMs, function()
        TriggerClientEvent('secretbag:circleRemove', -1, label)
    end)
end

--- server/debug.lua의 /sbforcecircle에서 타임라인 대기 없이 즉시 실행할 수 있도록 공개.
--- kind는 'circle1500' | 'circle100'. genuine이 없으면 false를 반환한다.
function LR.RevealCircleNow(session, kind)
    local cfg = Config.Circle[kind]
    if not cfg or not SecretBagMode.Bag.GetGenuine(session) then
        return false
    end
    revealCircle(session, cfg.radius, cfg.ttlMs, kind)
    return true
end

--- 사용자 요청: 210분에 최종 구역 "자체"를 5/6번(circle1500/circle100)과 같은 방식으로
--- 미리 공개한다. revealCircle과 달리 genuine 위치 기반 랜덤 오프셋이 아니라, 실제
--- 고정된 최종 구역 좌표/반경을 그대로 방송하고 TTL 후 사라진다(봉쇄 확정 시 finalzone.lua
--- lockZone이 다시 영구적으로 표시하는 것과는 별개의 "예고" 성격).
local function revealFinalZonePreview(session)
    TriggerClientEvent('secretbag:circleReveal', -1, 'finalzonepreview', Config.FinalZoneCenter, Config.FinalZone.radius)
    SecretBagMode.LogTimelineEvent(session, '최종 구역 미리 공개')
    SetTimeout(Config.Circle.finalZonePreview.ttlMs, function()
        TriggerClientEvent('secretbag:circleRemove', -1, 'finalzonepreview')
    end)
end

--- server/debug.lua의 /sbforcecircle finalzone에서 타임라인 대기 없이 즉시 실행할 수 있도록 공개.
function LR.RevealFinalZonePreviewNow(session)
    revealFinalZonePreview(session)
end

function LR.StartScheduler(session)
    CreateThread(function()
        while SecretBagMode.CurrentSession == session and session.state ~= SessionState.ENDED do
            local elapsed = SecretBagMode.MainElapsedMinutes(session)
            -- Config.Features.liveReveal을 먼저 확인해야 한다 — 꺼져있는 동안은 MarkTimelineEventOnce가
            -- 호출조차 안 되어 플래그가 소모되지 않고, 나중에 다시 켜지면 그 시점에 "뒤늦게" 발동한다.
            if elapsed and Config.Features.liveReveal then
                if elapsed >= Config.Circle.circle1500.atMinute
                    and SecretBagMode.MarkTimelineEventOnce(session, 'circle1500') then
                    revealCircle(session, Config.Circle.circle1500.radius, Config.Circle.circle1500.ttlMs, 'circle1500')
                    U.NotifyAll('진짜 가방 위치가 대략적으로 공개되었습니다.')
                end
                if elapsed >= Config.Circle.circle100.atMinute
                    and SecretBagMode.MarkTimelineEventOnce(session, 'circle100') then
                    revealCircle(session, Config.Circle.circle100.radius, Config.Circle.circle100.ttlMs, 'circle100')
                    U.NotifyAll('진짜 가방 위치가 더 좁게 공개되었습니다.')
                end
                if elapsed >= Config.Circle.finalZonePreview.atMinute
                    and SecretBagMode.MarkTimelineEventOnce(session, 'finalZonePreview') then
                    revealFinalZonePreview(session)
                    U.NotifyAll('최종 구역이 지도에 공개되었습니다.')
                end
            end
            Wait(5000)
        end
    end)
end

function LR.Cleanup(session)
    TriggerClientEvent('secretbag:circleRemove', -1, 'circle1500')
    TriggerClientEvent('secretbag:circleRemove', -1, 'circle100')
    TriggerClientEvent('secretbag:circleRemove', -1, 'finalzonepreview')
end
