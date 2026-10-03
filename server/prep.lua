--- REQ-PREP-001 / REQ-PREP-002: 무적/전투 금지 처리.
---
--- 원래 SetPlayerWeaponDamageModifier/SetPlayerWeaponDefenseModifier를 "서버 네이티브라
--- 신뢰 가능하다"는 잘못된 가정으로 서버에서 직접 호출했었다 — 실제로는 두 네이티브 모두
--- API set이 client 전용이라(docs.fivem.net 확인) 서버 Lua 환경에는 그 전역 함수 자체가
--- 존재하지 않는다. 서버에서 호출하면 매번 "attempt to call a nil value"로 즉시 죽어서,
--- 이 함수를 거치는 모든 경로(assignrole/emergencysetowner/startgame의 PREP 보호/승자
--- 확정 시 전원 보호/endgame 정리)가 전부 조용히 실패하고 있었다 — 구문 검사(luaparser)는
--- 이런 "존재하지 않는 전역 호출"을 잡아내지 못해 실제로 실행해보기 전까지 드러나지 않았다.
--- SetPlayerInvincible은 서버사이드 RPC 동등 네이티브가 있고("모든 형태의 피해"를 막아
--- 기존 두 네이티브보다 더 포괄적이다) 그것으로 대체한다. 폭발/낙사/차량 등은 여전히
--- 클라이언트의 SetEntityInvincible로 보강한다 (client/main.lua 참고).

local Role = SecretBagMode.Role

SecretBagMode.Protection = {} -- [playerId:number] = boolean

local function applyProtection(playerId, invincible)
    playerId = tonumber(playerId)
    SecretBagMode.Protection[playerId] = invincible
    -- "Player" 타입 네이티브는 서버 ID를 문자열로 기대한다 (GetPlayerPed 등과 동일 관례).
    -- 숫자를 넘겨도 대부분 동작하지만, 코드베이스 전체 관례에 맞춰 명시적으로 변환한다.
    local playerIdStr = tostring(playerId)
    SetPlayerInvincible(playerIdStr, invincible)
    TriggerClientEvent('secretbag:setInvincible', playerId, invincible)
end

SecretBagMode.ApplyProtection = applyProtection

--- PREP 진입: 전원 participant 무적 + 전투 금지. 가방/인벤토리 조작은 허용 (REQ-PREP-001).
function SecretBagMode.ApplyPrepProtections(session)
    for pid in pairs(session.sessionParticipantIds) do
        applyProtection(pid, true)
    end
end

--- PREP 종료(RUNNING 진입) 시 participant 보호 해제.
--- SERVER_OWNER/HELPER/late nonparticipant는 세션 내내 유지된다 (REQ-PREP-002).
function SecretBagMode.OnPrepEnd(session)
    for pid in pairs(session.sessionParticipantIds) do
        applyProtection(pid, false)
    end
end

--- 비참가자(SERVER_OWNER/HELPER/late nonparticipant)는 role 배정 즉시 무적 적용.
function SecretBagMode.ApplyNonParticipantProtection(playerId)
    applyProtection(playerId, true)
end

--- REQ-END-004: cleanup 완료 시 모든 유저의 보호 상태를 완전 해제한다.
function SecretBagMode.ClearAllProtections()
    for _, playerId in ipairs(GetPlayers()) do
        applyProtection(playerId, false)
    end
end
