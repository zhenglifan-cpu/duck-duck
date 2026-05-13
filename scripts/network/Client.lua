-- ============================================================================
-- Client.lua — 《赶鸭子上架》多人客户端逻辑
-- 职责：渲染、等距相机、输入采集+转发、鸭子/矮人视觉、HUD
-- ============================================================================

local Client = {}
local Shared = require("network.Shared")
local DuckRenderer = require("entity.DuckRenderer")
local DwarfRenderer = require("entity.DwarfRenderer")
local MapPreviewCamera = require("MapPreviewCamera")
local AudioManager = require("audio.AudioManager")
local MapEditor = require("MapEditor")
local TerrainEditor = require("TerrainEditor")
local UI = require("urhox-libs/UI")
local AstroonTheme = require("config.AstroonTheme")

require "LuaScripts/Utilities/Sample"

-- ============================================================================
-- 快捷引用
-- ============================================================================

local Config = Shared.Config
local EVENTS = Shared.EVENTS
local CTRL   = Shared.CTRL
local VARS   = Shared.VARS

-- ============================================================================
-- 变量
-- ============================================================================

---@type Scene
local scene_ = nil
---@type Node
local cameraNode_ = nil
---@type Node
local myRoleNode_ = nil
local myRoleIndex_ = 0

-- 连接状态
local needSendReady_ = false
local pendingNodeId_ = 0
local pendingNodes_ = {}     -- 所有待处理的复制节点 ID（NodeAdded 时名称/vars 可能尚未同步）

-- 已设置渲染的节点
local renderedRoles_ = {}  -- nodeId -> true
local renderedDucks_ = {}  -- nodeId -> true

-- 鸭子状态追踪（用于检测状态变化触发音效）
local prevDuckStates_ = {}  -- nodeId -> previous state string
local idleQuackTimer_ = 0   -- 闲逛鸭子随机叫声计时器

-- 玩家状态
local clapCooldown_ = 0.0
local clapAnimTimer_ = 0.0
local isMoving_ = false
local gameTime_ = 0.0

-- 鸭子上架计数（来自服务端事件）
local settledCount_ = 0
local totalDucks_ = #Config.Level1.DuckPositions
local starRating_ = 0

-- 金币系统
local totalGold_ = 0    -- 玩家总金币余额（从云端加载）
local earnedGold_ = 0   -- 本局获得的金币

-- 游戏状态
local gameState_ = Config.GameState.PLAYING

-- UI
local uiRoot_ = nil
---@type table
local hudLabels_ = {}

-- 世界反馈
local pingMarkers_ = {}
local breadPickupNode_ = nil
local breadActiveNode_ = nil
local breadState_ = {
    state = "available",
    ownerRole = 0,
    pickupPos = Config.Level1.BreadcrumbPos,
    activePos = nil,
    timeLeft = 0,
}

-- 延迟回调
local pendingCallbacks_ = {}

-- 闪屏动画
local splashVg_ = nil
local splashImage_ = -1
local splashImageW_ = 0
local splashImageH_ = 0
local splashTimer_ = 0
local splashActive_ = false
local SPLASH_ANIM_DURATION = 1.0   -- 旋转缩放入场（快速）
local SPLASH_HOLD_DURATION = 2.0   -- 标题静态展示
local SPLASH_FADE_DURATION = 1.0   -- 渐隐退出

-- ============================================================================
-- 入口
-- ============================================================================

function Client.Start()
    SampleStart()

    Shared.RegisterEvents()
    InitUI()

    scene_ = Shared.CreateScene(false)

    SetupCamera()
    CreateHUD()

    -- 订阅事件
    SubscribeToEvent(EVENTS.ASSIGN_ROLE, "HandleAssignRole")
    SubscribeToEvent(EVENTS.PING_BROADCAST, "HandlePingBroadcast")
    SubscribeToEvent(EVENTS.BREAD_STATE, "HandleBreadState")
    SubscribeToEvent(EVENTS.DUCK_SETTLED, "HandleDuckSettled")
    SubscribeToEvent(EVENTS.DUCK_ESCAPED, "HandleDuckEscaped")
    SubscribeToEvent(EVENTS.GAME_RESULT, "HandleGameResult")
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostRenderUpdate", "HandlePostRenderUpdate")
    SubscribeToEvent(scene_, "NodeAdded", "HandleNodeAdded")

    -- 关联场景到连接（可能此时连接尚未建立，HandleUpdate 中重试）
    local serverConn = network:GetServerConnection()
    if serverConn then
        serverConn.scene = scene_
        print("[Client] 已关联 scene 到 serverConn")
    else
        print("[Client] serverConn 尚未建立，将在 HandleUpdate 中重试")
    end

    -- 初始化地图预览相机
    MapPreviewCamera.Init(cameraNode_, scene_)

    -- 初始化地图编辑器（传入 getter 以确保始终获取最新的 uiRoot_）
    MapEditor.Init(cameraNode_, scene_, function() return uiRoot_ end)

    -- 初始化地形规划编辑器（传入 getter 以确保始终获取最新的 uiRoot_）
    TerrainEditor.Init(cameraNode_, scene_, function() return uiRoot_ end)

    -- 初始化音频并播放背景音乐
    AudioManager.Init(scene_)
    AudioManager.PlayMusic()

    -- 闪屏动画（3s 旋转放大 + 1.5s 渐隐）
    InitSplash()

    -- 从云端加载金币余额
    if clientCloud then
        clientCloud:Get("gold", {
            ok = function(values, iscores)
                totalGold_ = iscores.gold or 0
                print("[Client] 云端金币余额: " .. totalGold_)
                if hudLabels_.goldLabel then
                    hudLabels_.goldLabel.text = "💰 " .. totalGold_
                end
            end,
            error = function(code, reason)
                print("[Client] 加载金币失败: " .. tostring(reason))
            end,
        })
    else
        print("[Client] clientCloud 尚未就绪，跳过金币加载")
    end

    needSendReady_ = true
    print("[Client] 《赶鸭子上架》客户端已启动")
