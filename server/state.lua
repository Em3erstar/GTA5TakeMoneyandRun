local C = SecretBagMode.SessionState
local U = SecretBagMode.Util

SecretBagMode.CurrentSession = nil -- 동시에 세션 1개만 지원 (기획서 전제와 동일)

SecretBagMode.RoleState = {
    activeServerOwnerId = nil,
    roles = {}, -- [playerId] = Role
    bootstrapAdminIds = {}, -- GetConvar 로 로드, 클라이언트에서 변경 불가 (REQ-보안)
}

local function loadBootstrapAdminIds()
    local raw = GetConvar('secretbag_bootstrap_admins', '')
    local ids = {}
    for id in string.gmatch(raw, '([^,]+)') do
        ids[tonumber(id) or id] = true
    end
    return ids
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    SecretBagMode.RoleState.bootstrapAdminIds = loadBootstrapAdminIds()
end)

-- server.cfg에서 "setr secretbag_bootstrap_admins"가 "ensure GTA5TakeMoneyandRun"보다
-- 뒤에 적혀 있으면(실수하기 쉬운 순서다 — 실제로 이 프로젝트의 server.cfg도 한동안 이
-- 순서가 잘못돼 있었다), 리소스가 시작되는 순간(onResourceStart)에는 아직 그 줄이
-- 처리되기 전이라 convar가 빈 값으로 읽혀 부트스트랩 관리자가 아무도 등록되지 않는다.
-- server.cfg 순서를 고치는 것과는 별개로, convar가 "나중에" 바뀌어도(정상 순서든 잘못된
-- 순서든, 또는 운영 중 콘솔에서 값을 바꾸든) 즉시 다시 읽어오도록 리스너를 걸어
-- 이 문제 자체가 재발할 여지를 없앤다.
AddConvarChangeListener('secretbag_bootstrap_admins', function()
    SecretBagMode.RoleState.bootstrapAdminIds = loadBootstrapAdminIds()
end)

function SecretBagMode.GetRole(playerId)
    return SecretBagMode.RoleState.roles[playerId]
end

function SecretBagMode.IsServerOwner(playerId)
    return SecretBagMode.RoleState.activeServerOwnerId == playerId
end

--- 새 세션 골격 생성. StartGame 검증 통과 후에만 호출한다.
function SecretBagMode.NewSession(participantIds)
    local session = {
        sessionId = U.NewId('sess'),
        state = C.PREP,
        startedAt = U.Now(),
        mainStartedAt = nil, -- PREP 종료 시 설정 (mainElapsed=0 기준)
        sessionParticipantIds = {},
        P = 0,
        cleanupInProgress = false,
        forcedEnd = false,
        finalWinnerPlayerId = nil,
        winnerLocked = false,
        timelineFlags = {}, -- [eventKey] = true, REQ-STATE idempotency
        bags = {}, -- [bagId] = SecretBag
        noteItems = {}, -- [noteId] = NoteItem
        deathEvents = {}, -- [deathEventId] = DeathLootEvent
        genuineBagId = nil,
        logicalGenuineId = nil,
        playerSessions = {}, -- [playerId] = PlayerSession
        genuineHistory = {}, -- admin_observer가 채움
        historySeq = 0,
        scheduledCloseAt = nil, -- finalzone.lua가 채움 (270분부터)
        finalZoneLocked = false, -- finalzone.lua lockZone()이 true로
        mutationLocked = false, -- finalizeWinnerState()가 true로 (winner 확정 후 가방 변동 금지)
        liveRevealActive = false, -- finalzone.lua EnsureLiveReveal 진행 중 여부
        timelineLog = {}, -- { {label=string, min=number}, ... } — 사용자 요청: 게임 종료 시 전체 이벤트 타임라인 표시
    }
    for _, pid in ipairs(participantIds) do
        session.sessionParticipantIds[pid] = true
        session.P = session.P + 1
        session.playerSessions[pid] = SecretBagMode.NewPlayerSession()
    end
    SecretBagMode.CurrentSession = session
    return session
end

function SecretBagMode.NewPlayerSession()
    return {
        traceCount = 0,
        nextTracePingAt = nil,
        hiddenTraceTargets = {}, -- [targetPlayerId] = true
        policeRelation = SecretBagMode.PoliceState.NEUTRAL,
        infoLootCount = 0,
        infoHostileUntil = nil,
        pkHostileUntil = nil,
        revealedHintIds = {},
        personalInfoClosed = false,
        forgedOnce = false,
        cooldowns = {}, -- [cooldownKey] = expiresAtMs
        pendingFinalZoneRespawn = false, -- death.lua/finalzone.lua: FinalZone 내부 사망 후 부활 대기 중
        -- 사용자 요청: 사망~부활(60초) 동안 가방/NPC 상호작용·인벤토리 사용을 서버 쪽에서도
        -- 막는다(클라이언트 UI 차단은 우회 가능하므로 실제 권위는 서버가 가져야 함).
        -- death.lua에서 true로, 부활 처리 시 false로 되돌린다.
        awaitingRespawn = false,
    }
