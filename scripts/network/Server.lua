-- ============================================================================
-- Server.lua — 《赶鸭子上架》多人服务端逻辑
-- 职责：角色池、鸭子 AI (Boids)、拍手处理、上架检测、结算广播
-- ============================================================================

local Server = {}
local Shared = require("network.Shared")

require "LuaScripts/Utilities/Sample"

-- ============================================================================
-- Headless 模式 mock（服务端无渲染）
-- ============================================================================

if GetGraphics() == nil then
    local mockGraphics = {
        SetWindowIcon = function() end,
        SetWindowTitleAndIcon = function() end,
        GetWidth = function() return 1920 end,
        GetHeight = function() return 1080 end,
    }
    function GetGraphics() return mockGraphics end
    graphics = mockGraphics
    console = { background = {} }
    function GetConsole() return console end
    debugHud = {}
    function GetDebugHud() return debugHud end
end

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

-- 角色池（预创建 REPLICATED 节点）
local rolePool_ = {}         -- roleId -> Node
local roleAssignments_ = {}  -- roleId -> connKey | nil

-- 连接管理
local connectionRoles_ = {}   -- connKey -> roleId
local serverConnections_ = {} -- connKey -> Connection

-- 鸭子数据（服务端权威）
local ducks_ = {}       -- { node, vel, state, fearTimer, settleTimer, wanderAngle }
local settledCount_ = 0
local totalDucks_ = 0

-- 游戏状态
local gameTime_ = 0.0
local gameState_ = Config.GameState.PLAYING
local starRating_ = 0

-- 上架鸭子逃跑判定计时器
local escapeCheckTimer_ = Config.Duck.EscapeCheckInterval

-- 碰撞检测
local obstacleColliders_ = nil   -- 缓存的障碍物碰撞体列表
local PLAYER_COLLISION_RADIUS = Config.Player.Radius  -- 0.35m
local DUCK_COLLISION_RADIUS = 0.25  -- 鸭子碰撞半径

-- 整个地图的移动边界（外围地面范围，以农场中心为原点）
local EXT = Config.Exterior
local MAP_CENTER_X = Config.Level1.MapWidth / 2
local MAP_CENTER_Z = Config.Level1.MapHeight / 2
local MAP_MIN_X = MAP_CENTER_X - EXT.GroundWidth / 2   -- -16
local MAP_MAX_X = MAP_CENTER_X + EXT.GroundWidth / 2   --  34
local MAP_MIN_Z = MAP_CENTER_Z - EXT.GroundHeight / 2  -- -14
local MAP_MAX_Z = MAP_CENTER_Z + EXT.GroundHeight / 2  --  26

-- 延迟回调
local pendingCallbacks_ = {}

-- 面包屑状态（服务端权威）
local breadState_ = "available"  -- available / held / active / cooldown
local breadOwnerRole_ = nil
local breadActivePos_ = nil
local breadActiveTimer_ = 0.0
local breadRespawnTimer_ = 0.0

-- ============================================================================
-- 辅助：从 terrainGrid 计算 target 区域边界（AABB）
-- ============================================================================

local function GetTargetBounds()
    local grid = Shared.terrainGrid
    if not grid then
        local ta = Config.Level1.TargetArea
        local hx = ta.Size.x / 2
        local hz = ta.Size.z / 2
        return ta.Center.x - hx, ta.Center.x + hx, ta.Center.z - hz, ta.Center.z + hz
    end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for x, row in pairs(grid) do
        for z, cellType in pairs(row) do
            if cellType == "target" then
                if x < minX then minX = x end
                if x + 1 > maxX then maxX = x + 1 end
                if z < minZ then minZ = z end
                if z + 1 > maxZ then maxZ = z + 1 end
            end
        end
    end
    if minX == math.huge then
        local ta = Config.Level1.TargetArea
        local hx = ta.Size.x / 2
        local hz = ta.Size.z / 2
        return ta.Center.x - hx, ta.Center.x + hx, ta.Center.z - hz, ta.Center.z + hz
    end
    return minX, maxX, minZ, maxZ
end

local function SetDuckState(duck, state, timer)
    if duck == nil or duck.state == "settled" then return end
    duck.state = state
    if timer then duck.fearTimer = timer end
    duck.node:SetVar(VARS.DUCK_STATE, Variant(state))
end

local function GetRoleForward(roleNode)
    local fwd = roleNode:GetDirection()
    fwd.y = 0
    if fwd:Length() < 0.01 then
        return Vector3(0, 0, 1)
    end
    return fwd:Normalized()
end

-- ============================================================================
-- 入口
-- ============================================================================

function Server.Start()
    SampleStart()

    Shared.RegisterEvents()
    scene_ = Shared.CreateScene(true)

    CreateRolePool()
    CreateDucks()

    -- 缓存障碍物碰撞体列表
    obstacleColliders_ = Shared.BuildObstacleColliders()

    SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent(EVENTS.PLAYER_CLAP, "HandlePlayerClap")
    SubscribeToEvent(EVENTS.PLAYER_PING, "HandlePlayerPing")
    SubscribeToEvent(EVENTS.BREAD_USE, "HandleBreadUse")
    SubscribeToEvent(EVENTS.MAP_EDIT_OBS, "HandleMapEditObs")
    SubscribeToEvent(EVENTS.MAP_EDIT_TERRAIN, "HandleMapEditTerrain")
    SubscribeToEvent(EVENTS.MAP_EDIT_STRUCT, "HandleMapEditStruct")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")
    SubscribeToEvent("Update", "HandleUpdate")

    print("[Server] 《赶鸭子上架》服务端已启动，最多 " .. Config.Network.MaxPlayers .. " 名玩家")
end

function Server.Stop()
end

-- ============================================================================
-- 角色池（预创建 REPLICATED 节点）
-- ============================================================================