end

function Client.Stop()
    if splashActive_ then EndSplash() end
    UI.Shutdown()
end

-- ============================================================================
-- UI 初始化
-- ============================================================================

function InitUI()
    AstroonTheme.InitUI()
end

-- ============================================================================
-- 闪屏动画
-- ============================================================================

function InitSplash()
    splashVg_ = nvgCreate(1)
    if splashVg_ == nil then
        print("[Client] 闪屏 NanoVG 创建失败")
        splashActive_ = false
        return
    end

    -- flag=0 加载（与引擎 UI 库一致，避免 KTX 格式不兼容）
    splashImage_ = nvgCreateImage(splashVg_, "image/标题.png", 0)
    if splashImage_ <= 0 then
        print("[Client] 标题图片加载失败")
        splashActive_ = false
        nvgDelete(splashVg_)
        splashVg_ = nil
        return
    end

    -- 硬编码原始 PNG 像素尺寸（nvgImageSize / Image 资源在 Web 平台不可靠）
    splashImageW_ = 2048
    splashImageH_ = 524
    print("[Client] 标题图片: " .. splashImageW_ .. "x" .. splashImageH_)

    SubscribeToEvent(splashVg_, "NanoVGRender", "HandleSplashRender")

    -- 完全移除 UI 根节点，确保闪屏期间不渲染任何 HUD
    UI.SetRoot(nil)

    splashTimer_ = 0
    splashActive_ = true
end

function HandleSplashRender(eventType, eventData)
    if not splashActive_ or splashVg_ == nil then return end

    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local dpr = graphics:GetDPR()
    -- 使用逻辑分辨率 + DPR，确保高 DPI 屏下清晰渲染
    local screenW = physW / dpr
    local screenH = physH / dpr

    nvgBeginFrame(splashVg_, screenW, screenH, dpr)

    -- 三阶段时间轴：入场动画 → 静态展示 → 渐隐退出
    local animScale = 1.0
    local rotation = 0
    local alpha = 1.0

    if splashTimer_ < SPLASH_ANIM_DURATION then
        -- 阶段1：旋转缩放入场
        local animProgress = splashTimer_ / SPLASH_ANIM_DURATION
        local eased = 1.0 - (1.0 - animProgress) ^ 3  -- ease-out cubic
        animScale = 0.3 + 0.7 * eased       -- 从 30% → 100%
        rotation = (1.0 - eased) * math.pi * 2  -- 从 360° → 0°
    elseif splashTimer_ < SPLASH_ANIM_DURATION + SPLASH_HOLD_DURATION then
        -- 阶段2：静态展示（标题完整可见）
        animScale = 1.0
        rotation = 0
    else
        -- 阶段3：渐隐退出
        local fadeProgress = (splashTimer_ - SPLASH_ANIM_DURATION - SPLASH_HOLD_DURATION) / SPLASH_FADE_DURATION
        fadeProgress = math.min(fadeProgress, 1.0)
        alpha = 1.0 - fadeProgress
    end

    nvgGlobalAlpha(splashVg_, alpha)

    -- 白色背景（覆盖全屏）
    nvgBeginPath(splashVg_)
    nvgRect(splashVg_, 0, 0, screenW, screenH)
    nvgFillColor(splashVg_, nvgRGBA(255, 255, 255, 255))
    nvgFill(splashVg_)

    -- 计算图片目标尺寸（屏幕像素宽度 61.8%，保持原始比例，无形变）
    -- 用户要求：最终显示宽度 = 屏幕像素宽度 × 61.8%
    -- 在逻辑坐标系下：targetW = (physW * 0.618) / dpr
    local targetW = physW * 0.618 / dpr
    local imgAspect = splashImageW_ / splashImageH_
    local targetH = targetW / imgAspect

    local drawW = targetW * animScale
    local drawH = targetH * animScale

    -- 居中旋转绘制
    local cx = screenW / 2
    local cy = screenH / 2

    nvgSave(splashVg_)
    nvgTranslate(splashVg_, cx, cy)
    nvgRotate(splashVg_, rotation)

    local imgPaint = nvgImagePattern(
        splashVg_, -drawW / 2, -drawH / 2, drawW, drawH, 0, splashImage_, 1.0
    )
    nvgBeginPath(splashVg_)
    nvgRect(splashVg_, -drawW / 2, -drawH / 2, drawW, drawH)
    nvgFillPaint(splashVg_, imgPaint)
    nvgFill(splashVg_)

    nvgRestore(splashVg_)
    nvgEndFrame(splashVg_)
end

function UpdateSplash(dt)
    if not splashActive_ then return end

    splashTimer_ = splashTimer_ + dt

    if splashTimer_ >= SPLASH_ANIM_DURATION + SPLASH_HOLD_DURATION + SPLASH_FADE_DURATION then
        EndSplash()
    end
end

function EndSplash()
    splashActive_ = false

    if splashVg_ then
        if splashImage_ > 0 then
            nvgDeleteImage(splashVg_, splashImage_)
        end
        nvgDelete(splashVg_)
        splashVg_ = nil
    end

    -- 恢复游戏 HUD（重新设置 UI 根节点）
    if uiRoot_ then
        UI.SetRoot(uiRoot_)
    end

    print("[Client] 闪屏结束，进入游戏")
end

-- ============================================================================
-- 相机
-- ============================================================================

function SetupCamera()
    cameraNode_ = scene_:CreateChild("Camera", LOCAL)
    local camera = cameraNode_:CreateComponent("Camera", LOCAL)
    camera.fov = Config.Camera.Fov
    camera.nearClip = Config.Camera.NearClip
    camera.farClip = Config.Camera.FarClip

    renderer:SetViewport(0, Viewport:new(scene_, camera))
    renderer.hdrRendering = true

    -- 固定等距相机
    Shared.SetupIsometricCamera(cameraNode_)
end

-- ============================================================================
-- HUD
-- ============================================================================

