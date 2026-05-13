-- ============================================================================
-- DuckRenderer.lua — 鸭子渲染器（使用 3D 模型）
-- 仅客户端使用
-- ============================================================================

local Config = require("config.GameConfig")

local DuckRenderer = {}

-- 鸭子 3D 模型路径
local DUCK_MODEL = "Meshes/duck.mdl"
local DUCK_MATERIAL = "Materials/duck_00_tripo_material_de9897e8-6b1e-4bd0-be26-3d5d6d3a8b5f.xml"

-- 模型原始包围盒高度 0.25m，目标高度约 0.45m
local DUCK_SCALE = 1.8

-- 矫正模型朝向：使鸭头对齐引擎 +Z（FORWARD）
local MODEL_YAW_OFFSET = -90

--- 为一个鸭子节点创建 3D 模型
---@param duckNode Node 鸭子根节点（已有位置/旋转）
---@param createMaterialFn function Shared.CreatePBRMaterial（保留用于 settled 着色）
function DuckRenderer.Setup(duckNode, createMaterialFn)
    -- 创建模型子节点
    local modelNode = duckNode:CreateChild("DuckModel", LOCAL)
    modelNode.scale = Vector3(DUCK_SCALE, DUCK_SCALE, DUCK_SCALE)
    -- 模型中心在原点附近，底部 y=-0.125*scale，需要抬升使底部贴地
    modelNode.position = Vector3(0, 0.125 * DUCK_SCALE, 0)
    -- 初始旋转：矫正模型朝向
    modelNode.rotation = Quaternion(MODEL_YAW_OFFSET, Vector3.UP)

    local staticModel = modelNode:CreateComponent("StaticModel", LOCAL)
    staticModel:SetModel(cache:GetResource("Model", DUCK_MODEL))
    staticModel:SetMaterial(cache:GetResource("Material", DUCK_MATERIAL))
    staticModel.castShadows = true

    print("[DuckRenderer] 创建鸭子模型: " .. duckNode.name)
end

--- 切换鸭子为"上架/安定"外观（添加金色光环效果）
---@param duckNode Node
---@param createMaterialFn function
function DuckRenderer.SetSettled(duckNode, createMaterialFn)
    -- 在鸭子头上添加一个小星标记
    local existingStar = duckNode:GetChild("SettledStar")
    if existingStar then return end

    local starNode = duckNode:CreateChild("SettledStar", LOCAL)
    starNode.position = Vector3(0, 0.55, 0)
    starNode.scale = Vector3(0.12, 0.12, 0.12)
    local starModel = starNode:CreateComponent("StaticModel", LOCAL)
    starModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    starModel:SetMaterial(createMaterialFn(Color(1.0, 0.85, 0.2, 1.0), 0.8, 0.3))
end

--- 更新鸭子的状态提示标记
---@param duckNode Node
---@param state string
---@param createMaterialFn function
function DuckRenderer.SetMood(duckNode, state, createMaterialFn)
    local existing = duckNode:GetChild("MoodMarker")
    if state == "idle" or state == "" or state == "settled" then
        if existing then existing:Remove() end
        return
    end

    local color = nil
    local scale = 0.10
    if state == "alert" then
        color = Color(1.0, 0.75, 0.15, 1.0)
        scale = 0.10
    elseif state == "panic" or state == "scared" then
        color = Color(1.0, 0.18, 0.12, 1.0)
        scale = 0.14
    end
    if color == nil then return end

    local marker = existing
    if marker == nil then
        marker = duckNode:CreateChild("MoodMarker", LOCAL)
        marker.position = Vector3(0, 0.78, 0)
        local model = marker:CreateComponent("StaticModel", LOCAL)
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    end

    marker.scale = Vector3(scale, scale, scale)
    local model = marker:GetComponent("StaticModel")
    if model then
        model:SetMaterial(createMaterialFn(color, 0.1, 0.25))
    end
end

--- 简单摆动动画（每帧调用）
---@param duckNode Node
---@param dt number
---@param time number 累计时间
function DuckRenderer.Animate(duckNode, dt, time)
    local modelNode = duckNode:GetChild("DuckModel")
    if modelNode == nil then return end

    -- 基础旋转（矫正模型朝向）+ 身体微微左右摇摆（模拟走路蹒跚）
    local wobble = math.sin(time * 6.0) * 4.0
    modelNode.rotation = Quaternion(MODEL_YAW_OFFSET, Vector3.UP) * Quaternion(wobble, Vector3.FORWARD)

    -- 上下微弹（走路节奏感）
    local bob = math.abs(math.sin(time * 8.0)) * 0.02
    modelNode.position = Vector3(0, 0.125 * DUCK_SCALE + bob, 0)
end

return DuckRenderer
