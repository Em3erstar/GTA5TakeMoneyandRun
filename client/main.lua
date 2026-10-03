--- 진단 결과: 오브젝트(가방)는 정상 렌더링되는데 서버가 CreatePed로 만드는 ped는
--- 모델·위치·재시도 로직을 전부 고쳐도, 심지어 /sbpull로 눈앞까지 끌어와도 계속 안
--- 보였다 — 반면 GTA5가 자체적으로 만드는 일반 행인/경찰은 정상적으로 보인다. 서버는
--- 모델 스트리밍이라는 개념 자체가 없어(렌더링을 하지 않으므로) 클라이언트가 아직
--- 그 모델을 한 번도 요청/캐싱한 적이 없는 상태에서 OneSync가 "이 위치에 이 모델의
--- ped가 있다"고 동기화하면, 클라이언트가 모델을 뒤늦게 스트리밍하는 동안(또는 실패
--- 시) 그 엔티티를 다시 렌더링 대상으로 재시도하지 않아 영구히 빈 채로 남는 경우가
--- 있는 것으로 보인다 — DoesEntityExist/좌표 이동은 네트워크 엔티티 레지스트리 차원의
--- 값이라 서버 쪽에서는 "성공"으로 보이는 것과도 일치한다. 리소스 시작 시점에 미리
--- RequestModel로 요청해둬 실제 스폰 시점(빨라도 PREP 종료 이후)까지 충분한 시간을
--- 두고 클라이언트가 캐싱을 끝내도록 한다.
CreateThread(function()
    local npcModels = { 'a_m_y_business_01', 'a_m_y_business_02', 's_m_y_cop_01' }
    for _, name in ipairs(npcModels) do
        RequestModel(GetHashKey(name))
    end
end)

local adminGenuineBlip = nil
local tracePingBlips = {} -- [targetPlayerId] = blip handle

-- [bagId] = netId, 월드에 드롭된 SecretBag 프롭 (server/inventory.lua Inv.SpawnWorldBag 동기화).
local worldBags = {}
-- [bagId] = true, 현재 이 클라이언트가 소지 중인 SecretBag (UI/드롭 선택용, server/bag.lua가 push).
local heldBagIds = {}
-- [noteId] = netId, 월드에 드롭된 NoteItem 프롭.
local worldNotes = {}
-- [noteId] = hintText, 현재 이 클라이언트가 소지 중인 NoteItem.
local heldNotes = {}
local circleBlips = {} -- [label] = blip handle ('circle1500' | 'circle100')
local liveRevealBlip = nil
local npcBlips = {} -- [npcId] = blip handle (싸구려/진짜 감정사 등)
local npcCoords = {} -- [npcId] = vector3, secretbag:npcBlipAdd가 채움(근접 상호작용 프롬프트용)

-- 인벤토리/전화 두 창이 동시에 뜨면 NUI 포커스가 꼬이므로 한쪽을 열면 다른 쪽을 닫는다.
-- closePhone은 전화 관련 코드 블록에서 정의되므로, 그보다 먼저 나오는 openInventory가
-- 참조할 수 있도록 미리 로컬만 선언해둔다(Lua 상호 참조 시 흔한 전방 선언 패턴).
local phoneOpen = false
local closePhone

--- 사용자 요청: 사망 후 부활 대기(60초) 동안 가방/NPC 상호작용과 인벤토리 사용을 막는다.
--- 실제 값은 death-detection 스레드(파일 아래쪽)에서 설정하지만, openInventory/E키
--- 상호작용 루프가 이 변수보다 먼저 코드상에 나오므로 위 phoneOpen과 동일한 이유로
--- 미리 선언해둔다.
local awaitingRespawn = false

-- ============================================================
-- 인벤토리 창 (사용자 요청: "가방 및 쪽지 목록을 보고 상호작용할 수 있는 인벤토리 창").
-- 이 모드는 프레임워크가 없어 표준 인벤토리 UI가 아예 없었다(config.lua 참고) — heldBagIds/
-- heldNotes는 이미 위에서 서버 이벤트로 실시간 추적되고 있으므로, 그 데이터를 NUI로 그대로
-- 보여주고 버튼 클릭을 기존 서버 커맨드/이벤트로 그대로 위임하기만 하면 된다(새 서버 로직 불필요).
-- ============================================================
local inventoryOpen = false

local function syncInventoryUI()
    local bags = {}
    for bagId in pairs(heldBagIds) do
        table.insert(bags, { bagId = bagId })
    end
    local notes = {}
    for noteId, text in pairs(heldNotes) do
        table.insert(notes, { noteId = noteId, text = text })
    end
    SendNUIMessage({ type = 'invSync', bags = bags, notes = notes })
end

local function closeInventory()
    if not inventoryOpen then return end
    inventoryOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'invHide' })
end

local function openInventory()
    if inventoryOpen then return end
    -- 사용자 요청: 사망 후 부활 대기 중에는 인벤토리 사용 불가.
    if awaitingRespawn then return end
    if phoneOpen and closePhone then closePhone() end
    inventoryOpen = true
    syncInventoryUI()
    SendNUIMessage({ type = 'invShow' })
    SetNuiFocus(true, true)
end

RegisterCommand('sbinventory', function()
    if inventoryOpen then closeInventory() else openInventory() end
end, false)
RegisterKeyMapping('sbinventory', '인벤토리 열기/닫기', 'keyboard', 'I')

--- 인벤토리/전화 창이 떠 있는 동안 이동/공격 입력을 막아 실수로 캐릭터가 움직이거나
--- 총을 쏘지 않게 한다. SetNuiFocus(true,true)만으로는 WASD 이동이 막히지 않는다.
CreateThread(function()
    while true do
        if inventoryOpen or phoneOpen then
            DisableControlAction(0, 30, true) -- INPUT_MOVE_LEFT_RIGHT
            DisableControlAction(0, 31, true) -- INPUT_MOVE_UP_DOWN
            DisableControlAction(0, 21, true) -- INPUT_SPRINT
            DisableControlAction(0, 22, true) -- INPUT_JUMP
            DisableControlAction(0, 24, true) -- INPUT_ATTACK
            DisableControlAction(0, 25, true) -- INPUT_AIM
            DisableControlAction(0, 257, true) -- INPUT_ATTACK2
            DisableControlAction(0, 263, true) -- INPUT_MELEE_ATTACK_LIGHT
            Wait(0)
        else
            Wait(200)
        end
    end
end)

RegisterNUICallback('invClose', function(_, cb)
    closeInventory()
    cb('ok')
end)

RegisterNUICallback('invDropBag', function(data, cb)
    if data and data.bagId then
        TriggerServerEvent('secretbag:tryDropBag', data.bagId)
    end
    cb('ok')
end)