function CreateHUD()
    local T = AstroonTheme.Tokens

    uiRoot_ = UI.Panel {
        id = "gameHUD",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            -- 顶部信息栏（宇宙主题深色面板）
            UI.Panel {
                id = "topBar",
                position = "absolute",
                top = 12,
                left = "50%",
                translateX = -1,
                width = 650,
                height = 50,
                justifyContent = "center",
                alignItems = "center",
                flexDirection = "row",
                gap = 20,
                backgroundColor = T.surface,
                borderRadius = 9999,
                borderWidth = 1,
                borderColor = T.border,
                boxShadow = {
                    { x = 0, y = 4, blur = 12, spread = 0, color = T.shadow },
                },
                children = {
                    UI.Label {
                        id = "goldLabel",
                        text = "💰 " .. totalGold_,
                        fontSize = 18,
                        fontWeight = "bold",
                        fontColor = { 255, 215, 0, 255 },
                    },
                    UI.Label {
                        id = "duckCount",
                        text = "🦆 0 / " .. totalDucks_,
                        fontSize = 22,
                        fontWeight = "bold",
                        fontColor = T.text,
                    },
                    UI.Label {
                        id = "starLabel",
                        text = "☆☆☆",
                        fontSize = 22,
                        fontWeight = "bold",
                        fontColor = T.primary,
                    },
                    UI.Label {
                        id = "timeLabel",
                        text = "⏱ 00:00",
                        fontSize = 18,
                        fontColor = T.textSecondary,
                    },
                    UI.Label {
                        id = "breadLabel",
                        text = "🍞 地图上",
                        fontSize = 16,
                        fontWeight = "bold",
                        fontColor = { 255, 220, 120, 255 },
                    },
                },
            },
            -- 底部操作提示（半透明胶囊）
            UI.Panel {
                id = "controlHintBar",
                position = "absolute",
                bottom = 12,
                left = "50%",
                translateX = -1,
                width = 720,
                height = 36,
                justifyContent = "center",
                alignItems = "center",
                backgroundColor = { T.background[1], T.background[2], T.background[3], 180 },
                borderRadius = 9999,
                borderWidth = 1,
                borderColor = T.border,
                children = {
                    UI.Label {
                        id = "controlHint",
                        text = "WASD 移动 | Shift 冲刺 | 空格 拍手 | E 撒面包 | 1-4 标记 | P 预览",
                        fontSize = 13,
                        fontColor = T.textMuted,
                        textAlign = "center",
                    },
                },
            },
        },
    }

    UI.SetRoot(uiRoot_)

    hudLabels_.goldLabel = uiRoot_:FindById("goldLabel")
    hudLabels_.duckCount = uiRoot_:FindById("duckCount")
    hudLabels_.starLabel = uiRoot_:FindById("starLabel")
    hudLabels_.timeLabel = uiRoot_:FindById("timeLabel")
    hudLabels_.breadLabel = uiRoot_:FindById("breadLabel")
    hudLabels_.controlHint = uiRoot_:FindById("controlHint")
    hudLabels_.controlHintBar = uiRoot_:FindById("controlHintBar")

    -- 坐标网格开关（预览模式用）
    CreateGridToggleButton()

    -- 地图编辑器按钮（预览模式用）
    CreateEditToggleButton()
    CreateTerrainToggleButton()
    CreateSaveButton()
end

-- ============================================================================
-- 事件处理
-- ============================================================================

function HandleAssignRole(eventType, eventData)
    local nodeId = eventData["NodeId"]:GetUInt()
    local roleNode = scene_:GetNode(nodeId)
    if roleNode then
        BindToRole(roleNode)
    else
        pendingNodeId_ = nodeId
        print("[Client] 角色节点未到达，等待同步... NodeId: " .. nodeId)
    end
end

function BindToRole(roleNode)
    myRoleNode_ = roleNode
    local roleIndexVar = roleNode:GetVar(VARS.ROLE_INDEX)
    if not roleIndexVar:IsEmpty() then
        myRoleIndex_ = roleIndexVar:GetInt()
    else
        myRoleIndex_ = tonumber(string.match(roleNode.name or "", "Role_(%d+)")) or 0
    end
    print("[Client] 绑定到角色: " .. roleNode.name)
end

function HandleNodeAdded(eventType, eventData)
    local node = eventData["Node"]:GetPtr("Node")
    if node and node.replicated then
        -- NodeAdded 时 name/vars 可能尚未同步，先全部入队，延迟分类
        table.insert(pendingNodes_, node.ID)
    end
end

function HandleDuckSettled(eventType, eventData)
    local duckNodeId = eventData["NodeId"]:GetUInt()
    settledCount_ = eventData["SettledCount"]:GetInt()
    totalDucks_ = eventData["TotalDucks"]:GetInt()

    -- 更改鸭子外观
    local duckNode = scene_:GetNode(duckNodeId)
    if duckNode then
        DuckRenderer.SetMood(duckNode, "settled", Shared.CreatePBRMaterial)
        DuckRenderer.SetSettled(duckNode, Shared.CreatePBRMaterial)
    end

    -- 更新星级
    local L = Config.Level1
    if settledCount_ >= L.Star3 then starRating_ = 3
    elseif settledCount_ >= L.Star2 then starRating_ = 2
    elseif settledCount_ >= L.Star1 then starRating_ = 1
    end

    -- 鸭子上架时播放嘎嘎叫
    AudioManager.PlayDuckQuack()

    print("[Client] 鸭子上架! " .. settledCount_ .. " / " .. totalDucks_)

    -- 立即同步 HUD，避免等到下一帧才刷新
    UpdateHUD()
end

