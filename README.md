# GTA V 비밀 가방 추적 게임모드

FiveM standalone 리소스 스캐폴딩. `기획서`/`개발사양서` PDF의 REQ-ID를 코드 주석에 그대로 매핑했다.

## 리소스 설치

`resources/[local]/` 아래에 이 폴더를 통째로 복사하고 `server.cfg`에 추가:

```
ensure GTA5TakeMoneyandRun
```

부트스트랩 관리자(콘솔/긴급 SERVER_OWNER 교체 권한)는 convar로 설정한다. `server.cfg`에:

```
setr secretbag_bootstrap_admins "1,2"
```

요소별 on/off + 발동 시각을 어떻게 설정하는지는 [FEATURE_TOGGLE_GUIDE.md](FEATURE_TOGGLE_GUIDE.md)
참고. 솔로 디버깅용 `/sb*` 명령 전체 목록은 [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md) 참고.

## 구현 상태

### Phase 1 — 완료 (동작함)
- 상태머신: PRE_GAME → PREP → RUNNING → FINAL_LOCKED_CONTEST/FINISHING → ENDED (`server/state.lua`)
- `/assignrole`, `/emergencysetowner` — 역할 배정 (REQ-STATE 역할 잠금 포함)
- `/startgame` — 검증 순서(state/cleanup→owner권한→P>=4→freeSlot)와 initial SecretBag RNG (REQ-START-001~004)
- PREP 무적/전투금지, 비참가자 상시 보호 (REQ-PREP-001/002)
- SecretBag 모델: pickup/drop/ownership history/admin genuine respawn (REQ-BAG-001~004)
- FinalZoneCheck 우선순위 1~4 평가 + finalizeWinnerState() + contest pickup 원자 처리 (REQ-FINAL-001~004)
- `/endgame` — forcedEnd 판정, cleanup 순서, 보호상태 전체 해제 (REQ-END-001~005)
- SERVER_OWNER 전용 진짜가방 관리자 조회: `/genuineinfo`, `/genuinewhere`, `/genuinehistory [type]`, `/spawngenuine` (사양서 12~15장, 기획서 4.1)
- **Standalone 인벤토리** (`server/inventory.lua`) — 프레임워크 없이 이 모드가 직접 SecretBag 소지 슬롯(`Config.Inventory.maxModSlots`)을 관리.
  월드 드롭은 실제 네트워크 오브젝트(`hei_prop_heist_bag_var22`)로 스폰되며 `/pickupbag`(근접 3m 이내 최단거리 자동 선택)·`/dropbag`으로 pickup/drop.
  거리·역할·mutationLocked를 서버에서 전부 재검증(클라 좌표 불신). `playerDropped`에서 REQ-DISC-001(winner 미확정 시 자동 world_drop) 처리.
- **CheapAppraiser + True#1/#2/FinalTrue** (`server/appraiser.lua`) — PREP 종료 시 CheapAppraiser 2곳 스폰,
  60/180/260분에 True#1/#2/FinalTrue 스폰·75/195분(또는 remainingUses 소진)에 True#1/#2 despawn하는 자체 스케줄러 포함.
  `/usecheap`·`/usetrue`·`/usefinaltrue`. Score 7단계 고정 대사, bagCount==1 검증, 개인/공유 쿨다운, 공용 사용 한도
  (ceil(P/2), ceil(P/2)+2, 255), SERVER_OWNER 면제, FinalTrue pre-lock(단일 bag 진위)/post-lock(보유 전체 genuine 존재 여부)
  분기까지 문서 그대로 구현 (기획서 6장 전체).
- **Death/Respawn** (`server/death.lua`) — 클라이언트가 자기 사망을 감지(`IsEntityDead`/`GetPedSourceOfDeath`)해 서버에 보고,
  보유 SecretBag 전부를 deathCoords에 world_drop, 60초 후 `NetworkResurrectLocalPlayer`로 부활 (REQ-DEATH-001/002).
  **신뢰 경계 주의**: 킬러 귀속은 클라 자가신고를 참가자 여부만 재검증하는 수준이라 악용 여지가 있다 (파일 헤더 주석 참고).
- **Trace 시스템** (`server/trace.lua`) — 킬러가 자신이 죽인 death event의 드롭 가방을 pickup하면 death당 최대 +1
  (`bag.lua` `OnPickup`에서 훅), count별 핑 주기, 120분 전원 +1(오프라인은 count만 증가 후 재접속 즉시 ping),
  observer의 `/deletetraceping`으로 특정 target 영구 숨김, FinalZone lock 즉시 서비스 종료 + 클라이언트 ping 전체 제거
  (REQ-TRACE-001~004, REQ-RECON-001).