function CreateRolePool()
    for roleId = 1, Config.Network.MaxPlayers do
        local spawnPos = Shared.GetSpawnPoint(roleId)
        local roleNode = CreatePlayerRole(scene_, roleId, spawnPos)

        rolePool_[roleId] = roleNode
        roleAssignments_[roleId] = nil

        print("[Server] 创建 Role_" .. roleId .. " (ID: " .. roleNode.ID .. ")")
    end
end

function CreatePlayerRole(scene, roleId, spawnPos)
    local roleNode = scene:CreateChild("Role_" .. roleId, REPLICATED)
    roleNode.position = Vector3(spawnPos.x, 0, spawnPos.z)

    -- 物理碰撞（REPLICATED 以便同步）
    -- 使用运动学刚体：脚本控制位置，物理仅做碰撞检测，避免抽搐
    local body = roleNode:CreateComponent("RigidBody", REPLICATED)
    body.mass = 1.0
    body.kinematic = true
    body:SetCollisionLayer(2)

    local shape = roleNode:CreateComponent("CollisionShape", REPLICATED)
    shape:SetCapsule(Config.Player.Radius * 2, Config.Player.Height,
                     Vector3(0, Config.Player.Height / 2, 0))

    -- 网络变量
    roleNode:SetVar(VARS.IS_ROLE, Variant(true))
    roleNode:SetVar(VARS.ROLE_INDEX, Variant(roleId))

    return roleNode
end

function FindFreeRole()
    for roleId = 1, Config.Network.MaxPlayers do
        if roleAssignments_[roleId] == nil then
            return roleId
        end
    end
    return nil
end

function ResetRoleState(roleId)
    local roleNode = rolePool_[roleId]
    if roleNode == nil then return end
    local spawnPos = Shared.GetSpawnPoint(roleId)
    roleNode.position = Vector3(spawnPos.x, 0, spawnPos.z)
    roleNode.rotation = Quaternion.IDENTITY
end

-- ============================================================================
-- 鸭子创建（REPLICATED 用于同步位置到客户端）
-- ============================================================================

function CreateDucks()
    local positions = Config.Level1.DuckPositions
    totalDucks_ = #positions

    for i, pos in ipairs(positions) do
        local duckNode = scene_:CreateChild("Duck_" .. i, REPLICATED)
        duckNode.position = Vector3(pos.x, 0, pos.z)

        -- 标记
        duckNode:SetVar(VARS.IS_DUCK, Variant(true))
        duckNode:SetVar(VARS.DUCK_STATE, Variant("idle"))

        -- 服务端鸭子数据
        ducks_[i] = {
            node = duckNode,
            vel = Vector3.ZERO,
            state = "idle",
            fearTimer = 0.0,
            settleTimer = 0.0,
            wanderAngle = math.random() * math.pi * 2,
            -- 上架后行为
            jumpTimer = 0.0,
            jumpAnim = 0.0,
        }
    end

    print("[Server] 创建了 " .. totalDucks_ .. " 只鸭子 (REPLICATED)")
end

-- ============================================================================
-- 连接处理
-- ============================================================================