function HandleDuckEscaped(eventType, eventData)
    local duckNodeId = eventData["NodeId"]:GetUInt()
    settledCount_ = eventData["SettledCount"]:GetInt()
    totalDucks_ = eventData["TotalDucks"]:GetInt()

    local duckNode = scene_:GetNode(duckNodeId)
    if duckNode then
        -- 移除上架星标
        local star = duckNode:GetChild("SettledStar")
        if star then star:Remove() end
        DuckRenderer.SetMood(duckNode, "panic", Shared.CreatePBRMaterial)
    end

    -- 更新星级（可能降级）
    local L = Config.Level1
    if settledCount_ >= L.Star3 then starRating_ = 3
    elseif settledCount_ >= L.Star2 then starRating_ = 2
    elseif settledCount_ >= L.Star1 then starRating_ = 1
    else starRating_ = 0
    end

    -- 播放鸭子逃跑音效
    AudioManager.PlayDuckQuack()
    print("[Client] 鸭子逃跑了! 剩余上架: " .. settledCount_ .. " / " .. totalDucks_)

    -- 立即同步 HUD
    UpdateHUD()
end

function HandleGameResult(eventType, eventData)
    starRating_ = eventData["Stars"]:GetInt()
    settledCount_ = eventData["SettledCount"]:GetInt()
    totalDucks_ = eventData["TotalDucks"]:GetInt()
    local minutes = eventData["TimeMinutes"]:GetInt()
    local seconds = eventData["TimeSeconds"]:GetInt()
    earnedGold_ = eventData["EarnedGold"]:GetInt()
    totalGold_ = totalGold_ + earnedGold_

    -- 保存金币到云端
    if earnedGold_ > 0 and clientCloud then
        clientCloud:Add("gold", earnedGold_, {
            ok = function()
                print("[Client] 金币已保存到云端, +" .. earnedGold_ .. ", 总计: " .. totalGold_)
            end,
            error = function(code, reason)
                print("[Client] 金币保存失败: " .. tostring(reason))
            end,
        })
    end

    gameState_ = Config.GameState.COMPLETE
    AudioManager.StopMusic()
    print("[Client] 游戏结束! 星级: " .. starRating_ .. " 金币: +" .. earnedGold_)

    -- 同步顶部 HUD 到最终数值（gameState=COMPLETE 后 HandleUpdate 不再调用 UpdateHUD）
    UpdateHUD()

    ShowResult(minutes, seconds)
end

function HandlePingBroadcast(eventType, eventData)
    local roleId = eventData["RoleId"]:GetInt()
    local pingType = eventData["PingType"]:GetString()
    local x = eventData["X"]:GetFloat()
    local z = eventData["Z"]:GetFloat()

    CreatePingMarker(roleId, pingType, Vector3(x, 0, z))
end

function HandleBreadState(eventType, eventData)
    breadState_.state = eventData["State"]:GetString()
    breadState_.ownerRole = eventData["OwnerRole"]:GetInt()
    breadState_.pickupPos = Vector3(eventData["PickupX"]:GetFloat(), 0.3, eventData["PickupZ"]:GetFloat())
    breadState_.timeLeft = eventData["TimeLeft"]:GetFloat()

    local ax = eventData["ActiveX"]:GetFloat()
    local az = eventData["ActiveZ"]:GetFloat()
    if breadState_.state == "active" then
        breadState_.activePos = Vector3(ax, 0.08, az)
    else
        breadState_.activePos = nil
    end

    UpdateBreadVisual()
    UpdateHUD()
end

function CreateMarkerNode(name, pos, color, scale)
    local node = scene_:CreateChild(name, LOCAL)
    node.position = pos
    node.scale = Vector3(scale, scale, scale)

    local model = node:CreateComponent("StaticModel", LOCAL)
    model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    model:SetMaterial(Shared.CreatePBRMaterial(color, 0.05, 0.25))
    model.castShadows = false

    return node
end

function CreatePingMarker(roleId, pingType, pos)
    local pingInfo = Config.Ping.Types[pingType] or Config.Ping.Types.go
    local color = pingInfo.color
    local node = CreateMarkerNode("Ping_" .. pingType, Vector3(pos.x, 0.18, pos.z), color, 0.18)

    table.insert(pingMarkers_, {
        node = node,
        timer = Config.Ping.Duration,
        duration = Config.Ping.Duration,
        baseScale = 0.18,
        roleId = roleId,
        pingType = pingType,
    })
end

function UpdatePingMarkers(dt)
    for i = #pingMarkers_, 1, -1 do
        local marker = pingMarkers_[i]
        marker.timer = marker.timer - dt
        if marker.timer <= 0 then
            if marker.node then marker.node:Remove() end
            table.remove(pingMarkers_, i)
        elseif marker.node then
            local t = 1.0 - marker.timer / marker.duration
            local pulse = marker.baseScale * (1.0 + math.sin(t * math.pi * 6.0) * 0.18)
            marker.node.scale = Vector3(pulse, pulse, pulse)
            marker.node.position = Vector3(marker.node.position.x, 0.18 + math.sin(t * math.pi) * 0.45, marker.node.position.z)
        end
    end
end

function UpdateBreadVisual()
    if breadPickupNode_ == nil then
        breadPickupNode_ = scene_:GetChild("Breadcrumb", false)
    end

    if breadPickupNode_ then
        breadPickupNode_.enabled = (breadState_.state == "available")
        breadPickupNode_.position = breadState_.pickupPos
    end

    if breadState_.state == "active" and breadState_.activePos ~= nil then
        if breadActiveNode_ == nil then
            breadActiveNode_ = CreateMarkerNode("ActiveBread", breadState_.activePos, Config.Colors.Breadcrumb, 0.24)
        end
        breadActiveNode_.enabled = true
        breadActiveNode_.position = breadState_.activePos
    elseif breadActiveNode_ then
        breadActiveNode_.enabled = false
    end
end

-- ============================================================================
-- 主循环
-- ============================================================================