end

--- StartGame 순간 온라인 PLAYER만 참가자로 고정 (REQ-STATE-001).
function SecretBagMode.IsParticipant(session, playerId)
    return session ~= nil and session.sessionParticipantIds[playerId] == true
end

function SecretBagMode.TransitionTo(session, newState)
    session.state = newState
    TriggerClientEvent('secretbag:stateChanged', -1, newState)
end

--- REQ-* idempotent 타임라인 이벤트 실행 마커. 같은 key는 세션당 1회만 통과.
function SecretBagMode.MarkTimelineEventOnce(session, key)
    if session.timelineFlags[key] then
        return false
    end
    session.timelineFlags[key] = true
    return true
end

function SecretBagMode.MainElapsedMinutes(session)
    if not session.mainStartedAt then return nil end
    return (U.Now() - session.mainStartedAt) / 60000.0
end

--- 사용자 요청: "이벤트 타임라인 마지막에 보여주세요" — 주요 이벤트(감정사/위조업자
--- 등장, 위치 공개, 승자 확정 등) 발생 시점을 기록해뒀다가 게임 종료 시 전원에게
--- 한 번에 보여준다. label만 기록하고 실제 출력(U.NotifyAll)은 호출부가 이미 하고
--- 있으므로 여기서는 로그만 남긴다(중복 안내 방지).
function SecretBagMode.LogTimelineEvent(session, label)
    local elapsed = SecretBagMode.MainElapsedMinutes(session)
    table.insert(session.timelineLog, { label = label, min = elapsed and math.floor(elapsed + 0.5) or 0 })
end

--- StartGame 가능 상태인지 (PRE_GAME 상당 = 세션 없음, 또는 ENDED && cleanup 완료).
function SecretBagMode.CanStartGame()
    local session = SecretBagMode.CurrentSession
    if session == nil then return true end
    if session.state == C.ENDED and not session.cleanupInProgress then return true end
    return false
end

--- REQ-STATE: PREP 진입~ENDED 전까지 역할 변경 금지. Bootstrap/콘솔의 비상 교체만 예외.
local function isRoleLockActive()
    local session = SecretBagMode.CurrentSession
    return session ~= nil and session.state ~= C.PRE_GAME and session.state ~= C.ENDED
end

--- AssignRole API (사양서 19장). PRE_GAME/ENDED에서만 허용.
RegisterCommand('assignrole', function(source, args)
    if source ~= 0 and not SecretBagMode.RoleState.bootstrapAdminIds[source] and not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end
    if isRoleLockActive() then
        U.NotifyPlayer(source, '게임 진행 중에는 역할을 변경할 수 없습니다.')
        return
    end
    local targetId = tonumber(args[1])
    local role = args[2]
    if not targetId or not SecretBagMode.Role[role] then
        U.NotifyPlayer(source, '사용법: /assignrole <playerId> <PLAYER|SERVER_OWNER|HELPER>')
        return
    end
    SecretBagMode.RoleState.roles[targetId] = role
    if role == SecretBagMode.Role.SERVER_OWNER then
        SecretBagMode.RoleState.activeServerOwnerId = targetId
    end
    if role ~= SecretBagMode.Role.PLAYER then
        SecretBagMode.ApplyNonParticipantProtection(targetId)
    end
    -- 성공 시 아무 알림도 없어서, 실패(권한 없음 등)와 성공을 구분할 방법이 없었다 —
    -- 특히 chat 리소스가 없는 서버에서는 콘솔에도 아무 것도 안 찍혀 완전히 무반응처럼
    -- 보였다. U.NotifyPlayer가 콘솔에도 출력하므로 이제 성공 여부를 항상 확인할 수 있다.
    U.NotifyPlayer(source, ('%d번을 %s로 지정했습니다.'):format(targetId, role))
end, false)

--- EmergencySetOwner (사양서 19장): Bootstrap/콘솔 전용, 게임 중에도 예외적으로 허용.
--- sessionParticipant PLAYER는 새 SERVER_OWNER가 될 수 없다.
RegisterCommand('emergencysetowner', function(source, args)
    if source ~= 0 and not SecretBagMode.RoleState.bootstrapAdminIds[source] then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end
    local targetId = tonumber(args[1])
    if not targetId then
        U.NotifyPlayer(source, '사용법: /emergencysetowner <playerId>')
        return
    end

    local session = SecretBagMode.CurrentSession
    if session and SecretBagMode.IsParticipant(session, targetId) then
        U.NotifyPlayer(source, 'sessionParticipant PLAYER는 새 SERVER_OWNER가 될 수 없습니다.')
        return
    end

    SecretBagMode.RoleState.activeServerOwnerId = targetId
    SecretBagMode.RoleState.roles[targetId] = SecretBagMode.Role.SERVER_OWNER
    SecretBagMode.ApplyNonParticipantProtection(targetId)
    U.NotifyPlayer(source, ('%d번을 긴급 SERVER_OWNER로 지정했습니다.'):format(targetId))
end, false)
