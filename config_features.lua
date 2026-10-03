--- 게임 시작 전 프리셋: 요소별 on/off + "언제 발동할지"를 한곳에 모아둔 파일
--- (사용자 요청: "게임이 시작되기 전에 각 요소를 킬지 끌지, 요소를 언제 발생시킬지에
--- 대한 내용을 미리 정할 수 있었으면 좋겠습니다. 이것은 따로 config 파일 등을 만들어도
--- 됩니다").
---
--- config.lua의 Config.Timeline/Config.Circle/Config.Features가 "코드가 실제로 읽는 값"
--- 이라면, 여기는 서버 운영자가 config.lua 속 사양서 확정 파라미터들을 뒤지지 않고 매
--- 게임 전에 손쉽게 건드릴 수 있는 프리셋 레이어다. server/featurepreset.lua가 리소스
--- 시작 시 이 테이블을 Config.Features/Config.Timeline/Config.Circle 위에 그대로
--- 덮어쓴다. 서버를 재시작하지 않고 즉석에서 바꾸고 싶다면 게임 시작 전(PRE_GAME/ENDED)
--- 상태에서 `/featuretime <이름> <필드> <분>` 명령을 쓰면 된다 (`/feature`는 on/off를
--- 언제든 바꿀 수 있지만, 시각은 RUNNING 중에 바꿔봐야 이미 지나간 이벤트를 되돌릴 수
--- 없어 게임 시작 전으로만 제한한다).
---
--- 필드 설명 (사용자 확정 규칙(2026) 반영 — 두 번째 진짜 감정사 삭제, 진짜 감정사는
--- 디스폰 없이 영구 유지되어 End 필드 자체가 없어짐):
---   cheapAppraiser.spawnAt      : 싸구려 감정사 2곳 스폰 시각 (기본 0분 = RUNNING 즉시)
---   trueAppraiser.spawnAt       : 진짜 감정사 스폰 시각 (기본 60분, 이후 디스폰 없음)
---   trueAppraiser.finalTrueStart: FinalTrue 스폰 시각 (기본 230분)
---   forger.spawnAt              : 위조업자 스폰 시각 (기본 120분, 추적 강화와 동시)
---   police.ambientStartAt       : 경찰 앰비언트 스폰 시작 시각 (커스텀 경찰 기본 미사용이라 실질적으로 안 쓰임)
---   police.infoShutdownAt       : 경찰 신규 스폰 금지 + 정보경제 종료 시각 (기본 165분, 미사용)
---   police.despawnAt            : 경찰 전원 철수 시각 (기본 180분, 미사용)
---   trace.bumpAt                : 전원 TraceCount +1 시각 (기본 120분)
---   liveReveal.circle1500At     : 1차(넓은, 반경 500m) 위치원 공개 시각 (기본 150분)
---   liveReveal.circle100At      : 2차(좁은, 반경 75m) 위치원 공개 시각 (기본 180분)
---   liveReveal.finalZonePreviewAt: 최종 구역 자체를 미리 공개하는 시각 (기본 210분,
---                                  genuine 위치가 아니라 실제 고정된 최종 구역 표시)
---   finalCheck.firstAt          : FinalZoneCheck 최초 실행 시각 (기본 240분)
---   finalCheck.intervalMin      : FinalZoneCheck 실패 시 재시도 간격(분) (기본 5분)
--- (policeInfoLoot은 시간 트리거가 없는 순수 판정 분기라 enabled만 있다.)

-- TEMP-TESTING: true면 아래 productionPreset 대신 testPreset10Min(전체 이벤트를 10분
-- 이내로 압축한 프리셋)을 사용한다. 실제 배포 전 반드시 false로 되돌릴 것!
-- (Config.MinPlayers/Config.PrepDurationMs와 같은 종류의 임시값 — 혼자 빠르게 전체
-- 타임라인을 훑어보고 싶다는 사용자 요청으로 추가, 이후 "10분 안에 끝나도록 더 짧게"
-- 요청에 따라 30분 프리셋에서 10분 프리셋으로 교체.)
Config.UseTestTimeline = true

-- 사용자 확정 규칙(2026): 진짜 감정사(60분)는 디스폰 없이 영구 유지 + 서버 전체 무제한
-- 사용(개인 쿨다운만 존재, config.lua Config.Appraiser.trueCooldownMs 참고) — 두 번째
-- 진짜 감정사는 완전히 삭제됐다. 위조업자는 150→120분(추적 강화와 동시)으로 당겨졌고,
-- 그 뒤 모든 이벤트가 30분씩 당겨졌다(165/180/230/240분).
local productionPreset = {
    cheapAppraiser = { enabled = true, spawnAt = 0 },
    trueAppraiser = {
        enabled = true,
        spawnAt = 60,
        finalTrueStart = 230,
    },
    forger = { enabled = true, spawnAt = 120 },
    -- 사용자 확정 규칙: 커스텀 경찰 시스템은 기본 규칙에서 완전히 미사용. 코드는 남겨두고
    -- (/feature police on 으로 언제든 재활성화 가능) 기본값만 꺼둔다.
    police = {
        enabled = false,
        ambientStartAt = 0,
        infoShutdownAt = 165,
        despawnAt = 180,
    },
    policeInfoLoot = { enabled = false },
    trace = { enabled = true, bumpAt = 120 },
    liveReveal = {
        enabled = true,
        circle1500At = 150, -- 반경은 Config.Circle.circle1500.radius(=500m)에서 관리
        circle100At = 180, -- 반경은 Config.Circle.circle100.radius(=75m)에서 관리
        finalZonePreviewAt = 210, -- 최종 구역 자체를 미리 공개(반경은 Config.FinalZone.radius)
    },
    finalCheck = { firstAt = 240, intervalMin = 5 },
}

-- 새 실제 타임라인(0~240분+재시도)을 240/24=10 비율로 눌러 담은 버전. 진짜 감정사(2분,
-- 이후 영구 유지) → 위조업자+추적 강화(5분, 동시) → 넓은 위치원(6분) → 좁은 위치원(7분)
-- → 최종 구역 미리 공개(8분) → FinalTrue(9분) → FinalZoneCheck 최초(10분, 이후 30초
-- 간격 재시도)까지 10분 안에 발생한다. (전체 테스트 세션을 10분 안에 끝낼 수 있도록.)
local testPreset10Min = {
    cheapAppraiser = { enabled = true, spawnAt = 0 },
    trueAppraiser = {
        enabled = true,
        spawnAt = 2,
        finalTrueStart = 9,
    },
    forger = { enabled = true, spawnAt = 5 },
    police = {
        enabled = false,
        ambientStartAt = 0,
        infoShutdownAt = 7,
        despawnAt = 7,
    },
    policeInfoLoot = { enabled = false },
    trace = { enabled = true, bumpAt = 5 },
    liveReveal = {
        enabled = true,
        circle1500At = 6,
        circle100At = 7,
        finalZonePreviewAt = 8,
    },
    finalCheck = { firstAt = 10, intervalMin = 0.5 },
}

Config.FeaturePreset = Config.UseTestTimeline and testPreset10Min or productionPreset
