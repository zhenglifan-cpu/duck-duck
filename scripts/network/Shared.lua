-- ============================================================================
-- Shared.lua — 共享代码（Server / Client 均引用）
-- 职责：场景创建、地图搭建、材质工具、远程事件注册
-- ============================================================================

local Shared = {}
local Config = require("config.GameConfig")

-- Re-export 方便其他模块使用
Shared.Config  = Config
Shared.CTRL    = Config.CTRL
Shared.EVENTS  = Config.EVENTS
Shared.VARS    = Config.VARS

-- ============================================================================
-- 工具函数
-- ============================================================================

function Shared.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- 创建 PBR 纯色材质（不透明）
function Shared.CreatePBRMaterial(color, metallic, roughness)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(color.r, color.g, color.b, 1.0)))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.5, 0.5, 0.5, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    return mat
end

--- 创建 PBR 半透明材质
function Shared.CreatePBRAlphaMaterial(color, metallic, roughness)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.4, 0.4, 0.4, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    return mat
end

-- ============================================================================
-- 场景创建
-- ============================================================================

function Shared.CreateScene(isServer)
    local scene = Scene()

    scene:CreateComponent("Octree", LOCAL)
    scene:CreateComponent("DebugRenderer", LOCAL)

    local physicsWorld = scene:CreateComponent("PhysicsWorld", LOCAL)
    physicsWorld:SetGravity(Vector3(0, -9.81, 0))

    -- 光照（仅客户端）
    if not isServer then
        scene:InstantiateXML("LightGroup/Daytime.xml", Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
    end

    -- 搭建地图
    Shared.CreateMap(scene, isServer)

    return scene
end

-- ============================================================================
-- 地图搭建
-- ============================================================================

function Shared.CreateMap(scene, isServer)
    local L = Config.Level1
    local C = Config.Colors

    -- ====== 外围环境（在农场地面之前创建，层级在下方）======
    Shared.CreateExterior(scene, isServer)

    -- ====== 地面 ======
    local floor = scene:CreateChild("Floor", LOCAL)
    floor.position = Vector3(L.MapWidth / 2, -0.25, L.MapHeight / 2)
    floor.scale = Vector3(L.MapWidth, 0.5, L.MapHeight)
    if not isServer then
        local m = floor:CreateComponent("StaticModel", LOCAL)
        m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        -- 纯色草地（与树木绿色一致）
        local grassMat = Material:new()
        grassMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        grassMat:SetShaderParameter("MatDiffColor", Variant(Color(0.25, 0.82, 0.05, 1.0)))
        grassMat:SetShaderParameter("Roughness", Variant(0.92))
        grassMat:SetShaderParameter("Metallic", Variant(0.0))
        m:SetMaterial(grassMat)
    end
    local fb = floor:CreateComponent("RigidBody", LOCAL)
    fb:SetCollisionLayer(1)
    local fs = floor:CreateComponent("CollisionShape", LOCAL)
    fs:SetBox(Vector3(1, 1, 1))

    -- ====== 目标区地面（黄色棋盘格贴图，按 terrainGrid target 格子动态生成） ======
    if not isServer then
        Shared.RebuildTargetFloor(scene)
    end

    -- ====== 边界围墙（h=0.7m，参考概念图比例） ======
    local wallH = 0.7
    local wallThick = 0.5
    -- 下边 (Z=0) — 水平墙包裹角落
    Shared.CreateWall(scene, Vector3(L.MapWidth/2, wallH/2, -wallThick/2), Vector3(L.MapWidth + wallThick, wallH, wallThick), isServer)
    -- 上边 (Z=MapHeight) — 水平墙包裹角落
    Shared.CreateWall(scene, Vector3(L.MapWidth/2, wallH/2, L.MapHeight + wallThick/2), Vector3(L.MapWidth + wallThick, wallH, wallThick), isServer)
    -- 左边 (X=0) — 垂直墙不包含角落，缩短长度
    Shared.CreateWall(scene, Vector3(-wallThick/2, wallH/2, L.MapHeight/2), Vector3(wallThick, wallH, L.MapHeight), isServer)
    -- 右边 (X=MapWidth) — 垂直墙不包含角落，缩短长度
    Shared.CreateWall(scene, Vector3(L.MapWidth + wallThick/2, wallH/2, L.MapHeight/2), Vector3(wallThick, wallH, L.MapHeight), isServer)

    -- ====== U 形目标围栏 ======
    Shared.CreateTargetFence(scene, isServer)

    -- ====== 障碍物 ======
    for _, obs in ipairs(L.Obstacles) do
        Shared.CreateObstacle(scene, obs, isServer)
    end

    -- ====== 面包屑道具（仅视觉+触发器） ======
    Shared.CreateBreadcrumb(scene, L.BreadcrumbPos, isServer)

    print("[Shared] Map created: " .. L.Name)
end

-- ============================================================================
-- 目标区地面重建（黄色棋盘格贴图，按 terrainGrid target 格子生成）
-- ============================================================================

--- 缓存的目标区材质（避免每格重复创建）
local targetFloorMat_ = nil

local function GetTargetFloorMaterial()
    if targetFloorMat_ then return targetFloorMat_ end
    targetFloorMat_ = Material:new()
    targetFloorMat_:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRDiff.xml"))
    targetFloorMat_:SetTexture(TU_DIFFUSE, cache:GetResource("Texture2D", "image/target_checker_20260511052831.png"))
    targetFloorMat_:SetShaderParameter("UOffset", Variant(Vector4(1, 0, 0, 0)))
    targetFloorMat_:SetShaderParameter("VOffset", Variant(Vector4(0, 1, 0, 0)))
    targetFloorMat_:SetShaderParameter("Roughness", Variant(0.7))
    targetFloorMat_:SetShaderParameter("Metallic", Variant(0.0))
    return targetFloorMat_
end

--- 根据 Shared.terrainGrid 的 "target" 格子动态重建目标区地面
---@param scene Scene
function Shared.RebuildTargetFloor(scene)
    -- 删除旧容器
    local old = scene:GetChild("TargetFloorGroup", false)
    if old then old:Remove() end

    local group = scene:CreateChild("TargetFloorGroup", LOCAL)
    local mat = GetTargetFloorMaterial()
    local boxModel = cache:GetResource("Model", "Models/Box.mdl")

    -- 优先使用 terrainGrid
    local grid = Shared.terrainGrid
    if grid then
        for x, row in pairs(grid) do
            for z, cellType in pairs(row) do
                if cellType == "target" then
                    local tile = group:CreateChild("TF", LOCAL)
                    tile.position = Vector3(x + 0.5, 0.011, z + 0.5)
                    tile.scale = Vector3(1.0, 0.01, 1.0)
                    local sm = tile:CreateComponent("StaticModel", LOCAL)
                    sm:SetModel(boxModel)
                    sm:SetMaterial(mat)
                end
            end
        end
    else
        -- fallback：使用 Config 默认 TargetArea
        local ta = Config.Level1.TargetArea
        local hx = ta.Size.x / 2
        local hz = ta.Size.z / 2
        local minX = math.floor(ta.Center.x - hx)
        local maxX = math.ceil(ta.Center.x + hx)
        local minZ = math.floor(ta.Center.z - hz)
        local maxZ = math.ceil(ta.Center.z + hz)
        for x = minX, maxX - 1 do
            for z = minZ, maxZ - 1 do
                local tile = group:CreateChild("TF", LOCAL)
                tile.position = Vector3(x + 0.5, 0.011, z + 0.5)
                tile.scale = Vector3(1.0, 0.01, 1.0)
                local sm = tile:CreateComponent("StaticModel", LOCAL)
                sm:SetModel(boxModel)
                sm:SetMaterial(mat)
            end
        end
    end
end

-- ============================================================================
-- 围墙
-- ============================================================================

function Shared.CreateWall(scene, pos, size, isServer)
    local wall = scene:CreateChild("Wall", LOCAL)
    wall.position = pos

    local wallModel = Config.Models.Wall
    if not isServer then
        if wallModel then
            -- 院墙模型自然尺寸: ~1.75 x 0.22 x 0.20 (X x Y x Z)
            -- X方向是模型的长边(~1.75m)，用来沿墙排列
            local isHorizontal = (size.x > size.z)
            local wallLength = isHorizontal and size.x or size.z

            -- 等比缩放: 让模型高度匹配墙高
            local modelNaturalHeight = 0.22  -- 模型自然高度(Y)
            local ms = size.y / modelNaturalHeight  -- 统一缩放因子
            local segmentSpan = 1.75 * ms  -- 每段覆盖的长度(X方向 * 缩放)

            -- 从墙起点开始，步进 segmentSpan，只放置段中心在墙范围内的段
            local halfLen = wallLength / 2
            local startOffset = -halfLen + segmentSpan / 2  -- 第一段中心
            local segIndex = 0

            while true do
                local offset = startOffset + segIndex * segmentSpan
                -- 段中心超出墙范围就停止
                if offset > halfLen then break end

                local segNode = wall:CreateChild("WallSeg", LOCAL)
                segNode.scale = Vector3(ms, ms, ms)

                -- 模型X轴是长边(~1.75m)
                -- 水平墙(沿世界X): 模型X自然沿X，无需旋转
                -- 垂直墙(沿世界Z): 旋转90°让模型X映射到世界Z
                if isHorizontal then
                    segNode.position = Vector3(offset, 0, 0)
                else
                    segNode.rotation = Quaternion(90, Vector3.UP)
                    segNode.position = Vector3(0, 0, offset)
                end

                local m = segNode:CreateComponent("StaticModel", LOCAL)
                m:SetModel(cache:GetResource("Model", wallModel.model))
                m:SetMaterial(cache:GetResource("Material", wallModel.material))
                m.castShadows = true

                -- 底部对齐: 让模型底部贴 y=0
                local bb = m.boundingBox
                segNode.position = Vector3(segNode.position.x, -pos.y - bb.min.y * ms, segNode.position.z)

                segIndex = segIndex + 1
            end
        else
            wall.scale = size
            local m = wall:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            m:SetMaterial(Shared.CreatePBRMaterial(Config.Colors.Wall, 0.0, 0.75))
            m.castShadows = true
        end
    end

    local b = wall:CreateComponent("RigidBody", LOCAL)
    b:SetCollisionLayer(1)
    local s = wall:CreateComponent("CollisionShape", LOCAL)
    s:SetBox(size)
end

-- ============================================================================
-- U 形目标围栏
-- ============================================================================

function Shared.CreateTargetFence(scene, isServer)
    local ta = Config.Level1.TargetArea
    local cx, cz = ta.Center.x, ta.Center.z
    local hw, hh = ta.Size.x / 2, ta.Size.z / 2
    local fenceH = 0.8
    local fenceThick = 0.3

    -- 右段 (X+ 侧，完整高墙)
    Shared.CreateFenceSegment(scene,
        Vector3(cx + hw + fenceThick/2, fenceH/2, cz),
        Vector3(fenceThick, fenceH, ta.Size.z + fenceThick*2),
        isServer)

    -- 上段 (Z+ 侧)
    Shared.CreateFenceSegment(scene,
        Vector3(cx, fenceH/2, cz + hh + fenceThick/2),
        Vector3(ta.Size.x, fenceH, fenceThick),
        isServer)

    -- 下段 (Z- 侧)
    Shared.CreateFenceSegment(scene,
        Vector3(cx, fenceH/2, cz - hh - fenceThick/2),
        Vector3(ta.Size.x, fenceH, fenceThick),
        isServer)
end

function Shared.CreateFenceSegment(scene, pos, size, isServer)
    local fence = scene:CreateChild("Fence", LOCAL)
    fence.position = pos

    local fenceModel = Config.Models.Fence
    if not isServer then
        if fenceModel then
            -- 新围栏模型自然尺寸: ~0.076 x 0.221 x 0.998 (X x Y x Z)
            -- Z方向是模型的长边(~1.0m)，沿围栏排列
            local isHorizontal = (size.x > size.z)
            local fenceLength = isHorizontal and size.x or size.z

            -- 等比缩放: 让模型高度匹配围栏高度
            local modelNaturalHeight = 0.221
            local ms = size.y / modelNaturalHeight
            local segmentSpan = 0.998 * ms  -- 每段覆盖的长度(Z方向 * 缩放)

            -- 从围栏起点开始，步进 segmentSpan
            local halfLen = fenceLength / 2
            local startOffset = -halfLen + segmentSpan / 2
            local segIndex = 0

            while true do
                local offset = startOffset + segIndex * segmentSpan
                if offset > halfLen then break end

                local segNode = fence:CreateChild("FenceSeg", LOCAL)
                segNode.scale = Vector3(ms, ms, ms)

                -- 模型Z轴是长边(~1.0m)
                -- 水平围栏(沿世界X): 旋转90°让模型Z映射到世界X
                -- 垂直围栏(沿世界Z): 模型Z自然沿Z，无需旋转
                if isHorizontal then
                    segNode.rotation = Quaternion(90, Vector3.UP)
                    segNode.position = Vector3(offset, 0, 0)
                else
                    segNode.position = Vector3(0, 0, offset)
                end

                local m = segNode:CreateComponent("StaticModel", LOCAL)
                m:SetModel(cache:GetResource("Model", fenceModel.model))
                m:SetMaterial(cache:GetResource("Material", fenceModel.material))
                m.castShadows = true

                -- 底部对齐
                local bb = m.boundingBox
                segNode.position = Vector3(
                    segNode.position.x,
                    -pos.y - bb.min.y * ms,
                    segNode.position.z
                )

                segIndex = segIndex + 1
            end
        else
            fence.scale = size
            local m = fence:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            m:SetMaterial(Shared.CreatePBRMaterial(Config.Colors.Fence, 0.0, 0.7))
            m.castShadows = true
        end
    end

    local b = fence:CreateComponent("RigidBody", LOCAL)
    b:SetCollisionLayer(1)
    local s = fence:CreateComponent("CollisionShape", LOCAL)
    s:SetBox(size)
end

-- ============================================================================
-- 障碍物（统一创建）
-- ============================================================================

function Shared.CreateObstacle(scene, obs, isServer)
    local pos   = obs.pos
    local scale = obs.scale
    local name  = obs.name

    local node = scene:CreateChild(name, LOCAL)
    -- 碰撞体位置：底部贴地
    node.position = Vector3(pos.x, scale.y / 2, pos.z)

    -- 查找是否有对应的 3D 模型
    local modelInfo = obs.modelKey and Config.Models[obs.modelKey] or nil

    if not isServer then
        if modelInfo then
            -- ===== 使用导入的 3D 模型 =====
            local visualNode = node:CreateChild("Visual", LOCAL)
            local ms = obs.modelScale or 1.0
            visualNode.scale = Vector3(ms, ms, ms)

            -- 支持模型旋转修正（如饮水池需要转正）
            if obs.modelRotation then
                visualNode.rotation = obs.modelRotation
            end

            local m = visualNode:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", modelInfo.model))
            m:SetMaterial(cache:GetResource("Material", modelInfo.material))
            m.castShadows = true

            -- 用世界包围盒计算底部偏移，让模型底部贴地（y=0）
            local worldBB = m.worldBoundingBox
            local worldMinY = worldBB.min.y
            visualNode.position = Vector3(
                visualNode.position.x,
                visualNode.position.y + (node.position.y - scale.y / 2) - worldMinY,
                visualNode.position.z
            )
        else
            -- ===== 回退到基础形状 =====
            node.scale = scale
            local m = node:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            m:SetMaterial(Shared.CreatePBRMaterial(Config.Colors.Rock, 0.0, 0.7))
            m.castShadows = true
        end
    end

    -- ===== 物理碰撞体（装饰物可跳过） =====
    if not obs.noCollision then
        local b = node:CreateComponent("RigidBody", LOCAL)
        b:SetCollisionLayer(1)
        local s = node:CreateComponent("CollisionShape", LOCAL)

        if modelInfo and modelInfo.footprintRadius then
            -- 使用 footprintRadius 精确设置碰撞体（与 BuildObstacleColliders 一致）
            local ms = obs.modelScale or 1.0
            local dia = modelInfo.footprintRadius * 2 * ms
            local h = scale.y  -- 高度仍用 obs.scale.y
            if string.find(name, "Rock") or string.find(name, "Barrel") then
                s:SetSphere(dia)
            else
                s:SetBox(Vector3(dia, h, dia))
            end
        elseif modelInfo then
            -- 有模型但没有 footprintRadius，回退到 obs.scale
            if string.find(name, "Rock") or string.find(name, "Barrel") then
                s:SetSphere(math.max(scale.x, scale.z))
            else
                s:SetBox(scale)
            end
        else
            -- 无模型的基础形状
            if string.find(name, "Rock") or string.find(name, "Barrel") then
                s:SetSphere(1.0)
            else
                s:SetBox(Vector3(1, 1, 1))
            end
        end
    end
end

-- ============================================================================
-- 面包屑道具
-- ============================================================================

function Shared.CreateBreadcrumb(scene, pos, isServer)
    local node = scene:CreateChild("Breadcrumb", LOCAL)
    node.position = pos
    node.scale = Vector3(0.2, 0.2, 0.2)

    if not isServer then
        local m = node:CreateComponent("StaticModel", LOCAL)
        m:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local mat = Shared.CreatePBRMaterial(Config.Colors.Breadcrumb, 0.0, 0.4)
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.6, 0.1)))
        m:SetMaterial(mat)
        m.castShadows = false
    end

    -- 触发器检测
    local b = node:CreateComponent("RigidBody", LOCAL)
    b.trigger = true
    b:SetCollisionLayer(2)
    local s = node:CreateComponent("CollisionShape", LOCAL)
    s:SetSphere(3.0)  -- 拾取范围较大