--- dropnote/givenote는 서버 RegisterCommand(콘솔·채팅 명령)라 클라에서 별도 이벤트로
--- 감싸지 않고, 기존 코드처럼 ExecuteCommand로 그대로 위임한다(FiveM은 로컬에 없는
--- 명령을 자동으로 서버에 넘겨 해당 클라이언트를 source로 실행한다).
RegisterNUICallback('invDropNote', function(data, cb)
    if data and data.noteId then
        ExecuteCommand('dropnote ' .. data.noteId)
    end
    cb('ok')
end)

RegisterNUICallback('invGiveNote', function(data, cb)
    if data and data.noteId and data.targetId then
        ExecuteCommand('givenote ' .. data.noteId .. ' ' .. tostring(data.targetId))
    end
    cb('ok')
end)

-- ============================================================
-- 전화 시스템 (사용자 요청: "현재 접속한 플레이어와 서버장끼리 1대1로 전화할 수 있다").
-- 역할과 무관하게 현재 접속 중인 아무나와 통화할 수 있다. 음성은 MUMBLE_SET_VOICE_CHANNEL
-- (문자 그대로 "내 클라이언트의 음성 채널을 설정" — 서버 대응 버전이 있을 수 없는 순수
-- 클라이언트 기능)로 거리와 무관하게 통화 상대의 목소리만 들리게 한다(채널 0 = 평소 근접
-- 음성으로 복귀). 서버 로직은 server/phone.lua 참고.
-- ============================================================
local phoneCallState = 'idle' -- 'idle' | 'roster' | 'ringing' | 'incoming' | 'connected'

local function setPhoneNui(msgType, extra)
    local payload = extra or {}
    payload.type = msgType
    SendNUIMessage(payload)
end

closePhone = function()
    if not phoneOpen then return end
    -- 통화 중/수신 중/발신 중에는 화면의 버튼으로만 끝내게 한다 — M키로 실수로 닫으면
    -- 통화 상태(및 음성 채널)를 놓치기 쉽다.
    if phoneCallState ~= 'roster' and phoneCallState ~= 'idle' then return end
    phoneOpen = false
    SetNuiFocus(false, false)
    setPhoneNui('phoneHide')
end

local function openPhoneRoster()
    if phoneOpen then return end
    if inventoryOpen then closeInventory() end
    phoneOpen = true
    phoneCallState = 'roster'
    setPhoneNui('phoneShow')
    SetNuiFocus(true, true)
    TriggerServerEvent('secretbag:phoneRequestRoster')
end

RegisterCommand('sbphone', function()
    if phoneOpen then closePhone() else openPhoneRoster() end
end, false)
RegisterKeyMapping('sbphone', '전화기 열기/닫기', 'keyboard', 'M')

RegisterNUICallback('phoneClose', function(_, cb)
    closePhone()
    cb('ok')
end)

RegisterNUICallback('phoneCall', function(data, cb)
    if data and data.targetId then
        TriggerServerEvent('secretbag:phoneCall', tonumber(data.targetId))
    end
    cb('ok')
end)

RegisterNUICallback('phoneAccept', function(_, cb)
    TriggerServerEvent('secretbag:phoneAccept')
    cb('ok')
end)

--- 통화 종료·수신 거절·발신 취소를 화면에서는 버튼 하나로 통일한다 — 서버가 현재
--- 상태(통화 중/수신 대기/발신 대기)를 보고 알맞게 정리한다(server/phone.lua 참고).
RegisterNUICallback('phoneHangup', function(_, cb)
    TriggerServerEvent('secretbag:phoneHangup')
    cb('ok')
end)

RegisterNetEvent('secretbag:phoneRoster', function(roster)
    setPhoneNui('phoneRoster', { roster = roster })
end)

--- 수신 전화는 전화기 UI를 열어두지 않았어도 강제로 화면에 띄운다 — 실제 전화처럼
--- "받을지 말지"를 그 자리에서 바로 선택하게 하기 위함.
RegisterNetEvent('secretbag:phoneIncoming', function(callerId, callerName)
    if inventoryOpen then closeInventory() end
    phoneOpen = true
    phoneCallState = 'incoming'
    setPhoneNui('phoneShow')
    setPhoneNui('phoneIncoming', { callerName = callerName or ('#' .. tostring(callerId)) })
    SetNuiFocus(true, true)
end)

RegisterNetEvent('secretbag:phoneRinging', function(targetId, targetName)
    phoneCallState = 'ringing'
    setPhoneNui('phoneRinging', { targetName = targetName or ('#' .. tostring(targetId)) })
end)

RegisterNetEvent('secretbag:phoneConnected', function(partnerId, partnerName, channel)
    phoneCallState = 'connected'
    MumbleSetVoiceChannel(channel)
    setPhoneNui('phoneConnected', { partnerName = partnerName or ('#' .. tostring(partnerId)) })
end)

local phoneEndReasonLabels = {
    declined = '상대방이 거절했습니다.',
    cancelled = '발신을 취소했습니다.',
    no_answer = '응답이 없습니다.',
    busy = '상대방이 통화 중입니다.',
    self_busy = '이미 통화 중이거나 전화가 오고 있습니다.',
    offline = '상대방이 접속 중이 아닙니다.',
    hangup = '통화가 종료되었습니다.',
    disconnected = '상대방의 연결이 끊어졌습니다.',
}

RegisterNetEvent('secretbag:phoneEnded', function(reason)
    MumbleSetVoiceChannel(0)
    local message = phoneEndReasonLabels[reason] or '통화가 종료되었습니다.'

    if phoneOpen then
        phoneCallState = 'roster'
        setPhoneNui('phoneRoster', { message = message })
        TriggerServerEvent('secretbag:phoneRequestRoster')
    else
        phoneCallState = 'idle'
    end
end)

--- REQ-RECON-001: 최초 스폰/리스폰마다 서버에 알려 Trace 재접속 즉시 ping을 트리거한다.
--- (참가자가 아니면 서버가 조용히 무시하므로 매번 보내도 안전하다.)
AddEventHandler('playerSpawned', function()
    TriggerServerEvent('secretbag:clientReady')
end)

