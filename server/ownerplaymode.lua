--- 서버장 임시 플레이어 모드 (사용자 요청: "서버장이 자신에게 플레이어 역할을 임시로
--- 부여하고 제거할 수 있게 해주세요").
---
--- 핵심 트릭: SecretBagMode.RoleState.roles[id](표시 역할, GetRole이 반환)와
--- SecretBagMode.RoleState.activeServerOwnerId(관리자 신원, IsServerOwner가 검사하는 값)는
--- 서로 완전히 독립된 필드다(server/state.lua). roles[id]만 PLAYER로 바꾸면:
---   - NPC/이벤트(대부분 GetRole==PLAYER && IsParticipant 조합으로 판정)는 이 유저를
---     진짜 참가자처럼 대한다.
---   - IsServerOwner(id)는 여전히 true이므로 /startgame, /endgame, /assignrole, /sb* 등
---     SERVER_OWNER 전용 커맨드는 그대로 전부 사용할 수 있다.
---
--- 세션이 이미 PREP/RUNNING 중일 때 켜면 그 세션에도 즉시 "합류"시킨다
--- (sessionParticipantIds/playerSessions 추가 + 무적 해제). 세션이 없을 때(PRE_GAME/ENDED)
--- 켜두면, 당장 아무것도 하지 않고 다음 /startgame이 role==PLAYER인 온라인 유저를
--- 스캔하는 로직(server/startgame.lua)에 의해 자연히 다음 게임부터 정식 참가자가 된다.
---
--- server/endgame.lua의 performEndGame이 세션 종료마다 활성 tempPlayerMode를 전부
--- 자동 회수한다 — 그렇지 않으면 roles[id]=PLAYER가 다음 게임까지 새어나가
--- startgame.lua의 참가자 스캔에 의도치 않게 다시 포함되어 버린다.

local U = SecretBagMode.Util
local Role = SecretBagMode.Role
local SessionState = SecretBagMode.SessionState

SecretBagMode.RoleState.tempPlayerMode = SecretBagMode.RoleState.tempPlayerMode or {} -- [playerId] = true

local function joinableSession()
    local session = SecretBagMode.CurrentSession
    if session and session.state ~= SessionState.ENDED then
        return session
    end
    return nil
end

--- SERVER_OWNER 본인에게만 적용 가능(다른 사람을 대신 임시 플레이어로 만드는 기능이 아니다).
function SecretBagMode.EnableTempPlayerMode(playerId)
    if not SecretBagMode.IsServerOwner(playerId) then
        return false, 'NOT_OWNER'
    end
    if SecretBagMode.RoleState.tempPlayerMode[playerId] then
        return false, 'ALREADY_ON'
    end

    SecretBagMode.RoleState.tempPlayerMode[playerId] = true
    SecretBagMode.RoleState.roles[playerId] = Role.PLAYER

    local session = joinableSession()
    if session then
        session.sessionParticipantIds[playerId] = true
        if not session.playerSessions[playerId] then
            session.playerSessions[playerId] = SecretBagMode.NewPlayerSession()
        end
        SecretBagMode.ApplyProtection(playerId, false)

        -- startgame.lua가 RUNNING 시작 시 참가자 전원에게 한 번 쏘는 초기 policeRelation
        -- 방송을 이 사람은 놓쳤으므로(이미 RUNNING인 세션에 뒤늦게 합류), 여기서 대신
        -- 보내야 HUD 상태줄(html/index.html)이 빈 채로 남지 않는다.
        TriggerClientEvent('secretbag:policeRelationChanged', playerId, session.playerSessions[playerId].policeRelation)
    end

    return true
end

function SecretBagMode.DisableTempPlayerMode(playerId)
    if not SecretBagMode.RoleState.tempPlayerMode[playerId] then
        return false, 'NOT_ACTIVE'
    end

    SecretBagMode.RoleState.tempPlayerMode[playerId] = nil
    SecretBagMode.RoleState.roles[playerId] = Role.SERVER_OWNER

    local session = joinableSession()
    if session then
        session.sessionParticipantIds[playerId] = nil
        -- playerSessions/보유 SecretBag은 그대로 남긴다 — 기록 보존 + 재활성화 시
        -- traceCount/policeRelation 등 이전 상태를 이어갈 수 있도록.

        -- 더 이상 참가자가 아니므로 본인 화면의 HUD 상태줄(html/index.html)은 비워준다.
        -- 실제 저장된 policeRelation은 안 건드린다(위 주석대로 재활성화 시 이어가야 하므로) —
        -- PoliceState.DISABLED는 client/main.lua의 policeRelationLabels에서 "표시 없음"으로
        -- 매핑되는 값이라, 이 클라이언트의 화면 갱신 목적으로만 재사용한다.
        TriggerClientEvent('secretbag:policeRelationChanged', playerId, SecretBagMode.PoliceState.DISABLED)
    end

    -- 비참가자(SERVER_OWNER)는 항상 무적이어야 한다(server/prep.lua ApplyNonParticipantProtection과
    -- 동일 규칙). 세션이 없을 때 껐어도 평상시 SERVER_OWNER 무적 상태로 되돌려야 하므로
    -- joinableSession 여부와 무관하게 항상 복원한다.
    SecretBagMode.ApplyProtection(playerId, true)

    return true
end

local tempPlayerErrorText = {
    NOT_OWNER = 'SERVER_OWNER만 사용할 수 있습니다.',
    ALREADY_ON = '이미 임시 플레이어 모드가 켜져 있습니다.',
    NOT_ACTIVE = '임시 플레이어 모드가 켜져 있지 않습니다.',
}

RegisterCommand('tempplayer', function(source, args)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end

    local mode = args[1]
    if mode == 'on' then
        local ok, err = SecretBagMode.EnableTempPlayerMode(source)
        if not ok then
            U.NotifyPlayer(source, tempPlayerErrorText[err] or ('실패: ' .. tostring(err)))
            return
        end
        U.NotifyPlayer(source, '임시 플레이어 모드를 켰습니다. 이제 NPC/이벤트가 당신을 참가자로 취급합니다.')
    elseif mode == 'off' then
        local ok, err = SecretBagMode.DisableTempPlayerMode(source)
        if not ok then
            U.NotifyPlayer(source, tempPlayerErrorText[err] or ('실패: ' .. tostring(err)))
            return
        end
        U.NotifyPlayer(source, '임시 플레이어 모드를 껐습니다.')
    else
        U.NotifyPlayer(source, '사용법: /tempplayer <on|off>')
    end
end, false)