- **실측 좌표 반영** — `npc_spawn_place.txt`(사용자 제공)의 CheapAppraiser 1/2·TrueAppraiser·Forger 랜덤 스폰
  후보지, 플레이 영역(원형 반지름 2500m), 최종 목적지(원형 반지름 100m)를 `config.lua`에 그대로 옮겼다.
  스폰 시점마다 각 카테고리 후보 목록에서 균등 랜덤으로 하나를 고른다(`Util.PickRandom`). 경찰 스폰 좌표는
  파일에 없어 이전 placeholder 그대로 유지. **z 높이는 전부 추정치(도심 30.0, 부두 5.0)** — 원본 데이터가
  x,y만 제공하고 서버사이드에는 지면 높이를 구하는 네이티브가 없어서다. 실서버에서 NPC가 파묻히거나 뜨면
  교체해야 한다.
- **경찰 시스템** (`server/police.lua`) — 고정 좌표 목록이 아니라 **일반 시민 앰비언트 스폰처럼**
  온라인 참가자 근처에 낮은 빈도로 트리클 스폰된다(`Config.Police.ambientSpawnCheckIntervalMs`=30초마다
  `ambientSpawnChance`=15% 확률로 굴림, `maxActive`=3 상한). 서버는 지형 데이터가 없어 안전한 z를 모르므로
  스폰 후보 클라이언트에게 `GetGroundZFor_3dCoord`로 확인받은 뒤에만 생성 — 다른 NPC들과 달리 z를 추정해둘
  필요가 아예 없다(경찰 좌표 실측 자체가 불필요해짐). 모든 참가자로부터 `despawnDistance`=200m보다 멀어지면
  앰비언트 디스폰되고, 죽으면 그 자리에 재스폰하지 않고 루프가 자연스럽게 다시 채운다. `TaskWanderStandard`로
  평소엔 순찰하듯 배회하다가 HOSTILE 타겟이 50m 이내 들어오면 `TaskCombatPed`로 추격(REQ-POLICE-001).
  NEUTRAL participant가 직접 사살 시 정보 강탈 상태 전이(n회차=n×5분 hostile), PK는 1분 ALERT→5분 HOSTILE→1분
  ALERT_TO_NEUTRAL, info/PK 두 hostile 원인이 겹치면 둘 다 끝나야 해제(REQ-POLICE-002/003). 195분 이후 신규
  스폰 금지, 210분 전부 철수는 그대로 유지.
  **신뢰 경계 주의**: (1) 경찰 킬러 판정은 서버가 `GetPedSourceOfDeath`를 직접 호출하는데 서버사이드 가용성이
  빌드마다 다를 수 있어 미검증 — 실패 시 정보 강탈만 조용히 스킵됨. (2) 앰비언트 스폰 좌표도 death.lua의
  reportDeath와 같은 부류로 클라이언트가 보고함 — 스푸핑 난이도는 있지만 이론상 악용 여지가 있음.
- **위조업자** (`server/forger.lua`) — 150분에 `Config.NpcSpawnPools.forger` 중 랜덤 1곳 스폰, EndGame까지 유지.
  `/useforger`. bagCount==1·freeSlot>=1·forgedOnce==false 검증, `newFake.score=randomInt(max(0,S-20),S)`로
  새 fake를 별도 슬롯에 지급(원본 유지), 세션 1회 소모, SERVER_OWNER는 bagCount/freeSlot만 적용, winner 확정
  후 비활성화 (기획서 7장).
- **NoteItem / Hint Engine** (`server/hint.lua`) — 5가지 힌트 유형(cheap/ownership/initialFakeOwner/
  realLikeFakeCount/higherThanGenuineCount)을 현재 게임 상태에서 실시간 계산, recipient별 미공개 힌트 중
  균등 랜덤 발급. count류/cheap/ownership은 상태가 바뀌면 hintId 문자열 자체가 달라지므로 REQ-HINT-003
  dynamic reopen이 별도 로직 없이 자연히 성립. initialFakeOwner는 recipient별 최대 floor(P/2) distinct 캡.
  인벤토리 full이면 발밑 world_drop, `/readnote`(재열람, 비소모)·`/dropnote`·`/givenote`(직접 전달,
  전달받은 쪽은 자신의 중복 기록에 영향 없음)·`/pickupnote`. `police.lua`의 정보강탈이 이 위에서 완전히
  동작한다(eligible=0이면 개인 ALERT_SHUTDOWN, 새 hintId 생기면 195분 전 자동 재개).
