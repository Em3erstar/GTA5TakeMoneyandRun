--- 수배(Wanted) 시스템 (사용자 확정 규칙, 2026). 참가자 간 PK가 확정되면(death.lua) 킬러에게
--- 항상 정확히 Config.Wanted.level 단계를 부여한다. 그 외 어떤 사유로도 수배 레벨이 바뀌면
--- 안 되므로("플레이어 킬 이외에는 수배 레벨 변동 없음"), 활성 상태인 동안은 이 스레드가
--- 계속 그 값으로 강제 고정한다 — GTA5 기본 인구가 켜져 있어 시민을 치거나 공공장소에서
--- 소란을 피워도 수배가 오르내리지 않게 막는 역할까지 겸한다. 사망해도 수배가 사라지면
--- 안 되므로(부활 시 게임 엔진이 초기화할 가능성 포함), 매 tick 강제 재적용한다.
---
--- SetPlayerWantedLevel/GetPlayerWantedLevel/ClearPlayerWantedLevel은 전부 CFX 네임스페이스에
--- API set: server인 RPC 버전이 따로 있어(docs.fivem.net 확인 — death.lua의 기존 수배 로직도
--- 이미 이 방식을 썼다) 클라이언트 왕복 없이 서버에서 직접 처리한다.

local U = SecretBagMode.Util

SecretBagMode.Wanted = SecretBagMode.Wanted or {}
local W = SecretBagMode.Wanted

W.expiresAt = {} -- [playerId] = ms timestamp (U.Now() 기준)

--- 참가자 간 PK 확정 시 호출한다(death.lua). 이미 수배 중이면 리셋이 아니라 남은 시간에
--- 15분을 더한다(사용자 확정 규칙: "수배 중 재킬 시 현재 타이머에 15분이 더해짐").
--- 사용자 확정 규칙(2026): Config.Timeline.policeDespawnAt(180분) 이후에는 경찰 시스템
--- 자체가 완전히 종료되므로 어떤 PK가 발생해도 수배 레벨을 새로 부여하지 않는다.
function W.OnPlayerKill(session, killerId)
    local elapsed = session and SecretBagMode.MainElapsedMinutes(session)
    if elapsed and elapsed >= Config.Timeline.policeDespawnAt then return end

    local now = U.Now()
    local current = W.expiresAt[killerId]
    local base = (current and current > now) and current or now
    W.expiresAt[killerId] = base + Config.Wanted.durationMs
    SetPlayerWantedLevel(tostring(killerId), Config.Wanted.level, false)
end

--- 180분 도달 시 police.lua가 호출한다. 이미 부여된 수배도 즉시 전부 해제한다 — 그대로
--- 두면 실제 GTA5 기본 경찰이 계속 추격하게 되어 "180분부터 모든 경찰 스폰을 끈다"는
--- 취지에 어긋난다.
function W.ClearAll()
    for playerId in pairs(W.expiresAt) do
        ClearPlayerWantedLevel(tostring(playerId))
    end
    W.expiresAt = {}
end

--- 활성 상태 유지 + 만료 처리. 1초 주기로 충분하다 — 수배 단계가 눈에 띄게 늦게 반영될
--- 정도로 긴 간격이 아니고, 만료 시점도 15분 단위라 1초 오차는 무의미하다.
CreateThread(function()
    while true do
        local now = U.Now()
        for playerId, expiresAt in pairs(W.expiresAt) do
            if not U.IsPlayerOnline(playerId) then
                W.expiresAt[playerId] = nil
            elseif now >= expiresAt then
                -- 사용자 확정 규칙: 서서히 감소하는 기본 GTA5 방식이 아니라 즉시 완전히 초기화.
                ClearPlayerWantedLevel(tostring(playerId))
                W.expiresAt[playerId] = nil
            elseif GetPlayerWantedLevel(tostring(playerId)) ~= Config.Wanted.level then
                SetPlayerWantedLevel(tostring(playerId), Config.Wanted.level, false)
            end
        end
        Wait(1000)
    end
end)