--- 최초 접속 스폰 지점 강제 (사용자 요청: "모든 플레이어가 처음으로 서버에 입장해 스폰될
--- 때 [x,y]에서 스폰 가능한 가장 가까운 위치에서 스폰"). 기본 spawnmanager/basic-gamemode
--- 랜덤 스폰이 이미 한 번 캐릭터를 띄운 뒤, 이 세션에서 처음 받는 playerSpawned에서만
--- (hasAppliedInitialSpawn 플래그) 곧바로 목표 좌표로 재배치한다 — death.lua의
--- secretbag:respawnAt과 동일한 NetworkResurrectLocalPlayer 방식이라 사망/부활 로직과
--- 완전히 별개로 안전하게 동작한다. GetGroundZFor_3dCoord는 ped 없이도 동작하는 순수
--- 월드 쿼리라(police.lua 앰비언트 스폰 요청과 동일 기법) 최초 스폰 시점에도 쓸 수 있다.
local hasAppliedInitialSpawn = false
AddEventHandler('playerSpawned', function()
    if hasAppliedInitialSpawn then return end
    hasAppliedInitialSpawn = true
    local target = Config.InitialSpawnCoord
    if not target then return end
    CreateThread(function()
        -- 스폰 직후엔 기본 스폰 지점(멀리 떨어진 랜덤 위치) 주변 콜리전만 로드돼 있어,
        -- 목표 좌표의 GetGroundZFor_3dCoord가 지금 당장은 부정확하거나 실패할 수 있다.
        -- 일단 이 추정치로 먼저 이동시킨 뒤, 실제로 그 자리에 도착해 콜리전이 스트리밍될
        -- 시간을 주고 나서(월드 가방/쪽지/NPC와 동일한 PlaceObjectOnGroundProperly로) 한 번
        -- 더 보정한다 — 이 네이티브는 ped/object 구분 없이 엔티티 일반에 대해 동작한다.
        local found, groundZ = GetGroundZFor_3dCoord(target.x, target.y, target.z + 100.0, false)
        local z = found and groundZ or target.z
        local ped = PlayerPedId()
        NetworkResurrectLocalPlayer(target.x, target.y, z, GetEntityHeading(ped), true, false)
        Wait(1500)
        PlaceObjectOnGroundProperly(PlayerPedId())
    end)
end)

--- 전체 공지 (사용자 요청): server/announce.lua의 /announce를 화면 중앙 살짝 아래에
--- GTA5 기본 폰트로 크게(주황색) 표시한다. 채팅이 아니라 순수 게임 네이티브 텍스트
--- 렌더링이라 html/index.html의 HUD와 달리 정말 GTA5 자체 폰트가 그대로 나온다.
--- 새 공지가 도착하면 진행 중이던 이전 공지의 while 조건이 그 즉시 false가 되어
--- 이전 표시 스레드가 자연히 종료되고 새 공지로 교체된다(별도 취소 처리 불필요).
local currentAnnounceText = nil

RegisterNetEvent('secretbag:announce', function(text)
    currentAnnounceText = text
    local cfg = Config.Announcement
    local expireAt = GetGameTimer() + cfg.durationMs
    CreateThread(function()
        while currentAnnounceText == text and GetGameTimer() < expireAt do
            SetTextFont(cfg.font)
            SetTextScale(0.0, cfg.scale)
            SetTextColour(cfg.color.r, cfg.color.g, cfg.color.b, 255)
            SetTextCentre(true)
            SetTextEdge(2, 0, 0, 0, 200)
            BeginTextCommandDisplayText('STRING')
            AddTextComponentString(text)
            EndTextCommandDisplayText(0.5, cfg.screenY)
            Wait(0)
        end
        if currentAnnounceText == text then
            currentAnnounceText = nil
        end
    end)
end)

--- 사용자 요청: 경찰 커스텀 이벤트는 끄고 GTA5 기본 인구/수배 시스템을 쓴다(수배 별 자체는
--- server/wanted.lua가 서버사이드 RPC 네이티브로 직접 처리 — 클라 왕복 불필요).
---
--- SetPedPopulationBudget(3)을 매초 강제 적용하던 코드를 진단 목적으로 비활성화한다 —
--- "감정사 NPC뿐 아니라 경찰(/sbforceambientpolice)까지, 스폰 방식/모델과 무관하게
--- 모든 script 생성 ped가 아예 안 보인다"는 증상이 확인되어, ped 인구 메모리 budget을
--- 계속 최대치로 강제하는 이 코드가 OneSync로 동기화되는 script ped와 충돌해 렌더링을
--- 막고 있을 가능성이 가장 유력한 용의자로 좁혀졌다(가방 같은 오브젝트는 이 설정의
--- 영향을 받지 않아 정상적으로 보였던 것과도 일치). GTA5는 이 호출이 없어도 기본값으로
--- 앰비언트 인구가 어느 정도 자연스럽게 채워지므로, 우선 꺼서 NPC가 다시 보이는지부터
--- 검증한다 — 만약 이게 원인이 맞다면, 인구밀도를 최대치가 아닌 더 낮은 값으로 절충하거나
--- 다른 방식을 찾아야 한다.
-- CreateThread(function()
--     while true do
--         SetPedPopulationBudget(3)
--         SetVehiclePopulationBudget(3)
--         Wait(1000)
--     end
-- end)

--- 사용자 확정 규칙(2026): "GTA5 기본 체포 시스템을 완전히 끄고, 수배 중인 플레이어에 대한
--- 경찰의 기본 대응은 항상 사살". 앰비언트(수배 반응) 경찰은 서버가 만든 엔티티가 아니라
--- 각 클라이언트가 로컬로 시뮬레이션하는 population 개체라(OneSync에 등록되지 않음) 서버는
--- 이들을 볼 수도 조작할 수도 없다 — 각자 자기 화면의 경찰을 자기 클라이언트가 직접
--- 제어해야 한다. "체포를 막는 단일 전역 스위치" 네이티브는 없어서(docs.fivem.net에서
--- ARREST 관련 native를 확인했으나 그런 것이 없음을 확인했다), police.lua가 이미 커스텀
--- 경찰 추격에 쓰는 것과 동일한 TaskCombatPed로 매초 강제 교전시켜 체포 접근(TASK_ARREST_PED)
--- 자체가 끝까지 진행되지 못하게 한다 — 체포 애니메이션이 완료되려면 몇 초가 걸리므로 1초
--- 주기로도 충분히 막을 수 있다. GetGamePool('CPed')는 API set이 shared라 클라에서 부르면
--- 이 클라이언트가 로컬로 알고 있는 모든 ped(앰비언트 포함)를 돌려준다.
CreateThread(function()
    while true do
        Wait(1000)
        if GetPlayerWantedLevel(PlayerId()) > 0 then
            local myPed = PlayerPedId()
            local myCoords = GetEntityCoords(myPed)
            for _, ped in ipairs(GetGamePool('CPed')) do
                if DoesEntityExist(ped) and not IsPedAPlayer(ped) and GetPedType(ped) == 6 then
                    if #(myCoords - GetEntityCoords(ped)) <= 60.0 then
                        TaskCombatPed(ped, myPed, 0, 16)
                    end
                end
            end
        end
    end
end)

--- 서버가 NPC/월드 오브젝트를 만든 뒤 "이 엔티티에 이런 로컬 설정을 걸어달라"고 위임하는
--- 범용 이벤트. SetEntityInvincible/SetBlockingOfNonTemporaryEvents/SetPedAccuracy/
--- TaskWanderStandard/PlaceObjectOnGroundProperly는 전부 FiveM API set이 "client" 전용이라
--- (docs.fivem.net 확인) 서버 Lua에서는 그 전역 함수 자체가 존재하지 않는다 — 서버에서
--- 직접 호출하면 매번 "attempt to call a nil value"로 즉시 죽는다. CreatePed/CreateObject
--- 자체는 서버에서 호출 가능하지만(API set: server인 CFX 네임스페이스 버전이 따로 있음),
--- 그 뒤에 거는 "행동/외형" 설정은 이렇게 클라이언트에 위임해야 한다.
--- 새로 생성된 네트워크 엔티티는 클라이언트에 동기화되기까지 몇 tick 걸릴 수 있어 재시도한다.
--- NetworkGetEntityFromNetworkId를 아직 존재하지 않는 netId로 바로 호출하면 콘솔에
--- "GetNetworkObject: no object by ID N" 경고가 매번 찍혀 스팸이 된다 — NetworkDoesEntityExist
--- WithNetworkId로 먼저 조용히 존재 여부를 확인한 뒤에만 실제 resolve를 호출한다.
RegisterNetEvent('secretbag:setupNpc', function(netId, opts)
    CreateThread(function()
        -- 사용자 보고("최종 감정사 무적 적용 안 됨") 이후 대응: 예전엔 100ms 간격으로
        -- 폴링해서 무적 적용까지 최대 수백 ms의 창이 있었다 — 그 사이 도착해서 공격하면
        -- 무적이 아직 안 걸린 상태일 수 있었다. Wait(0)(매 틱)로 훨씬 촘촘하게 폴링해
        -- 그 창을 최대한 줄인다.
        local attempts = 0
        while not NetworkDoesEntityExistWithNetworkId(netId) and attempts < 300 do
            Wait(0)
            attempts = attempts + 1
        end
        if not NetworkDoesEntityExistWithNetworkId(netId) then return end
        local entity = NetworkGetEntityFromNetworkId(netId)
        if not entity or entity == 0 or not DoesEntityExist(entity) then return end

        if opts.invincible then
            SetEntityInvincible(entity, true)
            -- 사용자 보고: "NPC가 무적이 아닌 것 같다" — SetEntityInvincible 하나만으로는
            -- 체력 소모는 막아도 피격 반응/넉백/특정 피해 유형(폭발 등)까지 완전히 막지
            -- 못하는 경우가 있다. SetEntityProofs(전부 true)를 추가해 총알/화염/폭발/충돌/
            -- 근접/증기/익사 피해까지 전부 무시하도록 강화한다(docs.fivem.net 확인, client 전용).
            SetEntityProofs(entity, true, true, true, true, true, true, true, true)
        end
        if opts.blockEvents then
            SetBlockingOfNonTemporaryEvents(entity, true)
        end
        if opts.accuracy then
            SetPedAccuracy(entity, opts.accuracy)
        end
        if opts.wander then
            TaskWanderStandard(entity, 10.0, 10)
        end
        if opts.groundSnap then
            PlaceObjectOnGroundProperly(entity)
        end
        if opts.health ~= nil then
            SetEntityHealth(entity, opts.health)
        end
    end)
end)

--- 싸구려/진짜 감정사 지도 표시 (사용자 요청 — 원래는 마커 없이 직접 찾는 설계였으나 예외로 추가).
--- npcId를 key로 둬서 같은 NPC가 재스폰되면 이전 블립을 덮어쓰고, 디스폰되면 지운다.
RegisterNetEvent('secretbag:npcBlipAdd', function(npcId, coords, label, sprite, colour)
    if npcBlips[npcId] then
        RemoveBlip(npcBlips[npcId])
    end
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, sprite or 1)
    SetBlipColour(blip, colour or 1)
    SetBlipScale(blip, 0.9)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label or 'NPC')
    EndTextCommandSetBlipName(blip)
    npcBlips[npcId] = blip
    npcCoords[npcId] = coords
