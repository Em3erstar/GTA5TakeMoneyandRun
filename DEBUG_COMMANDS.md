# SecretBag 명령어 목록 / 디버그 시나리오

`server/debug.lua`의 `/sb*` 명령은 `Config.Debug.enabled = true`일 때만 등록된다.
**실서버 배포 전 반드시 `false`로 끌 것** — genuine 강제 지급, 시간 조작, 승자 강제 확정,
가짜 참가자 등록 같은 치트성 기능이라 운영 중에 노출되면 안 된다.

디버그 명령은 `SERVER_OWNER` 또는 `PLAYER`(세션 참가자) 역할이 있으면 누구나 쓸 수 있다
(HELPER/미배정/늦참가자는 막힘).

## 핵심 설계: "혼자서 안 되는 것"을 없애는 두 가지 도구

1. **가짜 참가자 (`/sbaddfakeplayer`)** — 실제 접속 없이 세션 참가자로 등록되는 가상의 ID.
   `killerId`/`targetId`/`asPlayerId` 인자로 넘기면 "다른 사람이 한 것처럼" 실제 프로덕션
   코드(같은 함수)를 그대로 태울 수 있다. ped가 없어 좌표 기반 판정(FinalZone 내부 여부 등)에는
   항상 "없음"으로 잡히지만, 그 외 대부분의 상태(트레이스, 소유권 이력, 힌트 발급, 경찰 상태)는
   실제 참가자와 동일하게 동작한다.
2. **자기 화면 강제 표시 (`/sbtracetest` 등)** — 원래 "본인 제외 관찰자에게만" 뜨는 것들을,
   디버그 명령으로 본인 화면에도 강제로 띄워서 렌더링/로직을 직접 눈으로 확인한다.