function HandleClientReady(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    print("[Server] 收到 ClientReady")

    connection.scene = scene_

    local connKey = tostring(connection)
    local roleId = FindFreeRole()

    if roleId == nil then
        print("[Server] 服务器已满，拒绝连接")
        connection:Disconnect()
        return
    end

    local roleNode = rolePool_[roleId]
    print("[Server] 分配 Role_" .. roleId .. " (ID: " .. roleNode.ID .. ")")

    roleAssignments_[roleId] = connKey
    connectionRoles_[connKey] = roleId
    serverConnections_[connKey] = connection

    roleNode:SetOwner(connection)
    roleNode:SetVar(VARS.CONNECTED, Variant(true))
    ResetRoleState(roleId)

    -- 延迟一帧再发送分配事件，确保客户端已同步场景
    local nodeId = roleNode.ID
    local conn = connection
    DelayOneFrame(function()
        local assignData = VariantMap()
        assignData["NodeId"] = Variant(nodeId)
        conn:SendRemoteEvent(EVENTS.ASSIGN_ROLE, true, assignData)
        SendBreadState(conn)
        print("[Server] 发送 ASSIGN_ROLE, NodeId: " .. nodeId)
    end)
end

function HandleClientDisconnected(eventType, eventData)
    local connection = eventData:GetPtr("Connection", "Connection")
    local connKey = tostring(connection)

    local roleId = connectionRoles_[connKey]
    if roleId then
        roleAssignments_[roleId] = nil
        local roleNode = rolePool_[roleId]
        if roleNode then
            roleNode:SetOwner(nil)
            roleNode:SetVar(VARS.CONNECTED, Variant(false))
        end
        ResetRoleState(roleId)
        if breadOwnerRole_ == roleId then
            breadState_ = "available"
            breadOwnerRole_ = nil
            breadActivePos_ = nil
            breadActiveTimer_ = 0
            breadRespawnTimer_ = 0
            BroadcastBreadState()
        end
        print("[Server] 玩家断开, 回收 Role_" .. roleId)
    end

    connectionRoles_[connKey] = nil
    serverConnections_[connKey] = nil
end

-- ============================================================================
-- 拍手处理（来自客户端远程事件）
-- ============================================================================

function HandlePlayerClap(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local roleId = connectionRoles_[connKey]
    if roleId == nil then return end

    local roleNode = rolePool_[roleId]
    if roleNode == nil then return end

    local playerPos = roleNode.position
    print("[Server] 玩家 " .. roleId .. " 拍手! 位置: "
        .. string.format("(%.1f, %.1f)", playerPos.x, playerPos.z))

    -- 影响范围内的鸭子
    for _, duck in ipairs(ducks_) do
        if duck.state ~= "settled" then
            local dist = (duck.node.position - playerPos):Length()
            if dist < Config.Duck.ClapFearRadius then
                SetDuckState(duck, "panic", Config.Duck.PanicTime)

                local fleeDir = (duck.node.position - playerPos)
                fleeDir.y = 0
                if fleeDir:Length() > 0.01 then
                    fleeDir = fleeDir:Normalized()
                end
                duck.vel = duck.vel + fleeDir * Config.Duck.MoveSpeed * Config.Duck.ClapFearBoost
            end
        end
    end
end

-- ============================================================================
-- 世界标记与面包屑
-- ============================================================================

function HandlePlayerPing(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local roleId = connectionRoles_[connKey]
    if roleId == nil then return end

    local roleNode = rolePool_[roleId]
    if roleNode == nil then return end

    local pingType = eventData["PingType"]:GetString()
    if Config.Ping.Types[pingType] == nil then
        pingType = "go"
    end

    local pos = roleNode.position + GetRoleForward(roleNode) * Config.Ping.ForwardOffset
    BroadcastPing(roleId, pingType, Vector3(pos.x, 0, pos.z))
end

function HandleBreadUse(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local roleId = connectionRoles_[connKey]
    if roleId == nil or breadState_ ~= "held" or breadOwnerRole_ ~= roleId then return end

    local roleNode = rolePool_[roleId]
    if roleNode == nil then return end

    local usePos = roleNode.position + GetRoleForward(roleNode) * Config.Bread.UseOffset
    breadState_ = "active"
    breadOwnerRole_ = nil
    breadActivePos_ = Vector3(usePos.x, 0, usePos.z)
    breadActiveTimer_ = Config.Bread.ActiveTime
    breadRespawnTimer_ = 0

    print(string.format("[Server] 玩家 %d 撒下面包屑: (%.1f, %.1f)", roleId, breadActivePos_.x, breadActivePos_.z))
    BroadcastBreadState()
end

function UpdateBread(dt)
    local B = Config.Bread

    if breadState_ == "available" then
        local pickupPos = Config.Level1.BreadcrumbPos
        for roleId, connKey in pairs(roleAssignments_) do
            if connKey and rolePool_[roleId] then
                local rolePos = rolePool_[roleId].position
                local dist = (Vector3(rolePos.x, 0, rolePos.z) - Vector3(pickupPos.x, 0, pickupPos.z)):Length()
                if dist <= B.PickupRadius then
                    breadState_ = "held"
                    breadOwnerRole_ = roleId
                    print("[Server] 玩家 " .. roleId .. " 拾取面包屑")
                    BroadcastBreadState()
                    break
                end
            end
        end
    elseif breadState_ == "active" then
        breadActiveTimer_ = breadActiveTimer_ - dt
        if breadActiveTimer_ <= 0 then
            breadState_ = "cooldown"
            breadOwnerRole_ = nil
            breadActivePos_ = nil
            breadActiveTimer_ = 0
            breadRespawnTimer_ = B.RespawnTime
            BroadcastBreadState()
        end
    elseif breadState_ == "cooldown" then
        breadRespawnTimer_ = breadRespawnTimer_ - dt
        if breadRespawnTimer_ <= 0 then
            breadState_ = "available"
            breadOwnerRole_ = nil
            breadActivePos_ = nil
            breadRespawnTimer_ = 0
            BroadcastBreadState()
        end
    end
end

-- ============================================================================
-- 主循环
-- ============================================================================

function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")

    ProcessPendingCallbacks()

    -- 编辑器修改后重建障碍物碰撞缓存
    if Shared.obstacleCollidersDirty then
        obstacleColliders_ = Shared.BuildObstacleColliders()
        Shared.obstacleCollidersDirty = false
        print("[Server] 障碍物碰撞缓存已重建, 碰撞体数量: " .. #obstacleColliders_)
    end

    if gameState_ ~= Config.GameState.PLAYING then return end

    gameTime_ = gameTime_ + dt

    -- 处理每个连接的玩家移动
    for roleId, connKey in pairs(roleAssignments_) do
        if connKey then
            local roleNode = rolePool_[roleId]
            local connection = serverConnections_[connKey]
            if connection and roleNode then
                MoveRole(roleNode, connection, roleId, dt)
            end
        end
    end

    -- 面包屑拾取/持续/刷新
    UpdateBread(dt)

    -- 服务端权威：鸭子 AI
    UpdateDucks(dt)

    -- 上架检测
    CheckSettled()
end

-- ============================================================================
-- 玩家移动（读取 controls 位掩码）
-- ============================================================================

function MoveRole(roleNode, connection, roleId, dt)
    local controls = connection.controls
    local buttons = controls.buttons

    local moveDir = Vector3.ZERO
    local speed = Config.Player.WalkSpeed

    if (buttons & CTRL.SPRINT) ~= 0 then
        speed = Config.Player.SprintSpeed
    end

    -- 基于等距相机 yaw 映射 WASD
    local camYaw = Config.Camera.Yaw
    local yawRad = math.rad(camYaw)
    local fwd   = Vector3(math.sin(yawRad), 0, math.cos(yawRad)):Normalized()
    local right = Vector3(math.cos(yawRad), 0, -math.sin(yawRad)):Normalized()

    if (buttons & CTRL.FORWARD) ~= 0 then moveDir = moveDir + fwd end
    if (buttons & CTRL.BACK) ~= 0    then moveDir = moveDir - fwd end
    if (buttons & CTRL.LEFT) ~= 0    then moveDir = moveDir - right end
    if (buttons & CTRL.RIGHT) ~= 0   then moveDir = moveDir + right end

    if moveDir:Length() > 0.01 then
        moveDir = moveDir:Normalized()
        local newPos = roleNode.position + moveDir * speed * dt

        -- 边界钳制（整个地图范围）
        local L = Config.Level1
        newPos.x = Shared.Clamp(newPos.x, MAP_MIN_X + 0.5, MAP_MAX_X - 0.5)
        newPos.z = Shared.Clamp(newPos.z, MAP_MIN_Z + 0.5, MAP_MAX_Z - 0.5)

        -- 碰撞推开：障碍物
        local px, pz = Shared.ResolveObstacleCollisions(
            newPos.x, newPos.z, PLAYER_COLLISION_RADIUS, obstacleColliders_)

        -- 地形阻挡：blocked 格子不可通行（考虑碰撞半径）
        if Shared.IsTerrainBlocked(px, pz, PLAYER_COLLISION_RADIUS) then
            px = roleNode.position.x
            pz = roleNode.position.z
        end

        -- 碰撞推开：其他玩家
        for otherRoleId, otherConnKey in pairs(roleAssignments_) do
            if otherConnKey and otherRoleId ~= roleId then
                local otherNode = rolePool_[otherRoleId]
                if otherNode then
                    px, pz = Shared.ResolveCircleCollision(
                        px, pz, PLAYER_COLLISION_RADIUS,
                        otherNode.position.x, otherNode.position.z, PLAYER_COLLISION_RADIUS)
                end
            end
        end

        -- 碰撞推开：鸭子（玩家推开鸭子）
        for _, duck in ipairs(ducks_) do
            if duck.state ~= "settled" then
                local dpos = duck.node.position
                local ddx = dpos.x - px
                local ddz = dpos.z - pz
                local ddist = math.sqrt(ddx * ddx + ddz * ddz)
                local minDist = PLAYER_COLLISION_RADIUS + DUCK_COLLISION_RADIUS
                if ddist < minDist and ddist > 0.001 then
                    local overlap = minDist - ddist
                    local nx, nz = ddx / ddist, ddz / ddist
                    local newDX = dpos.x + nx * overlap
                    local newDZ = dpos.z + nz * overlap
                    -- 边界钳制
                    newDX = Shared.Clamp(newDX, MAP_MIN_X + 0.3, MAP_MAX_X - 0.3)
                    newDZ = Shared.Clamp(newDZ, MAP_MIN_Z + 0.3, MAP_MAX_Z - 0.3)
                    -- 障碍物碰撞推开
                    newDX, newDZ = Shared.ResolveObstacleCollisions(
                        newDX, newDZ, DUCK_COLLISION_RADIUS, obstacleColliders_)
                    -- 地形阻挡检查：如果推到 blocked 格子，回退到原位
                    if Shared.IsTerrainBlocked(newDX, newDZ, DUCK_COLLISION_RADIUS) then
                        newDX = dpos.x
                        newDZ = dpos.z
                    end
                    duck.node.position = Vector3(newDX, 0, newDZ)
                    duck.vel = duck.vel + Vector3(nx, 0, nz) * 1.5
                end
            end
        end

        -- 再次边界钳制（整个地图范围）
        px = Shared.Clamp(px, MAP_MIN_X + 0.5, MAP_MAX_X - 0.5)
        pz = Shared.Clamp(pz, MAP_MIN_Z + 0.5, MAP_MAX_Z - 0.5)

        roleNode.position = Vector3(px, 0, pz)

        -- 朝向
        local angle = math.deg(math.atan(moveDir.x, moveDir.z))
        roleNode.rotation = Quaternion(angle, Vector3.UP)
    end
end

-- ============================================================================
-- 鸭子 Boids AI（服务端权威）
-- ============================================================================

function UpdateDucks(dt)
    local D = Config.Duck
    local L = Config.Level1

    -- 收集所有活跃玩家位置
    local playerPositions = {}
    for roleId, connKey in pairs(roleAssignments_) do
        if connKey and rolePool_[roleId] then
            table.insert(playerPositions, rolePool_[roleId].position)
        end
    end

    -- 目标区域边界（从 terrainGrid 动态计算）
    local taMinX, taMaxX, taMinZ, taMaxZ = GetTargetBounds()

    for i, duck in ipairs(ducks_) do
        if duck.state == "settled" then
            -- ====== 上架鸭子：在围栏内自由闲逛 + 跳跃 ======
            local pos = duck.node.position
            local steer = Vector3.ZERO

            -- 闲逛力（在围栏内随机移动）
            duck.wanderAngle = duck.wanderAngle + (math.random() - 0.5) * 2.0 * dt
            local wanderDir = Vector3(math.cos(duck.wanderAngle), 0, math.sin(duck.wanderAngle))
            steer = steer + wanderDir * D.WanderWeight * 0.8

            -- 围栏边界约束（保持在目标区域内）
            local penMargin = 0.4
            if pos.x < taMinX + penMargin then steer = steer + Vector3(D.BoundaryWeight, 0, 0) end
            if pos.x > taMaxX - penMargin then steer = steer + Vector3(-D.BoundaryWeight, 0, 0) end
            if pos.z < taMinZ + penMargin then steer = steer + Vector3(0, 0, D.BoundaryWeight) end
            if pos.z > taMaxZ - penMargin then steer = steer + Vector3(0, 0, -D.BoundaryWeight) end

            -- 与其他上架鸭子的分离力
            for j, other in ipairs(ducks_) do
                if i ~= j and other.state == "settled" then
                    local diff = pos - other.node.position
                    diff.y = 0
                    local dist = diff:Length()
                    if dist < D.SeparationDist and dist > 0.01 then
                        steer = steer + diff:Normalized() * D.SeparationWeight * 0.5
                    end
                end
            end

            -- 应用转向
            duck.vel = duck.vel + steer * dt * 3.0
            duck.vel = duck.vel * 0.85  -- 阻尼（更强，减少围栏边沿震荡）
            duck.vel.y = 0
            local speed = duck.vel:Length()
            if speed > D.SettledWanderSpeed then
                duck.vel = duck.vel:Normalized() * D.SettledWanderSpeed
            end

            -- 更新位置
            local newPos = pos + duck.vel * dt

            -- 围栏内障碍物碰撞推开
            local resolvedX, resolvedZ = Shared.ResolveObstacleCollisions(
                newPos.x, newPos.z, DUCK_COLLISION_RADIUS, obstacleColliders_)

            -- 地形阻挡：blocked 格子不可通行（考虑碰撞半径）
            if Shared.IsTerrainBlocked(resolvedX, resolvedZ, DUCK_COLLISION_RADIUS) then
                resolvedX = pos.x
                resolvedZ = pos.z
                duck.vel = Vector3.ZERO
            end

            -- 与其他上架鸭子碰撞推开
            for j, other in ipairs(ducks_) do
                if j ~= i and other.state == "settled" then
                    resolvedX, resolvedZ = Shared.ResolveCircleCollision(
                        resolvedX, resolvedZ, DUCK_COLLISION_RADIUS,
                        other.node.position.x, other.node.position.z, DUCK_COLLISION_RADIUS)
                end
            end

            -- 边界钳制 + 碰壁速度归零（消除 Clamp 与力之间的拉锯震荡）
            local clampMinX = taMinX + 0.3
            local clampMaxX = taMaxX - 0.3
            local clampMinZ = taMinZ + 0.3
            local clampMaxZ = taMaxZ - 0.3
            if resolvedX <= clampMinX then resolvedX = clampMinX; if duck.vel.x < 0 then duck.vel.x = 0 end end
            if resolvedX >= clampMaxX then resolvedX = clampMaxX; if duck.vel.x > 0 then duck.vel.x = 0 end end
            if resolvedZ <= clampMinZ then resolvedZ = clampMinZ; if duck.vel.z < 0 then duck.vel.z = 0 end end
            if resolvedZ >= clampMaxZ then resolvedZ = clampMaxZ; if duck.vel.z > 0 then duck.vel.z = 0 end end
            newPos.x = resolvedX
            newPos.z = resolvedZ

            -- 跳跃动画
            duck.jumpTimer = duck.jumpTimer - dt
            if duck.jumpTimer <= 0 then
                duck.jumpAnim = D.SettledJumpDuration
                local interval = D.SettledJumpInterval
                duck.jumpTimer = interval[1] + math.random() * (interval[2] - interval[1])
            end

            local groundY = 0
            if duck.jumpAnim > 0 then
                duck.jumpAnim = duck.jumpAnim - dt
                local t = 1.0 - (duck.jumpAnim / D.SettledJumpDuration)
                groundY = math.sin(t * math.pi) * D.SettledJumpHeight
                if duck.jumpAnim <= 0 then
                    duck.jumpAnim = 0
                end
            end
            newPos.y = groundY

            duck.node.position = newPos

            -- 朝向
            if speed > 0.05 then
                local angle = math.deg(math.atan(duck.vel.x, duck.vel.z))
                duck.node.rotation = Quaternion(angle, Vector3.UP)
            end

            goto continue
        end

        local pos = duck.node.position
        local steer = Vector3.ZERO

        -- === 1. 分离力 ===
        local separationMul = (duck.state == "panic") and 1.45 or 1.0
        for j, other in ipairs(ducks_) do
            if i ~= j and other.state ~= "settled" then
                local diff = pos - other.node.position
                diff.y = 0
                local dist = diff:Length()
                if dist < D.SeparationDist and dist > 0.01 then
                    steer = steer + diff:Normalized() * (D.SeparationDist - dist) / D.SeparationDist * D.SeparationWeight * separationMul
                end
            end
        end

        -- === 2. 聚合力 ===
        local cohesionCenter = Vector3.ZERO
        local cohesionCount = 0
        for j, other in ipairs(ducks_) do
            if i ~= j and other.state ~= "settled" then
                local dist = (pos - other.node.position):Length()
                if dist < D.CohesionRadius then
                    cohesionCenter = cohesionCenter + other.node.position
                    cohesionCount = cohesionCount + 1
                end
            end
        end
        if cohesionCount > 0 then
            cohesionCenter = cohesionCenter / cohesionCount
            local toCenter = cohesionCenter - pos
            toCenter.y = 0
            if toCenter:Length() > 0.01 then
                local cohesionMul = 1.0
                if duck.state == "alert" then cohesionMul = 0.7 end
                if duck.state == "panic" then cohesionMul = 0.35 end
                steer = steer + toCenter:Normalized() * D.CohesionWeight * cohesionMul
            end
        end

        -- === 3. 恐惧力（远离所有玩家，区分警觉/惊慌） ===
        local alertHit = false
        local panicHit = false
        for _, playerPos in ipairs(playerPositions) do
            local toPlayer = pos - playerPos
            toPlayer.y = 0
            local distToPlayer = toPlayer:Length()
            if distToPlayer < D.FearRadius and distToPlayer > 0.01 then
                local fearStrength = (1.0 - distToPlayer / D.FearRadius)
                steer = steer + toPlayer:Normalized() * fearStrength * D.FearWeight
                panicHit = true
            elseif distToPlayer < D.AlertRadius and distToPlayer > 0.01 then
                local alertStrength = (1.0 - distToPlayer / D.AlertRadius)
                steer = steer + toPlayer:Normalized() * alertStrength * D.AlertFearWeight
                alertHit = true
            end
        end
        if panicHit then
            SetDuckState(duck, "panic", D.CalmDownTime)
        elseif alertHit and duck.state ~= "panic" then
            SetDuckState(duck, "alert", D.AlertTime)
        end

        -- === 4. 恐惧衰减 ===
        if duck.state == "panic" or duck.state == "alert" then
            duck.fearTimer = duck.fearTimer - dt
            if duck.fearTimer <= 0 then
                SetDuckState(duck, "idle", 0)
            end
        end

        -- === 5. 闲逛（警觉状态会收敛一点） ===
        if duck.state == "idle" or duck.state == "alert" then
            duck.wanderAngle = duck.wanderAngle + (math.random() - 0.5) * 2.0 * dt
            local wanderDir = Vector3(math.cos(duck.wanderAngle), 0, math.sin(duck.wanderAngle))
            local wanderMul = (duck.state == "alert") and 0.35 or 1.0
            steer = steer + wanderDir * D.WanderWeight * wanderMul
        end

        -- === 6. 边界约束（整个地图范围） ===
        local margin = 1.0
        if pos.x < MAP_MIN_X + margin then steer = steer + Vector3(D.BoundaryWeight, 0, 0) end
        if pos.x > MAP_MAX_X - margin then steer = steer + Vector3(-D.BoundaryWeight, 0, 0) end
        if pos.z < MAP_MIN_Z + margin then steer = steer + Vector3(0, 0, D.BoundaryWeight) end
        if pos.z > MAP_MAX_Z - margin then steer = steer + Vector3(0, 0, -D.BoundaryWeight) end

        -- === 7. 障碍物避让 ===
        for _, obs in ipairs(L.Obstacles) do
            local obsPos = Vector3(obs.pos.x, 0, obs.pos.z)
            local obsRadius = math.max(obs.scale.x, obs.scale.z) * 0.6
            local toObs = pos - obsPos
            toObs.y = 0
            local distObs = toObs:Length()
            if distObs < obsRadius + 0.5 and distObs > 0.01 then
                steer = steer + toObs:Normalized() * D.ObstacleWeight * (1.0 - distObs / (obsRadius + 0.5))
            end
        end

        -- === 8. 面包屑吸引力（第一关引诱玩法最小版） ===
        if breadState_ == "active" and breadActivePos_ ~= nil then
            local toBread = breadActivePos_ - pos
            toBread.y = 0
            local distBread = toBread:Length()
            if distBread < Config.Bread.AttractRadius and distBread > 0.01 then
                local attract = (1.0 - distBread / Config.Bread.AttractRadius) * Config.Bread.AttractWeight
                if duck.state == "panic" then
                    attract = attract * 0.65
                end
                steer = steer + toBread:Normalized() * attract
                if distBread < Config.Bread.EatSlowRadius then
                    duck.vel = duck.vel * 0.8
                end
            end
        end

        -- === 应用转向力 ===
        duck.vel = duck.vel + steer * dt * 5.0

        local damping = duck.state == "panic" and 0.97 or 0.92
        duck.vel = duck.vel * damping

        duck.vel.y = 0
        local speed = duck.vel:Length()
        local maxSpd = D.MoveSpeed * 0.5
        if duck.state == "alert" then
            maxSpd = D.MoveSpeed * 0.75
        elseif duck.state == "panic" then
            maxSpd = D.MaxSpeed * D.PanicSpeedMultiplier
        end
        if speed > maxSpd then
            duck.vel = duck.vel:Normalized() * maxSpd
        end

        -- 更新位置
        local newPos = pos + duck.vel * dt
        newPos.y = 0
        newPos.x = Shared.Clamp(newPos.x, MAP_MIN_X + 0.3, MAP_MAX_X - 0.3)
        newPos.z = Shared.Clamp(newPos.z, MAP_MIN_Z + 0.3, MAP_MAX_Z - 0.3)

        -- 碰撞推开：障碍物
        local nx, nz = Shared.ResolveObstacleCollisions(
            newPos.x, newPos.z, DUCK_COLLISION_RADIUS, obstacleColliders_)

        -- 碰撞推开：所有活跃玩家
        for rid, ck in pairs(roleAssignments_) do
            if ck and rolePool_[rid] then
                nx, nz = Shared.ResolveCircleCollision(
                    nx, nz, DUCK_COLLISION_RADIUS,
                    rolePool_[rid].position.x, rolePool_[rid].position.z, PLAYER_COLLISION_RADIUS)
            end
        end

        -- 碰撞推开：其他鸭子
        for j, other in ipairs(ducks_) do
            if j ~= i and other.state ~= "settled" then
                nx, nz = Shared.ResolveCircleCollision(
                    nx, nz, DUCK_COLLISION_RADIUS,
                    other.node.position.x, other.node.position.z, DUCK_COLLISION_RADIUS)
            end
        end

        -- 地形阻挡：blocked 格子不可通行（考虑碰撞半径）
        if Shared.IsTerrainBlocked(nx, nz, DUCK_COLLISION_RADIUS) then
            nx = pos.x
            nz = pos.z
            duck.vel = Vector3.ZERO
        end

        -- 再次边界钳制（整个地图范围）
        nx = Shared.Clamp(nx, MAP_MIN_X + 0.3, MAP_MAX_X - 0.3)
        nz = Shared.Clamp(nz, MAP_MIN_Z + 0.3, MAP_MAX_Z - 0.3)

        duck.node.position = Vector3(nx, 0, nz)

        -- 朝向
        if duck.vel:Length() > 0.1 then
            local angle = math.deg(math.atan(duck.vel.x, duck.vel.z))
            duck.node.rotation = Quaternion(angle, Vector3.UP)
        end

        ::continue::
    end
end

-- ============================================================================
-- 上架检测（服务端权威）
-- ============================================================================

function CheckSettled()
    local dt = 1.0 / 60.0

    -- 第一遍：累积 settleTimer，标记新上架的鸭子
    local newlySettled = {}
    for _, duck in ipairs(ducks_) do
        if duck.state == "settled" then
            goto next
        end

        local pos = duck.node.position
        -- 使用 terrainGrid 的 "target" 格子判定是否在目标区
        local gx = math.floor(pos.x)
        local gz = math.floor(pos.z)
        local inTarget = Shared.terrainGrid
            and Shared.terrainGrid[gx]
            and Shared.terrainGrid[gx][gz] == "target"

        if inTarget then
            duck.settleTimer = duck.settleTimer + dt
            if duck.settleTimer >= Config.Duck.SettleTime then
                duck.state = "settled"
                -- 保留随机闲逛速度，不归零
                local randAngle = math.random() * math.pi * 2
                duck.vel = Vector3(math.cos(randAngle), 0, math.sin(randAngle)) * Config.Duck.SettledWanderSpeed * 0.5
                duck.wanderAngle = randAngle
                -- 初始化跳跃计时
                local interval = Config.Duck.SettledJumpInterval
                duck.jumpTimer = interval[1] + math.random() * (interval[2] - interval[1])
                duck.jumpAnim = 0
                duck.node:SetVar(VARS.DUCK_STATE, Variant("settled"))
                table.insert(newlySettled, duck)
            end
        else
            duck.settleTimer = 0
        end

        ::next::
    end

    -- 第二遍：统计所有 settled 鸭子的准确总数
    settledCount_ = 0
    for _, duck in ipairs(ducks_) do
        if duck.state == "settled" then
            settledCount_ = settledCount_ + 1
        end
    end

    -- 用准确总数广播所有新上架事件
    for _, duck in ipairs(newlySettled) do
        print("[Server] 鸭子上架! 已上架: " .. settledCount_)
        BroadcastDuckSettled(duck.node.ID, settledCount_)
    end

    -- ====== 逃跑判定（每15秒检查一次）======
    escapeCheckTimer_ = escapeCheckTimer_ - dt
    if escapeCheckTimer_ <= 0 then
        escapeCheckTimer_ = Config.Duck.EscapeCheckInterval

        -- 收集所有活跃玩家位置
        local activePlayers = {}
        for roleId, connKey in pairs(roleAssignments_) do
            if connKey and rolePool_[roleId] then
                table.insert(activePlayers, rolePool_[roleId].position)
            end
        end

        for _, duck in ipairs(ducks_) do
            if duck.state == "settled" then
                local duckPos = duck.node.position
                -- 检查是否所有玩家都超过逃跑距离
                local allFar = true
                for _, pPos in ipairs(activePlayers) do
                    local dist = (Vector3(duckPos.x, 0, duckPos.z) - Vector3(pPos.x, 0, pPos.z)):Length()
                    if dist <= Config.Duck.EscapeDistance then
                        allFar = false
                        break
                    end
                end
                -- 无玩家在线时也算"都很远"
                if #activePlayers == 0 then allFar = true end

                if allFar then
                    -- 1/15 概率逃跑
                    if math.random() < Config.Duck.EscapeChance then
                        duck.state = "panic"
                        duck.settleTimer = 0
                        duck.jumpAnim = 0
                        duck.node.position = Vector3(duck.node.position.x, 0, duck.node.position.z)
                        -- 给一个向围栏开口方向的冲刺速度
                        duck.vel = Vector3(-1, 0, 0) * Config.Duck.MoveSpeed * 1.5
                        duck.fearTimer = Config.Duck.CalmDownTime
                        duck.node:SetVar(VARS.DUCK_STATE, Variant("panic"))

                        -- 逃跑后递减计数
                        settledCount_ = settledCount_ - 1

                        -- 广播逃跑事件给客户端（携带最新计数）
                        BroadcastDuckEscaped(duck.node.ID, settledCount_)
                        print("[Server] 鸭子逃跑了! 剩余上架: " .. settledCount_)
                    end
                end
            end
        end
    end

    -- 星级判定 + 完成检测
    local L = Config.Level1
    local newStar = 0
    if settledCount_ >= L.Star3 then newStar = 3
    elseif settledCount_ >= L.Star2 then newStar = 2
    elseif settledCount_ >= L.Star1 then newStar = 1
    end

    if newStar > starRating_ then
        starRating_ = newStar
        print("[Server] 当前星级: " .. string.rep("★", starRating_))
    end

    -- 全部上架 → 游戏结束
    if settledCount_ >= totalDucks_ and gameState_ == Config.GameState.PLAYING then
        gameState_ = Config.GameState.COMPLETE
        BroadcastGameResult()
    end
end

-- ============================================================================
-- 广播事件
-- ============================================================================

function BroadcastPing(roleId, pingType, pos)
    local eventData = VariantMap()
    eventData["RoleId"] = Variant(roleId)
    eventData["PingType"] = Variant(pingType)
    eventData["X"] = Variant(pos.x)
    eventData["Z"] = Variant(pos.z)

    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.PING_BROADCAST, true, eventData)
    end
end

function FillBreadState(eventData)
    eventData["State"] = Variant(breadState_)
    eventData["OwnerRole"] = Variant(breadOwnerRole_ or 0)
    eventData["PickupX"] = Variant(Config.Level1.BreadcrumbPos.x)
    eventData["PickupZ"] = Variant(Config.Level1.BreadcrumbPos.z)
    eventData["ActiveX"] = Variant(breadActivePos_ and breadActivePos_.x or 0)
    eventData["ActiveZ"] = Variant(breadActivePos_ and breadActivePos_.z or 0)
    eventData["TimeLeft"] = Variant(math.max(breadActiveTimer_, breadRespawnTimer_))
end

function SendBreadState(conn)
    if conn == nil then return end
    local eventData = VariantMap()
    FillBreadState(eventData)
    conn:SendRemoteEvent(EVENTS.BREAD_STATE, true, eventData)
end

function BroadcastBreadState()
    local eventData = VariantMap()
    FillBreadState(eventData)
    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.BREAD_STATE, true, eventData)
    end
end

function BroadcastDuckSettled(duckNodeId, count)
    local eventData = VariantMap()
    eventData["NodeId"] = Variant(duckNodeId)
    eventData["SettledCount"] = Variant(count)
    eventData["TotalDucks"] = Variant(totalDucks_)

    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.DUCK_SETTLED, true, eventData)
    end
end

function BroadcastDuckEscaped(duckNodeId, count)
    local eventData = VariantMap()
    eventData["NodeId"] = Variant(duckNodeId)
    eventData["SettledCount"] = Variant(count)
    eventData["TotalDucks"] = Variant(totalDucks_)

    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.DUCK_ESCAPED, true, eventData)
    end
end

function BroadcastGameResult()
    local minutes = math.floor(gameTime_ / 60)
    local seconds = math.floor(gameTime_ % 60)

    -- 计算金币：每只上架鸭子 1 枚 + 每颗星 1 枚
    local earnedGold = settledCount_ + starRating_

    local eventData = VariantMap()
    eventData["Stars"] = Variant(starRating_)
    eventData["SettledCount"] = Variant(settledCount_)
    eventData["TotalDucks"] = Variant(totalDucks_)
    eventData["TimeMinutes"] = Variant(minutes)
    eventData["TimeSeconds"] = Variant(seconds)
    eventData["EarnedGold"] = Variant(earnedGold)

    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.GAME_RESULT, true, eventData)
    end

    print("[Server] 游戏结束! 星级: " .. starRating_
        .. " 金币: +" .. earnedGold
        .. " 用时: " .. string.format("%02d:%02d", minutes, seconds))
