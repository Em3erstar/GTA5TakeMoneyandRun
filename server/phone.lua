--- 유저 간 1:1 전화 시스템 (사용자 요청). 현재 접속 중인 아무나(역할과 무관 — PLAYER,
--- SERVER_OWNER 등 전부 포함)가 서로 전화를 걸고 받을 수 있다. 게임 세션(SecretBagMode.
--- CurrentSession) 존재 여부와 무관하게 항상 동작한다 — 게임 규칙이 아니라 일반 통신
--- 기능이라 PRE_GAME 등 어느 상태에서도 쓸 수 있어야 한다.
---
--- 음성은 클라이언트의 MUMBLE_SET_VOICE_CHANNEL(client/main.lua)로 두 사람을 같은 채널에
--- 묶어 거리와 무관하게 서로만 들리게 한다. 매 통화 성사 시 새 채널 번호를 발급해
--- 동시에 여러 통화가 진행돼도 서로 섞이지 않는다.

local U = SecretBagMode.Util

local PhoneState = {
    activeCallPartner = {}, -- [playerId] = otherPlayerId (통화 연결됨)
    pendingCalls = {}, -- [targetId] = { callerId, requestedAt } (수신 대기 중, 아직 안 받음)
    -- pendingCalls의 역방향 인덱스. "이 사람이 이미 누군가에게 발신 중인가?"를 매번
    -- pendingCalls 전체를 순회하지 않고 바로 확인/정리할 수 있게 해준다 — 원래 이 인덱스가
    -- 없어서 발신 측 "이미 다른 사람에게 거는 중" 여부를 전혀 체크하지 않았고, 그 상태로
    -- 같은 사람이 짧은 시간에 두 번째 통화를 걸어 둘 다 accept되면 activeCallPartner가
    -- 뒤엣것으로 덮어써지며 첫 번째 상대는 응답 없이 방치되는 버그가 있었다.
    outgoingPendingTarget = {}, -- [callerId] = targetId
    nextChannel = 1000, -- 매 통화 성사마다 +1 — 겹치지 않는 채널 번호를 계속 새로 발급
}

local CALL_RING_TIMEOUT_MS = 20 * 1000

local function endCall(playerId, reason)
    local partnerId = PhoneState.activeCallPartner[playerId]
    if not partnerId then return end
    PhoneState.activeCallPartner[playerId] = nil
    PhoneState.activeCallPartner[partnerId] = nil
    TriggerClientEvent('secretbag:phoneEnded', playerId, reason)
    TriggerClientEvent('secretbag:phoneEnded', partnerId, reason)
end

--- 전화기 UI를 열 때마다 현재 접속 중인(자신 제외) 명단을 보내준다.
RegisterNetEvent('secretbag:phoneRequestRoster', function()
    local src = source
    local roster = {}
    for _, pidStr in ipairs(GetPlayers()) do
        local pid = tonumber(pidStr)
        if pid ~= src then
            table.insert(roster, { id = pid, name = GetPlayerName(pidStr) })
        end
    end
    TriggerClientEvent('secretbag:phoneRoster', src, roster)
end)

RegisterNetEvent('secretbag:phoneCall', function(targetId)
    local callerId = source
    targetId = tonumber(targetId)

    if not targetId or targetId == callerId or not U.IsPlayerOnline(targetId) then
        TriggerClientEvent('secretbag:phoneEnded', callerId, 'offline')
        return
    end
    -- 이미 통화 중이거나, 누군가 나에게 거는 중이거나, 내가 이미 다른 사람에게 거는 중이면 안 됨.
    if PhoneState.activeCallPartner[callerId] or PhoneState.pendingCalls[callerId]
        or PhoneState.outgoingPendingTarget[callerId] then
        TriggerClientEvent('secretbag:phoneEnded', callerId, 'self_busy')
        return
    end
    if PhoneState.activeCallPartner[targetId] or PhoneState.pendingCalls[targetId] then
        TriggerClientEvent('secretbag:phoneEnded', callerId, 'busy')
        return
    end

    PhoneState.pendingCalls[targetId] = { callerId = callerId, requestedAt = U.Now() }
    PhoneState.outgoingPendingTarget[callerId] = targetId
    TriggerClientEvent('secretbag:phoneIncoming', targetId, callerId, GetPlayerName(tostring(callerId)))
    TriggerClientEvent('secretbag:phoneRinging', callerId, targetId, GetPlayerName(tostring(targetId)))

    SetTimeout(CALL_RING_TIMEOUT_MS, function()
        local pending = PhoneState.pendingCalls[targetId]
        if pending and pending.callerId == callerId then
            PhoneState.pendingCalls[targetId] = nil
            PhoneState.outgoingPendingTarget[callerId] = nil
            TriggerClientEvent('secretbag:phoneEnded', callerId, 'no_answer')
            TriggerClientEvent('secretbag:phoneEnded', targetId, 'no_answer')
        end
    end)
end)