이 두 가지를 조합하면 아래 5가지는 이제 전부 혼자서 실질적으로 검증 가능하다(기존에는 "2명
필요"로 분류했던 것들):

| 원래 "혼자 불가" 항목 | 지금 해결법 |
|---|---|
| Trace ping이 다른 사람 화면에 뜨는지 | `/sbtracetest <targetId>` — 관찰자 입장에서 오는 핑을 내 화면에 시뮬레이션, hiddenTraceTargets도 그대로 검증 |
| `/deletetraceping` 숨김 효과 | 위와 동일 — 숨긴 대상이면 `/sbtracetest`가 "핑을 못 받습니다"로 알려줌 |
| 경찰 정보강탈 공지가 다른 사람에게도 가는지 | 원래부터 `NotifyAll`/`TriggerClientEvent(-1,...)`이라 본인도 받고 있었음 (재확인만 필요) |
| NoteItem `/givenote`가 실제로 다른 유저에게 전달되는지 | `/sbforcetransfer <noteId> <targetId>` — 온라인/거리 무시하고 강제 전달, dedup 무결성은 `/sbdump`의 issuedTo로 확인 |
| FINAL_LOCKED_CONTEST 동시 pickup 원자성 | `/sbracetest [fakeId]` — 같은 tick에 두 번 호출해서 정확히 1건만 성공하는지 직접 검증 (오히려 실전 네트워크 타이밍보다 더 결정적) |

---

## 1. 일반 명령어 (실제 플레이 경로)

**근접 자동 상호작용(E키)**: 월드에 떨어진 가방/쪽지, 그리고 CheapAppraiser/True#1·#2/
FinalTrue/위조업자 NPC 전부 — 아래 표의 명령을 직접 칠 필요 없이 근처에 서면 화면 하단에
`[E] ...` 프롬프트가 뜨고 E키(GTA5 기본 픽업 키)로 바로 실행된다(client/main.lua). 명령은
호환성을 위해 그대로 남아 있고, 서버 쪽 거리/자격 검증도 동일하게 다시 이뤄진다.

| 명령 | 파일 | 권한 | 설명 |
|---|---|---|---|
| `/assignrole <id> <PLAYER\|SERVER_OWNER\|HELPER>` | state.lua | 콘솔/부트스트랩/SERVER_OWNER | 역할 배정. PRE_GAME/ENDED에서만 |
| `/emergencysetowner <id>` | state.lua | 콘솔/부트스트랩 전용 | 게임 중에도 SERVER_OWNER 강제 교체 |
| `/startgame` | startgame.lua | SERVER_OWNER | PREP 10분 카운트다운 시작 |
| `/endgame` | endgame.lua | SERVER_OWNER | 강제 종료/정상 종료, cleanup |
| `/pickupbag` | client/main.lua → inventory.lua | 참가자 | 근접 3m 이내 가장 가까운 SecretBag 줍기 |
| `/dropbag` | client/main.lua → inventory.lua | 소지자 | 소지 중인 가방 하나 드롭 |
| `/sbinventory` (기본 `I`키, `RegisterKeyMapping`으로 재바인딩 가능) | client/main.lua | 아무나 | 소지 중인 가방/쪽지 목록 창을 열고 닫는다. 가방 버리기, 쪽지 버리기/전달을 클릭으로 처리(내부적으로 기존 `tryDropBag`/`dropnote`/`givenote` 그대로 호출) |
| `/sbphone` (기본 `M`키, `RegisterKeyMapping`으로 재바인딩 가능) | client/main.lua → phone.lua | 아무나 | 전화기 UI. 현재 접속 중인 아무나(역할 무관, 서버장 포함)와 1:1 통화. 목록에서 상대를 눌러 발신, 수신 시 화면에 강제로 받기/거절 UI가 뜬다. 음성은 `MumbleSetVoiceChannel`로 거리와 무관하게 상대와만 연결됨(통화 종료 시 평소 근접 음성으로 자동 복귀) |
| `/usecheap` | appraiser.lua | 참가자/OWNER | 근처 CheapAppraiser 감정 (근접 2.5m) |
| `/usetrue` | appraiser.lua | 참가자/OWNER | 근처 True#1/#2 감정 |
| `/usefinaltrue` | appraiser.lua | 참가자/OWNER | Final True 감정 (pre/post-lock 자동 분기) |
| `/useforger` | forger.lua | 참가자/OWNER | 위조업자 상호작용 |
| `/genuineinfo` | admin_observer.lua | SERVER_OWNER | genuine 현재 상태 전체 조회 |
| `/genuinewhere` | admin_observer.lua | SERVER_OWNER | genuine 위치 관리자 핑 |
| `/genuinehistory [type]` | admin_observer.lua | SERVER_OWNER | genuine 이력 열람 (타입 필터 가능) |
| `/spawngenuine` | admin_observer.lua | SERVER_OWNER | genuine 재생성 (전방 3m world_drop) |
| `/inspectbags <targetId>` | admin_observer.lua | SERVER_OWNER | 특정 유저가 현재 소지 중인 SecretBag 전부의 진위 여부·외형 점수 조회 |
| `/giveappistol <targetId> [탄약수]` | admintools.lua | SERVER_OWNER | 특정 유저에게 AP 피스톨 지급 (기본 탄약 250) |
| `/gotoplayer <targetId>` | admintools.lua | SERVER_OWNER | 대상 유저의 3m 이내, 실제 지면 높이가 확인된 안전한 위치로 순간이동 (대상 클라이언트가 `GetGroundZFor_3dCoord`로 확인 후 응답 — police.lua 앰비언트 스폰과 동일 기법) |
| `/deletetraceping <id>` | trace.lua | 아무 참가자 | 특정 대상 Trace ping 영구 숨김 |
| `/readnote <noteId>` | hint.lua | 소지자 | 쪽지 재열람 |
| `/dropnote <noteId>` | hint.lua | 소지자 | 쪽지 드롭 |
| `/givenote <noteId> <targetId>` | hint.lua | 소지자 | 쪽지 직접 전달 (3m 이내) |
| `/pickupnote` | client/main.lua → hint.lua | 참가자/OWNER | 근접 쪽지 줍기 |
| `/feature <이름> <on\|off>` | features.lua | SERVER_OWNER | 게임 시스템 개별 on/off. 끄면 해당 NPC/이벤트가 즉시 사라지거나 더 이상 발동하지 않음. 언제든(RUNNING 중에도) 변경 가능. 이름: `cheapAppraiser`\|`trueAppraiser`\|`forger`\|`police`\|`policeInfoLoot`\|`trace`\|`liveReveal` |
| `/features` | features.lua | SERVER_OWNER | 현재 on/off 상태 전체 조회 (서버 콘솔에도 출력) |
| `/featuretime <이름> <필드> <분>` | featurepreset.lua | SERVER_OWNER | 요소별 발동 시각(분)을 게임 시작 전에만 조정. 필드 생략 시 그 이름의 필드 목록을 알려줌 (자세한 설명은 §6) |
| `/featuretimes` | featurepreset.lua | SERVER_OWNER | 현재 발동 시각 설정 전체 조회 (서버 콘솔에도 출력) |
| `/featurereset` | featurepreset.lua | SERVER_OWNER | `config_features.lua`의 프리셋 값으로 전부 되돌림 (게임 시작 전에만) |
| `/tempplayer <on\|off>` | ownerplaymode.lua | SERVER_OWNER | SERVER_OWNER 본인에게 임시로 PLAYER 역할 부여/회수. 켜져 있어도 SERVER_OWNER 전용 명령은 그대로 사용 가능 (자세한 설명은 §5) |
| `/announce <내용>` | announce.lua | SERVER_OWNER | 전체 공지. 채팅이 아니라 본인 포함 전원의 화면 중앙 살짝 아래에 GTA5 기본 폰트(Chalet London)로 36pt 상당·주황색으로 8초간 표시(client/main.lua `SetTextFont`/`BeginTextCommandDisplayText`). 크기·위치·색·지속시간은 `config.lua`의 `Config.Announcement`에서 조정 |

---

## 2. 디버그 전용 명령어 (`server/debug.lua`)

### 상태 조회
| 명령 | 설명 |
|---|---|
| `/sbdump` | 세션 전체 상태(state/genuine/모든 가방/모든 쪽지(issuedTo 포함)/모든 참가자의 police·trace·hint 상태/NPC 생존 여부)를 **서버 콘솔**에 출력. chat 리소스 없어도 확인 가능. 가짜 참가자도 함께 표시됨 |

### 시간 조작
| 명령 | 설명 |
|---|---|
| `/sbtime <분>` | mainElapsed을 강제로 이동. 스케줄러가 폴링 방식(3~5초)이라 몇 초 내로 해당 시점 이벤트가 실제로 발동함. PREP이 끝난 뒤(mainStartedAt 존재)에만 동작 |

### 가짜 참가자
| 명령 | 설명 |
|---|---|
| `/sbaddfakeplayer <id>` | 실접속 없이 세션 참가자로 등록 (예: `/sbaddfakeplayer 9001`). `session.P`는 안 바뀜 — REQ-STATE-001상 P는 세션 종료까지 불변이어야 하므로 |
| `/sbremovefakeplayer <id>` | 가짜 참가자 제거. 들고 있던 가방은 내 위치에 world_drop 처리(고아 방지) |

### 가방 / 인벤토리
| 명령 | 설명 |
|---|---|
| `/sbgive <genuine\|fake> [score]` | RNG/StartGame 없이 즉시 가방 지급. genuine 지정 시 기존 genuine 자동 제거(동시 2개 방지) |
| `/sbclearbags` | 내가 든 가방 전부 제거 (재테스트용 초기화) |
| `/sbforcepickup <bagId> [asPlayerId]` | 가방을 임의의 playerId(가짜 참가자 포함)가 주운 것으로 강제 처리. A→floor→B(ownershipChanged=true)/A→floor→A(false 유지) 검증, deathEventId 걸린 가방이면 Trace 지급까지 같이 탐. **FINAL_LOCKED_CONTEST 중 genuine이면** `TryContestPickup`으로 자동 위임(실전과 동일한 원자적 승자 확정 경로를 탐 — 직접 `Bag.OnPickup`으로 빼돌리면 세션이 영구 고착되는 버그가 있어 수정됨) |
| `/sbforcetransfer <noteId> <targetId>` | NoteItem을 온라인/거리 체크 없이 강제 전달. 원 발급자(issuedTo)는 안 바뀌는지 `/sbdump`로 확인 |

### 감정사
| 명령 | 설명 |
|---|---|
| `/sbresetcooldowns [targetId]` | CheapAppraiser(2곳 공유)/True#1/True#2/FinalTrue 상호작용 쿨다운을 전부 초기화. `ps.cooldowns.*`는 `U.Now()`(서버 가동시간 실시간 ms) 기준이라 `/sbtime`으로 게임 내 타임라인을 앞당겨도 영향받지 않음 — 혼자 반복 테스트할 때 필수. targetId 생략 시 자기 자신 |

### 경찰 / 정보강탈 / Hint
| 명령 | 설명 |
|---|---|
| `/sbforcepk [killerId]` | 실제로 안 죽여도 PK 경찰 페널티 강제 발동. killerId 생략 시 자기 자신, 가짜 참가자 지정 가능 |
| `/sbforceinfo [targetId]` | 실제로 경찰 안 죽여도 정보 강탈 강제 발동 (NEUTRAL 상태여야 함). targetId 생략 시 자기 자신 |
| `/sbpolicerelation <상태> [targetId]` | policeRelation 직접 강제 설정 (`NEUTRAL`\|`ALERT_TO_HOSTILE`\|`HOSTILE`\|`ALERT_TO_NEUTRAL`\|`ALERT_SHUTDOWN`\|`DISABLED`) |
| `/sbresetinfo [targetId]` | infoLootCount/hostile 타이머/힌트 이력 전부 초기화 + NEUTRAL 복귀 (반복 테스트용) |
| `/sbforceambientpolice` | 앰비언트 확률 굴림을 기다리지 않고 내 근처에 경찰 스폰을 즉시 강제 시도(195분 이전 + maxActive 미만 + `Config.Features.police`가 켜져 있을 때만) |
| `/sbkillpolice` | 가장 가까운 경찰 즉사. 앰비언트 루프가 나중에 다시 채우는지 확인용. **킬러 귀속은 안 될 수 있음** — 정보강탈까지 보려면 `/sbforceinfo` 별도 사용 |
| `/sbtracetest <targetId>` | 관찰자 입장에서 오는 Trace ping을 내 화면에 시뮬레이션. `/deletetraceping`으로 숨긴 대상이면 "못 받는다"고 알려줌(실제 로직 그대로 검증) |

### FinalZone / 승자 / Live Reveal
| 명령 | 설명 |
|---|---|
| `/sbforcecheck` | FinalZoneCheck를 5분 대기 없이 즉시 1회 실행 (RUNNING + 스케줄러 시작 후에만) |
| `/sbforcewin` | 승자를 즉시 확정 (나 자신). genuine이 있으면 실전 4A 경로와 동일하게 FinalZone lock부터 거친 뒤 확정한다(건너뛰면 Trace 스케줄러가 안 멈추는 버그가 있어 수정됨). 이미 확정돼 있으면 아무 일도 안 함(idempotent) |
| `/sbracetest [fakeId]` | FINAL_LOCKED_CONTEST에서 동시 pickup 시뮬레이션. 나 + 가짜ID로 같은 tick에 연속 호출 — 정확히 1건만 성공해야 정상 |
| `/sbforcecircle <1500\|100>` | 150분/210분 위치원을 즉시 공개 (genuine 필요) |

### 사망 / 부활
| 명령 | 설명 |
|---|---|
| `/sbforcedeath [killerId]` | 실제로 안 죽어도 사망 이벤트 강제 발동 (가방 드롭 + 60초 후 부활, 대상=자기 자신). killerId를 주면 PK 페널티까지 같이 테스트. 쿨다운 우회 |
| `/sbforcevictimdeath <victimId> [killerId]` | 임의의(보통 가짜) victimId가 사망한 것으로 처리. 가짜 참가자에게 `/sbforcepickup`으로 가방을 쥐어준 뒤 쓰면 "남이 죽어서 내가 주웠을 때 Trace가 오르는지" 전부 혼자 검증 가능 |

### 이동 / 좌표
| 명령 | 설명 |
|---|---|
| `/sbcoords` | 현재 좌표+헤딩 출력. NPC 스폰 z값 실측할 때 사용 |
| `/sbtp <x> <y> <z>` | 좌표 순간이동 |
| `/sbtploc <이름>` | 이름으로 순간이동: `finalzone` `gamearea` `safe` `cheap1` `cheap2` `trueappraiser` `forger` (경찰은 고정 지점이 없어 제외 — `/sbforceambientpolice` + `/sbpull police` 사용) |
| `/sbpull <종류>` | NPC를 내 앞 2m로 끌어옴: `cheap1` `cheap2` `true1` `finaltrue` `forger` `police`(스폰된 경우에만) |

---

## 3. 테스트 시나리오 모음

각 시나리오는 `/startgame` 이후, PREP이 끝나(RUNNING 진입) 있다고 가정한다.
PREP을 빨리 넘기려면 `config.lua`의 `Config.PrepDurationMs`를 임시로 줄여두면 편하다.
`config_features.lua`의 `Config.UseTestTimeline = true`(기본값)면 60/120/150/180/230/240분에
걸쳐 있던 전체 이벤트 스케줄이 0~30분 안에 전부 발생하도록 압축된 프리셋이 적용된다
(`/featuretimes`로 실제 적용값 확인 가능). **실서버 배포 전 반드시 `false`로 되돌릴 것.**

**경찰**: 사용자 확정 규칙(2026)으로 커스텀 경찰 시스템은 기본 규칙에서 완전히 미사용
(`config_features.lua`의 `police`/`policeInfoLoot`이 `enabled = false`). 코드는 남아있어
`/feature police on`, `/feature policeInfoLoot on`으로 언제든 재활성화할 수 있다. 대신 GTA5
기본 인구 시스템을 켜뒀고(client/main.lua, `SetPedPopulationBudget`/`SetVehiclePopulationBudget`),
GTA5 기본 체포 시스템은 완전히 비활성화되어(같은 파일의 `GetGamePool('CPed')` + `TaskCombatPed`
강제 루프) 수배 중인 플레이어에 대한 경찰의 기본 대응은 항상 사살이다. 참가자가 다른 참가자를
죽이면 서버가 킬러에게 항상 정확히 수배 2단계를 부여하고(server/wanted.lua) 15분간 유지하며
(사망해도 유지, 재킬 시 15분씩 누적), 시간이 끝나면 서서히 감소하지 않고 즉시 0으로 초기화된다.
킬 이외의 사유로는 수배 레벨이 바뀌지 않는다(매초 강제로 재적용).

**최초 스폰 위치**: `config.lua`의 `Config.InitialSpawnCoord`(기본 `[-152.2375, -877.6794]`) —
접속한 클라이언트가 이 세션에서 처음 받는 `playerSpawned`에서 그 좌표(z는 `GetGroundZFor_3dCoord`로
실측 보정)로 재배치된다(client/main.lua). 기본 스폰(랜덤 위치)이 잠깐 보인 뒤 곧바로 이동하는
방식이라 화면이 한 번 깜빡일 수 있다 — 정상이다.

### 시나리오 A — 감정 시스템 전체 (Cheap → True#1 → True#2 → FinalTrue)
```
/sbgive fake 45
/sbpull cheap1
/usecheap                      → "수상한 부분이 꽤 있군..." (30~44 구간 대사) 확인
/sbtime 60
/sbpull true1
/usetrue                       → "가짜입니다." 확인
/sbtime 180
/sbpull true2
/usetrue                       → True#2도 동일 확인, remainingUses 소모 확인(/sbdump)
/sbtime 260
/sbpull finaltrue
/usefinaltrue                  → pre-lock 단일 가방 판정 확인
```

### 시나리오 B — 위조업자
```
/sbgive fake 70
/sbtime 150
/sbpull forger
/useforger                     → 새 fake 지급 확인 (score는 max(0,70-20)~70 사이)
/sbdump                        → 가방 2개(원본+위조) 보유, forgedOnce=true 확인
/useforger                     → "이미 위조를 사용했습니다." (세션 1회 제한 확인)
```

### 시나리오 C — 경찰 정보강탈 → PK → 해제까지 전체 사이클
```
/sbforceinfo                   → NEUTRAL → HOSTILE 전이, infoLootCount=1, 쪽지 수령 확인
/sbdump                        → policeRelation=HOSTILE, infoHostileUntil 확인
/sbresetinfo                   → NEUTRAL로 복귀 (힌트 이력도 초기화)
/sbforcepk                     → ALERT_TO_HOSTILE(1분) → HOSTILE(5분) → ALERT_TO_NEUTRAL(1분) 전이 관찰
/sbforcepk                     → (이미 HOSTILE 상태에서) 다시 호출 — 버그 수정 확인용:
                                  policeRelation이 ALERT_TO_HOSTILE로 안 돌아가고 HOSTILE 유지 + 타이머만 연장돼야 함
```

### 시나리오 D — Hint 중복/재개방 확인 (2명 이상 독립 이력까지)
```
/sbpolicerelation NEUTRAL
/sbforceinfo                   → 힌트 1개 수령, hintId 확인(/sbdump)
/sbpolicerelation NEUTRAL      → (sbresetinfo와 달리 revealedHintIds는 유지한 채 관계만 되돌림)
/sbforceinfo                   → 직전과 다른 hintId가 나오는지 확인 (같은 게 나오면 dedup 버그)

# 서로 다른 참가자는 독립적으로 이력을 쌓는지:
/sbaddfakeplayer 9001
/sbforceinfo 9001               → 9001도 힌트 하나 받음(/sbdump로 9001의 revealedHints 개수 확인)
/sbforceinfo 9001               → 연속 호출 — 9001이 NEUTRAL이 아니게 됐으므로 아무 일도 없어야 정상
/sbpolicerelation NEUTRAL 9001
/sbforceinfo 9001               → 9001이 이미 받은 hintId는 다시 안 나오는지(자기 자신과 별개 이력인지) 확인
```

### 시나리오 E — FinalZone 5가지 우선순위 케이스 전부 (완주형)
```
# 케이스 2: genuine이 구역 밖
/sbgive genuine 90
/sbforcecheck                  → "진짜 가방이 밖에 있다!" 확인, scheduledCloseAt +5분

# 케이스 3: genuine은 안, 유효 참가자 0명
/sbtploc finalzone
/dropbag                       → genuine을 구역 안에 드롭
/sbtploc gamearea              → 자신은 구역 밖으로
/sbforcecheck                  → "아무도 최종 구역에 없다!" 확인

# 케이스 4B: genuine world_drop 상태로 구역 안 + 유효 참가자 1명 이상
/sbtploc finalzone
/pickupbag
/dropbag                       → 다시 드롭한 채로 구역 안에 남기
/sbforcecheck                  → FINAL_LOCKED_CONTEST 전이 확인 (/sbdump)

# 이 상태에서 바로 동시 pickup 원자성까지:
/sbracetest                    → 정확히 1건만 성공하는지 확인 (/sbdump로 winnerLocked=true, state=FINISHING)
```
케이스 1(SERVER_OWNER 보유)과 4A(PLAYER 소지 상태로 구역 안)를 보려면 `/endgame` 후 새 세션에서:
```
# 케이스 1
/sbgive genuine 90             → (SERVER_OWNER로 실행 시) currentOwnerId=나=activeServerOwnerId
/sbforcecheck                  → "운영자가 진짜 가방을 보유 중입니다!" 확인

# 케이스 4A
/sbtploc finalzone
/sbgive genuine 90             → (PLAYER로 실행 시) 구역 안에서 소지 상태
/sbforcecheck                  → 즉시 FINISHING 전이 확인
```

### 시나리오 F — Live Reveal 원
```
/sbgive genuine 80
/sbforcecircle 1500            → 전원에게 원 공개 (radius=750)
/sbforcecircle 100             → 더 좁은 원 (radius=50)
```

### 시나리오 G — 사망→드롭→PK, 남이 죽고 내가 주워서 Trace 오르는 것까지 (완전 솔로)
```
/sbaddfakeplayer 9001
/sbgive fake 50
/dropbag                       → 가방을 WORLD_DROP 상태로
/sbforcepickup <bagId> 9001    → 9001이 주운 것으로 처리 (ownershipChanged 확인)
/sbforcevictimdeath 9001 <내ID>  → 9001이 "나"에게 죽어서 그 가방을 드롭
/sbdump                        → deathEvents에 killerId=<내ID> 항목 확인, bagId가 world_drop인지 확인
/sbforcepickup <bagId> <내ID>   → 내가 그 가방을 주움
/sbdump                        → 내 traceCount가 1 늘었는지 확인 (REQ-TRACE-001 완전 검증)
/sbtracetest <내ID>             → "다른 관찰자였다면 이렇게 보였을 것" 시뮬레이션으로 핑 렌더링까지 확인
```

### 시나리오 H — 경찰 앰비언트 스폰/사망/디스폰
```
/sbforceambientpolice          → 확률 굴림 없이 내 근처에 즉시 스폰 시도 (클라 응답까지 몇 초)
/sbdump                        → police active count가 늘어난 것 확인
/sbpull police                 → 스폰된 경찰을 내 앞으로 끌어옴 (걸어가지 않아도 됨)
/sbkillpolice                  → 가장 가까운 경찰 즉사
/sbdump                        → police active count가 다시 줄어든 것 확인
/sbforceambientpolice          → 앰비언트 루프가 195분 전이라면 다시 채워지는지 확인

# 195분 이후 신규 스폰 금지 확인
/sbtime 200
/sbforceambientpolice          → "TOO_LATE"로 조용히 거부되어야 정상 (/sbdump로 count 안 늘어난 것 확인)

# 210분 전부 철수 확인
/sbtime 210
/sbdump                        → police active count=0, 전원 policeRelation=DISABLED 확인
```

### 시나리오 I — NoteItem 전달 무결성
```
/sbforceinfo                   → 힌트 1개 수령 (noteId 확인)
/sbaddfakeplayer 9001
/sbforcetransfer <noteId> 9001 → 9001에게 강제 전달
/sbdump                        → note.owner=9001, note.issuedTo=<내ID>(원 발급자 그대로) 확인
                                  → 내 revealedHintIds에는 그 hintId가 여전히 남아있어야 함(중복 방지 유지)
                                  → 9001의 revealedHintIds에는 안 늘어나 있어야 함(전달은 이력에 영향 없음)
```

### 시나리오 J — EndGame/Cleanup 검증
```
/sbdump                        → 종료 전 상태 스냅샷
/endgame
/sbdump                        → 세션이 없다고 나와야 정상
```
서버 콘솔에서 NPC(감정사/경찰/위조업자)가 실제로 다 사라졌는지, 보호 상태가 풀렸는지(무적 해제)
육안으로도 확인할 것.

### 시나리오 K — 기능 on/off (위조업자를 예시로)
```
/sbtime 150
/sbpull forger
/useforger                     → 정상 동작 확인 (기준선)
/feature forger off            → "위조업자가 도착했습니다" NPC가 즉시 사라지는지 확인
/useforger                     → "위조업자가 아직 오지 않았습니다." (완전히 사라졌는지 확인)
/feature forger on             → 다음 폴링(5초 내)에 forger_spawn 플래그가 뒤늦게 소비되며 다시 스폰되는지 확인
/sbpull forger
/useforger                     → 다시 정상 동작하는지 확인
/features                      → 전체 목록에서 forger=ON으로 표시되는지 확인
```
CheapAppraiser는 폴링 스케줄러가 없어 별도로 검증:
```
/feature cheapAppraiser off    → /sbpull cheap1 이 실패(대상 없음)하는지 확인
/feature cheapAppraiser on     → features.lua가 즉시 재스폰(SpawnCheap 재호출)하므로 바로 /sbpull cheap1 가능한지 확인
```
경찰 정보강탈만 따로 끄는 경우(경찰 자체는 유지):
```
/feature policeInfoLoot off
/sbforceinfo                   → NEUTRAL 유지, 정보 강탈/쪽지 발급이 전혀 없어야 정상 (policeRelation 안 바뀜)
/feature policeInfoLoot on
/sbforceinfo                   → 다시 정상적으로 힌트 발급/HOSTILE 전이 확인
```

### 시나리오 L — 서버장 임시 플레이어 모드
```
/tempplayer on                 → "이제 게임 요소들이 당신을 플레이어로 취급합니다" 확인
/sbdump                        → 내 ID가 session.sessionParticipantIds/playerSessions에 새로 포함됐는지 확인
/usecheap                      → SERVER_OWNER 전용 분기가 아니라 일반 PLAYER 분기(쿨다운/cheapVisitHistory 기록)를 타는지 확인
/startgame                     → SERVER_OWNER 전용 명령이 여전히 그대로 동작하는지 확인 (role 마스커레이드 중에도 IsServerOwner는 true)
/tempplayer off                → "임시 플레이어 모드를 껐습니다" 확인
/sbdump                        → 내 ID가 sessionParticipantIds에서 빠졌는지 확인, 무적이 다시 걸렸는지(SetPlayerWeaponDefenseModifier) 클라에서 체감 확인
/endgame                       → (tempplayer on 상태로 끝내는 경우) EndGame이 자동으로 회수하는지: 종료 후 /assignrole로 다시 확인해보면 role이 SERVER_OWNER로 남아있어야 정상
```

### 시나리오 M — 발동 시각 프리셋 (게임 시작 전 조정)
```
/featuretimes                  → 기본값(config_features.lua) 그대로인지 확인
/featuretime forger spawnAt 1  → 위조업자를 150분이 아니라 1분에 스폰되도록 변경
/featuretime police despawnAt 3 → 경찰을 3분에 전원 철수하도록 변경
/startgame
# PREP 10분 종료 후(RUNNING):
/featuretime forger spawnAt 5  → "게임이 진행 중일 때는 시각을 바꿀 수 없습니다" 메시지로 거부되는지 확인 (RUNNING 중 변경 차단)
/sbtime 1                      → forger가 1분 조건을 이미 넘겼으므로 바로 스폰되는지 확인 (/sbpull forger)
/sbtime 3                      → police가 3분 조건에 despawn되는지 확인 (/sbdump로 count=0, policeRelation=DISABLED)
/endgame
/featurereset                  → 다시 기본값(150분/210분)으로 복구되는지 /featuretimes로 확인
```

---

## 4. 그래도 완전히 똑같지는 않은 것 (참고만)

아래는 위 도구들로 **로직 자체는 100% 검증 가능**하지만, "진짜 다른 사람 화면에 실제로 렌더링되는지"의
최종 확인은 여전히 실제 클라이언트 2대가 있을 때 더 확실하다. 코드 경로는 동일하게 타므로 실전에서
다르게 동작할 가능성은 낮다:
- Trace ping 블립이 실제 타인 화면에서 정확한 좌표/이름으로 보이는지 (로직은 `/sbtracetest`로 검증됨)
- 경찰 정보강탈 공지/핑이 실제 타인 화면에서도 보이는지 (원래 전체 브로드캐스트라 이미 자신도 받고 있었음)
- FINAL_LOCKED_CONTEST 실제 네트워크 동시 요청 타이밍 (원자성 자체는 `/sbracetest`가 더 결정적으로 검증)

---

## 5. `/tempplayer` 설계 메모

`SecretBagMode.RoleState.roles[id]`(표시 역할, `GetRole`이 반환)와
`SecretBagMode.RoleState.activeServerOwnerId`(관리자 신원, `IsServerOwner`가 검사하는 값)는
`server/state.lua`에서 서로 완전히 독립된 필드다. `/tempplayer on`은 `roles[id]`만 `PLAYER`로
바꾼다 — `activeServerOwnerId`는 그대로 자신을 가리키므로:
- NPC/이벤트(대부분 `GetRole==PLAYER && IsParticipant` 조합으로 판정)는 이 유저를 진짜
  참가자처럼 대한다.
- `IsServerOwner(id)`는 여전히 `true`라서 `/startgame`, `/endgame`, `/assignrole`, `/sb*` 등
  SERVER_OWNER 전용 커맨드는 그대로 전부 사용할 수 있다.
- `FZ.TryContestPickup`은 `IsServerOwner`를 직접 검사해 최종 우승자가 되는 것만은 여전히 막는다
  (마스커레이드 중에도 진짜 승자가 될 수는 없음 — 의도된 안전장치).

세션이 이미 PREP/RUNNING 중일 때 켜면 `session.sessionParticipantIds`/`playerSessions`에도
즉시 추가되어("합류") 그 게임에도 바로 반영된다. `server/endgame.lua`의 `performEndGame`이
세션 종료마다 활성 `tempPlayerMode`를 전부 자동으로 꺼주므로, 껐다 켜는 것을 잊고 다음 게임으로
넘어가도 다음 `/startgame`의 참가자 스캔에 실수로 포함되지 않는다.

---

## 6. `/featuretime` / `config_features.lua` 설계 메모

**두 계층으로 나뉜다:**
1. **파일 프리셋** (`config_features.lua`의 `Config.FeaturePreset`) — 서버 시작(리소스 start) 시
   `server/featurepreset.lua`가 자동으로 `Config.Features`/`Config.Timeline`/`Config.Circle`에
   그대로 덮어쓴다. 서버 운영자가 매번 `/featuretime`을 치지 않고 파일 하나만 편집해두면
   재시작할 때마다 그 값으로 시작하고 싶을 때 사용한다.
2. **런타임 조정** (`/featuretime`, `/featuretimes`, `/featurereset`) — 서버를 재시작하지 않고
   즉석에서 이번 판만 다르게 돌려보고 싶을 때 사용한다. 값은 `Config.Timeline`/`Config.Circle`을
   직접 수정하므로, 각 모듈(appraiser/forger/police/trace/livereveal)이 이미 그 값을 그때그때
   읽어가는 기존 구조를 그대로 재사용한다 — 별도의 "런타임 상태 테이블"이 따로 있는 게 아니다.

**필드 목록** (`/featuretime <이름> <필드> <분>`):

| 이름 | 필드 | 기본값(분) | 실제 대응 Config 경로 |
|---|---|---|---|
| `cheapAppraiser` | `spawnAt` | 0 | `Config.Timeline.cheapAppraiserSpawnAt` |
| `trueAppraiser` | `spawnAt` | 60 (디스폰 없이 영구 유지) | `Config.Timeline.trueAppraiserSpawnAt` |
| `trueAppraiser` | `finalTrueStart` | 230 | `Config.Timeline.finalTrueStart` |
| `forger` | `spawnAt` | 120 | `Config.Timeline.forgerSpawnAt` |
| `police` | `ambientStartAt` | 0 (미사용) | `Config.Timeline.policeAmbientStartAt` |
| `police` | `infoShutdownAt` | 165 (미사용) | `Config.Timeline.policeInfoShutdownAt` |
| `police` | `despawnAt` | 180 (미사용) | `Config.Timeline.policeDespawnAt` |
| `trace` | `bumpAt` | 120 | `Config.Timeline.traceBumpAt` |
| `liveReveal` | `circle1500At` / `circle100At` | 150 / 180 (반경 500m / 75m) | `Config.Circle.circle1500/circle100.atMinute` |
| `liveReveal` | `finalZonePreviewAt` | 210 (최종 구역 자체 미리 공개, 반경 `Config.FinalZone.radius`) | `Config.Circle.finalZonePreview.atMinute` |
| `finalCheck` | `firstAt` / `intervalMin` | 240 / 5 | `Config.Timeline.finalCheckFirstAt/finalCheckIntervalMin` |

(두 번째 진짜 감정사는 사용자 확정 규칙(2026)으로 완전히 삭제됐다. `trueAppraiser`는 이제
`spawnAt` 하나만 있으며, 등장 이후 디스폰 없이 게임 종료까지 유지된다.)

(`policeInfoLoot`은 시간 트리거가 없는 순수 판정 분기라 `/featuretime` 대상이 아니다 — `/feature`로
on/off만 가능.)

위 "기본값"은 `Config.UseTestTimeline = false`(실서버) 기준이다. 현재처럼 `true`(TEMP-TESTING,
config_features.lua)면 `/featuretimes` 출력이 0~30분 압축 프리셋값(예: `trueAppraiser.true1Start = 3`)으로
나온다 — 놀라지 말 것, 정상이다.

**왜 RUNNING 중엔 막아두는가**: 각 모듈의 스폰/despawn 판정은 `SecretBagMode.MarkTimelineEventOnce`로
세션당 1회만 통과하는 플래그를 쓴다. 예를 들어 `elapsed`가 이미 160분을 지난 세션에서
`forgerSpawnAt`을 200분으로 바꿔봐야 `elapsed >= 200`이 될 때까지 그냥 대기 상태가 될 뿐이고,
반대로 이미 지나간 시각으로 바꾸면 다음 폴링에 즉시(의도치 않게) 발동해버린다 — 세션 진행 중에는
직관적이지 않은 부작용이 생기기 쉬워 아예 게임 시작 전(`SecretBagMode.CanStartGame()==true`,
즉 세션 없음 또는 ENDED+cleanup 완료)으로만 제한했다. `cheapAppraiser`/`police`의 시작 시각도
같은 이유로 RUNNING 중에는 조정할 수 없다.
