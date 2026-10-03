--- GameArea 경계("게임 무대는 섬 남부의 도시인 로스 산토스를 감싸는 원") — REQ 없이 사용자
--- 지시로 도입된 플레이 가능 구역. startgame.lua에 있던 "GameArea wall 활성화" TODO를 구현한다.
---
--- 실제 충돌체 벽을 원형 경계 전체에 두르는 건 불가능(임의 반경 원 둘레에 프롭을 촘촘히
--- 세워야 함)하므로, finalzone.lua의 FinalBarrier와 동일한 방식을 쓴다: 서버가 직접
--- GetEntityCoords/SetEntityCoords로 참가자 좌표를 감시하다가, 경계 밖으로 나가면 "마지막으로
--- 확인된 경계 안쪽 좌표"로 되돌린다. 임의로 z를 계산하지 않으므로(그 참가자 본인이 실제로
--- 서 있었던 좌표를 재사용) 지면에 파묻히거나 공중에 뜨는 문제가 없다 — police.lua 추격
--- 판정, finalzone.lua FinalBarrier와 동일한 신뢰 경계/구현 패턴.
---
--- 대상은 session.sessionParticipantIds(참가 PLAYER)만이다 — SERVER_OWNER/HELPER는
--- 관전/관리 목적상 구역 제한 없이 자유롭게 이동할 수 있어야 한다(ApplyPrepProtections가
--- participant만 대상으로 하는 것과 동일한 설계).

local U = SecretBagMode.Util
local SessionState = SecretBagMode.SessionState

SecretBagMode.GameArea = SecretBagMode.GameArea or {}
local GA = SecretBagMode.GameArea

local lastInsideCoords = {} -- [playerId] = vector3, 마지막으로 확인된 경계 안쪽 좌표
local lastWarnAt = {} -- [playerId] = ms, 안내 메시지 스팸 방지용
local WARN_INTERVAL_MS = 5000

local function isInsideGameArea(coords)
    if not Config.GameArea or not coords then return true end
    local dx = coords.x - Config.GameArea.center.x
    local dy = coords.y - Config.GameArea.center.y
    return (dx * dx + dy * dy) <= (Config.GameArea.radius * Config.GameArea.radius)
end

GA.IsInsideGameArea = isInsideGameArea

local function shouldEnforce(session)
    return session.state == SessionState.RUNNING or session.state == SessionState.FINAL_LOCKED_CONTEST
end

function GA.StartScheduler(session)
    lastInsideCoords = {}
    lastWarnAt = {}

    CreateThread(function()
        while SecretBagMode.CurrentSession == session and session.state ~= SessionState.ENDED do
            if shouldEnforce(session) then
                for pid in pairs(session.sessionParticipantIds) do
                    if U.IsPlayerOnline(pid) then
                        local ped = GetPlayerPed(tostring(pid))
                        if ped and ped ~= 0 then
                            local coords = GetEntityCoords(ped)
                            if isInsideGameArea(coords) then
                                lastInsideCoords[pid] = coords
                            else
                                local back = lastInsideCoords[pid] or Config.GameArea.center
                                SetEntityCoords(ped, back.x, back.y, back.z, false, false, false, true)
                                local now = U.Now()
                                if not lastWarnAt[pid] or (now - lastWarnAt[pid]) >= WARN_INTERVAL_MS then
                                    lastWarnAt[pid] = now
                                    U.NotifyPlayer(pid, '플레이 영역을 벗어날 수 없습니다.')
                                end
                            end
                        end
                    end
                end
            end
            Wait(2000)
        end
    end)
end

function GA.Cleanup(session)
    lastInsideCoords = {}
    lastWarnAt = {}
end
