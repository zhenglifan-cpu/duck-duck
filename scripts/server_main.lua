-- ============================================================================
-- server_main.lua — 联机模式服务端入口
-- ============================================================================

local Server = require("network.Server")

function Start()
    print("[ServerMain] 启动服务端")
    Server.Start()
end

function Stop()
    if Server.Stop then
        Server.Stop()
    end
end
