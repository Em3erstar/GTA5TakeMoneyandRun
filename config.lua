Config = {}

-- ============================================================
-- 확정된 규칙 파라미터 (기획서/사양서 기준)
-- ============================================================

-- TEMP-TESTING: 원래 4. 혼자 스모크 테스트하려고 1로 낮춰둠 — 실제 배포 전 반드시 4로 되돌릴 것!
Config.MinPlayers = 1

-- 솔로 디버깅용 커맨드(server/debug.lua) 활성화 스위치. 실제 배포 전 반드시 false로 끌 것 —
-- SERVER_OWNER 전용이긴 하지만 genuine 강제 지급/시간 조작 등 치트성 기능이라 운영 중엔 위험하다.
Config.Debug = {
    enabled = true,
}

-- 게임 시스템 개별 on/off 스위치 (server/features.lua, /feature 커맨드로 SERVER_OWNER가 런타임에 변경).
-- 각 server/*.lua는 이 테이블을 직접 참조하므로, /feature 커맨드는 이 필드를 그 자리에서
-- 덮어쓴다(별도 런타임 상태 테이블 없음) — 끄면 해당 NPC/이벤트가 즉시 사라지거나 더 이상 발동하지 않는다.
-- 사용자 확정 규칙(2026): 경찰(커스텀 시스템)은 기본 규칙에서 아예 쓰지 않는다. 코드는
-- 그대로 두되(나중에 필요하면 /feature police on 으로 재활성화 가능) 기본값을 꺼둔다.
-- (config_features.lua의 FeaturePreset이 어차피 매 시작마다 이 값을 덮어쓰지만, 그
-- 파일을 안 보고 여기만 봐도 "기본은 꺼짐"이 바로 보이도록 여기 기본값도 맞춰둔다.)
Config.Features = {
    cheapAppraiser = true,
    trueAppraiser = true,
    forger = true,
    police = false,
    policeInfoLoot = false,
    trace = true,
    liveReveal = true,
}

-- TEMP-TESTING: 원래 5분(5 * 60 * 1000, 사용자 확정 규칙으로 10분→5분 축소). 혼자 빠르게
-- 반복 테스트하려고 30초로 낮춰둠 — 실제 배포 전 반드시 5 * 60 * 1000으로 되돌릴 것!
-- (Config.MinPlayers와 같은 종류의 임시값)
Config.PrepDurationMs = 30 * 1000

-- 본 게임 타임라인 (분 단위, mainElapsed 기준). 사용자 확정 규칙(2026)으로 재조정됨:
-- 두 번째 진짜 감정사 삭제, 위조업자를 추적 강화와 동시로 당김, 그 이후 이벤트 전부 30분씩 당김.
-- config_features.lua/Config.FeaturePreset이 서버 시작 시 이 테이블 위에 프리셋을 덮어쓰고,
-- SERVER_OWNER는 게임 시작 전(PRE_GAME/ENDED)에 /featuretime으로 즉석에서 더 조정할 수 있다
-- (server/featurepreset.lua). RUNNING 중에는 이미 지나간 이벤트를 되돌릴 수 없어 막아둔다.
Config.Timeline = {
    cheapAppraiserSpawnAt = 0, -- 원래 RUNNING 시작과 동시(즉시) 스폰이었다. 폴링 스케줄러 방식으로 바뀌며 지연 스폰도 가능해졌다.
    trueAppraiserSpawnAt = 60, -- 등장 후 디스폰 없이 게임 종료까지 유지(server/appraiser.lua 참고) — End 시각 자체가 없다.
    traceBumpAt = 120,
    forgerSpawnAt = 120, -- 150분 → 120분(추적 강화와 동시). 사용자 확정 규칙.
    -- 두 번째 진짜 감정사(trueAppraiser2Start/End)는 완전히 삭제됨.
    policeAmbientStartAt = 0, -- 원래 RUNNING 시작과 동시에 앰비언트 굴림 시작이었다. (커스텀 경찰 기본 미사용이라 실질적으로 안 쓰임)
    policeInfoShutdownAt = 165, -- 195 → 165 (30분 당김)
    policeDespawnAt = 180, -- 210 → 180 (30분 당김)
    finalTrueStart = 230, -- 260 → 230 (30분 당김)
    finalCheckFirstAt = 240, -- 270 → 240 (30분 당김)
    finalCheckIntervalMin = 5,
}

-- Standalone 인벤토리(server/inventory.lua): 프레임워크 없이 이 모드가 직접
-- SecretBag/NoteItem 소지 슬롯을 카운트한다. 일반 아이템(무기 등)은 무관.
Config.Inventory = {
    maxModSlots = 5,
}

Config.SecretBag = {
    genuineScoreMin = 70,
    genuineScoreMax = 99,
    fakeScoreMin = 10,
    fakeScoreMax = 90,
    fakeRealLikeMinCount = 2, -- score>=60인 fake가 최소 2개
    fakeRealLikeThreshold = 60,
}

-- 사용자 확정 규칙(2026)으로 전면 재조정: 진짜 감정사/최종 감정사 둘 다 서버 전체
-- 사용 한도가 없어져(무제한) 관련 필드가 삭제됐다 — 이제 남는 제약은 "개인 쿨다운"뿐이다.
Config.Appraiser = {
    cheapCooldownMs = 5 * 1000, -- 60분 → 5초. CheapAppraiser 2곳이 공유하는 건 동일.
    interactDistance = 2.5,
    trueCooldownMs = 60 * 60 * 1000, -- 진짜 감정사(구 True#1) 개인 쿨다운: 6분 → 60분. 서버 전체 사용 한도는 없음(무제한).
    finalTruePreLockCooldownMs = 1 * 60 * 1000, -- 3분 → 1분 (등장~최종구역 판정 전)
    finalTruePostLockCooldownMs = 5 * 1000, -- 1초 → 5초 (봉쇄 확정 이후). 서버 전체 사용 한도는 없음(무제한, 기존 255회 제한 삭제).
}

Config.Trace = {
    -- index = TraceCount, value = ping interval(ms). count>=3은 반복 사용.
    pingIntervalMsByCount = {
        [0] = nil, -- 핑 없음
        [1] = 10 * 60 * 1000,
        [2] = 5 * 60 * 1000,
        [3] = 2 * 60 * 1000, -- 3 이상은 이 값, 단 mainElapsed>=120이면 아래로 override
    },
    intervalAfter120Ms = 1 * 60 * 1000, -- count>=4 이고 mainElapsed>=120
}

Config.Death = {
    respawnDelayMs = 60 * 1000, -- REQ-DEATH-002
    reportCooldownMs = 5000, -- 자체 추가: 클라 리포트 스팸 방지 (문서에는 없는 방어적 rate limit)
}

Config.Police = {
    detectionRadius = 50.0,
    infoHostileStepMinutes = 5, -- n회차 = n*5분
    pkAlertMs = 1 * 60 * 1000,
    pkHostileMs = 5 * 60 * 1000,
    alertToNeutralMs = 1 * 60 * 1000,

    -- 앰비언트(시민처럼) 랜덤 스폰. 고정 좌표 목록이 아니라 온라인 참가자 근처에
    -- 낮은 빈도로 트리클 스폰한다. 고정 지점이 없으므로 "경찰 스폰 좌표 실측"이 애초에 불필요해진다.
    ambientSpawnCheckIntervalMs = 30 * 1000, -- 이 주기로 스폰 여부를 "굴린다"
    ambientSpawnChance = 0.15, -- 굴릴 때마다 실제로 스폰될 확률 (낮은 빈도 = 낮은 확률)
    maxActive = 3, -- 동시 활성 경찰 상한 (기존 고정 4명과 달리 이제 인구 상한 개념)
    spawnMinDistance = 40.0, -- 참가자로부터 최소 거리 (바로 옆에 뜨지 않게)
    spawnMaxDistance = 90.0, -- 참가자로부터 최대 거리
    despawnDistance = 200.0, -- 모든 온라인 참가자로부터 이보다 멀면 정리 대상 (앰비언트 디스폰과 동일한 개념)
    spawnRequestTimeoutMs = 10 * 1000, -- 클라이언트가 안전좌표를 응답하지 않을 때 요청을 버리는 시간
}

Config.FinalZone = {
    -- 사용자 확정값: 30m (100m -> 55m -> 30m).
    radius = 30.0,
}

-- 필드 이름(circle1500/circle100)은 사양서 초기 초안의 반경(1500m/100m) 흔적이라 지금
-- 실제 반경과 안 맞은 지 오래됐다(750/50이었다가 이제 500/75) — 기존부터 쓰던 식별자라
-- 코드 영향 범위를 줄이려 이름은 그대로 두고 값만 갱신한다.
Config.Circle = {
    circle1500 = { atMinute = 150, radius = 500.0, ttlMs = 5 * 60 * 1000 }, -- 750 → 500
    circle100 = { atMinute = 180, radius = 75.0, ttlMs = 5 * 60 * 1000 }, -- 50 → 75, 시각도 210→180
    -- 사용자 요청: 210분에 최종 구역 자체를 5/6번(circle1500/circle100)과 동일한 방식으로
    -- 미리 공개한다. genuine 위치 기반 랜덤 오프셋 원이 아니라 실제 고정된 최종 구역
    -- 좌표/반경(Config.FinalZoneCenter / Config.FinalZone.radius)을 그대로 보여준다 —
    -- 그래서 radius 필드가 따로 없다.
    finalZonePreview = { atMinute = 210, ttlMs = 5 * 60 * 1000 },
}

-- ============================================================
-- 실측 좌표 (npc_spawn_place.txt 기준, 2025 제공)
--
-- 원본 파일은 x,y만 제공한다(z/높이 없음). 이 모드는 NPC를 서버에서 직접
-- CreatePed/CreateObject로 생성하는데, 서버사이드에는 지면 높이를 구하는
-- 표준 네이티브가 없어(클라이언트 전용) z는 전부 30.0(도심 평균 지면 높이
-- 추정치, 최종 목적지 부두만 5.0으로 낮게 추정)으로 채워뒀다. 실서버에서
-- NPC가 지면에 파묻히거나 공중에 뜨면 각 좌표의 z를 인게임에서 직접 찍어
-- 교체해야 한다. heading은 원본에 없어 스폰 시 매번 랜덤으로 준다.
-- ============================================================

local NPC_Z_DEFAULT = 30.0

-- 플레이 영역(GameArea): 원형. npc_spawn_place.txt [플레이 영역] 그대로(2500 -> 2600으로 확장).
Config.GameArea = {
    center = vector3(-264.0234, -1329.4922, NPC_Z_DEFAULT),
    radius = 2600.0,
}

-- 최종 목적지(FinalZone): 원형, radius는 Config.FinalZone.radius(=100)와 연동.
-- 사용자가 직접 현장에서 확인한 실측 좌표로 교체(기존 -1336.0483, -3044.3604, 13.9297 ->
-- 아래 실측값). 최종 감정사(FinalTrue)도 이 좌표에 고정 스폰된다(server/appraiser.lua 참고).
Config.FinalZoneCenter = vector3(1367.2748, -578.4659, 74.3700)

-- NPC 스폰 풀: 카테고리별로 후보 좌표 여러 개를 두고, 스폰 시점에 그중 하나를
-- 균등 랜덤으로 고른다(기획서에 좌표 하나로 고정하라는 규칙이 없고, 사용자가
-- "랜덤 스폰 후보지"로 제공했으므로 매 세션 스폰 위치가 달라진다).
-- CheapAppraiser는 동시에 2개체가 존재해야 하므로 풀을 1/2로 분리해뒀다
-- (같은 좌표에 두 NPC가 겹쳐 스폰되는 것을 방지).
-- z는 전부 실측값이다(추정치 NPC_Z_DEFAULT 아님) — /sbmeasureallgroundz(원격 순간이동
-- 방식)와 /sbrecordground(직접 걸어가서 기록하는 방식, 원격 방식이 계속 실패하던 5곳
-- 전용)로 실제 서버에서 측정했다. 실측 전에는 NPC_Z_DEFAULT(=30.0)로 고정돼 있어 실제
-- 지형과 안 맞는 좌표(특히 아래 forger 3곳 전부, 해안/수변 지역으로 추정)에서 NPC가
-- 파묻히거나 아예 렌더링되지 않는(=스폰 안 된 것처럼 보이는) 문제가 있었다 — 사용자가
-- 직접 원격 텔레포트 시 캐릭터가 맵 밖으로 떨어지는 것으로 재현/확인함. 걸어가서 기록한
-- 5곳(cheapAppraiser2[1], trueAppraiser[2], forger 전체)은 원래 후보 좌표 근방으로
-- x/y도 실측값으로 갱신됐다(정확히 같은 지점이 아니라 도보로 도달 가능한 바로 옆).
Config.NpcSpawnPools = {
    cheapAppraiser1 = {
        -- 사용자가 실제 위치에서 확인 후 더 나은 지점으로 직접 교체 요청(-151.9629,
        -- -447.0154 -> 아래 좌표).
        vector3(-118.2857, -433.0549, 35.9019),
        -- 사용자가 실제 위치에서 확인 후 더 나은 지점으로 직접 교체 요청(1365.5237,
        -- -580.7739 -> 아래 좌표. 기존 좌표는 최종 목적지로 옮겨졌다).
        vector3(156.3033, -964.2857, 30.0886),
        -- 사용자가 실제 위치에서 확인 후 더 나은 지점으로 직접 교체 요청(-480.1794,
        -- -626.3672 -> 아래 좌표).
        vector3(-497.6044, -691.2264, 33.2058),
    },
    cheapAppraiser2 = {
        vector3(688.4572, -983.9868, 23.4498),
        -- 사용자가 실제 위치에서 확인 후 더 나은 지점으로 직접 교체 요청(285.8423,
        -- -1567.0715 -> 아래 좌표).
        vector3(299.8549, -1616.0571, 30.5267),
        -- 사용자가 실제 위치에서 확인 후 더 나은 지점으로 직접 교체 요청(-529.8926,
        -- -230.0354 -> 아래 좌표).
        vector3(-490.2462, -225.9429, 36.3737),
    },
    -- 진짜 감정사(60분~영구)/FinalTrue(230분~)가 공유하는 풀. 매번 이 풀에서
    -- 독립적으로 랜덤 선택한다.
    trueAppraiser = {
        -- 사용자가 실제 위치에서 확인 후 더 나은 지점으로 직접 교체 요청(358.9014,
        -- 18.8049 -> 아래 좌표).
        vector3(374.0308, -36.1187, 91.2535),
        vector3(-1017.0593, -1010.2022, 2.1348),
        vector3(-42.3743, -784.845, 43.2575),
    },
    forger = {
        vector3(250.4308, -1966.9714, 22.0176),
        vector3(14.8352, -1883.8286, 23.1802),
        vector3(468.5802, -1698.5934, 29.1956),
    },
    -- 경찰은 고정 스폰 풀이 없다. Config.Police의 앰비언트 스폰 설정에 따라 온라인 참가자
    -- 근처에 트리클 스폰된다(server/police.lua) — 클라이언트가 GetGroundZFor_3dCoord로
    -- 실시간 지면 높이를 찾아주므로 다른 NPC처럼 z를 추정해둘 필요조차 없다.
}

-- 초기 사망/부활 안전 좌표 fallback (nearestSafeCoord 계산 실패 시) — GameArea 중심으로.
Config.DefaultSafeCoord = vector3(-264.0234, -1329.4922, NPC_Z_DEFAULT)

-- 최초 접속 스폰 지점 (사용자 요청). client/main.lua가 최초 playerSpawned 시점에 실제로
-- 그 자리에 도착한 뒤 GetGroundZFor_3dCoord로 한 번 더 보정하므로(플레이어 본인이 실제로
-- 거기 있어 콜리전이 정상적으로 로드됨 — 원격 NPC 스폰과 달리 이 보정은 안정적으로
-- 동작한다) 이 z는 엄밀히는 없어도 되지만, 사용자가 실제로 확인한 실측값으로 맞춰둔다.
Config.InitialSpawnCoord = vector3(-150.5934, -875.0110, 29.5831)

-- 전체 공지(/announce, server/announce.lua) 표시 설정 (사용자 요청). client/main.lua가
-- SetTextFont(0)(=GTA5 기본 폰트 Chalet London)으로 화면에 직접 그린다 — html/index.html의
-- HUD와 달리 진짜 GTA5 자체 폰트가 그대로 나온다(HTML/NUI는 라이선스상 GTA 폰트를
-- 번들할 수 없어 대체 폰트를 쓴다는 점이 README에 이미 명시돼 있다).
-- scale은 GTA 텍스트 렌더링 고유의 상대적 크기 단위라 실제 "pt"에 대응하는 표준 변환이
-- 없다 — 아래 값은 요청받은 "36pt"에 가깝도록 육안으로 근사한 값이라, 실제 화면에서 보고
-- 조정이 필요할 수 있다.
Config.Announcement = {
    font = 0, -- 0 = Chalet London, GTA5 기본 UI 폰트
    scale = 0.7,
    -- 화면을 위아래로 4등분했을 때 아래에서 첫 번째 등분선(= 위에서 3/4 지점) 요청 반영.
    screenY = 0.75,
    color = { r = 255, g = 165, b = 0 }, -- 주황색
    durationMs = 8000,
}

-- 수배(Wanted) 시스템 (사용자 확정 규칙, server/wanted.lua). 참가자 간 PK 시에만 발동하며,
-- 그 외 어떤 사유로도 수배 레벨이 바뀌지 않는다 — GTA5 기본 인구가 켜져 있어 시민을 치거나
-- 공공장소에서 소란을 피워도 수배가 오르면 안 되므로, server/wanted.lua가 활성 상태인 동안
-- 이 level 값으로 계속 강제 고정한다. 체포 비활성화/사살 전용 대응은 client/main.lua 참고.
Config.Wanted = {
    level = 2, -- 킬 시 항상 정확히 이 값으로 고정 (증가/감소 없음)
    durationMs = 15 * 60 * 1000, -- 15분. 유지 중 재킬 시 이 값만큼 추가(누적, 상한 없음).
}