RegisterNetEvent('secretbag:phoneAccept', function()
    local targetId = source
    local pending = PhoneState.pendingCalls[targetId]
    if not pending then return end
    PhoneState.pendingCalls[targetId] = nil

    local callerId = pending.callerId
    PhoneState.outgoingPendingTarget[callerId] = nil

    if not U.IsPlayerOnline(callerId) then
        TriggerClientEvent('secretbag:phoneEnded', targetId, 'hangup')
        return
    end

    PhoneState.activeCallPartner[callerId] = targetId
    PhoneState.activeCallPartner[targetId] = callerId
    PhoneState.nextChannel = PhoneState.nextChannel + 1
    local channel = PhoneState.nextChannel

    TriggerClientEvent('secretbag:phoneConnected', callerId, targetId, GetPlayerName(tostring(targetId)), channel)
    TriggerClientEvent('secretbag:phoneConnected', targetId, callerId, GetPlayerName(tostring(callerId)), channel)
end)

--- 통화 종료·수신 거절·발신 취소를 이 하나의 이벤트로 전부 처리한다: 클라이언트는
--- "지금 상태가 뭐든 끝낸다" 버튼만 누르면 되고, 서버가 발신자/수신자/통화중 중
--- 어느 상태인지 보고 알맞게 정리한다.
RegisterNetEvent('secretbag:phoneHangup', function()
    local playerId = source

    if PhoneState.activeCallPartner[playerId] then
        endCall(playerId, 'hangup')
        return
    end

    -- 내가 수신 대기 중(누군가 나에게 거는 중)이었다면 = 거절.
    local incoming = PhoneState.pendingCalls[playerId]
    if incoming then
        PhoneState.pendingCalls[playerId] = nil
        PhoneState.outgoingPendingTarget[incoming.callerId] = nil
        TriggerClientEvent('secretbag:phoneEnded', incoming.callerId, 'declined')
        TriggerClientEvent('secretbag:phoneEnded', playerId, 'declined')
        return
    end

    -- 내가 발신 대기 중(응답을 기다리는 중)이었다면 = 취소.
    local outgoingTarget = PhoneState.outgoingPendingTarget[playerId]
    if outgoingTarget then
        PhoneState.pendingCalls[outgoingTarget] = nil
        PhoneState.outgoingPendingTarget[playerId] = nil
        TriggerClientEvent('secretbag:phoneEnded', outgoingTarget, 'cancelled')
        TriggerClientEvent('secretbag:phoneEnded', playerId, 'cancelled')
    end
end)

--- 통화 중이거나 수신/발신 대기 중인 사람이 접속을 끊으면 상대방에게도 알려 정리한다
--- (안 그러면 상대방은 음성 채널이 계속 걸린 채로 남거나 응답 없는 화면에 갇힌다).
AddEventHandler('playerDropped', function()
    local playerId = tonumber(source)
    endCall(playerId, 'disconnected')

    local incoming = PhoneState.pendingCalls[playerId]
    if incoming then
        PhoneState.pendingCalls[playerId] = nil
        PhoneState.outgoingPendingTarget[incoming.callerId] = nil
        TriggerClientEvent('secretbag:phoneEnded', incoming.callerId, 'disconnected')
    end

    local outgoingTarget = PhoneState.outgoingPendingTarget[playerId]
    if outgoingTarget then
        PhoneState.pendingCalls[outgoingTarget] = nil
        PhoneState.outgoingPendingTarget[playerId] = nil
        TriggerClientEvent('secretbag:phoneEnded', outgoingTarget, 'disconnected')
    end
end)
