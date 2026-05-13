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

--- 应用鸭子分型外观（v2.2 引入）
--- 通过修改 DuckModel 缩放 + 增设子节点装饰区分类型
---@param duckNode Node
---@param duckType string  "normal"|"leader"|"stubborn"|"mom"|"duckling"
---@param createMaterialFn function Shared.CreatePBRMaterial
function DuckRenderer.SetType(duckNode, duckType, createMaterialFn)
    local typeData = Config.DuckTypes and Config.DuckTypes[duckType]
    if typeData == nil then return end

    -- 调整身体缩放（保持脚底贴地）
    local modelNode = duckNode:GetChild("DuckModel")
    if modelNode then
        local s = DUCK_SCALE * (typeData.scale or 1.0)
        modelNode.scale = Vector3(s, s, s)
        modelNode.position = Vector3(0, 0.125 * s, 0)
    end

    -- 清掉旧装饰，避免重复挂载
    local oldCrown = duckNode:GetChild("TypeCrown")
    if oldCrown then oldCrown:Remove() end
    local oldRing = duckNode:GetChild("TypeRing")
    if oldRing then oldRing:Remove() end
    local oldBow = duckNode:GetChild("TypeBow")
    if oldBow then oldBow:Remove() end
    local oldScarf = duckNode:GetChild("TypeScarf")
    if oldScarf then oldScarf:Remove() end
    local oldGloss = duckNode:GetChild("TypeDucklingGloss")
    if oldGloss then oldGloss:Remove() end

    if duckType == "leader" then
        -- 头顶金色小冠（一个较小的金色球替代锥体，复用现有 Sphere.mdl）
        local crown = duckNode:CreateChild("TypeCrown", LOCAL)
        crown.position = Vector3(0, 0.62, 0)
        crown.scale = Vector3(0.18, 0.22, 0.18)
        local cm = crown:CreateComponent("StaticModel", LOCAL)
        cm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        cm:SetMaterial(createMaterialFn(Color(1.0, 0.82, 0.15, 1.0), 1.0, 0.25))
        -- 脚下金色环（用扁球模拟）
        local ring = duckNode:CreateChild("TypeRing", LOCAL)
        ring.position = Vector3(0, 0.02, 0)
        ring.scale = Vector3(1.05, 0.04, 1.05)
        local rm = ring:CreateComponent("StaticModel", LOCAL)
        rm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        rm:SetMaterial(createMaterialFn(Color(1.0, 0.86, 0.3, 0.85), 0.8, 0.35))

    elseif duckType == "stubborn" then
        -- 颈部一圈深色"围巾" — 暗示倔强性格
        local scarf = duckNode:CreateChild("TypeScarf", LOCAL)
        scarf.position = Vector3(0, 0.32, 0.05)
        scarf.scale = Vector3(0.22, 0.10, 0.22)
        local sm = scarf:CreateComponent("StaticModel", LOCAL)
        sm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        sm:SetMaterial(createMaterialFn(Color(0.18, 0.18, 0.22, 1.0), 0.2, 0.4))

    elseif duckType == "mom" then
        -- 体侧粉色花结
        local bow = duckNode:CreateChild("TypeBow", LOCAL)
        bow.position = Vector3(0.22, 0.32, 0)
        bow.scale = Vector3(0.10, 0.10, 0.10)
        local bm = bow:CreateComponent("StaticModel", LOCAL)
        bm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        bm:SetMaterial(createMaterialFn(Color(1.0, 0.45, 0.65, 1.0), 0.9, 0.3))

    elseif duckType == "duckling" then
        -- 头顶一抹鲜黄"绒毛"凸出（区分小鸭仔）
        local gloss = duckNode:CreateChild("TypeDucklingGloss", LOCAL)
        gloss.position = Vector3(0, 0.42, 0)
        gloss.scale = Vector3(0.10, 0.10, 0.10)
        local gm = gloss:CreateComponent("StaticModel", LOCAL)
        gm:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        gm:SetMaterial(createMaterialFn(Color(1.0, 0.92, 0.25, 1.0), 1.0, 0.3))
    end
    -- normal: 不挂任何装饰
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
    elseif state == "crying" then
        -- 小鸭仔脱离母鸭：淡蓝色 🥺 标记
        color = Color(0.45, 0.75, 1.0, 1.0)
        scale = 0.12
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