end

-- ============================================================================
-- 注册远程事件
-- ============================================================================

function Shared.RegisterEvents()
    for _, eventName in pairs(Config.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

-- ============================================================================
-- 固定等距相机设置
-- ============================================================================

function Shared.SetupIsometricCamera(cameraNode)
    local cam = Config.Camera
    -- 从目标点出发，按 yaw/pitch/distance 计算相机位置
    local yawRad   = math.rad(cam.Yaw)
    local pitchRad = math.rad(-cam.Pitch)  -- pitch 是负数(向下)，取反得正

    local horizontalDist = cam.Distance * math.cos(pitchRad)
    local verticalDist   = cam.Distance * math.sin(pitchRad)

    local offsetX = horizontalDist * math.sin(yawRad)
    local offsetZ = horizontalDist * math.cos(yawRad)

    local camPos = Vector3(
        cam.TargetPos.x - offsetX,
        cam.TargetPos.y + verticalDist,
        cam.TargetPos.z - offsetZ
    )

    cameraNode.position = camPos

    -- 使用 LookAt 直接朝向目标点（最可靠）
    local targetPos = Vector3(cam.TargetPos.x, cam.TargetPos.y, cam.TargetPos.z)
    cameraNode:LookAt(targetPos)

    local camera = cameraNode:GetComponent("Camera")
    if camera then
        camera.fov = cam.Fov
        camera.nearClip = cam.NearClip
        camera.farClip = cam.FarClip
    end

    print(string.format("[Shared] 相机位置: (%.1f, %.1f, %.1f) 看向: (%.1f, %.1f, %.1f)",
        camPos.x, camPos.y, camPos.z, targetPos.x, targetPos.y, targetPos.z))
end

-- ============================================================================
-- 碰撞检测 & 推开（脚本层，用于 kinematic 刚体）
-- ============================================================================

-- ============================================================================
-- 编辑器 → 服务端 同步机制
-- ============================================================================

--- 障碍物碰撞缓存脏标记（编辑器修改后置 true，服务端下一帧重建）
Shared.obstacleCollidersDirty = false

--- 标记障碍物碰撞缓存需要重建（MapEditor / TerrainEditor 调用）
function Shared.MarkObstacleCollidersDirty()
    Shared.obstacleCollidersDirty = true
end

--- 围栏段存活状态（动态管理，支持编辑器删除后同步碰撞体）
--- key: "right" | "top" | "bottom"，value: true/nil
Shared.fenceSegmentsAlive = { right = true, top = true, bottom = true }

--- 删除围栏段（按标签匹配）
--- @param label string 如 "围栏段1"、"围栏段2"、"围栏段3"
function Shared.RemoveFenceSegment(label)
    -- 围栏段编号对应：1=右段, 2=上段, 3=下段（按 ScanStructures 的枚举顺序）
    local segMap = { ["围栏段1"] = "right", ["围栏段2"] = "top", ["围栏段3"] = "bottom" }
    local segKey = segMap[label]
    if segKey then
        Shared.fenceSegmentsAlive[segKey] = nil
        Shared.obstacleCollidersDirty = true
        print(string.format("[Shared] 围栏段 '%s' → '%s' 已删除, 碰撞体将重建", label, segKey))
    else
        print(string.format("[Shared] 未知围栏段标签: '%s'", label))
    end
end

--- 按方向标识（side）删除围栏段碰撞（基于位置识别，比 label 编号更可靠）
---@param side string "right"|"top"|"bottom"
function Shared.RemoveFenceSegmentBySide(side)
    if Shared.fenceSegmentsAlive[side] then
        Shared.fenceSegmentsAlive[side] = nil
        Shared.obstacleCollidersDirty = true
        print(string.format("[Shared] 围栏段 side='%s' 已删除, 碰撞体将重建", side))
    else
        print(string.format("[Shared] 围栏段 side='%s' 不存在或已删除", side))
    end
end

--- 地形网格数据（TerrainEditor 写入，Server 读取）
--- 格式: terrainGrid[x][z] = "open" | "blocked" | "target"
Shared.terrainGrid = nil

--- 检查指定世界坐标是否为 blocked 地形（考虑碰撞半径）
--- 当 radius > 0 时，检查圆形范围覆盖的所有格子，任一为 blocked 即返回 true
---@param wx number 世界 X
---@param wz number 世界 Z
---@param radius number? 碰撞半径（默认 0，仅检查中心点）
---@return boolean
function Shared.IsTerrainBlocked(wx, wz, radius)
    if not Shared.terrainGrid then return false end
    local r = radius or 0
    local minGX = math.floor(wx - r)
    local maxGX = math.floor(wx + r)
    local minGZ = math.floor(wz - r)
    local maxGZ = math.floor(wz + r)
    for gx = minGX, maxGX do
        local row = Shared.terrainGrid[gx]
        if row then
            for gz = minGZ, maxGZ do
                if row[gz] == "blocked" then
                    return true
                end
            end
        else
            -- grid 范围外视为不阻挡（超出地图边界由 Clamp 处理）
        end
    end
    return false
end

--- 构建障碍物碰撞列表（圆形近似），调用一次缓存结果
--- 返回 { {x, z, radius}, ... }
function Shared.BuildObstacleColliders()
    local colliders = {}
    for _, obs in ipairs(Config.Level1.Obstacles) do
        if not obs.noCollision then
            local r
            local modelInfo = obs.modelKey and Config.Models[obs.modelKey] or nil
            if modelInfo and modelInfo.footprintRadius then
                -- 使用模型实际 XZ 碰撞半径 × modelScale（精确匹配视觉体积）
                r = modelInfo.footprintRadius * (obs.modelScale or 1.0)
            else
                -- 回退：使用 obs.scale 的最大 XZ 值的一半
                r = math.max(obs.scale.x, obs.scale.z) * 0.5
            end
            table.insert(colliders, { x = obs.pos.x, z = obs.pos.z, radius = r })
        end
    end
    -- 边界围墙碰撞由 terrainGrid 的 blocked 格子处理（IsTerrainBlocked 已支持碰撞半径）
    -- 不再硬编码四面围墙 AABB，这样 TerrainEditor 改为 open 的格子可以自由通行

    -- 围栏段碰撞体（U 形围栏三段，动态管理，支持编辑器删除）
    -- 碰撞范围必须与 CreateFenceSegment 的模型 tiling 视觉范围一致
    local ta = Config.Level1.TargetArea
    local cx, cz = ta.Center.x, ta.Center.z
    local hw, hh = ta.Size.x / 2, ta.Size.z / 2
    local fenceThick = 0.3
    local fenceH = 0.8

    -- 计算模型 tiling 的实际视觉半长度（与 CreateFenceSegment 逻辑一致）
    local modelNaturalHeight = 0.221
    local ms = fenceH / modelNaturalHeight
    local segmentSpan = 0.998 * ms  -- 每段覆盖的长度

    ---计算围栏 tiling 后的实际视觉半长度
    ---@param nominalLen number 围栏的名义长度（CreateTargetFence 中的 size.z 或 size.x）
    ---@return number visualHalfLen 实际视觉半长度
    ---@return number centerOffset 视觉中心相对于围栏中心的偏移
    local function calcFenceVisualExtent(nominalLen)
        local halfLen = nominalLen / 2
        local startOffset = -halfLen + segmentSpan / 2
        -- 找到最后一段的偏移
        local lastOffset = startOffset
        local segIdx = 0
        while true do
            local nextOffset = startOffset + (segIdx + 1) * segmentSpan
            if nextOffset > halfLen then break end
            lastOffset = nextOffset
            segIdx = segIdx + 1
        end
        -- 第一段和最后一段的视觉边缘
        local visualMin = startOffset - segmentSpan / 2
        local visualMax = lastOffset + segmentSpan / 2
        local visualCenter = (visualMin + visualMax) / 2
        local visualHalfLen = (visualMax - visualMin) / 2
        return visualHalfLen, visualCenter
    end

    local alive = Shared.fenceSegmentsAlive
    -- 右段（垂直围栏，fenceLength = ta.Size.z + fenceThick*2 = 5.6）
    if alive.right then
        local rightLen = ta.Size.z + fenceThick * 2
        local visualHalf, centerOff = calcFenceVisualExtent(rightLen)
        table.insert(colliders, { x = cx + hw + fenceThick / 2, z = cz + centerOff, halfW = fenceThick / 2, halfH = visualHalf, isBox = true })
    end
    -- 上段（水平围栏，fenceLength = ta.Size.x = 4）
    if alive.top then
        local topLen = ta.Size.x
        local visualHalf, centerOff = calcFenceVisualExtent(topLen)
        table.insert(colliders, { x = cx + centerOff, z = cz + hh + fenceThick / 2, halfW = visualHalf, halfH = fenceThick / 2, isBox = true })
    end
    -- 下段（水平围栏，fenceLength = ta.Size.x = 4）
    if alive.bottom then
        local bottomLen = ta.Size.x
        local visualHalf, centerOff = calcFenceVisualExtent(bottomLen)
        table.insert(colliders, { x = cx + centerOff, z = cz - hh - fenceThick / 2, halfW = visualHalf, halfH = fenceThick / 2, isBox = true })
    end
    return colliders
end

--- 将位置 (px, pz) 以半径 pr 推离所有障碍物碰撞体
--- @param px number
--- @param pz number
--- @param pr number 移动物体的碰撞半径
--- @param colliders table Shared.BuildObstacleColliders() 的返回值
--- @return number, number 修正后的 px, pz
function Shared.ResolveObstacleCollisions(px, pz, pr, colliders)
    for _, c in ipairs(colliders) do
        if c.isBox then
            -- AABB vs Circle 推开
            -- 找到 AABB 上最近点
            local closestX = Shared.Clamp(px, c.x - c.halfW, c.x + c.halfW)
            local closestZ = Shared.Clamp(pz, c.z - c.halfH, c.z + c.halfH)
            local dx = px - closestX
            local dz = pz - closestZ
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < pr and dist > 0.001 then
                local overlap = pr - dist
                px = px + (dx / dist) * overlap
                pz = pz + (dz / dist) * overlap
            elseif dist < 0.001 then
                -- 完全在内部，推出到最近的边
                local pushX = (pr + c.halfW) - math.abs(px - c.x)
                local pushZ = (pr + c.halfH) - math.abs(pz - c.z)
                if pushX < pushZ then
                    px = px + (px > c.x and pushX or -pushX)
                else
                    pz = pz + (pz > c.z and pushZ or -pushZ)
                end
            end
        else
            -- Circle vs Circle 推开
            local dx = px - c.x
            local dz = pz - c.z
            local dist = math.sqrt(dx * dx + dz * dz)
            local minDist = pr + c.radius
            if dist < minDist and dist > 0.001 then
                local overlap = minDist - dist
                px = px + (dx / dist) * overlap
                pz = pz + (dz / dist) * overlap
            end
        end
    end
    return px, pz
end

--- 两个圆形碰撞体互相推开，返回修正后的位置
--- @param ax number 物体A的x
--- @param az number 物体A的z
--- @param ar number 物体A的碰撞半径
--- @param bx number 物体B的x
--- @param bz number 物体B的z
--- @param br number 物体B的碰撞半径
--- @return number, number 修正后的 ax, az（只推开A）
function Shared.ResolveCircleCollision(ax, az, ar, bx, bz, br)
    local dx = ax - bx
    local dz = az - bz
    local dist = math.sqrt(dx * dx + dz * dz)
    local minDist = ar + br
    if dist < minDist and dist > 0.001 then
        local overlap = minDist - dist
        ax = ax + (dx / dist) * overlap
        az = az + (dz / dist) * overlap
    end
    return ax, az
end

-- ============================================================================
-- 农场外围环境
-- ============================================================================

function Shared.CreateExterior(scene, isServer)
    local E = Config.Exterior
    local L = Config.Level1

    -- ====== 外围大地面（比农场大很多，覆盖蓝色空白区域） ======
    local extFloor = scene:CreateChild("ExteriorFloor", LOCAL)
    -- 以农场中心为中心放置
    extFloor.position = Vector3(L.MapWidth / 2, -0.35, L.MapHeight / 2)
    extFloor.scale = Vector3(E.GroundWidth, 0.2, E.GroundHeight)
    if not isServer then
        local m = extFloor:CreateComponent("StaticModel", LOCAL)
        m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local grassMat = Material:new()
        grassMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        grassMat:SetShaderParameter("MatDiffColor", Variant(E.GroundColor))
        grassMat:SetShaderParameter("Roughness", Variant(0.95))
        grassMat:SetShaderParameter("Metallic", Variant(0.0))
        m:SetMaterial(grassMat)
    end

    -- ====== 道路 ======
    if not isServer then
        for i, road in ipairs(E.Roads) do
            local roadNode = scene:CreateChild("Road" .. i, LOCAL)
            roadNode.position = road.center
            roadNode.scale = road.size
            local m = roadNode:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local roadMat = Material:new()
            roadMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
            roadMat:SetShaderParameter("MatDiffColor", Variant(road.color))
            roadMat:SetShaderParameter("Roughness", Variant(0.85))
            roadMat:SetShaderParameter("Metallic", Variant(0.0))
            m:SetMaterial(roadMat)
        end
    end

    -- ====== 外围装饰物（纯视觉，无碰撞） ======
    if not isServer then
        for _, dec in ipairs(E.Decorations) do
            local modelInfo = dec.modelKey and Config.Models[dec.modelKey] or nil
            if modelInfo then
                local node = scene:CreateChild(dec.name or ("Ext_" .. dec.modelKey), LOCAL)
                node.position = Vector3(dec.pos.x, 0, dec.pos.z)

                local visualNode = node:CreateChild("Visual", LOCAL)
                local ms = dec.modelScale or 1.0
                visualNode.scale = Vector3(ms, ms, ms)

                local m = visualNode:CreateComponent("StaticModel", LOCAL)
                m:SetModel(cache:GetResource("Model", modelInfo.model))
                m:SetMaterial(cache:GetResource("Material", modelInfo.material))
                m.castShadows = true

                -- 底部对齐地面
                local worldBB = m.worldBoundingBox
                local worldMinY = worldBB.min.y
                visualNode.position = Vector3(0, -worldMinY, 0)
            end
        end
    end

    print("[Shared] Exterior environment created")
end

-- ============================================================================
-- 获取出生点
-- ============================================================================

function Shared.GetSpawnPoint(index)
    local pts = Config.Level1.SpawnPoints
    local i = ((index - 1) % #pts) + 1
    return pts[i]
end

return Shared