end)

RegisterNetEvent('secretbag:npcBlipRemove', function(npcId)
    if npcBlips[npcId] then
        RemoveBlip(npcBlips[npcId])
        npcBlips[npcId] = nil
    end
    npcCoords[npcId] = nil
end)

--- 경찰 앰비언트 스폰 좌표 요청 (server/police.lua). 서버는 콜리전/지형 데이터가 없어
--- 안전한 지면 z를 모르므로, 요청받은 클라이언트가 자기 위치 기준 랜덤 방향·거리로 후보
--- 좌표를 잡고 GetGroundZFor_3dCoord로 실제 지면 높이를 찾아 보고한다. 다른 NPC들처럼
--- z를 추정해둘 필요가 아예 없어지는 방식이다.
RegisterNetEvent('secretbag:requestAmbientSpawnPoint', function(requestId, minDist, maxDist)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local angle = math.random() * 2 * math.pi
    local dist = minDist + math.random() * (maxDist - minDist)
    local x = coords.x + math.cos(angle) * dist
    local y = coords.y + math.sin(angle) * dist

    local found, groundZ = GetGroundZFor_3dCoord(x, y, coords.z + 100.0, false)
    local z = found and groundZ or coords.z
    local heading = math.random(0, 359)

    TriggerServerEvent('secretbag:ambientSpawnPointResult', requestId, x, y, z, heading)
end)