function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")

    -- 更新音频管理器（冷却计时等）
    AudioManager.Update(dt)

    ProcessPendingCallbacks()

    -- 闪屏动画计时
    UpdateSplash(dt)
    UpdatePingMarkers(dt)
    if breadState_.timeLeft > 0 then
        breadState_.timeLeft = math.max(0, breadState_.timeLeft - dt)
    end

    -- 发送 Ready（等待连接可用才发送，否则保持重试）
    if needSendReady_ then
        local serverConn = network:GetServerConnection()
        if serverConn then
            -- 确保 scene 已关联
            if serverConn.scene == nil then
                serverConn.scene = scene_
                print("[Client] 延迟关联 scene 到 serverConn")
            end
            needSendReady_ = false
            serverConn:SendRemoteEvent(EVENTS.CLIENT_READY, true)
            print("[Client] 发送 ClientReady")
        else
            print("[Client] 等待服务器连接...")
        end
    end

    -- 处理待渲染的复制节点（统一队列）
    ProcessPendingNodes()

    -- 检查待绑定节点
    if pendingNodeId_ ~= 0 then
        local roleNode = scene_:GetNode(pendingNodeId_)
        if roleNode then
            pendingNodeId_ = 0
            BindToRole(roleNode)
        end
    end

    -- 闪屏播放中，跳过游戏交互
    if splashActive_ then return end

    -- P 键切换地图预览模式
    if input:GetKeyPress(KEY_P) then
        MapPreviewCamera.Toggle()
        if MapPreviewCamera.IsActive() then
            -- 进入预览：发送零 controls 停住角色
            local serverConn = network:GetServerConnection()
            if serverConn then
                local controls = Controls()
                controls.buttons = 0
                serverConn.controls = controls
            end
            isMoving_ = false
        end
        UpdateControlHint()
    end

    -- 预览模式：更新预览相机，跳过游戏输入
    if MapPreviewCamera.IsActive() then
        MapPreviewCamera.Update(dt)
        if MapEditor.IsActive() then
            MapEditor.Update(dt)
        end
        if TerrainEditor.IsActive() then
            TerrainEditor.Update(dt)
        end
        -- 游戏时间和动画/HUD 仍然继续
        if gameState_ == Config.GameState.PLAYING then
            gameTime_ = gameTime_ + dt
            UpdateAnimations(dt)
            UpdateHUD()
        end
        return
    end

    if gameState_ ~= Config.GameState.PLAYING then return end

    gameTime_ = gameTime_ + dt

    -- 输入采集 + 转发
    UpdateInput(dt)

    -- 动画更新
    UpdateAnimations(dt)

    -- HUD
    UpdateHUD()
end

-- ============================================================================
-- 处理待渲染节点
-- ============================================================================

function ProcessPendingNodes()
    if #pendingNodes_ == 0 then return end

    local pending = pendingNodes_
    pendingNodes_ = {}

    for _, nodeId in ipairs(pending) do
        -- 已处理过的跳过
        if renderedRoles_[nodeId] or renderedDucks_[nodeId] then
            goto continue
        end

        local node = scene_:GetNode(nodeId)
        if node == nil then
            goto continue
        end

        local name = node.name or ""

        -- 尝试识别角色节点
        if name:sub(1, 5) == "Role_" then
            local roleIndexVar = node:GetVar(VARS.ROLE_INDEX)
            local connectedVar = node:GetVar(VARS.CONNECTED)
            if roleIndexVar:IsEmpty() or connectedVar:IsEmpty() then
                -- Vars 还未同步（三态中的"空"），放回队列下帧重试
                table.insert(pendingNodes_, nodeId)
            elseif connectedVar:GetBool() then
                -- CONNECTED=true：有真实玩家，创建模型
                local roleIndex = roleIndexVar:GetInt()
                DwarfRenderer.Setup(node, roleIndex, Shared.CreatePBRMaterial)
                renderedRoles_[nodeId] = true
                print("[Client] 为 " .. name .. " 创建了矮人模型 (roleIndex=" .. roleIndex .. ")")
            else
                -- CONNECTED=false：空槽位或已断线，不创建模型
                -- 不放回队列，也不标记 rendered（后续如果重连，会通过断线清理逻辑重新进入队列）
            end
        -- 尝试识别鸭子节点
        elseif name:sub(1, 5) == "Duck_" then
            DuckRenderer.Setup(node, Shared.CreatePBRMaterial)
            renderedDucks_[nodeId] = true
            print("[Client] 为 " .. name .. " 创建了鸭子模型")

            -- 检查是否已经是 settled 状态
            local stateVar = node:GetVar(VARS.DUCK_STATE)
            if not stateVar:IsEmpty() then
                local state = stateVar:GetString()
                if state == "settled" then
                    DuckRenderer.SetSettled(node, Shared.CreatePBRMaterial)
                else
                    DuckRenderer.SetMood(node, state, Shared.CreatePBRMaterial)
                end
            end
        else
            -- 名称尚未同步（可能还是空字符串），放回队列
            if name == "" then
                table.insert(pendingNodes_, nodeId)
            end
            -- 名称非空但不匹配 Role_/Duck_ → 忽略（如场景自身的 Octree 节点等）
        end

        ::continue::
    end
end

-- ============================================================================
-- 输入采集 + 转发到服务端 controls
-- ============================================================================

