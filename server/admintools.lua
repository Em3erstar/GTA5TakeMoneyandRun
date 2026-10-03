--- 관리자(SERVER_OWNER) 전용 유틸리티 도구 모음 (사용자 요청).

local U = SecretBagMode.Util

local apPistolHash = GetHashKey('WEAPON_APPISTOL')

--- 특정 유저에게 AP 피스톨을 지급한다. GiveWeaponToPed는 이미 police.lua에서 경찰 NPC에게
--- 무기를 지급할 때 서버사이드로 검증된 native라, 대상이 NPC가 아닌 플레이어 ped여도 그대로 쓸 수 있다.
RegisterCommand('giveappistol', function(source, args)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end

    local targetId = tonumber(args[1])
    if not targetId or not U.IsPlayerOnline(targetId) then
        U.NotifyPlayer(source, '사용법: /giveappistol <targetId> [탄약수(기본 250)]')
        return
    end

    local ammo = tonumber(args[2]) or 250
    local ped = GetPlayerPed(tostring(targetId))
    if not ped or ped == 0 then
        U.NotifyPlayer(source, '대상의 캐릭터를 찾을 수 없습니다.')
        return
    end

    GiveWeaponToPed(ped, apPistolHash, ammo, false, true)
    U.NotifyPlayer(source, ('%d번에게 AP 피스톨(탄약 %d)을 지급했습니다.'):format(targetId, ammo))
    U.NotifyPlayer(targetId, 'AP 피스톨을 지급받았습니다.')
end, false)

-- ============================================================
-- 특정 유저 근처로 안전하게 이동 (사용자 요청: "특정 유저의 3m 안 무사히 스폰할 수 있는
-- 곳으로 이동"). 서버는 콜리전/지형 데이터가 없어 안전한 지면 z를 모르므로, police.lua의
-- 앰비언트 스폰 요청과 동일한 기법으로 대상 본인의 클라이언트에게 자기 주변 3m 이내
-- 좌표의 실제 지면 높이를 구해오도록 요청한 뒤, 그 결과로 관리자를 이동시킨다.
-- ============================================================

local pendingGotoRequests = {} -- [requestId] = { adminId, targetId, requestedAt }

RegisterCommand('gotoplayer', function(source, args)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end

    local targetId = tonumber(args[1])
    if not targetId or not U.IsPlayerOnline(targetId) then
        U.NotifyPlayer(source, '사용법: /gotoplayer <targetId>')
        return
    end

    local requestId = U.NewId('goto')
    pendingGotoRequests[requestId] = { adminId = source, targetId = targetId, requestedAt = U.Now() }
    TriggerClientEvent('secretbag:requestSafeCoordNear', targetId, requestId)

    SetTimeout(10 * 1000, function()
        pendingGotoRequests[requestId] = nil -- 응답이 없었으면 조용히 버림 (메모리 누수 방지)
    end)
end, false)

RegisterNetEvent('secretbag:safeCoordNearResult', function(requestId, x, y, z)
    local pending = pendingGotoRequests[requestId]
    if not pending then return end -- 이미 타임아웃됐거나 알 수 없는 requestId
    if pending.targetId ~= source then return end -- 요청받은 그 클라이언트 본인만 응답할 수 있다
    pendingGotoRequests[requestId] = nil

    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return end

    local adminPed = GetPlayerPed(tostring(pending.adminId))
    if not adminPed or adminPed == 0 then return end
    SetEntityCoords(adminPed, x, y, z, false, false, false, true)
    U.NotifyPlayer(pending.adminId, ('%d번 근처(3m 이내)의 안전한 위치로 이동했습니다.'):format(pending.targetId))
end)
