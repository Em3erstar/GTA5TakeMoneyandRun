fx_version 'cerulean'
game 'gta5'

author 'SecretBag Mode'
description 'GTA V 비밀 가방 추적 게임모드 (standalone, server-authoritative)'
version '0.1.0'

shared_scripts {
    'config.lua',
    'config_features.lua', -- 게임 시작 전 on/off + 발동 시각 프리셋 (server/featurepreset.lua가 적용)
    'shared/constants.lua',
}

server_scripts {
    'server/util.lua',
    'server/wanted.lua',
    'server/state.lua',
    'server/bag.lua',
    'server/inventory.lua',
    'server/hint.lua',
    'server/death.lua',
    'server/prep.lua',
    'server/ownerplaymode.lua',
    'server/startgame.lua',
    'server/endgame.lua',
    'server/appraiser.lua',
    'server/trace.lua',
    'server/police.lua',
    'server/forger.lua',
    'server/finalzone.lua',
    'server/livereveal.lua',
    'server/gamearea.lua',
    'server/hud.lua',
    'server/featurepreset.lua',
    'server/features.lua',
    'server/admin_observer.lua',
    'server/announce.lua',
    'server/admintools.lua',
    'server/phone.lua',
    'server/debug.lua', -- Config.Debug.enabled=false로 끄면 통째로 비활성화됨. 배포 전 끌 것.
}

client_scripts {
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
}

lua54 'yes'
