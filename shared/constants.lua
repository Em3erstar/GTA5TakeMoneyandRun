SecretBagMode = SecretBagMode or {}

SecretBagMode.SessionState = {
    PRE_GAME = 'PRE_GAME',
    PREP = 'PREP',
    RUNNING = 'RUNNING',
    FINAL_LOCKED_CONTEST = 'FINAL_LOCKED_CONTEST',
    FINISHING = 'FINISHING',
    ENDED = 'ENDED',
}

SecretBagMode.Role = {
    PLAYER = 'PLAYER',
    SERVER_OWNER = 'SERVER_OWNER',
    HELPER = 'HELPER',
    LATE_NONPARTICIPANT = 'LATE_NONPARTICIPANT',
}

SecretBagMode.BagState = {
    INVENTORY = 'inventory',
    WORLD_DROP = 'world_drop',
    REPLACED = 'replaced',
}

SecretBagMode.PoliceState = {
    NEUTRAL = 'NEUTRAL',
    ALERT_TO_HOSTILE = 'ALERT_TO_HOSTILE',
    HOSTILE = 'HOSTILE',
    ALERT_TO_NEUTRAL = 'ALERT_TO_NEUTRAL',
    ALERT_SHUTDOWN = 'ALERT_SHUTDOWN',
    DISABLED = 'DISABLED',
}

SecretBagMode.HistoryEventType = {
    INITIAL_CREATED = 'INITIAL_CREATED',
    PICKUP = 'PICKUP',
    DROP_MANUAL = 'DROP_MANUAL',
    DROP_DEATH = 'DROP_DEATH',
    DROP_DISCONNECT = 'DROP_DISCONNECT',
    TRANSFER = 'TRANSFER',
    CHEAP_APPRAISAL = 'CHEAP_APPRAISAL',
    ADMIN_CHEAP_APPRAISAL = 'ADMIN_CHEAP_APPRAISAL',
    TRUE_APPRAISAL = 'TRUE_APPRAISAL',
    ADMIN_INSPECT = 'ADMIN_INSPECT',
    LOCATION_REVEAL = 'LOCATION_REVEAL',
    ADMIN_RESPAWN_GENUINE = 'ADMIN_RESPAWN_GENUINE',
    FINAL_CHECK = 'FINAL_CHECK',
    FINAL_LOCKED_CONTEST = 'FINAL_LOCKED_CONTEST',
    WINNER_LOCKED = 'WINNER_LOCKED',
    END_GAME = 'END_GAME',
}

SecretBagMode.ErrorCode = {
    START_NO_SLOT = 'START_NO_SLOT',
    NO_ACCESS = 'NO_ACCESS',
    FINAL_OWNER_HOLD = 'FINAL_OWNER_HOLD',
    FINAL_OUTSIDE = 'FINAL_OUTSIDE',
    FINAL_EMPTY = 'FINAL_EMPTY',
    POLICE_INFO = 'POLICE_INFO',
    NOT_SERVER_OWNER = 'NOT_SERVER_OWNER',
    NO_ACTIVE_GENUINE = 'NO_ACTIVE_GENUINE',
    INVALID_FILTER = 'INVALID_FILTER',
    -- 아래는 원래 여러 server/*.lua가 Message 테이블에 없는 맨 문자열('LOCKED' 등)을
    -- 그대로 반환해, 실패 시 플레이어 화면에 "TOO_FAR" 같은 코드가 번역 없이 그대로
    -- 노출되던 버그를 고치며 추가했다 (inventory.lua/finalzone.lua/bag.lua 참고).
    LOCKED = 'LOCKED', -- U.WithLock 동시성 충돌(다른 처리가 같은 잠금을 쓰는 중)
    MUTATION_LOCKED = 'MUTATION_LOCKED', -- winner 확정 후 가방 조작 금지 (session.mutationLocked)
    AWAITING_RESPAWN = 'AWAITING_RESPAWN', -- 사망~부활 대기 중(playerSession.awaitingRespawn) 가방/NPC 상호작용 금지
    NOT_ON_GROUND = 'NOT_ON_GROUND',
    NO_PED = 'NO_PED',
    TOO_FAR = 'TOO_FAR',
    NO_SLOT = 'NO_SLOT',
    NOT_OWNER = 'NOT_OWNER',
    NOT_CONTEST = 'NOT_CONTEST',
    OWNER_DENIED = 'OWNER_DENIED',
    RACE_LOST = 'RACE_LOST',
}

SecretBagMode.Message = {
    [SecretBagMode.ErrorCode.START_NO_SLOT] = '인벤토리 빈 슬롯을 1개 이상 만들어주세요.',
    [SecretBagMode.ErrorCode.NO_ACCESS] = '접근 권한이 없다.',
    [SecretBagMode.ErrorCode.FINAL_OWNER_HOLD] = '운영자가 진짜 가방을 보유 중입니다! (5분 추가 시간)',
    [SecretBagMode.ErrorCode.FINAL_OUTSIDE] = '진짜 가방이 밖에 있다! (5분 추가 시간)',
    [SecretBagMode.ErrorCode.FINAL_EMPTY] = '아무도 최종 구역에 없다! (5분 추가 시간)',
    [SecretBagMode.ErrorCode.POLICE_INFO] = '누군가 경찰에게서 정보를 강탈했습니다.',
    [SecretBagMode.ErrorCode.LOCKED] = '지금은 처리할 수 없습니다. 잠시 후 다시 시도해주세요.',
    [SecretBagMode.ErrorCode.MUTATION_LOCKED] = '게임이 마무리 단계라 더 이상 가방을 조작할 수 없습니다.',
    [SecretBagMode.ErrorCode.AWAITING_RESPAWN] = '사망 후 부활 대기 중에는 조작할 수 없습니다.',
    [SecretBagMode.ErrorCode.NOT_ON_GROUND] = '땅에 떨어져 있는 가방이 아닙니다.',
    [SecretBagMode.ErrorCode.NO_PED] = '캐릭터를 찾을 수 없습니다.',
    [SecretBagMode.ErrorCode.TOO_FAR] = '가방과 너무 멉니다.',
    [SecretBagMode.ErrorCode.NO_SLOT] = '인벤토리에 빈 슬롯이 없습니다.',
    [SecretBagMode.ErrorCode.NOT_OWNER] = '소지한 가방이 아닙니다.',
    [SecretBagMode.ErrorCode.NOT_CONTEST] = '지금은 확보 경쟁 상태가 아닙니다.',
    [SecretBagMode.ErrorCode.OWNER_DENIED] = 'SERVER_OWNER는 승자가 될 수 없습니다.',
    [SecretBagMode.ErrorCode.RACE_LOST] = '다른 사람이 먼저 확보했습니다.',
}
