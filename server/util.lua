SecretBagMode = SecretBagMode or {}
SecretBagMode.Util = {}

local U = SecretBagMode.Util

function U.Now()
    return GetGameTimer()
end

function U.NewId(prefix)
    local template = (prefix or 'id') .. '-xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 15) or math.random(8, 11)
        return string.format('%x', v)
    end)
end

function U.RandomInt(min, max)
    return math.random(min, max)
end

--- 리스트에서 균등 랜덤으로 하나를 뽑는다. NPC 후보 스폰 좌표 풀 선택에 사용.
function U.PickRandom(list)
    if not list or #list == 0 then return nil end
    return list[math.random(1, #list)]
end

-- 세션 전체를 아우르는 단순 뮤텍스. FiveM Lua는 이벤트 핸들러 사이에서
-- yield(await) 없이 실행되는 한 원자적이므로, CAS가 필요한 구간
-- (StartGame/EndGame/FinalZoneCheck/AdminSpawnGenuine/winner pickup)은
-- 이 플래그로 재진입을 막는 것만으로 REQ-STATE-002 / REQ-FINAL-004 요구를 충족한다.
-- DB 비동기 호출을 넣게 되면 반드시 이 락 안에서 await하지 말 것.
local locks = {}

function U.WithLock(lockName, fn)
    if locks[lockName] then
        return false, 'LOCKED'
    end
    locks[lockName] = true
    local ok, result = pcall(fn)
    locks[lockName] = false
    if not ok then
        error(result, 0)
    end
    return true, result
end

-- U.NotifyAll/NotifyPlayer는 원래 클라이언트 이벤트 하나로만 알림을 보냈다. 클라이언트는
-- 이를 TriggerEvent('chat:addMessage', ...)로 받아 표시하는데, 이 프로젝트의 실제 배포
-- 환경(cfx-server-data 기본 구성)에는 chat 리소스가 없어 그 이벤트를 듣는 쪽이 아무도
-- 없다 — 즉 /startgame, /pickupbag 같은 일반 명령의 성공/실패 알림이 전부 조용히
-- 사라져서, 명령어가 실제로 실행됐는지조차 확인할 방법이 없었다(제대로 안 먹히는 것처럼
-- 보이는 원인 중 하나). server/debug.lua의 debugPrint가 이미 하던 "서버 콘솔에도 출력"
-- 패턴을 여기서도 적용해, chat 리소스가 있든 없든 항상 서버 콘솔(검은 창)에서는 확인할
-- 수 있게 한다.
function U.NotifyAll(message)
    print('[SecretBag] (전체) ' .. tostring(message))
    TriggerClientEvent('secretbag:notify', -1, message)
end

function U.NotifyPlayer(playerId, message)
    print(('[SecretBag] (%s) %s'):format(tostring(playerId), tostring(message)))
    -- source==0은 실제 접속한 플레이어가 아니라 서버 콘솔/RCON 자신을 가리키는 특수값이다
    -- (state.lua의 assignrole 등 여러 명령이 콘솔에서 직접 실행 가능하도록 source~=0 체크를
    -- 우회하게 해준다). 0을 그대로 TriggerClientEvent에 넘기면 대상 클라이언트가 없어
    -- "Argument at index 1 was null" 네이티브 에러로 죽는다 — 콘솔 자신에게는 어차피 위의
    -- print()가 이미 보여줬으므로 클라이언트 이벤트 자체를 건너뛴다.
    local numId = tonumber(playerId)
    if not numId or numId <= 0 then return end
    TriggerClientEvent('secretbag:notify', playerId, message)
end

function U.IsPlayerOnline(playerId)
    local ped = GetPlayerPed(tostring(playerId))
    return ped ~= nil and ped ~= 0
end

--- CreatePed/CreateObject는 드물게 실패해 0(또는 무효 핸들)을 반환할 수 있다(GTA5 엔진
--- 자체의 알려진 특성 — 엔티티 풀/스트리밍 순간 혼잡 등). 기존에는 실패를 감지만 하고
--- 그대로 포기해, 한 번 실패하면 그 NPC/오브젝트가 세션 내내 영구히 스폰되지 않는
--- 문제가 있었다. 짧은 대기 후 최대 attemptFn 재시도. attemptFn은 CreatePed/CreateObject
--- 호출 자체를 감싸야 한다(재시도마다 새로 호출해야 하므로).
---
--- 생성 직후 곧바로 DoesEntityExist로 재확인하려 했더니, 핸들이 실제로는 유효한데도
--- 그 찰나에는 아직 (서버 내부) 엔티티 레지스트리 등록이 안 끝나 false가 나오는 경우가
--- 있었다 — Wait(0) 한 틱으로도 완전히 해소되지 않았다(가방이 3개→2개로 줄었을 뿐
--- 계속 재현됨). 실제로 무효한 모델(예: 오타난 모델명)일 때 CreateObject/CreatePed는
--- DoesEntityExist를 거치지 않고도 그 자리에서 곧바로 0을 반환한다는 것을
--- 'hei_prop_heist_bag_var22' 오타 사례로 이미 확인했으므로, DoesEntityExist라는 불필요
--- 하고 불안정한 재확인 없이 반환값이 0이 아닌지만으로 충분하다 — 대부분의 FiveM
--- 스크립트가 쓰는 표준적인 방식이기도 하다.
function U.RetryUntilValid(maxAttempts, waitMs, attemptFn)
    for i = 1, maxAttempts do
        local result = attemptFn()
        if result and result ~= 0 then
            return result
        end
        if i < maxAttempts then
            Wait(waitMs)
        end
    end
    return nil
end

--- 진짜 근본 원인을 /sbminimalobjecttest로 실측 확인했다: 서버 쪽 CreatePed/CreateObject는
--- 핸들을 즉시 반환하지만, 그 엔티티가 실제로 "존재하는" 상태가 되는 건 몇 틱 뒤다
--- (DoesEntityExist가 생성 직후 같은 틱에는 false, Wait(0)를 단 2번만 줘도 true로 확인됨 —
--- FiveM 커뮤니티에도 알려진 특성: "entity creation does not happen on the same tick").
--- 그동안 이 프로젝트에서 반복된 "Tried to access invalid entity" 크래시는 전부 이게
--- 원인이었다 — 생성 직후 같은 틱에 SetEntityDistanceCullingRadius 같은 후속 native를
--- 곧바로 불러서 아직 등록 안 된 엔티티를 건드린 것이다(모델/native 종류/호출 경로와는
--- 무관했다 — ped가 우연히 덜 자주 재현된 것도 이 타이밍 레이스 때문이었을 뿐이다).
---
--- 그래서 생성 후 곧바로 쓰지 않고, DoesEntityExist가 true가 될 때까지 Wait(0)로 틱을
--- 넘기며 기다린 뒤에만 setupFn(culling radius 등)을 호출한다. 이러면 재시도-삭제 같은
--- 복잡한 방어 로직 자체가 필요 없다 — 애초에 실패한 게 아니라 "아직 준비 안 된 것"뿐이었다.
function U.CreateEntitySafely(maxAttempts, waitMs, createFn, setupFn)
    for i = 1, maxAttempts do
        local entity = createFn()
        if entity and entity ~= 0 then
            local ticks = 0
            while not DoesEntityExist(entity) and ticks < 50 do
                Wait(0)
                ticks = ticks + 1
            end
            if DoesEntityExist(entity) then
                local ok, err = pcall(setupFn, entity)
                if not ok then
                    print('[SecretBag] 경고: 엔티티는 생성됐지만 초기설정 중 일부 실패 — 무시하고 계속 진행: ' .. tostring(err))
                end
                return entity
            end
        end
        if i < maxAttempts then
            Wait(waitMs)
        end
    end
    return nil
end

-- ============================================================
-- 지면 높이(Ground Z) 비동기 조회
-- ============================================================
-- Config.NpcSpawnPools의 후보 좌표들은 전부 같은 고정 추정치(NPC_Z_DEFAULT=30.0)를 쓰는데,
-- 실제 로스산토스 지형은 위치마다 고도가 크게 달라(해안가 0m 근처부터 언덕 100m 이상까지)
-- NPC가 땅에 파묻히거나 공중에 떠서 "스폰이 안 되는 것처럼" 보이는 문제의 원인이었다.
-- GetGroundZFor_3dCoord/RequestCollisionAtCoord는 둘 다 API set이 client 전용이라
-- (docs.fivem.net 확인) 서버가 직접 계산할 수 없어, 현재 접속 중인 아무 클라이언트에게
-- 위임한다 — RequestCollisionAtCoord로 그 좌표의 콜리전을 강제로 스트리밍하면 요청받은
-- 클라이언트가 그 위치 근처에 있어본 적이 없어도 정확한 지면 높이를 구할 수 있다(기존의
-- "일단 대충 스폰한 뒤 근처에 우연히 있는 클라이언트가 사후 보정" 방식보다 훨씬 안정적).
local groundZWaiters = {}
local groundZReqCounter = 0

--- (x, y) 위치의 실제 지면 높이를 비동기로 구해 callback(z)로 전달한다. 접속 중인 사람이
--- 아무도 없거나 7초 안에 응답이 없으면 fallbackZ로 대체한다. 클라이언트 쪽 재시도 예산이
--- 5초(client/main.lua의 secretbag:requestGroundZ)라 왕복 여유를 더해 7초로 잡는다.
function U.ResolveGroundZ(x, y, fallbackZ, callback)
    local resolverId = nil
    for _, pidStr in ipairs(GetPlayers()) do
        resolverId = tonumber(pidStr)
        break
    end
    if not resolverId then
        callback(fallbackZ)
        return
    end

    groundZReqCounter = groundZReqCounter + 1
    local requestId = groundZReqCounter
    local done = false

    groundZWaiters[requestId] = {
        pid = resolverId,
        resolve = function(found, z)
            if done then return end
            done = true
            groundZWaiters[requestId] = nil
            callback((found and type(z) == 'number') and z or fallbackZ)
        end,
    }

    TriggerClientEvent('secretbag:requestGroundZ', resolverId, requestId, x, y)

    SetTimeout(7000, function()
        local waiter = groundZWaiters[requestId]
        if waiter then waiter.resolve(false, fallbackZ) end
    end)
end

--- 요청받은 클라이언트 본인만 응답할 수 있다(police.lua의 ambientSpawnPointResult와 동일한
--- 검증 패턴) — 다른 클라이언트가 임의 requestId로 응답을 스푸핑하는 것을 막는다.
RegisterNetEvent('secretbag:groundZResult', function(requestId, found, z)
    local waiter = groundZWaiters[requestId]
    if not waiter or waiter.pid ~= source then return end
    waiter.resolve(found, z)
end)

--- 표준 ray-casting point-in-polygon (XY 평면, z 무시). vector2 목록으로 정의된
--- 임의 다각형 구역에 대해 coords가 내부인지 판정한다. 현재 Config.GameArea는
--- 원형(center+radius)이라 미사용이지만, 다각형 구역이 필요해지면(다른 존 등) 재사용할 수 있다.
function U.IsPointInPolygonXY(point, polygon)
    if not point or not polygon or #polygon < 3 then
        return false
    end
    local inside = false
    local n = #polygon
    local j = n
    for i = 1, n do
        local pi, pj = polygon[i], polygon[j]
        if ((pi.y > point.y) ~= (pj.y > point.y)) and
           (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x) then
            inside = not inside
        end
        j = i
    end
    return inside
end
