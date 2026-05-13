-- ============================================================================
-- client_main.lua — 联机模式客户端入口
-- ============================================================================

local Client = require("network.Client")

function Start()
    print("[ClientMain] 启动客户端")
    Client.Start()
end

function Stop()
    if Client.Stop then
        Client.Stop()
    end
end