function UpdateInput(dt)
    local serverConn = network:GetServerConnection()
    if serverConn == nil then return end

    -- 构造 buttons 位掩码
    local buttons = 0
    if input:GetKeyDown(KEY_W) then buttons = buttons | CTRL.FORWARD end
    if input:GetKeyDown(KEY_S) then buttons = buttons | CTRL.BACK end
    if input:GetKeyDown(KEY_A) then buttons = buttons | CTRL.LEFT end
    if input:GetKeyDown(KEY_D) then buttons = buttons | CTRL.RIGHT end
    if input:GetKeyDown(KEY_SHIFT) then buttons = buttons | CTRL.SPRINT end

    -- 创建新 Controls 对象再赋回（Lua 绑定 getter 返回副本）
    local controls = Controls()
    controls.buttons = buttons
    serverConn.controls = controls

    -- 检测当前移动状态（用于动画）
    isMoving_ = (buttons & (CTRL.FORWARD | CTRL.BACK | CTRL.LEFT | CTRL.RIGHT)) ~= 0

    -- 拍手冷却
    if clapCooldown_ > 0 then
        clapCooldown_ = clapCooldown_ - dt
    end
    if clapAnimTimer_ > 0 then
        clapAnimTimer_ = clapAnimTimer_ - dt
    end

    -- 拍手（通过远程事件发送，不走 controls）
    if input:GetKeyPress(KEY_SPACE) and clapCooldown_ <= 0 then
        clapCooldown_ = Config.Player.ClapCooldown
        clapAnimTimer_ = 0.4
        serverConn:SendRemoteEvent(EVENTS.PLAYER_CLAP, true)
        -- 播放拍手音效（鸭叫由状态变化触发，不在这里播放）
        AudioManager.PlayClap()
        print("[Client] 发送拍手事件")
    end

    if input:GetKeyPress(KEY_E) then
        serverConn:SendRemoteEvent(EVENTS.BREAD_USE, true)
        print("[Client] 请求使用面包屑")
    end

    if input:GetKeyPress(KEY_1) then SendPing("go") end
    if input:GetKeyPress(KEY_2) then SendPing("block") end
    if input:GetKeyPress(KEY_3) then SendPing("help") end
    if input:GetKeyPress(KEY_4) then SendPing("watch") end
end

function SendPing(pingType)
    local serverConn = network:GetServerConnection()
    if serverConn == nil then return end
    local eventData = VariantMap()
    eventData["PingType"] = Variant(pingType)
    serverConn:SendRemoteEvent(EVENTS.PLAYER_PING, true, eventData)
end

-- ============================================================================
-- 动画更新
-- ============================================================================

function UpdateAnimations(dt)
    -- 断线清理：检测其他玩家 CONNECTED 变为 false，移除 LOCAL 模型
    for nodeId, _ in pairs(renderedRoles_) do
        local node = scene_:GetNode(nodeId)
        if node and node ~= myRoleNode_ then
            local connectedVar = node:GetVar(VARS.CONNECTED)
            -- 仅当 CONNECTED 明确为 false 时移除（断线清理）
            -- 空/未同步时不操作，避免误删
            if not connectedVar:IsEmpty() and not connectedVar:GetBool() then
                DwarfRenderer.Remove(node)
                renderedRoles_[nodeId] = nil
                -- 放回待处理队列，以便该槽位被新玩家重连时能重新创建模型
                table.insert(pendingNodes_, nodeId)
                print("[Client] 玩家断线，移除模型: " .. (node.name or ""))
            end
        elseif not node then
            -- 节点已被服务端删除
            renderedRoles_[nodeId] = nil
        end
    end

    -- 自己的矮人动画
    if myRoleNode_ then
        DwarfRenderer.AnimateClap(myRoleNode_, clapAnimTimer_)
        if clapAnimTimer_ <= 0 then
            DwarfRenderer.AnimateWalk(myRoleNode_, gameTime_, isMoving_)
        end
    end

    -- 所有鸭子动画 + 音效状态检测
    local hasIdleDuck = false
    for nodeId, _ in pairs(renderedDucks_) do
        local node = scene_:GetNode(nodeId)
        if node then
            local stateVar = node:GetVar(VARS.DUCK_STATE)
            local state = ""
            if not stateVar:IsEmpty() then
                state = stateVar:GetString()
            end

            -- 检测状态变化：进入惊慌时播放嘎嘎叫，并刷新头顶状态标记
            local prevState = prevDuckStates_[nodeId] or ""
            if state ~= prevState then
                DuckRenderer.SetMood(node, state, Shared.CreatePBRMaterial)
            end
            if (state == "panic" or state == "scared") and prevState ~= state then
                AudioManager.PlayDuckQuack()
            end
            prevDuckStates_[nodeId] = state

            -- 统计是否有闲逛中的鸭子
            if state == "idle" then
                hasIdleDuck = true
            end

            -- 所有鸭子都播放动画（包括上架后闲逛的鸭子）
            DuckRenderer.Animate(node, dt, gameTime_)
        else
            renderedDucks_[nodeId] = nil
            prevDuckStates_[nodeId] = nil
        end
    end

    -- 闲逛的鸭子偶尔叫一声（3~6秒随机间隔）
    if hasIdleDuck then
        idleQuackTimer_ = idleQuackTimer_ - dt
        if idleQuackTimer_ <= 0 then
            AudioManager.PlayDuckQuack()
            idleQuackTimer_ = 3.0 + math.random() * 3.0
        end
    end
end

-- ============================================================================
-- HUD
-- ============================================================================

function UpdateHUD()
    if hudLabels_.goldLabel then
        hudLabels_.goldLabel.text = "💰 " .. totalGold_
    end

    if hudLabels_.duckCount then
        hudLabels_.duckCount.text = "🦆 " .. settledCount_ .. " / " .. totalDucks_
    end

    if hudLabels_.starLabel then
        local stars
        if starRating_ >= 3 then stars = "★★★"
        elseif starRating_ >= 2 then stars = "★★☆"
        elseif starRating_ >= 1 then stars = "★☆☆"
        else stars = "☆☆☆"
        end
        hudLabels_.starLabel.text = stars
    end

    if hudLabels_.timeLabel then
        local m = math.floor(gameTime_ / 60)
        local s = math.floor(gameTime_ % 60)
        hudLabels_.timeLabel.text = string.format("⏱ %02d:%02d", m, s)
    end

    if hudLabels_.breadLabel then
        if breadState_.state == "held" and breadState_.ownerRole == myRoleIndex_ then
            hudLabels_.breadLabel.text = "🍞 按 E"
        elseif breadState_.state == "held" then
            hudLabels_.breadLabel.text = "🍞 队友持有"
        elseif breadState_.state == "active" then
            hudLabels_.breadLabel.text = "🍞 引诱中"
        elseif breadState_.state == "cooldown" then
            hudLabels_.breadLabel.text = "🍞 刷新中"
        else
            hudLabels_.breadLabel.text = "🍞 地图上"
        end
    end