- **Live Reveal** (`server/livereveal.lua` + `finalzone.lua`) — 150/210분에 genuine을 포함하는 랜덤 오프셋
  원(반경 750/50, TTL 5분, 생성 시점 snapshot이라 genuine이 움직여도 원은 안 바뀜)을 전원에게 공개
  (REQ-CIRCLE-001). 270분 이후 FinalZoneCheck가 우선순위 1/2/3으로 실패하면 lock까지 몇 초 간격으로
  실시간 위치를 계속 갱신해 공개한다(REQ-LIVE-001) — owner/outside/empty 세 케이스 모두 이미 있던
  `Bag.ResolveCoords` 규칙 하나로 충분해서 별도 분기 없이 구현했다.
- **기능 개별 on/off** (`server/features.lua` + `config.lua` `Config.Features`) — `/feature <이름> <on|off>`로
  `cheapAppraiser`/`trueAppraiser`/`forger`/`police`/`policeInfoLoot`/`trace`/`liveReveal` 7개를 런타임에
  켜고 끌 수 있다. 끄면 appraiser/forger/police/trace/livereveal 각 모듈이 그때그때 `Config.Features.*`를
  직접 참조하는 스폰·이벤트 분기가 전부 막히고, 이미 스폰돼 있던 NPC는 `features.lua`가 즉시 despawn한다.
  다시 켜면 모든 요소(cheapAppraiser 포함)가 각자 폴링 스케줄러의 `MarkTimelineEventOnce` 미소비
  플래그(또는 상시 폴링) 덕에 다음 tick에 알아서 "뒤늦게" 따라잡는다. `/features`로 전체 상태 조회 가능.
- **게임 시작 전 프리셋: on/off + 발동 시각** (`config_features.lua` `Config.FeaturePreset` +
  `server/featurepreset.lua`) — 서버 운영자가 매 게임 config.lua 속 사양서 확정값을 뒤지지 않고
  손쉽게 건드릴 수 있는 별도 프리셋 파일. 리소스 시작 시 자동으로 `Config.Features`/`Config.Timeline`/
  `Config.Circle`에 반영되고, `/featuretime <이름> <필드> <분>`으로 게임 시작 전(PRE_GAME/ENDED)에만
  즉석 조정도 가능하다(`/featuretimes`로 조회, `/featurereset`으로 파일 기본값 복귀). 이 작업을 하며
  cheapAppraiser 스폰을 기존의 "RUNNING 시작 시 즉시 1회 호출"에서 다른 요소들과 동일한 폴링+
  `MarkTimelineEventOnce` 스케줄러 방식으로 통합해(`Config.Timeline.cheapAppraiserSpawnAt`, 기본 0분)
  지연 스폰이 가능해졌고, 경찰의 하드코딩돼 있던 195/210분 리터럴도 `Config.Timeline.policeInfoShutdownAt`/
  `policeDespawnAt`(원래 있었지만 실제로는 읽히지 않던 필드였다) 참조로 바뀌었다.
- **서버장 임시 플레이어 모드** (`server/ownerplaymode.lua`) — `/tempplayer <on|off>`로 SERVER_OWNER 본인이
  스스로에게 PLAYER 역할을 임시로 씌우거나 벗을 수 있다. `RoleState.roles[id]`(표시 역할)와
  `RoleState.activeServerOwnerId`(관리자 신원)가 서로 독립된 필드라는 점을 이용해 roles만 PLAYER로 바꾸므로,
  NPC/이벤트(대부분 `GetRole==PLAYER && IsParticipant` 판정)는 진짜 참가자처럼 반응하면서도
  `IsServerOwner`가 그대로 true라 SERVER_OWNER 전용 명령은 전부 유지된다. 활성 세션 중에 켜면
  `sessionParticipantIds`/`playerSessions`에도 즉시 합류하고 무적이 풀리며, `/endgame`이 세션 종료마다
  활성 상태를 자동으로 전부 회수해 다음 게임으로 새어나가지 않는다.
- **GameArea 경계** (`server/gamearea.lua`, 신규) — RUNNING/FINAL_LOCKED_CONTEST 동안 참가 PLAYER가
  `Config.GameArea`(원형) 밖으로 나가면 서버가 직접 `GetEntityCoords`/`SetEntityCoords`로 감지해
  마지막으로 확인된 경계 안쪽 좌표로 되돌린다(임의 z 계산 없이 본인이 실제로 서 있던 좌표만 재사용).
  SERVER_OWNER/HELPER는 대상에서 제외(관전/관리 목적상 자유 이동). `startgame.lua`의 "GameArea wall
  활성화" TODO를 구현.