end

-- ============================================================================
-- 地图编辑器同步（客户端 → 服务端）
-- ============================================================================

--- 处理障碍物编辑事件：add / move / scale / delete
function HandleMapEditObs(eventType, eventData)
    local action   = eventData["Action"]:GetString()
    local obsName  = eventData["Name"]:GetString()
    -- IsDec 标记：true 表示操作装饰物（Config.Exterior.Decorations），否则操作障碍物
    local isDec    = eventData:GetBool("IsDec")

    local label = isDec and "装饰物" or "障碍物"
    print(string.format("[Server] 收到地图编辑事件: %s %s (%s)", action, obsName, label))

    -- 选择目标数组
    local targetList = isDec and Config.Exterior.Decorations or Config.Level1.Obstacles

    if action == "delete" then
        for i, entry in ipairs(targetList) do
            if entry.name == obsName then
                table.remove(targetList, i)
                print(string.format("[Server] 已删除%s: %s, 剩余: %d", label, obsName, #targetList))
                break
            end
        end

    elseif action == "move" then
        local posX = eventData["PosX"]:GetFloat()
        local posZ = eventData["PosZ"]:GetFloat()
        for _, entry in ipairs(targetList) do
            if entry.name == obsName then
                entry.pos = Vector3(posX, 0, posZ)
                print(string.format("[Server] 已移动%s: %s -> (%.1f, %.1f)", label, obsName, posX, posZ))
                break
            end
        end

    elseif action == "scale" then
        local modelScale = eventData["ModelScale"]:GetFloat()
        for _, entry in ipairs(targetList) do
            if entry.name == obsName then
                entry.modelScale = modelScale
                print(string.format("[Server] 已缩放%s: %s -> %.2f", label, obsName, modelScale))
                break
            end
        end

    elseif action == "add" then
        local posX       = eventData["PosX"]:GetFloat()
        local posZ       = eventData["PosZ"]:GetFloat()
        local modelKey   = eventData["ModelKey"]:GetString()
        local modelScale = eventData["ModelScale"]:GetFloat()
        local scaleX     = eventData["ScaleX"]:GetFloat()
        local scaleY     = eventData["ScaleY"]:GetFloat()
        local scaleZ     = eventData["ScaleZ"]:GetFloat()

        local newEntry = {
            pos = Vector3(posX, 0, posZ),
            scale = Vector3(scaleX, scaleY, scaleZ),
            name = obsName,
            modelKey = modelKey,
            modelScale = modelScale,
        }
        table.insert(targetList, newEntry)
        print(string.format("[Server] 已添加%s: %s (%s) 在 (%.1f, %.1f)", label, obsName, modelKey, posX, posZ))
    end

    -- 仅障碍物操作需要重建碰撞缓存（装饰物无碰撞）
    if not isDec then
        obstacleColliders_ = Shared.BuildObstacleColliders()
        print(string.format("[Server] 障碍物碰撞缓存已重建(网络同步), 碰撞体数量: %d", #obstacleColliders_))
    end
end

--- 处理地形网格同步事件
function HandleMapEditTerrain(eventType, eventData)
    local gridData = eventData["GridData"]:GetString()

    print("[Server] 收到地形网格同步, 数据长度: " .. #gridData)

    -- 反序列化: "x,z,type;x,z,type;..." 格式
    local grid = {}
    for entry in gridData:gmatch("[^;]+") do
        local x, z, cellType = entry:match("^(-?%d+),(-?%d+),(%a+)$")
        if x and z and cellType then
            x = tonumber(x)
            z = tonumber(z)
            if not grid[x] then grid[x] = {} end
            grid[x][z] = cellType
        end
    end

    Shared.terrainGrid = grid
    print("[Server] 地形网格已更新(网络同步)")
end

--- 处理结构物编辑事件（围栏/围墙段删除）
function HandleMapEditStruct(eventType, eventData)
    local action = eventData["Action"]:GetString()
    local label  = eventData["Label"]:GetString()
    local sType  = eventData["Type"]:GetString()
    local side   = eventData["Side"] and eventData["Side"]:GetString() or ""

    print(string.format("[Server] 收到结构物编辑: action=%s label=%s type=%s side=%s", action, label, sType, side))

    if action == "delete" then
        if sType == "Fence" then
            -- 优先使用 side（基于位置的方向标识），比 label 更可靠
            if side ~= "" then
                Shared.RemoveFenceSegmentBySide(side)
            else
                Shared.RemoveFenceSegment(label)
            end
            print(string.format("[Server] 围栏段 '%s' (side=%s) 碰撞体已标记重建", label, side))
        elseif sType == "Wall" then
            -- 围墙碰撞由 terrainGrid blocked 格子管理
            -- 删除围墙段视觉效果后，用户需要通过地形编辑器将对应格子改为 open
            print(string.format("[Server] 围墙段 '%s' 已删除（碰撞由地形网格控制）", label))
        end
    end
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

return Server