end

-- ============================================================================
-- PostRenderUpdate — 绘制网格
-- ============================================================================

function HandlePostRenderUpdate(eventType, eventData)
    MapPreviewCamera.DrawGrid()
    MapEditor.DrawGizmos()
    TerrainEditor.DrawOverlay()
end

-- ============================================================================
-- 坐标网格开关按钮
-- ============================================================================

function CreateGridToggleButton()
    -- Design DNA: 蓝色面板堆叠、黑结构边框、底部强调、硬阴影、直角
    hudLabels_.gridTogglePanel = UI.Panel {
        id = "gridTogglePanel",
        position = "absolute",
        top = 10,
        right = 10,
        visible = false,
        -- 外层：黑结构边框 + 底部强调色加深
        backgroundColor = { 0, 0, 0, 255 },
        borderRadius = 0,
        padding = 2,
        paddingBottom = 4, -- 底部加厚 → 深度强调
        boxShadow = {
            { x = 0, y = 6, blur = 0, spread = 0, color = { 0, 0, 0, 64 } },
            { x = 0, y = 8, blur = 4, spread = 0, color = { 0, 0, 0, 64 } },
        },
        children = {
            UI.Button {
                id = "gridToggleBtn",
                text = "网格: 开",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 33, 69, 138, 255 },           -- Surface #21458A
                hoverBackgroundColor = { 45, 102, 200, 255 },     -- Hover  #2D66C8
                pressedBackgroundColor = { 34, 89, 183, 255 },    -- Pressed #2259B7
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    local newState = not MapPreviewCamera.IsGridEnabled()
                    MapPreviewCamera.SetGridEnabled(newState)
                    self.text = newState and "网格: 开" or "网格: 关"
                end,
            },
        },
    }
    uiRoot_:AddChild(hudLabels_.gridTogglePanel)
end

-- ============================================================================
-- 地图编辑器按钮
-- ============================================================================

function CreateEditToggleButton()
    hudLabels_.editTogglePanel = UI.Panel {
        id = "editTogglePanel",
        position = "absolute",
        top = 60,
        right = 10,
        visible = false,
        backgroundColor = { 0, 0, 0, 255 },
        borderRadius = 0,
        padding = 2,
        paddingBottom = 4,
        boxShadow = {
            { x = 0, y = 6, blur = 0, spread = 0, color = { 0, 0, 0, 64 } },
            { x = 0, y = 8, blur = 4, spread = 0, color = { 0, 0, 0, 64 } },
        },
        children = {
            UI.Button {
                id = "editToggleBtn",
                text = "编辑: 关",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 90, 40, 40, 255 },
                hoverBackgroundColor = { 130, 50, 50, 255 },
                pressedBackgroundColor = { 110, 45, 45, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    if MapEditor.IsActive() then
                        MapEditor.Disable()
                        self.text = "编辑: 关"
                        self.backgroundColor = { 90, 40, 40, 255 }
                        self.hoverBackgroundColor = { 130, 50, 50, 255 }
                    else
                        -- 开启编辑前，自动关闭地形模式
                        if TerrainEditor.IsActive() then
                            TerrainEditor.Disable()
                            local tBtn = hudLabels_.terrainTogglePanel and hudLabels_.terrainTogglePanel:FindById("terrainToggleBtn")
                            if tBtn then
                                tBtn.text = "地形: 关"
                                tBtn.backgroundColor = { 70, 40, 100, 255 }
                                tBtn.hoverBackgroundColor = { 100, 55, 140, 255 }
                            end
                        end
                        MapEditor.Enable()
                        self.text = "编辑: 开"
                        self.backgroundColor = { 40, 120, 40, 255 }
                        self.hoverBackgroundColor = { 50, 150, 50, 255 }
                    end
                end,
            },
        },
    }
    uiRoot_:AddChild(hudLabels_.editTogglePanel)
end

-- ============================================================================
-- 地形规划按钮
-- ============================================================================

function CreateTerrainToggleButton()
    hudLabels_.terrainTogglePanel = UI.Panel {
        id = "terrainTogglePanel",
        position = "absolute",
        top = 110,
        right = 10,
        visible = false,
        backgroundColor = { 0, 0, 0, 255 },
        borderRadius = 0,
        padding = 2,
        paddingBottom = 4,
        boxShadow = {
            { x = 0, y = 6, blur = 0, spread = 0, color = { 0, 0, 0, 64 } },
            { x = 0, y = 8, blur = 4, spread = 0, color = { 0, 0, 0, 64 } },
        },
        children = {
            UI.Button {
                id = "terrainToggleBtn",
                text = "地形: 关",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 70, 40, 100, 255 },
                hoverBackgroundColor = { 100, 55, 140, 255 },
                pressedBackgroundColor = { 85, 48, 120, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    if TerrainEditor.IsActive() then
                        TerrainEditor.Disable()
                        self.text = "地形: 关"
                        self.backgroundColor = { 70, 40, 100, 255 }
                        self.hoverBackgroundColor = { 100, 55, 140, 255 }
                    else
                        -- 开启地形前，自动关闭编辑模式
                        if MapEditor.IsActive() then
                            MapEditor.Disable()
                            local eBtn = hudLabels_.editTogglePanel and hudLabels_.editTogglePanel:FindById("editToggleBtn")
                            if eBtn then
                                eBtn.text = "编辑: 关"
                                eBtn.backgroundColor = { 90, 40, 40, 255 }
                                eBtn.hoverBackgroundColor = { 130, 50, 50, 255 }
                            end
                        end
                        TerrainEditor.Enable()
                        self.text = "地形: 开"
                        self.backgroundColor = { 120, 60, 180, 255 }
                        self.hoverBackgroundColor = { 140, 75, 200, 255 }
                    end
                end,
            },
        },
    }
    uiRoot_:AddChild(hudLabels_.terrainTogglePanel)