--- server/util.lua의 U.ResolveGroundZ 전용: 임의 좌표(요청받은 클라이언트가 근처에 있어본
--- 적이 없을 수도 있음)의 실제 지면 높이를 구한다.
---
--- 1차 시도(RequestCollisionAtCoord만 반복 호출)가 원거리 좌표에서는 콜리전 스트리밍이
--- 충분히 우선순위를 받지 못해 1초 예산 안에 끝나지 않는 경우가 있는 것으로 보인다 —
--- RequestCollisionAtCoord는 "요청"만 걸어둘 뿐, 실제 스트리밍 시스템은 여전히 카메라와의
--- 거리를 기준으로 우선순위를 매기기 때문. SetFocusPosAndVel(API set: client, docs.fivem.net
--- 확인 — "카메라가 지형을 렌더링할 영역을 강제로 지정", 원격 좌표 조회/텔레포트 계열
--- 스크립트의 표준 기법)로 스트리밍 초점 자체를 그 좌표로 옮겨 강제로 우선순위를 높이고,
--- 예산도 1초 -> 5초로 늘렸다. 로스산토스에서 가장 높은 지형(치리아드 산 정상 약 870m)보다도
--- 훨씬 높은 1000.0에서 아래로 내려가며 GetGroundZFor_3dCoord를 반복 시도한다. NPC/월드
--- 드롭 가방이 고정 추정 높이(NPC_Z_DEFAULT)와 실제 지형이 안 맞아 파묻히거나 공중에 떠서
--- "스폰이 안 되는 것처럼" 보이던 문제의 근본 수정.
RegisterNetEvent('secretbag:requestGroundZ', function(requestId, x, y)
    CreateThread(function()
        SetFocusPosAndVel(x, y, 1000.0, 0.0, 0.0, 0.0)
        local found, z = false, 1000.0
        for i = 1, 100 do
            RequestCollisionAtCoord(x, y, 1000.0)
            Wait(50)
            -- includeWater=true: 실측 결과 위조업자 후보(운하/부두 인근) 다수가 계속
            -- found=false로 실패했다 — docs.fivem.net 확인 결과 이 native는 물 위/아래
            -- 좌표에서 includeWater=false면 수면을 지면으로 치지 않아 실제 바닥까지
            -- 못 찾을 수 있다고 명시돼 있다. 수면 근처 지점은 수면을 지면으로 봐도
            -- NPC가 부두/물가에 서 있는 것처럼 보여 자연스럽다.
            found, z = GetGroundZFor_3dCoord(x, y, 1000.0, true)
            if found then break end
        end
        ClearFocus()
        if not found then
            print(('[SecretBag] 경고: (%.1f, %.1f) 지면 높이 조회 실패 — 콜리전 스트리밍이 5초 안에 끝나지 않음(기본 추정치로 대체됨)'):format(x, y))
        end
        TriggerServerEvent('secretbag:groundZResult', requestId, found, z)
    end)
end)

--- server/debug.lua의 /sbmeasureallgroundz 전용: RequestCollisionAtCoord로 원격 강제
--- 스트리밍하는 방식(위 requestGroundZ)이 실제 스폰 후보 좌표 다수에서 5초 예산 안에도
--- 실패하는 것으로 확인됨 — 캐릭터를 실제로 그 좌표로 순간이동시켜(카메라가 진짜 거기
--- 있으면 스트리밍이 훨씬 빠르고 확실하다) 지면 높이를 실측한다. 낙사 방지로 무적 처리.
RegisterNetEvent('secretbag:measureGroundZ', function(requestId, x, y)
    CreateThread(function()
        local ped = PlayerPedId()
        SetEntityInvincible(ped, true)
        SetEntityCoordsNoOffset(ped, x, y, 500.0, false, false, false)
        -- 2.5초로는 12곳 중 7곳이 실패했다(직접 순간이동해도 콜리전 스트리밍이 그만큼
        -- 오래 걸리는 곳이 있다는 뜻) — 여유 있게 8초로 늘리고, 그 사이에도 계속
        -- RequestCollisionAtCoord를 걸어 스트리밍을 최대한 재촉한다.
        local found, z = false, 0.0
        for i = 1, 16 do
            RequestCollisionAtCoord(x, y, 1000.0)
            Wait(500)
            found, z = GetGroundZFor_3dCoord(x, y, 1000.0, true) -- includeWater=true, 위와 동일한 이유
            if found then break end
        end
        SetEntityInvincible(ped, false)
        TriggerServerEvent('secretbag:measureGroundZResult', requestId, found, z)
    end)
end)

--- server/debug.lua의 /sbmeasureremaining 전용: 위조업자 후보 등 8초로도 계속 실패하는
--- 좌표(대부분 해안/개활수면 인근으로 추정 — 지형 스트리밍이 유난히 오래 걸리는 듯)를
--- 위해 훨씬 넉넉한 예산(약 25초)으로 재시도한다.
RegisterNetEvent('secretbag:measureGroundZLong', function(requestId, x, y)
    CreateThread(function()
        local ped = PlayerPedId()
        SetEntityInvincible(ped, true)
        SetEntityCoordsNoOffset(ped, x, y, 500.0, false, false, false)
        local found, z = false, 0.0
        for i = 1, 50 do
            RequestCollisionAtCoord(x, y, 1000.0)
            Wait(500)
            found, z = GetGroundZFor_3dCoord(x, y, 1000.0, true)
            if found then break end
        end
        SetEntityInvincible(ped, false)
        TriggerServerEvent('secretbag:measureGroundZResult', requestId, found, z)
    end)
end)

--- server/admintools.lua의 /gotoplayer 전용: 관리자가 이 클라이언트(=대상 유저) 근처
--- 3m 이내로 이동해도 되는지, police.lua의 앰비언트 스폰 요청과 동일한 기법(자기 위치
--- 기준 랜덤 오프셋 + GetGroundZFor_3dCoord로 실제 지면 높이 확인)으로 계산해 보고한다.
RegisterNetEvent('secretbag:requestSafeCoordNear', function(requestId)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local angle = math.random() * 2 * math.pi
    local dist = math.random() * 3.0
    local x = coords.x + math.cos(angle) * dist
    local y = coords.y + math.sin(angle) * dist

    local found, groundZ = GetGroundZFor_3dCoord(x, y, coords.z + 50.0, false)
    local z = found and groundZ or coords.z

    TriggerServerEvent('secretbag:safeCoordNearResult', requestId, x, y, z)
end)

--- REQ-DEATH-001: 자신의 사망을 감지해 서버에 보고한다(좌표 + 킬러 서버ID).
--- FiveM에 서버 권위형 킬러 감지 표준 API가 없어 안정적인 네이티브로 클라 탐지 후 보고한다
--- (server/death.lua 헤더 주석에 신뢰 경계 설명).
--- 사용자 지적: 사망 직후 기본 spawnmanager가 즉시 자동 부활시켜버려서, server/death.lua의
--- 60초 대기(Config.Death.respawnDelayMs) 동안 플레이어가 자유롭게 돌아다닐 수 있었다 —
--- 원래 의도는 60초간 대기하다 죽은 위치(또는 최종구역 안전좌표)로 옮겨지는 것이므로,
--- 그 사이엔 조작이 불가능해야 한다. isDead가 된 시점부터 secretbag:respawnAt이 실제로
--- 도착할 때까지 매 프레임 이동/공격 관련 컨트롤을 막고 위치를 고정한다(기본
--- spawnmanager가 새 ped로 부활시켜도 PlayerPedId()를 매 프레임 다시 읽어오므로 안전).
--- (awaitingRespawn 변수 자체는 파일 위쪽에 미리 선언돼 있다 — openInventory/E키 상호작용
--- 루프가 이 지점보다 먼저 나와 참조해야 하기 때문.)
local wasDead = false
CreateThread(function()
    while true do
        Wait(500)
        local ped = PlayerPedId()
        local isDead = IsEntityDead(ped)
        if isDead and not wasDead then
            wasDead = true
            awaitingRespawn = true
            local coords = GetEntityCoords(ped)
            local killerServerId = nil
            local killerPed = GetPedSourceOfDeath(ped)
            if killerPed and killerPed ~= 0 and killerPed ~= ped and IsPedAPlayer(killerPed) then
                local killerPlayerIndex = NetworkGetPlayerIndexFromPed(killerPed)
                if killerPlayerIndex then
                    killerServerId = tonumber(GetPlayerServerId(killerPlayerIndex))
                end
            end
            TriggerServerEvent('secretbag:reportDeath', coords, killerServerId)
        elseif not isDead then
            wasDead = false
        end
    end
end)

