--- TraceCount 시스템 (기획서 8장 / 사양서 REQ-TRACE-001~004, REQ-RECON-001).

local U = SecretBagMode.Util
local SessionState = SecretBagMode.SessionState

SecretBagMode.Trace = SecretBagMode.Trace or {}
local T = SecretBagMode.Trace

--- 핑 주기 계산 (기획서 8장 표). count>=4이고 mainElapsed>=120분이면 1분으로 override.
local function computeIntervalMs(count, mainElapsedMinutes)
    if count <= 0 then return nil end
    if mainElapsedMinutes and mainElapsedMinutes >= 120 and count >= 4 then
        return Config.Trace.intervalAfter120Ms
    end
    if count == 1 then return Config.Trace.pingIntervalMsByCount[1] end
    if count == 2 then return Config.Trace.pingIntervalMsByCount[2] end
    return Config.Trace.pingIntervalMsByCount[3] -- count>=3 기본값(2분)
end

--- 대상의 현재 좌표를 이름과 함께, hiddenTraceTargets에 없는 참가자에게만 핑.
function T.SendPing(session, targetPlayerId)
    if not U.IsPlayerOnline(targetPlayerId) then return end
    local ped = GetPlayerPed(tostring(targetPlayerId))
    local coords = GetEntityCoords(ped)
    local name = GetPlayerName(tostring(targetPlayerId))

    for pid in pairs(session.sessionParticipantIds) do
        if pid ~= targetPlayerId then
            local observerPs = session.playerSessions[pid]
            if not (observerPs and observerPs.hiddenTraceTargets[targetPlayerId]) then
                TriggerClientEvent('secretbag:tracePing', pid, targetPlayerId, name, coords)
            end
        end
    end
end

function T.RescheduleNextPing(session, playerId)
    local ps = session.playerSessions[playerId]
    if not ps then return end
    local interval = computeIntervalMs(ps.traceCount, SecretBagMode.MainElapsedMinutes(session))
    ps.nextTracePingAt = interval and (U.Now() + interval) or nil
end

--- REQ-TRACE-001: pickerId==killerId && bagId in droppedBagIds && traceAwarded=false일 때만
--- 1회 증가. 동일 death에서 최대 1회 (session.deathEvents[...].traceAwarded 게이트).
function T.OnBagPickedFromDeathEvent(session, pickerId, deathEventId)
    local deathEvent = session.deathEvents[deathEventId]
    if not deathEvent or deathEvent.traceAwarded then return end
    if deathEvent.killerId == nil or deathEvent.killerId ~= pickerId then return end

    deathEvent.traceAwarded = true
    T.Increment(session, pickerId)
end

--- REQ-TRACE-002: count 증가 즉시 ping + nextTracePingAt 재계산.
function T.Increment(session, playerId)
    if not Config.Features.trace then return end
    local ps = session.playerSessions[playerId]
    if not ps then return end
    ps.traceCount = ps.traceCount + 1
    T.SendPing(session, playerId)
    T.RescheduleNextPing(session, playerId)
end

--- REQ-TRACE-003: 120분, 모든 sessionParticipantIds +1. online은 즉시 ping,
--- offline은 count만 증가 후 reconnect 시 즉시 ping(REQ-RECON-001, clientReady 핸들러).
function T.OnMainElapsed120(session)
    if not Config.Features.trace then return end
    for pid in pairs(session.sessionParticipantIds) do
        local ps = session.playerSessions[pid]
        if ps then
            ps.traceCount = ps.traceCount + 1
            if U.IsPlayerOnline(pid) then
                T.SendPing(session, pid)
                T.RescheduleNextPing(session, pid)
                -- 사용자 요청: 평소엔 본인 화면에 본인 핑이 안 뜨지만("다른 관찰자에게만
                -- 노출"이 기본 설계), 추적 강화(120분) 이벤트가 실제로 발동했는지 본인도
                -- 바로 확인할 수 있도록 이 순간만큼은 자기 자신에게도 자기 위치 핑을 쏜다.
                local selfPed = GetPlayerPed(tostring(pid))
                if selfPed and selfPed ~= 0 then
                    TriggerClientEvent('secretbag:tracePing', pid, pid, GetPlayerName(tostring(pid)), GetEntityCoords(selfPed))
                end
            else
                ps.nextTracePingAt = nil
            end
        end
    end
    SecretBagMode.LogTimelineEvent(session, '추적 강화 (전원 TraceCount +1)')
    U.NotifyAll('추적이 강화되었습니다.')
end

--- REQ-TRACE-004: observer가 target ping을 삭제하면 세션 종료까지 해당 target 후속 ping 영구 숨김.
RegisterCommand('deletetraceping', function(source, args)
    local session = SecretBagMode.CurrentSession
    if not session then return end
    local targetId = tonumber(args[1])
    if not targetId then return end
    local ps = session.playerSessions[tonumber(source)]
    if ps then
        ps.hiddenTraceTargets[targetId] = true
    end
end, false)

--- REQ-RECON-001: 기존 participant가 재접속(스폰 완료 시점)하면 traceCount>0인 경우
--- 즉시 1회 ping 후 새 주기로 재계산한다.
RegisterNetEvent('secretbag:clientReady', function()
    local playerId = tonumber(source)
    local session = SecretBagMode.CurrentSession
    if not session then return end
    if not SecretBagMode.IsParticipant(session, playerId) then return end
    local ps = session.playerSessions[playerId]
    if ps and ps.traceCount > 0 then
        T.SendPing(session, playerId)
        T.RescheduleNextPing(session, playerId)
    end
end)

--- 120분 이벤트 + 예정된 개인별 nextTracePingAt 도래분을 폴링 처리.
--- REQ(기획서 8장): "FinalZone lock 즉시 TraceService 종료 및 기존 ping 제거" — session.finalZoneLocked가
--- true가 되는 순간 루프를 종료한다 (ping 제거 자체는 finalzone.lua의 lockZone에서 브로드캐스트).
function T.StartScheduler(session)
    CreateThread(function()
        while SecretBagMode.CurrentSession == session
            and session.state ~= SessionState.ENDED
            and not session.finalZoneLocked do
            local elapsed = SecretBagMode.MainElapsedMinutes(session)

            -- Config.Features.trace를 먼저 확인해야 한다 — MarkTimelineEventOnce는 조건절
            -- and 단축평가로만 호출되므로, 꺼져있는 동안은 플래그가 소모되지 않고 남아있다가
            -- 나중에 다시 켜지면 그 시점에 120분 이벤트가 정상적으로 "뒤늦게" 발동한다.
            if Config.Features.trace and elapsed and elapsed >= Config.Timeline.traceBumpAt
                and SecretBagMode.MarkTimelineEventOnce(session, 'trace_120') then
                T.OnMainElapsed120(session)
            end

            if Config.Features.trace then
                for pid in pairs(session.sessionParticipantIds) do
                    local ps = session.playerSessions[pid]
                    if ps and ps.nextTracePingAt and U.Now() >= ps.nextTracePingAt then
                        if U.IsPlayerOnline(pid) then
                            T.SendPing(session, pid)
                        end
                        T.RescheduleNextPing(session, pid)
                    end
                end
            end

            Wait(5000)
        end
    end)
end

function T.Cleanup(session)
    -- StartScheduler의 CreateThread는 session.state ~= RUNNING 계열이 되는 즉시 루프를 빠져나간다.
    -- 개별 SetTimeout이 아니라 폴링 방식이라 별도 타이머 해제가 필요 없다.
end
