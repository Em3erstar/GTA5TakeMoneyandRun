# 설치 가이드 — 다른 서버에 비밀가방(SecretBag) 설치하기

이 문서는 **이 게임모드를 만든 사람이 아니라, 자기 FiveM 서버에 이 모드를 새로 설치해서
운영하려는 사람**을 위한 가이드입니다. FXServer를 켜본 적이 있고 `server.cfg` 정도는
다뤄본 적이 있는 서버 운영자를 기준으로 설명합니다.

플레이어에게 보여줄 "게임 켜는 법 / 플레이 방법" 안내서는 이 문서가 아니라
[SecretBag_사용설명서.pdf](SecretBag_사용설명서.pdf)를 참고하세요. 이 문서는 그 전 단계,
즉 리소스 자체를 서버에 설치하고 운영 가능한 상태로 만드는 과정만 다룹니다.

## 1. 준비물

- 정상 동작하는 **FXServer** (Cfx.re 공식 서버 빌드)와 `server-data` 폴더
- **본인 서버용 GTA5 라이선스 키** — [Cfx.re Keymaster](https://keymaster.fivem.net/)에서
  본인이 직접 발급받아야 합니다. 다른 서버의 키를 재사용할 수 없고, 재사용하면 안 됩니다.
- FXServer 표준 리소스 4종: `mapmanager`, `basic-gamemode`, `spawnmanager`, `baseevents`
  (보통 `server-data`에 기본 포함되어 있습니다)
- FXServer에 내장된 `chat` 리소스 — 채팅창(T키)과 `/`로 시작하는 명령어 입력에
  필수입니다. 이게 없으면 이 모드의 모든 명령어가 전혀 작동하지 않습니다.

## 2. 리소스 복사

1. 이 저장소를 내려받습니다 (`git clone` 또는 GitHub에서 zip 다운로드 후 압축 해제).
2. `GTA5TakeMoneyandRun` 폴더 전체를 서버의 `resources/[아무 분류 폴더]/` 아래에
   그대로 복사합니다. 예: `resources/[local]/GTA5TakeMoneyandRun`.
   - 폴더 이름(`GTA5TakeMoneyandRun`)이 곧 리소스 이름이 됩니다. 폴더 이름을 바꾸면
     아래 `server.cfg`의 `ensure` 줄도 그 이름에 맞게 바꿔야 합니다.

## 3. server.cfg 설정

아래 내용을 참고해 `server.cfg`에 추가하세요 (실제 값은 본인 환경에 맞게 채우세요):

```cfg
# ---- 기본 네트워크 설정 ----
endpoint_add_tcp "0.0.0.0:30120"
endpoint_add_udp "0.0.0.0:30120"

sv_hostname "내 서버 이름"
sv_maxclients 32

# ---- 라이선스 키 (필수, 본인 키로 교체) ----
sv_licenseKey "본인이 Keymaster에서 발급받은 키"

# ---- 부트스트랩 관리자 ----
# /assignrole, 긴급 /emergencysetowner 를 쓸 수 있는 서버ID 목록(콤마로 구분).
# 서버에 처음 접속하는 사람이 보통 1번이다.
# 반드시 아래 "ensure GTA5TakeMoneyandRun"보다 위에 있어야 한다 — 리소스가 시작되는
# 순간(onResourceStart)에 이 값을 딱 한 번만 읽기 때문에, 순서가 바뀌면 여기 적은
# 번호가 실제로는 관리자로 인식되지 않는다.
setr secretbag_bootstrap_admins "1"

# ---- 기본 리소스 ----
ensure mapmanager
ensure basic-gamemode
ensure spawnmanager
ensure baseevents
ensure chat

# ---- 비밀가방 모드 ----
ensure GTA5TakeMoneyandRun

sv_enforceGameBuild 2699
```

## 4. 처음 켜기 전에 반드시 확인할 설정값

이 저장소의 `config.lua` / `config_features.lua`에는 **개발 중 테스트용으로 낮춰둔 값**이
그대로 들어 있습니다. 코드 안에도 `TEMP-TESTING: 실제 배포 전 반드시 되돌릴 것!` 주석이
달려 있으니, 실제로 정식 플레이를 하기 전에 아래 값들을 검토하세요.

| 파일 | 설정 | 현재 기본값 | 정식 운영 권장값 |
|---|---|---|---|
| `config.lua` | `Config.Debug.enabled` | `true` | `false` — `true`면 `/sb*` 치트성 디버그 명령어(가방 강제 지급, 시간 조작 등)가 전부 활성화됩니다. SERVER_OWNER 전용이긴 하지만, 운영 중에는 꺼두는 것이 안전합니다. |
| `config.lua` | `Config.MinPlayers` | `1` | `4` (원 기획 기준 최소 인원) |
| `config.lua` | `Config.PrepDurationMs` | `30 * 1000` (30초) | `5 * 60 * 1000` (5분) |
| `config_features.lua` | `Config.UseTestTimeline` | `true` | `false` — `true`면 전체 게임 타임라인이 약 10분으로 압축된 테스트 프리셋(`testPreset10Min`)으로 동작합니다. `false`로 바꾸면 정식 타임라인(`productionPreset`, 약 4시간 이상)이 적용됩니다. |

`/feature`, `/featuretime`, `/featuretimes`, `/featurereset` 명령으로 서버를 끄지 않고도
게임 시작 전(PRE_GAME/ENDED 상태)에 즉석으로 조정할 수 있습니다 — 자세한 사용법은
[FEATURE_TOGGLE_GUIDE.md](FEATURE_TOGGLE_GUIDE.md)를 참고하세요.

좌표 관련 설정(`Config.FinalZoneCenter`, `Config.NpcSpawnPools`, `Config.GameArea`)은
이미 실측된 GTA5 기본 맵 좌표가 들어 있어 수정 없이 바로 사용할 수 있습니다. 다른 위치를
쓰고 싶다면 [npc_spawn_place.txt](npc_spawn_place.txt)를 참고해 교체하세요.

## 5. 서버 실행 및 확인

서버를 켠 뒤 콘솔에 `Started resource GTA5TakeMoneyandRun`이 보이면 정상 설치된
것입니다. 에러가 뜬다면 3번의 `server.cfg` 순서(특히 `secretbag_bootstrap_admins`가
`ensure GTA5TakeMoneyandRun`보다 위에 있는지)와 2번의 리소스 경로를 다시 확인하세요.

## 6. 참고 문서

- [SecretBag_사용설명서.pdf](SecretBag_사용설명서.pdf) — 플레이어/방장을 위한 실제 플레이
  안내서 (서버 켜기, 친구 초대, 게임 시작, 조작법, 승리 조건)
- [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md) — `/sb*` 디버그 명령어 전체 목록
- [FEATURE_TOGGLE_GUIDE.md](FEATURE_TOGGLE_GUIDE.md) — 기능 on/off 및 타이밍 조정 방법
- [README.md](README.md) — 구현된 시스템 전체에 대한 기술적인 설명

## 7. 알아두어야 할 한계

- 게임 진행 상태는 전부 **메모리에서만** 관리됩니다 — 서버를 재시작하면 진행 중이던
  게임은 사라집니다 (별도 DB 저장 없음).
- 사망/킬러 판정, 경찰 NPC 스폰 좌표 등 일부는 클라이언트가 보고한 값을 서버가
  참가자 여부만 재검증하는 수준입니다 — 악의적인 클라이언트의 조작 여지가 이론상
  남아 있습니다 (각 파일 상단 주석에 상세히 설명되어 있습니다). 친한 사람들끼리
  캐주얼하게 즐기는 용도로는 문제없지만, 불특정 다수를 대상으로 하는 공개 서버에서는
  이 점을 감안하세요.