CreateThread(function()
    while true do
        Wait(0)
        if awaitingRespawn then
            local ped = PlayerPedId()
            FreezeEntityPosition(ped, true)
            DisableControlAction(0, 30, true) -- MoveLeftRight
            DisableControlAction(0, 31, true) -- MoveUpDown
            DisableControlAction(0, 24, true) -- Attack
            DisableControlAction(0, 25, true) -- Aim
            DisableControlAction(0, 22, true) -- Jump
            DisableControlAction(0, 23, true) -- Enter/exit vehicle
            DisableControlAction(0, 75, true) -- Exit vehicle
        end
    end
end)

RegisterNetEvent('secretbag:respawnAt', function(coords)
    awaitingRespawn = false
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)
end)

RegisterNetEvent('secretbag:tracePing', function(targetPlayerId, name, coords)
    if tracePingBlips[targetPlayerId] then
        RemoveBlip(tracePingBlips[targetPlayerId])
    end
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, 3)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(('Trace: %s'):format(name or '?'))
    EndTextCommandSetBlipName(blip)
    tracePingBlips[targetPlayerId] = blip
    TriggerEvent('chat:addMessage', { args = { '[Trace]', ('%s 위치가 포착되었습니다.'):format(name or '?') } })
end)

--- 기획서 8장: FinalZone lock 즉시 기존 Trace ping 제거.
RegisterNetEvent('secretbag:traceClearAll', function()
    for _, blip in pairs(tracePingBlips) do
        RemoveBlip(blip)
    end
    tracePingBlips = {}
end)

--- 기획서 9장 경찰 상태 UI 라벨.
local policeRelationLabels = {
    NEUTRAL = '경찰 정보 획득 가능',
    ALERT_TO_HOSTILE = '곧 경찰 적대',
    HOSTILE = '경찰 적대 중',
    ALERT_TO_NEUTRAL = '경찰 적대 해제됨',
    ALERT_SHUTDOWN = '경찰 경계 중',
    DISABLED = nil, -- 표시 없음
}

RegisterNetEvent('secretbag:policeRelationChanged', function(newRelation)
    local label = policeRelationLabels[newRelation]
    if label then
        TriggerEvent('chat:addMessage', { args = { '[경찰]', label } })
    end
    -- 사용자 요청: HUD 시계 아래 안내문(#status)은 이제 진짜 감정사 상태 전용이라
    -- (secretbag:timelineSync/trueApprCooldown 참고) 여기서는 더 이상 건드리지 않는다.
end)

local policeInfoPingBlips = {} -- [playerId] = blip handle

RegisterNetEvent('secretbag:policeInfoPing', function(playerId, name, coords)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 161)
    SetBlipColour(blip, 1)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('정보 강탈')
    EndTextCommandSetBlipName(blip)
    policeInfoPingBlips[playerId] = blip
    TriggerEvent('chat:addMessage', { args = { '[경찰]', '누군가 경찰에게서 정보를 강탈했습니다.' } })
end)

RegisterNetEvent('secretbag:policeInfoPingExpire', function(playerId)
    if policeInfoPingBlips[playerId] then
        RemoveBlip(policeInfoPingBlips[playerId])
        policeInfoPingBlips[playerId] = nil
    end
end)

RegisterNetEvent('secretbag:worldBagSpawned', function(bagId, netId)
    worldBags[bagId] = netId
end)

RegisterNetEvent('secretbag:worldBagRemoved', function(bagId)
    worldBags[bagId] = nil
end)

RegisterNetEvent('secretbag:resetInventoryState', function()
    worldBags = {}
    heldBagIds = {}
    worldNotes = {}
    heldNotes = {}
    for _, blip in pairs(tracePingBlips) do
        RemoveBlip(blip)
    end
    tracePingBlips = {}
    for _, blip in pairs(policeInfoPingBlips) do
        RemoveBlip(blip)
    end
    policeInfoPingBlips = {}
    for _, blip in pairs(circleBlips) do
        RemoveBlip(blip)
    end
    circleBlips = {}
    if liveRevealBlip then
        RemoveBlip(liveRevealBlip)
        liveRevealBlip = nil
    end
    for _, blip in pairs(npcBlips) do
        RemoveBlip(blip)
    end
    npcBlips = {}
    npcCoords = {}
    closeInventory()
end)

RegisterNetEvent('secretbag:heldBagAdded', function(bagId)
    heldBagIds[bagId] = true
    if inventoryOpen then syncInventoryUI() end
end)

RegisterNetEvent('secretbag:heldBagRemoved', function(bagId)
    heldBagIds[bagId] = nil
    if inventoryOpen then syncInventoryUI() end
end)

RegisterNetEvent('secretbag:worldNoteSpawned', function(noteId, netId)
    worldNotes[noteId] = netId
end)

RegisterNetEvent('secretbag:worldNoteRemoved', function(noteId)
    worldNotes[noteId] = nil
end)

RegisterNetEvent('secretbag:heldNoteAdded', function(noteId, hintText)
    heldNotes[noteId] = hintText
    TriggerEvent('chat:addMessage', { args = { '[쪽지]', hintText } })
    if inventoryOpen then syncInventoryUI() end
end)

RegisterNetEvent('secretbag:heldNoteRemoved', function(noteId)
    heldNotes[noteId] = nil
    if inventoryOpen then syncInventoryUI() end
end)

RegisterNetEvent('secretbag:noteText', function(hintText)
    TriggerEvent('chat:addMessage', { args = { '[쪽지]', hintText } })
end)