end

function CreateSaveButton()
    hudLabels_.savePanel = UI.Panel {
        id = "savePanel",
        position = "absolute",
        top = 10,
        left = 10,
        visible = false,
        backgroundColor = { 0, 0, 0, 255 },
        borderRadius = 0,
        padding = 2,
        paddingBottom = 4,
        boxShadow = {
            { x = 0, y = 6, blur = 0, spread = 0, color = { 0, 0, 0, 64 } },
            { x = 0, y = 8, blur = 4, spread = 0, color = { 0, 0, 0, 64 } },
        },
        children = {
            UI.Button {
                id = "saveBtn",
                text = "保存地图",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 33, 100, 33, 255 },
                hoverBackgroundColor = { 45, 140, 45, 255 },
                pressedBackgroundColor = { 34, 110, 34, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    MapEditor.SaveToLog()
                    TerrainEditor.ExportToLog()
                end,
            },
        },
    }
    uiRoot_:AddChild(hudLabels_.savePanel)
end

-- ============================================================================
-- 操作提示切换
-- ============================================================================

function UpdateControlHint()
    local isPreviewing = MapPreviewCamera.IsActive()

    -- 预览模式：隐藏底部操作提示，显示网格/编辑/地形按钮
    -- 游戏模式：显示底部操作提示，隐藏网格/编辑/地形按钮
    if hudLabels_.controlHint then
        hudLabels_.controlHint.text = "WASD 移动 | Shift 冲刺 | 空格 拍手 | E 撒面包 | 1-4 标记 | P 预览"
    end
    if hudLabels_.controlHintBar then
        hudLabels_.controlHintBar.visible = not isPreviewing
    end
    if hudLabels_.gridTogglePanel then
        hudLabels_.gridTogglePanel.visible = isPreviewing
    end
    if hudLabels_.editTogglePanel then
        hudLabels_.editTogglePanel.visible = isPreviewing
    end
    if hudLabels_.terrainTogglePanel then
        hudLabels_.terrainTogglePanel.visible = isPreviewing
    end

    -- 保存按钮：预览模式下始终可见
    if hudLabels_.savePanel then
        hudLabels_.savePanel.visible = isPreviewing
    end

    -- 退出预览时自动关闭编辑器
    if not isPreviewing and MapEditor.IsActive() then
        MapEditor.Disable()
        local btn = hudLabels_.editTogglePanel and hudLabels_.editTogglePanel:FindById("editToggleBtn")
        if btn then
            btn.text = "编辑: 关"
            btn.backgroundColor = { 90, 40, 40, 255 }
            btn.hoverBackgroundColor = { 130, 50, 50, 255 }
        end
    end

    -- 退出预览时自动关闭地形编辑器
    if not isPreviewing and TerrainEditor.IsActive() then
        TerrainEditor.Disable()
        local btn = hudLabels_.terrainTogglePanel and hudLabels_.terrainTogglePanel:FindById("terrainToggleBtn")
        if btn then
            btn.text = "地形: 关"
            btn.backgroundColor = { 70, 40, 100, 255 }
            btn.hoverBackgroundColor = { 100, 55, 140, 255 }
        end
    end
end

-- ============================================================================
-- 结算界面
-- ============================================================================

function ShowResult(minutes, seconds)
    local T = AstroonTheme.Tokens
    local stars = string.rep("★", starRating_) .. string.rep("☆", 3 - starRating_)

    local resultPanel = UI.Panel {
        id = "resultPanel",
        position = "absolute",
        top = 0, left = 0, right = 0, bottom = 0,
        justifyContent = "center",
        alignItems = "center",
        backgroundColor = T.overlay,
        children = {
            UI.Panel {
                width = 340,
                padding = 28,
                borderRadius = AstroonTheme.Radius.lg,
                backgroundColor = T.surface,
                borderWidth = 1,
                borderColor = T.border,
                alignItems = "center",
                gap = 16,
                boxShadow = {
                    { x = 0, y = 8, blur = 24, spread = 0, color = T.shadow },
                },
                children = {
                    UI.Label {
                        text = "关卡完成！",
                        fontSize = 32,
                        fontFamily = "longzhu",
                        fontColor = T.primary,
                    },
                    UI.Label {
                        text = stars,
                        fontSize = 40,
                        fontFamily = "longzhu",
                        fontColor = T.primary,
                    },
                    -- 分隔线
                    UI.Panel {
                        width = "80%",
                        height = 1,
                        backgroundColor = T.border,
                    },
                    UI.Label {
                        text = string.format("用时: %02d:%02d", minutes, seconds),
                        fontSize = 18,
                        fontColor = T.textSecondary,
                    },
                    UI.Label {
                        text = string.format("上架: %d / %d 只", settledCount_, totalDucks_),
                        fontSize = 18,
                        fontColor = T.success,
                    },
                    -- 金币明细分隔线
                    UI.Panel {
                        width = "80%",
                        height = 1,
                        backgroundColor = T.border,
                    },
                    UI.Label {
                        text = string.format("💰 上架报酬: +%d  星级奖励: +%d", settledCount_, starRating_),
                        fontSize = 16,
                        fontColor = { 255, 215, 0, 255 },
                    },
                    UI.Label {
                        text = string.format("💰 本局获得: +%d  总余额: %d", earnedGold_, totalGold_),
                        fontSize = 18,
                        fontWeight = "bold",
                        fontColor = { 255, 215, 0, 255 },
                    },
                },
            },
        },
    }

    UI.SetRoot(UI.Panel {
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = { uiRoot_, resultPanel },
    })
end

-- ============================================================================
-- 延迟执行
-- ============================================================================

function DelayOneFrame(callback)
    table.insert(pendingCallbacks_, callback)
end

function ProcessPendingCallbacks()
    if #pendingCallbacks_ > 0 then
        local callbacks = pendingCallbacks_
        pendingCallbacks_ = {}
        for _, cb in ipairs(callbacks) do cb() end
    end
end

return Client