- **FinalBarrier — 경계 이동 차단** (`finalzone.lua`) — FinalZone lock 시점에 각 참가자가 있던
  쪽(안/밖)을 고정해, 그 뒤로 경계를 넘으려 하면 GameArea와 동일한 방식(마지막 자기 쪽 좌표로 복귀)
  으로 막는다. winner가 확정되면(`winnerLocked`) 자동으로 해제된다. **단, "bullets/projectiles/
  explosions/ram/damage 양방향 차단"은 미구현** — FiveM에 서버 권위형 피해 이벤트 감지 표준 API가
  없다는, death.lua가 이미 명시한 것과 동일한 한계 때문에 신뢰할 수 있게 구현할 방법이 없어 이동
  차단만 구현했다(winner 확정 후에는 어차피 전원 무적이 걸려 피해 자체가 발생하지 않는다).
- **FinalZone 내부 death respawn wait 참가자 카운트** (`finalzone.lua`/`death.lua`) — FinalZone 안에서
  죽은 참가자는 60초 부활 대기 동안 `pendingFinalZoneRespawn` 플래그로 계속 "내부"로 집계된다
  (사망 직후 ped 좌표만으로 판정하면 순간적으로 "내부 아님"으로 오판정될 수 있었던 문제 수정).
- **에러 메시지 표준화** — `inventory.lua`/`finalzone.lua`/`bag.lua`가 `Message` 테이블에 없는 맨
  문자열(`'LOCKED'`, `'TOO_FAR'` 등)을 그대로 반환해, 실패 시 플레이어 화면에 번역 없이 코드 그대로
  노출되던 버그를 고쳤다(`shared/constants.lua`에 해당 코드들의 `ErrorCode`/`Message` 항목 추가).
  겸사겸사 `FZ.TryContestPickup`에 빠져 있던 인벤토리 빈 슬롯 체크(`NO_SLOT`)도 추가.
- **관리자 조회 `finalZoneInside` 연결** (`admin_observer.lua`) — `/genuineinfo` 스냅샷의
  `finalZoneInside`가 항상 `nil`이던 TODO를 `FZ.IsInsideFinalZone`로 연결해 실제 값이 나오게 했다.
- **상단 HUD: 시계 + 다음 이벤트** (`html/index.html` + `server/hud.lua`, 신규) — 사용자 제공 목업
  그대로 구현. 화면 상단 중앙에 24pt 굵은 시계(`MM : SS`, RUNNING 시작부터 경과)와 그 아래 작은
  안내문(경찰 시스템 미사용 확정 이후 진짜 감정사 출근/이용 가능/재이용 대기 상태로 교체 —
  `secretbag:timelineSync`의 `trueApprSpawnAtMin` + `secretbag:trueApprCooldown`과 연동), 오른쪽에 다음 타임라인
  이벤트까지 남은 시간과 이름을 표시한다. 매초 서버가 전원에게 쏘는 대신, RUNNING 시작·재접속
  (`secretbag:clientReady`)·`/feature` on-off 시점에만 스냅샷(경과 ms + 켜져 있는 요소들의 남은
  이벤트 목록)을 보내고 그 사이 흐름은 `html/index.html`의 JS가 자체 타이머로 채운다. `ui_page`로
  등록된 순수 오버레이라 `SetNuiFocus`를 쓰지 않고(=게임 입력을 가리지 않음), PRE_GAME/PREP/ENDED
  에서는 숨겨진다. GTA5 게임 폰트(Pricedown 등)는 라이선스 문제로 번들할 수 없어 일반 볼드 산세리프로
  대체했다 — 정식 폰트가 있다면 `html/index.html`의 `font-family`만 교체하면 된다.

### 아직 손대지 않음
- FinalBarrier의 피해(총격/폭발/차량 램) 양방향 차단 — 위 참고, 신뢰 가능한 구현 방법이 없어 이동
  차단만 구현
- SecretBag 직접 전달(TRANSFER, 드롭 없이 바로 상대에게 넘기기) — NoteItem은 `/givenote`로 이미 가능
- 사망 안전좌표(navmesh 기반 "안전한 곳" 판정) — 지금은 deathCoords 또는 FinalZoneCenter로 단순화됨
- HUD 나머지 항목(승자/최종구역 등 추가 알림을 채팅이 아니라 화면 UI로) — 상단 시계/다음 이벤트만
  우선 구현됨(위 참고). 기획서 13장/사양서 16장에 다른 화면 요소가 더 있다면 추가 작업 필요
- DB 영속화 (현재 전부 인메모리, 서버 재시작하면 세션 소실)

## 좌표 데이터

