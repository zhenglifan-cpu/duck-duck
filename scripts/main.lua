-- ============================================================================
-- main.lua — 《赶鸭子上架》入口路由
-- 根据运行模式加载对应模块：Client / Server
-- ============================================================================

local Module = nil

function Start()
    if IsServerMode() then
        print("[Main] 启动服务端模式")
        Module = require("network.Server")
    elseif IsNetworkMode() then
        print("[Main] 启动客户端模式")
        Module = require("network.Client")
    else
        print("[Main] 单机模式已移除，请在联机运行模式启动")
        return
    end
    Module.Start()
end

function Stop()
    if Module and Module.Stop then
        Module.Stop()
    end
end
