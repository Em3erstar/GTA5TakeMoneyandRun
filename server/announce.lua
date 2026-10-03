--- 전체 공지 시스템 (사용자 요청). SERVER_OWNER가 /announce로 쓰면 본인 포함 전원의
--- 화면에 큼직하게 표시된다 — 채팅창이 아니라 client/main.lua의 GTA5 네이티브 텍스트
--- 렌더링(화면 중앙 살짝 아래, GTA5 기본 폰트, 36pt 상당, 주황색)으로 출력된다.
--- 표시 방식/지속시간/크기/색상은 config.lua의 Config.Announcement에서 조정한다.

local U = SecretBagMode.Util

RegisterCommand('announce', function(source, args)
    if not SecretBagMode.IsServerOwner(source) then
        U.NotifyPlayer(source, SecretBagMode.Message.NO_ACCESS)
        return
    end

    local text = table.concat(args, ' ')
    if text == '' then
        U.NotifyPlayer(source, '사용법: /announce <공지 내용>')
        return
    end

    print(('[SecretBag] (공지) %s'):format(text))
    TriggerClientEvent('secretbag:announce', -1, text)
end, false)
