# 요소 on/off + 발동 시각 설정 가이드

서버장이 게임 요소(감정사/위조업자/경찰/추적/위치공개)를 **켜고 끄거나**, **언제 발동할지**
직접 정하는 방법을 설명한다. 디버그/치트용 `/sb*` 명령(→ [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md))과
달리, 이 문서에 나오는 명령들은 `Config.Debug.enabled`와 무관하게 항상 사용 가능한
정식 운영 기능이다.

## 설정 방법은 두 가지

| 방법 | 언제 쓰나 | 특징 |
|---|---|---|
| **A. 파일 편집** (`config_features.lua`) | 서버를 새로 켤 때마다 항상 이 값으로 시작하고 싶을 때 | 리소스 재시작(`restart GTA5TakeMoneyandRun` 또는 서버 재기동) 필요 |
| **B. 인게임 명령어** (`/feature`, `/featuretime` 등) | 서버를 켜둔 채로 이번 판만 다르게 돌려보고 싶을 때 | 즉시 적용, 재시작 불필요 |

두 방법은 같은 값을 다루므로 섞어 써도 된다 — 파일로 기본값을 잡아두고, 특정 판에서만
명령어로 잠깐 바꿨다가 `/featurereset`으로 되돌리는 식으로 쓸 수 있다.

---

## 1. on/off — 요소를 통째로 켜고 끄기

### 명령어
```
/feature <이름> <on|off>   -- 하나 켜기/끄기
/features                  -- 현재 전체 상태 조회 (서버 콘솔에도 출력)
```

### 요소 이름
| 이름 | 끄면 벌어지는 일 |
|---|---|
| `cheapAppraiser` | 싸구려 감정사 2곳이 즉시 사라짐. `/usecheap` 사용 불가 |
| `trueAppraiser` | True#1/#2/FinalTrue 전부(3개 NPC) 즉시 사라짐. `/usetrue`, `/usefinaltrue` 사용 불가 |
| `forger` | 위조업자가 즉시 사라짐. `/useforger` 사용 불가 |
| `police` | 경찰 앰비언트 스폰 중단 + 이미 있던 경찰 전부 즉시 철수. PK 페널티(추격/HOSTILE 전이)도 함께 꺼짐 |
| `policeInfoLoot` | 경찰은 그대로 순찰하지만, 죽여도 더 이상 정보(쪽지)를 주지 않음. `police` 자체와는 독립적으로 끌 수 있음 |
| `trace` | TraceCount 시스템 정지: 카운트 증가·핑 발송이 멈추고, 이미 떠 있던 핑 블립도 즉시 지워짐 |
| `liveReveal` | 150/210분 위치원 공개, 270분 이후 실시간 위치 공개가 전부 정지 |

### 언제든 즉시 반영된다
게임 시작 전이든 진행 중이든 상관없이 즉시 적용된다. 끄면:
- 이미 스폰된 NPC는 그 자리에서 바로 사라진다(despawn).
- 관련 상호작용 명령은 "아직 오지 않았습니다" 류의 메시지로 자연스럽게 막힌다.

