-- ============================================================================
-- DwarfRenderer.lua — 矮人角色渲染器（使用 3D 模型）
-- 仅客户端使用
-- ============================================================================

local Config = require("config.GameConfig")

local DwarfRenderer = {}

-- 矮人 3D 模型路径
local DWARF_MODEL = "Meshes/dwarf.mdl"
local DWARF_MATERIAL = "Materials/dwarf_00_tripo_material_07ab15d1-3bd3-484c-9597-f79cd7d6dccd.xml"

-- 模型原始包围盒高度 0.3m，目标高度约 1.0m → 缩放 3.3
local DWARF_SCALE = 3.3

-- 矫正模型朝向：使面部对齐引擎 +Z（FORWARD）
local MODEL_YAW_OFFSET = -90

--- 为矮人节点创建 3D 模型
---@param playerNode Node 玩家根节点
---@param roleIndex number 角色编号 (1~4)，决定颜色标记
---@param createMaterialFn function Shared.CreatePBRMaterial
function DwarfRenderer.Setup(playerNode, roleIndex, createMaterialFn)
    local P = Config.Player
    local color = P.Colors[((roleIndex - 1) % #P.Colors) + 1]

    -- 模型子节点
    local modelNode = playerNode:CreateChild("ModelNode", LOCAL)
    modelNode.scale = Vector3(DWARF_SCALE, DWARF_SCALE, DWARF_SCALE)
    -- 模型底部 y=-0.15*scale，抬升使底部贴地
    modelNode.position = Vector3(0, 0.15 * DWARF_SCALE, 0)
    -- 初始旋转：矫正模型朝向
    modelNode.rotation = Quaternion(MODEL_YAW_OFFSET, Vector3.UP)

    local staticModel = modelNode:CreateComponent("StaticModel", LOCAL)
    staticModel:SetModel(cache:GetResource("Model", DWARF_MODEL))
    staticModel:SetMaterial(cache:GetResource("Material", DWARF_MATERIAL))
    staticModel.castShadows = true

    -- 头顶颜色标记球（区分不同玩家）
    local markerNode = playerNode:CreateChild("ColorMarker", LOCAL)
    markerNode.position = Vector3(0, 1.15, 0)
    markerNode.scale = Vector3(0.15, 0.15, 0.15)
    local markerModel = markerNode:CreateComponent("StaticModel", LOCAL)
    markerModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    markerModel:SetMaterial(createMaterialFn(color, 0.3, 0.4))

    print("[DwarfRenderer] 创建矮人模型: " .. playerNode.name .. " (角色 " .. roleIndex .. ")")
end

--- 拍手动画（模型上下跳动 + 标记闪烁）
---@param playerNode Node
---@param clapTimer number 拍手计时（0~0.4秒）
function DwarfRenderer.AnimateClap(playerNode, clapTimer)
    local modelNode = playerNode:GetChild("ModelNode")
    if modelNode == nil then return end

    if clapTimer > 0 then
        -- 跳跃效果
        local t = math.sin(clapTimer * math.pi / 0.4)
        modelNode.position = Vector3(0, 0.15 * DWARF_SCALE + 0.15 * t, 0)

        -- 标记球变大
        local marker = playerNode:GetChild("ColorMarker")
        if marker then
            local s = 0.15 + 0.08 * t
            marker.scale = Vector3(s, s, s)
            marker.position = Vector3(0, 1.15 + 0.15 * t, 0)
        end
    else
        modelNode.position = Vector3(0, 0.15 * DWARF_SCALE, 0)
        local marker = playerNode:GetChild("ColorMarker")
        if marker then
            marker.scale = Vector3(0.15, 0.15, 0.15)
            marker.position = Vector3(0, 1.15, 0)
        end
    end
end

--- 走路摆动动画
---@param playerNode Node
---@param time number 累计时间
---@param isMoving boolean
function DwarfRenderer.AnimateWalk(playerNode, time, isMoving)
    local modelNode = playerNode:GetChild("ModelNode")
    if modelNode == nil then return end

    local baseRot = Quaternion(MODEL_YAW_OFFSET, Vector3.UP)
    if isMoving then
        -- 基础旋转 + 左右摇摆 + 上下微弹
        local sway = math.sin(time * 8.0) * 3.0
        local bob = math.abs(math.sin(time * 8.0)) * 0.03
        modelNode.rotation = baseRot * Quaternion(sway, Vector3.FORWARD)
        modelNode.position = Vector3(0, 0.15 * DWARF_SCALE + bob, 0)
    else
        modelNode.rotation = baseRot
        modelNode.position = Vector3(0, 0.15 * DWARF_SCALE, 0)
    end
end

--- 移除矮人模型（断线清理用）
---@param playerNode Node
function DwarfRenderer.Remove(playerNode)
    local modelNode = playerNode:GetChild("ModelNode")
    if modelNode then
        modelNode:Remove()
    end
    local marker = playerNode:GetChild("ColorMarker")
    if marker then
        marker:Remove()
    end
    print("[DwarfRenderer] 移除矮人模型: " .. playerNode.name)
end

return DwarfRenderer