--- 가장 가까운 월드 SecretBag의 (bagId, 거리)를 반환. server/inventory.lua Inv.PickupDistance와
--- 동일한 3.0m 기준을 클라이언트 프롬프트에도 사용한다.
local function findNearestWorldBag()
    local playerCoords = GetEntityCoords(PlayerPedId())
    local nearestBagId, nearestDist = nil, 3.0
    for bagId, netId in pairs(worldBags) do
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity ~= 0 and DoesEntityExist(entity) then
            local dist = #(playerCoords - GetEntityCoords(entity))
            if dist < nearestDist then
                nearestBagId, nearestDist = bagId, dist
            end
        end
    end
    return nearestBagId, nearestDist
end

RegisterCommand('pickupbag', function()
    local bagId = findNearestWorldBag()
    if not bagId then
        TriggerEvent('chat:addMessage', { args = { '[SecretBag]', '근처에 주울 수 있는 가방이 없습니다.' } })
        return
    end
    TriggerServerEvent('secretbag:tryPickupBag', bagId)
end, false)

RegisterCommand('dropbag', function()
    local bagId = next(heldBagIds)
    if not bagId then
        TriggerEvent('chat:addMessage', { args = { '[SecretBag]', '소지 중인 가방이 없습니다.' } })
        return
    end
    TriggerServerEvent('secretbag:tryDropBag', bagId)
end, false)

--- 가장 가까운 월드 NoteItem을 줍는다. /readnote, /dropnote, /givenote는 noteId를 인자로 받는데,
--- 보통 소지 쪽지가 1개뿐이므로 인자 없이도 동작하도록 서버 커맨드가 처리하진 않는다 — 필요하면
--- /readnote <noteId> 형태로 직접 입력해야 한다(heldNotes는 채팅으로 이미 hintText가 표시되므로
--- noteId를 몰라도 정보 자체는 확인 가능하다).
local function findNearestWorldNote()
    local playerCoords = GetEntityCoords(PlayerPedId())
    local nearestNoteId, nearestDist = nil, 3.0
    for noteId, netId in pairs(worldNotes) do
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity ~= 0 and DoesEntityExist(entity) then
            local dist = #(playerCoords - GetEntityCoords(entity))
            if dist < nearestDist then
                nearestNoteId, nearestDist = noteId, dist
            end
        end
    end
    return nearestNoteId, nearestDist
end

RegisterCommand('pickupnote', function()
    local noteId = findNearestWorldNote()
    if not noteId then
        TriggerEvent('chat:addMessage', { args = { '[SecretBag]', '근처에 주울 수 있는 쪽지가 없습니다.' } })
        return
    end
    TriggerServerEvent('secretbag:tryPickupNote', noteId)
end, false)

-- ============================================================
-- 근접 자동 상호작용 (사용자 요청: "가방/쪽지/NPC 모두 명령어 없이 근처에서 상호작용").
-- /pickupbag /pickupnote /usecheap /usetrue /usefinaltrue /useforger 명령을 그대로
-- 유지한 채(호환성), E키(INPUT_PICKUP)로도 같은 서버 경로를 트리거하는 프롬프트를 추가한다.
-- 실제 거리/자격 검증은 여전히 서버 커맨드/이벤트가 전부 다시 하므로 새 검증 로직은 없다.
-- ============================================================
-- 사용자 확정 규칙(2026): 두 번째 진짜 감정사는 삭제됨.
local npcInteractCommand = {
    cheap_1 = 'usecheap', cheap_2 = 'usecheap',
    true1 = 'usetrue',
    finaltrue = 'usefinaltrue',
    forger = 'useforger',
}
local npcInteractLabel = {
    cheap_1 = '싸구려 감정사', cheap_2 = '싸구려 감정사',
    true1 = '진짜 감정사',
    finaltrue = '최종 감정사',
    forger = '위조업자',
}
-- 하드코딩된 숫자를 따로 두면 나중에 config.lua 값이 바뀔 때 여기만 누락되기 쉽다 —
-- config.lua는 shared_script라 클라에서도 그대로 참조할 수 있다.
local NPC_INTERACT_DIST = Config.Appraiser.interactDistance

local lastPromptText = nil
local function setInteractPrompt(text)
    if text == lastPromptText then return end
    lastPromptText = text
    SendNUIMessage({ type = text and 'promptShow' or 'promptHide', text = text })
end

-- currentInteractAction은 아래 두 스레드가 공유하는 업밸류다: 거리 스캔은 무거워서(월드
-- 가방/쪽지/모든 NPC 좌표 순회) 200ms마다만 돌리고, 키 입력 감지는 IsControlJustPressed가
-- "그 프레임에만" true인 엣지 트리거라 Wait(0)로 매 프레임 확인해야 한다 — 둘을 한
-- 루프에 합쳐 200ms마다만 체크하면 200ms 미만으로 짧게 탭한 E키는 그 사이 프레임을
-- 놓쳐 씹히는 경우가 실제로 생긴다.
local currentInteractAction = nil

CreateThread(function()
    while true do
        Wait(200)
        -- 사용자 요청: 사망 후 부활 대기 중에는 가방/쪽지/NPC 근접 상호작용(E키) 불가.
        if inventoryOpen or awaitingRespawn then
            setInteractPrompt(nil)
            currentInteractAction = nil
        else
            local coords = GetEntityCoords(PlayerPedId())
            local bestDist, bestLabel, bestAction = 999999.0, nil, nil

            local bagId, bagDist = findNearestWorldBag()
            if bagId and bagDist < bestDist then
                bestDist, bestLabel = bagDist, '가방 줍기'
                bestAction = function() TriggerServerEvent('secretbag:tryPickupBag', bagId) end
            end

            local noteId, noteDist = findNearestWorldNote()
            if noteId and noteDist < bestDist then
                bestDist, bestLabel = noteDist, '쪽지 줍기'
                bestAction = function() TriggerServerEvent('secretbag:tryPickupNote', noteId) end
            end

            for npcId, npcCoord in pairs(npcCoords) do
                local d = #(coords - npcCoord)
                local cmd = npcInteractCommand[npcId]
                if cmd and d <= NPC_INTERACT_DIST and d < bestDist then
                    bestDist, bestLabel = d, npcInteractLabel[npcId] .. ' 상호작용'
                    bestAction = function() ExecuteCommand(cmd) end
                end
            end

            setInteractPrompt(bestLabel and ('[E] ' .. bestLabel) or nil)
            currentInteractAction = bestAction
        end
    end
end)

CreateThread(function()
    while true do
        Wait(0)
        if currentInteractAction and not inventoryOpen and IsControlJustPressed(0, 38) then -- INPUT_PICKUP ("E")
            currentInteractAction()
        end
    end
end)

RegisterNetEvent('secretbag:setInvincible', function(invincible)
    local ped = PlayerPedId()
    SetEntityInvincible(ped, invincible)
    SetPlayerInvincible(PlayerId(), invincible)
end)