다시 켜면:
- `cheapAppraiser`/`trueAppraiser`/`forger`/`police`는 다음 폴링(약 3~5초 이내)에 그 시점
  타임라인 조건을 다시 검사해서, 이미 지났어야 할 스폰이라면 곧바로 다시 스폰된다("뒤늦게
  따라잡기"). 즉 60분에 스폰돼야 할 True#1을 65분에 껐다가 70분에 다시 켜면, 다시 켜는
  순간 바로 스폰된다.
- `trace`/`liveReveal`도 마찬가지로 다음 폴링에 상태를 재검사해 필요한 이벤트를 다시 발동한다.

### 예시
```
/feature forger off      -- 위조업자 이벤트를 이번 판에서 완전히 빼고 싶을 때
/feature policeInfoLoot off  -- 경찰은 유지하되, 경찰을 죽여서 정보를 얻는 경로만 막고 싶을 때
/features                -- 지금 뭐가 켜져 있는지 확인
```

---

## 2. 발동 시각 — 요소가 "언제" 일어날지 정하기

### 명령어
```
/featuretime <이름> <필드> <분>   -- 특정 필드를 원하는 분(0 이상)으로 설정
/featuretime <이름>               -- 필드 생략 시 그 이름에 어떤 필드가 있는지 알려줌
/featuretimes                     -- 현재 전체 시각 설정 조회 (서버 콘솔에도 출력)
/featurereset                     -- config_features.lua의 파일 기본값으로 전부 되돌림
```

**⚠️ 게임이 진행 중(PREP~ENDED 전)일 때는 시각을 바꿀 수 없다.** 새 게임을 시작하기 전
(로비 상태, 또는 지난 게임이 `/endgame`으로 완전히 끝난 뒤)에만 바꿀 수 있다. on/off(`/feature`)는
이 제한이 없다 — 시각과 달리 on/off는 언제 바꿔도 안전하기 때문이다.

### 필드 목록

| 이름 | 필드 | 뜻 | 기본값(분) |
|---|---|---|---|
| `cheapAppraiser` | `spawnAt` | 싸구려 감정사 2곳이 스폰되는 시각 | 0 (RUNNING 즉시) |
| `trueAppraiser` | `true1Start` | True#1 스폰 시각 | 60 |
| `trueAppraiser` | `true1End` | True#1 despawn 시각 | 75 |
| `trueAppraiser` | `true2Start` | True#2 스폰 시각 | 180 |
| `trueAppraiser` | `true2End` | True#2 despawn 시각 | 195 |
| `trueAppraiser` | `finalTrueStart` | FinalTrue 스폰 시각 | 260 |
| `forger` | `spawnAt` | 위조업자 스폰 시각 | 150 |
| `police` | `ambientStartAt` | 경찰 앰비언트 스폰이 시작되는 시각 | 0 (RUNNING 즉시) |
| `police` | `infoShutdownAt` | 경찰 신규 스폰 금지 + 정보경제(정보 강탈) 종료 시각 | 195 |
| `police` | `despawnAt` | 경찰 전원 철수 시각 | 210 |
| `trace` | `bumpAt` | 전원 TraceCount +1(추적 강화) 시각 | 120 |
| `liveReveal` | `circle1500At` | 1차(넓은, 반경 750m) 위치원 공개 시각 | 150 |
| `liveReveal` | `circle100At` | 2차(좁은, 반경 50m) 위치원 공개 시각 | 210 |

(`policeInfoLoot`은 시간이 아니라 상태 기반 판정이라 시각 필드가 없다 — on/off만 가능하다.)

### 예시 — 테스트용으로 전체 타임라인을 앞당기고 싶을 때
```
/featuretime cheapAppraiser spawnAt 0
/featuretime trueAppraiser true1Start 5
/featuretime trueAppraiser true1End 8
/featuretime forger spawnAt 10
/featuretime police despawnAt 20
/featuretime trace bumpAt 3
/featuretime liveReveal circle1500At 12
/featuretimes            -- 원하는 대로 바뀌었는지 확인
/startgame
```
다 쓰고 나면 원래대로 되돌리기:
```
/featurereset
```

---

## 3. 두 기능을 합쳐서 — "이번 판은 위조업자만 없이, 나머지는 평소보다 빠르게"

```
/feature forger off
/featuretime trace bumpAt 30
/featuretime police despawnAt 60
/startgame
```

---

## 4. 서버 시작 시 항상 적용되는 기본값 바꾸기 (파일 편집)

[config_features.lua](config_features.lua)의 `Config.FeaturePreset`을 직접 편집하면, 리소스가
시작될 때마다(서버를 껐다 켤 때마다) 자동으로 이 값이 `/feature`, `/featuretime`과 똑같은
방식으로 적용된다. 예를 들어 경찰 시스템 자체를 이 서버에서는 아예 안 쓰기로 했다면:

```lua
police = {
    enabled = false,   -- 여기를 false로
    ambientStartAt = 0,
    infoShutdownAt = 195,
    despawnAt = 210,
},
```

파일을 저장한 뒤 리소스를 재시작(`restart GTA5TakeMoneyandRun`)하면 그 뒤로 서버가 켜질 때마다
경찰이 꺼진 채로 시작한다. 이 기본값은 게임 중에 `/feature police on`으로 언제든 다시 켤 수 있다.

---

## 5. 자주 헷갈리는 점

- **`/feature`는 언제든, `/featuretime`은 게임 시작 전에만.** on/off는 즉시 안전하게 반영되지만,
  시각은 이미 진행 중인 타임라인 이벤트를 "되돌릴" 방법이 없어서 막아뒀다. 예를 들어 이미 65분이
  지난 세션에서 `true1Start`를 70분으로 바꾼다고 해도, 이미 지나간 65분 시점의 스폰 여부는
  바뀌지 않는다 — 그래서 아예 게임 시작 전으로 제한했다.
- **껐다 켜면 "뒤늦게" 발동한다.** 예를 들어 100분에 `forger`를 껐다가 200분에 다시 켜면,
  원래 150분에 스폰됐어야 할 위조업자가 다시 켜는 순간(200분) 바로 스폰된다 — 150분이었을 때
  놓친 걸 버리지 않고 늦게라도 따라잡는 설계다.
- **`policeInfoLoot`과 `police`는 별개다.** 경찰 존재 자체(순찰/추격/PK 페널티)는 `police`,
  "경찰을 죽이면 정보를 주는 것"만 따로 끄고 싶으면 `policeInfoLoot`을 쓴다.
- **설정은 서버(메모리) 전역이지 세션별로 저장되지 않는다.** `/endgame` 이후에도 `/feature`,
  `/featuretime`으로 바꿔둔 값은 그대로 유지된다(다음 게임에도 적용됨). 다음 게임은 기본값으로
  시작하고 싶다면 `/featurereset`을 쓰거나 서버를 재시작한다.