`config.lua` 하단은 이제 사용자가 제공한 `npc_spawn_place.txt`의 실측 x,y 데이터를 쓴다.

| 항목 | 출처 | 비고 |
|---|---|---|
| `Config.GameArea` (원형, center+radius=2500) | `npc_spawn_place.txt` [플레이 영역] | 폴리곤 → 원형으로 변경 (실측 데이터 형식을 따름) |
| `Config.FinalZoneCenter` + `Config.FinalZone.radius`(=100) | [최종 목적지] | 사양서 REQ 표의 고정값(50m)과 다름 — 실측 데이터 우선 반영, 필요시 50.0으로 되돌리면 됨 |
| `Config.NpcSpawnPools.cheapAppraiser1/2` | [싸구려 감정사 1]/[싸구려 감정사 2] | 각 3개 후보, 스폰 시 랜덤 1개 선택 |
| `Config.NpcSpawnPools.trueAppraiser` | [진짜 감정사] | True#1/#2/FinalTrue가 공유(시간상 안 겹침), 매번 독립 랜덤 선택 |
| `Config.NpcSpawnPools.forger` | [위조] | 3개 후보, 스폰 시 랜덤 1개 선택 |
| 경찰 | 없음 — 좌표 자체가 불필요 | 앰비언트 스폰 방식으로 전환(아래 참고). 고정 좌표 목록이 없어 실측이 필요 없어졌다 |

**z 높이는 감정사/위조업자만 추정치**(`NPC_Z_DEFAULT = 30.0`, 최종 목적지 부두만 5.0)다. 원본 데이터가 x,y만
제공하고, 서버사이드 CreatePed/CreateObject에는 지면 높이를 구하는 표준 네이티브가 없어(클라이언트 전용)
추정할 수밖에 없었다. heading도 원본에 없어 스폰마다 `math.random(0,359)`로 랜덤 부여한다. **실서버에서
NPC가 지면에 파묻히거나 공중에 뜨면 각 좌표의 z를 인게임에서 직접 찍어 교체해야 한다.** 경찰은 이 문제 자체가
없다 — `client/main.lua`의 `secretbag:requestAmbientSpawnPoint` 핸들러가 스폰 시점마다 실시간으로
`GetGroundZFor_3dCoord`를 호출해 정확한 지면 높이를 구해오기 때문이다.

GameArea 내부 판정이 필요할 폴리곤 유틸(`SecretBagMode.Util.IsPointInPolygonXY`, `server/util.lua`)은 원형으로 바뀌며
당장은 쓰이지 않지만 남겨뒀다(다른 다각형 구역이 필요해지면 재사용 가능).

## 다음 단계 제안

1. **NPC z 높이 실측** (감정사/위조업자만 — 경찰은 실시간 계산이라 대상 아님) — 인게임에서 각 좌표에 직접 서서 z를 찍어 `NPC_Z_DEFAULT` 대신 정확한 값으로 교체
2. FinalBarrier 피해(총격/폭발/차량 램) 양방향 차단 — 이동 차단은 구현됐으나(위 참고) 피해 차단은 신뢰
   가능한 구현 방법을 아직 못 찾음. 사망 안전좌표(navmesh) 판정 고도화도 남음
3. SecretBag 직접 전달(TRANSFER) 구현
4. 킬러 귀속 + 경찰 앰비언트 스폰 좌표의 클라/네이티브 신뢰 경계 보강 (death.lua/police.lua 둘 다 클라 자가신고 성격)
5. NoteItem 프롭 모델(`prop_notepad_01`) 실존 여부 인게임 확인
6. 앰비언트 스폰 파라미터(빈도/거리/상한) + GameArea/FinalBarrier 경계 튕김 체감 실제 플레이해보며 밸런스 튜닝
7. 사양서 23장 QA 매트릭스를 그대로 테스트 체크리스트로 사용
8. NUI 나머지 요소 — 상단 시계/다음 이벤트는 구현됨(위 참고). 승자/사망 등 다른 알림도 채팅
   대신 화면 UI로 보여주고 싶다면 기획서 13장/사양서 16장의 나머지 레이아웃 확인 후 추가 구현
9. GTA5 정식 게임 폰트(Pricedown 등) 적용 — 지금은 일반 볼드 산세리프로 대체(위 HUD 항목 참고).
   폰트 파일을 구해 `html/index.html`의 `font-family` 교체 + `files`에 폰트 등록 필요

이 시점부터는 남은 항목이 전부 "완성도를 높이는" 성격이라, 실서버에 올려서 QA 매트릭스로 검증하며
발견되는 버그를 고치는 쪽이 더 이상 코드를 쌓는 것보다 가치가 클 수 있다.