RegisterNetEvent('secretbag:notify', function(message)
    -- 서버 QBCore/ESX/standalone 알림 UI가 없어 채팅으로 대체 — 상단 HUD(시계/다음 이벤트)는
    -- secretbag:stateChanged/timelineSync로 별도 구현됨(html/index.html).
    TriggerEvent('chat:addMessage', { args = { '[SecretBag]', message } })
end)

--- 상단 HUD 표시 상태. RUNNING부터 FINISHING까지(게임 시계가 의미 있는 구간)만 보여주고,
--- PRE_GAME/PREP/ENDED에서는 숨긴다 — mainElapsed 자체가 RUNNING 진입 전엔 없는 개념이라
--- (server/state.lua MainElapsedMinutes) PREP 카운트다운까지 이 시계로 표시하지 않는다.
local hudVisibleStates = {
    RUNNING = true,
    FINAL_LOCKED_CONTEST = true,
    FINISHING = true,
}

RegisterNetEvent('secretbag:stateChanged', function(newState)
    SendNUIMessage({ type = hudVisibleStates[newState] and 'show' or 'hide' })
end)

--- server/hud.lua가 RUNNING 시작/재접속/기능 on-off 시점마다 보내는 스냅샷.
--- 초 단위 흐름은 html/index.html이 자체 타이머로 채우므로, 여기서는 그대로 전달만 한다.
RegisterNetEvent('secretbag:timelineSync', function(elapsedMs, events, trueApprSpawnAtMin)
    SendNUIMessage({ type = 'timelineSync', elapsedMs = elapsedMs, events = events, trueApprSpawnAtMin = trueApprSpawnAtMin })
end)

--- 진짜 감정사 개인 재이용 쿨다운 만료 시각(elapsedMs 기준, 없으면 nil) — HUD #status가
--- "X:XX에 진짜 감정사 재이용 가능"을 계산하는 데 쓴다(server/hud.lua/appraiser.lua 참고).
RegisterNetEvent('secretbag:trueApprCooldown', function(endElapsedMs)
    SendNUIMessage({ type = 'trueApprCooldown', endElapsedMs = endElapsedMs })
end)

--- 관리자 전용 표시 예시 (기획서 9장 "표시예시" 포맷).
RegisterNetEvent('secretbag:adminGenuineInfo', function(snapshot)
    local lines = {
        '[ 진짜가방 관리자정보 ]',
        ('상태: %s'):format(snapshot.state or '알수없음'),
        ('현재소유주: %s (ID: %s)'):format(snapshot.currentOwnerName or '현재 소유주 없음', tostring(snapshot.currentOwnerId or '-')),
        ('마지막 PLAYER 소유주: %s (ID: %s)'):format(snapshot.lastPlayerOwnerName or '없음', tostring(snapshot.lastPlayerOwnerId or '-')),
        ('Bag ID: %s'):format(snapshot.activeBagId or '-'),
        ('appearanceScore: %s'):format(tostring(snapshot.appearanceScore)),
        ('승자확정: %s'):format(snapshot.winnerLocked and '예' or '아니오'),
    }
    for _, line in ipairs(lines) do
        TriggerEvent('chat:addMessage', { args = { '[Admin]', line } })
    end
end)

RegisterNetEvent('secretbag:adminGenuinePing', function(coords)
    if adminGenuineBlip then
        RemoveBlip(adminGenuineBlip)
        adminGenuineBlip = nil
    end
    if not coords then
        TriggerEvent('chat:addMessage', { args = { '[Admin]', 'genuine 좌표를 확인할 수 없습니다.' } })
        return
    end
    adminGenuineBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(adminGenuineBlip, 8)
    SetBlipColour(adminGenuineBlip, 1)
    SetBlipScale(adminGenuineBlip, 1.0)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('Genuine (Admin)')
    EndTextCommandSetBlipName(adminGenuineBlip)
end)

--- 150/210분 위치원 (기획서 11장). 일반 공개 — 전원에게 표시된다.
RegisterNetEvent('secretbag:circleReveal', function(label, center, radius)
    if circleBlips[label] then
        RemoveBlip(circleBlips[label])
    end
    local blip = AddBlipForRadius(center.x, center.y, center.z, radius)
    SetBlipColour(blip, 1)
    SetBlipAlpha(blip, 128)
    circleBlips[label] = blip
    TriggerEvent('chat:addMessage', { args = { '[위치공개]', '진짜 가방이 표시된 구역 안에 있습니다.' } })
end)

RegisterNetEvent('secretbag:circleRemove', function(label)
    if circleBlips[label] then
        RemoveBlip(circleBlips[label])
        circleBlips[label] = nil
    end
end)

--- 270분 이후 FinalZoneCheck 실패 시 실시간 공개 (REQ-LIVE-001). lock 전까지 계속 갱신된다.
RegisterNetEvent('secretbag:liveReveal', function(coords)
    if liveRevealBlip then
        RemoveBlip(liveRevealBlip)
    end
    liveRevealBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(liveRevealBlip, 8)
    SetBlipColour(liveRevealBlip, 1)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('진짜 가방')
    EndTextCommandSetBlipName(liveRevealBlip)
end)

RegisterNetEvent('secretbag:liveRevealClear', function()
    if liveRevealBlip then
        RemoveBlip(liveRevealBlip)
        liveRevealBlip = nil
    end
end)

--- CheapAppraiser 대사 (기획서 6.1장).
RegisterNetEvent('secretbag:appraiserDialogue', function(npcId, text)
    TriggerEvent('chat:addMessage', { args = { '[감정사]', text } })
end)

--- 진짜 감정사/FinalTrue 판정 결과 (기획서 6.2장). bagId==nil이면 FinalTrue post-lock
--- (보유 가방 전체 genuine 존재 여부), 아니면 특정 bag 1개의 진위 확정.
RegisterNetEvent('secretbag:trueAppraisalResult', function(npcId, bagId, isGenuine)
    local text
    if bagId == nil then
        text = isGenuine and '당신은 진짜 가방을 소지하고 있습니다!' or '당신은 진짜 가방을 소지하고 있지 않습니다.'
    else
        text = isGenuine and '진짜입니다!' or '가짜입니다.'
    end
    TriggerEvent('chat:addMessage', { args = { '[진짜감정사]', text } })
end)

RegisterNetEvent('secretbag:adminGenuineHistory', function(events, filterType)
    TriggerEvent('chat:addMessage', { args = { '[Admin]', ('이력 %d건 (filter=%s)'):format(#events, filterType or 'all') } })
    for _, evt in ipairs(events) do
        TriggerEvent('chat:addMessage', { args = { '[Admin]', ('#%d %s'):format(evt.seq, evt.type) } })
    end
end)
