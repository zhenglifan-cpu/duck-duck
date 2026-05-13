-- ============================================================================
-- MapPreviewCamera.lua — 地图预览模式相机控制
-- 按 P 切换，俯视地图，支持缩放/平移/旋转/WASD移动
-- 支持坐标网格显示、鼠标点击高亮网格
-- ============================================================================

local MapPreviewCamera = {}

local Config = require("config.GameConfig")
local Shared = require("network.Shared")
local MapEditor = require("MapEditor")
local TerrainEditor = require("TerrainEditor")

-- ============================================================================
-- 常量
-- ============================================================================

local ZOOM_STEP    = 2.0   -- 每次滚轮缩放量 (m)
local ZOOM_MIN     = 8.0   -- 最近距离 (m)
local ZOOM_MAX     = 50.0  -- 最远距离 (m)
local PAN_SPEED    = 0.05  -- 平移灵敏度 (世界单位/像素)
local ROTATE_SENS  = 0.3   -- 旋转灵敏度 (度/像素)
local MOVE_SPEED   = 15.0  -- WASD 移动速度 (m/s)
local PITCH_MIN    = -89.0 -- 最大俯角
local PITCH_MAX    = -10.0 -- 最小俯角

-- 网格颜色
local GRID_COLOR        = Color(0.6, 0.6, 0.6, 0.07)  -- 灰色半透明网格线（极淡）
local GRID_HIGHLIGHT    = Color(1.0, 0.9, 0.2, 0.7)   -- 黄色高亮选中网格
local GRID_COORD_COLOR  = Color(1.0, 1.0, 1.0, 0.9)   -- 坐标文字颜色
local GRID_Y            = 0.02                          -- 网格绘制高度（略高于地面）

-- ============================================================================
-- 状态
-- ============================================================================

---@type Node
local cameraNode_ = nil
---@type Scene
local scene_ = nil

local active_ = false

-- 预览相机参数（球坐标）
local targetPos_ = Vector3(12, 0, 9) -- 地图中心
local distance_  = 30.0
local yaw_       = 0.0
local pitch_     = -90.0  -- 正下方俯视

-- 进入预览前保存的游戏相机变换
local savedPos_ = Vector3.ZERO
local savedRot_ = Quaternion.IDENTITY

-- 坐标网格状态
local gridEnabled_ = true           -- 网格是否显示
local selectedCell_ = nil            -- 选中的网格格子 {x, z} (整数坐标，代表格子左下角)
local coordLabelNode_ = nil          -- 坐标文字 3D 节点

-- ============================================================================
-- API
-- ============================================================================

--- 初始化，传入相机节点和场景
---@param cameraNode Node
---@param scene Scene
function MapPreviewCamera.Init(cameraNode, scene)
    cameraNode_ = cameraNode
    scene_ = scene
end

--- 切换预览模式
function MapPreviewCamera.Toggle()
    if cameraNode_ == nil then return end

    active_ = not active_

    if active_ then
        -- 进入预览：保存当前相机状态
        savedPos_ = Vector3(cameraNode_.position.x, cameraNode_.position.y, cameraNode_.position.z)
        savedRot_ = Quaternion(cameraNode_.rotation.w, cameraNode_.rotation.x, cameraNode_.rotation.y, cameraNode_.rotation.z)

        -- 重置预览参数
        targetPos_ = Vector3(Config.Level1.MapWidth / 2, 0, Config.Level1.MapHeight / 2)
        distance_ = 30.0
        yaw_ = 0.0
        pitch_ = -90.0

        -- 重置网格选中状态
        selectedCell_ = nil
        RemoveCoordLabel()

        -- 应用预览相机
        ApplyCamera()

        print("[MapPreview] 进入地图预览模式")
    else
        -- 退出预览：恢复游戏相机
        selectedCell_ = nil
        RemoveCoordLabel()
        Shared.SetupIsometricCamera(cameraNode_)

        print("[MapPreview] 退出地图预览模式")
    end
end

--- 是否处于预览模式
---@return boolean
function MapPreviewCamera.IsActive()
    return active_
end

--- 每帧更新（仅预览模式下调用）
---@param dt number
function MapPreviewCamera.Update(dt)
    if not active_ or cameraNode_ == nil then return end

    local changed = false

    -- === 1. 滚轮缩放（添加模型面板打开时跳过，避免与列表滚动冲突） ===
    if not MapEditor.IsAddingModel() then
        local wheel = input:GetMouseMoveWheel()
        if wheel ~= 0 then
            distance_ = distance_ - wheel * ZOOM_STEP
            distance_ = Shared.Clamp(distance_, ZOOM_MIN, ZOOM_MAX)
            changed = true
        end
    end

    -- === 2. 中键拖拽平移 ===
    if input:GetMouseButtonDown(MOUSEB_MIDDLE) then
        local dx = input:GetMouseMoveX()
        local dy = input:GetMouseMoveY()
        if dx ~= 0 or dy ~= 0 then
            -- 沿相机的水平 right 和 forward 方向在 XZ 平面平移
            local yawRad = math.rad(yaw_)
            local rightDir = Vector3(math.cos(yawRad), 0, -math.sin(yawRad))
            local forwardDir = Vector3(math.sin(yawRad), 0, math.cos(yawRad))

            -- 鼠标向右→相机 right 方向，鼠标向上→相机 forward 方向
            local panScale = PAN_SPEED * (distance_ / 30.0) -- 远时平移更快
            targetPos_ = targetPos_ - rightDir * dx * panScale + forwardDir * dy * panScale
            changed = true
        end
    end

    -- === 3. 右键拖拽旋转 ===
    if input:GetMouseButtonDown(MOUSEB_RIGHT) then
        local dx = input:GetMouseMoveX()
        local dy = input:GetMouseMoveY()
        if dx ~= 0 or dy ~= 0 then
            yaw_ = yaw_ + dx * ROTATE_SENS
            pitch_ = pitch_ + dy * ROTATE_SENS
            pitch_ = Shared.Clamp(pitch_, PITCH_MIN, PITCH_MAX)
            changed = true
        end
    end

    -- === 4. WASD 移动 ===
    local moveDir = Vector3.ZERO
    local yawRad = math.rad(yaw_)
    local fwd = Vector3(math.sin(yawRad), 0, math.cos(yawRad))
    local right = Vector3(math.cos(yawRad), 0, -math.sin(yawRad))

    if input:GetKeyDown(KEY_W) then moveDir = moveDir + fwd end
    if input:GetKeyDown(KEY_S) then moveDir = moveDir - fwd end
    if input:GetKeyDown(KEY_A) then moveDir = moveDir - right end
    if input:GetKeyDown(KEY_D) then moveDir = moveDir + right end

    if moveDir:Length() > 0.01 then
        moveDir = moveDir:Normalized()
        targetPos_ = targetPos_ + moveDir * MOVE_SPEED * dt
        changed = true
    end

    -- === 5. 鼠标左键点击选中网格（编辑模式激活时屏蔽，避免冲突） ===
    if gridEnabled_ and input:GetMouseButtonPress(MOUSEB_LEFT) and not MapEditor.IsActive() and not TerrainEditor.IsActive() then
        print("[MapPreview] 左键点击检测到")
        local hitPos = RaycastGroundPlane()
        if hitPos then
            local cellX = math.floor(hitPos.x)
            local cellZ = math.floor(hitPos.z)
            print(string.format("[MapPreview] 命中地面: (%.2f, %.2f) -> 网格(%d, %d)", hitPos.x, hitPos.z, cellX, cellZ))
            -- 判断是否在网格范围内（包括外围区域）
            local E = Config.Exterior
            local mapW = Config.Level1.MapWidth
            local mapH = Config.Level1.MapHeight
            local extW = E and E.GroundWidth or mapW
            local extH = E and E.GroundHeight or mapH
            local gridMinX = math.floor(mapW / 2 - extW / 2)
            local gridMaxX = math.ceil(mapW / 2 + extW / 2)
            local gridMinZ = math.floor(mapH / 2 - extH / 2)
            local gridMaxZ = math.ceil(mapH / 2 + extH / 2)

            if cellX >= gridMinX and cellX < gridMaxX and cellZ >= gridMinZ and cellZ < gridMaxZ then
                if selectedCell_ and selectedCell_.x == cellX and selectedCell_.z == cellZ then
                    -- 再次点击同一格：取消选中
                    selectedCell_ = nil
                    RemoveCoordLabel()
                    print("[MapPreview] 取消选中")
                else
                    selectedCell_ = { x = cellX, z = cellZ }
                    UpdateCoordLabel()
                    print(string.format("[MapPreview] 选中网格: (%d, %d)", cellX, cellZ))
                end
            else
                print("[MapPreview] 点击在网格范围外")
            end
        else
            print("[MapPreview] RaycastGroundPlane 返回 nil")
        end
    end

    -- === 应用相机 ===
    if changed then
        ApplyCamera()
    end
end

-- ============================================================================
-- 网格 API
-- ============================================================================

--- 设置网格显示开关
---@param enabled boolean
function MapPreviewCamera.SetGridEnabled(enabled)
    gridEnabled_ = enabled
    if not enabled then
        selectedCell_ = nil
        RemoveCoordLabel()
    end
end

--- 获取网格是否显示
---@return boolean
function MapPreviewCamera.IsGridEnabled()
    return gridEnabled_
end

--- 在 PostRenderUpdate 中调用，绘制网格和高亮
function MapPreviewCamera.DrawGrid()
    if not active_ or not gridEnabled_ or not scene_ then return end

    local debugRenderer = scene_:GetComponent("DebugRenderer")
    if not debugRenderer then return end

    -- 网格覆盖外围环境区域
    local E = Config.Exterior
    local mapW = Config.Level1.MapWidth
    local mapH = Config.Level1.MapHeight
    local extW = E and E.GroundWidth or mapW
    local extH = E and E.GroundHeight or mapH

    -- 网格范围：以农场中心为基准，向四周延伸到外围地面边缘
    local gridMinX = math.floor(mapW / 2 - extW / 2)
    local gridMaxX = math.ceil(mapW / 2 + extW / 2)
    local gridMinZ = math.floor(mapH / 2 - extH / 2)
    local gridMaxZ = math.ceil(mapH / 2 + extH / 2)
    local y = GRID_Y

    -- 农场内的网格用标准颜色，农场外用更淡的颜色
    local GRID_EXT_COLOR = Color(0.5, 0.5, 0.5, 0.04)

    -- 绘制竖线 (沿X方向，固定Z间隔)
    -- depthTest=true: 网格线会被 3D 模型正确遮挡，模型优先渲染在网格上方
    for x = gridMinX, gridMaxX do
        local inFarm = (x >= 0 and x <= mapW)
        -- 农场内段
        if inFarm then
            local zLo = math.max(gridMinZ, 0)
            local zHi = math.min(gridMaxZ, mapH)
            -- 外段下方
            if gridMinZ < 0 then
                debugRenderer:AddLine(Vector3(x, y, gridMinZ), Vector3(x, y, 0), GRID_EXT_COLOR, true)
            end
            -- 农场内段
            debugRenderer:AddLine(Vector3(x, y, zLo), Vector3(x, y, zHi), GRID_COLOR, true)
            -- 外段上方
            if gridMaxZ > mapH then
                debugRenderer:AddLine(Vector3(x, y, mapH), Vector3(x, y, gridMaxZ), GRID_EXT_COLOR, true)
            end
        else
            debugRenderer:AddLine(Vector3(x, y, gridMinZ), Vector3(x, y, gridMaxZ), GRID_EXT_COLOR, true)
        end
    end

    -- 绘制横线 (沿Z方向，固定X间隔)
    for z = gridMinZ, gridMaxZ do
        local inFarm = (z >= 0 and z <= mapH)
        if inFarm then
            local xLo = math.max(gridMinX, 0)
            local xHi = math.min(gridMaxX, mapW)
            if gridMinX < 0 then
                debugRenderer:AddLine(Vector3(gridMinX, y, z), Vector3(0, y, z), GRID_EXT_COLOR, true)
            end
            debugRenderer:AddLine(Vector3(xLo, y, z), Vector3(xHi, y, z), GRID_COLOR, true)
            if gridMaxX > mapW then
                debugRenderer:AddLine(Vector3(mapW, y, z), Vector3(gridMaxX, y, z), GRID_EXT_COLOR, true)
            end
        else
            debugRenderer:AddLine(Vector3(gridMinX, y, z), Vector3(gridMaxX, y, z), GRID_EXT_COLOR, true)
        end
    end

    -- 绘制选中网格高亮（仅简单边框）
    if selectedCell_ then
        local cx = selectedCell_.x
        local cz = selectedCell_.z
        local hy = y + 0.01  -- 略高于网格线

        debugRenderer:AddLine(Vector3(cx, hy, cz), Vector3(cx + 1, hy, cz), GRID_HIGHLIGHT, true)
        debugRenderer:AddLine(Vector3(cx + 1, hy, cz), Vector3(cx + 1, hy, cz + 1), GRID_HIGHLIGHT, true)
        debugRenderer:AddLine(Vector3(cx + 1, hy, cz + 1), Vector3(cx, hy, cz + 1), GRID_HIGHLIGHT, true)
        debugRenderer:AddLine(Vector3(cx, hy, cz + 1), Vector3(cx, hy, cz), GRID_HIGHLIGHT, true)
    end
end

-- ============================================================================
-- 内部函数
-- ============================================================================

--- 根据球坐标参数计算并设置相机位置+朝向
function ApplyCamera()
    local pitchRad = math.rad(-pitch_) -- pitch 为负(向下)，取反得正
    local yawRad   = math.rad(yaw_)

    local hDist = distance_ * math.cos(pitchRad)
    local vDist = distance_ * math.sin(pitchRad)

    local camPos = Vector3(
        targetPos_.x - hDist * math.sin(yawRad),
        targetPos_.y + vDist,
        targetPos_.z - hDist * math.cos(yawRad)
    )

    cameraNode_.position = camPos
    cameraNode_:LookAt(targetPos_)
end

--- 鼠标射线与 Y=0 地面平面求交，返回交点或 nil
---@return Vector3|nil
function RaycastGroundPlane()
    if not cameraNode_ then return nil end

    local camera = cameraNode_:GetComponent("Camera")
    if not camera then return nil end

    -- 获取归一化屏幕坐标 (0~1)
    local mousePos = input.mousePosition
    local screenW = graphics:GetWidth()
    local screenH = graphics:GetHeight()
    if screenW <= 0 or screenH <= 0 then return nil end

    local nx = mousePos.x / screenW
    local ny = mousePos.y / screenH

    local ray = camera:GetScreenRay(nx, ny)

    -- 与 Y=0 平面求交: origin.y + t * direction.y = 0
    if math.abs(ray.direction.y) < 0.0001 then return nil end  -- 射线几乎平行于地面

    local t = -ray.origin.y / ray.direction.y
    if t < 0 then return nil end  -- 交点在相机后方

    return Vector3(
        ray.origin.x + t * ray.direction.x,
        0,
        ray.origin.z + t * ray.direction.z
    )
end

--- 移除坐标文字标签
function RemoveCoordLabel()
    if coordLabelNode_ then
        coordLabelNode_:Remove()
        coordLabelNode_ = nil
    end
end

--- 创建/更新坐标文字标签（使用 Text3D，描边 + 白色文字）
function UpdateCoordLabel()
    if not selectedCell_ or not scene_ then return end

    RemoveCoordLabel()

    local cx = selectedCell_.x + 0.5
    local cz = selectedCell_.z + 0.5

    coordLabelNode_ = scene_:CreateChild("CoordLabel", LOCAL)
    coordLabelNode_.position = Vector3(cx, 0.3, cz)

    local text3d = coordLabelNode_:CreateComponent("Text3D")
    -- 使用字符串路径加载字体（第一个重载更可靠）
    local fontOk = text3d:SetFont("Fonts/LongZhuTi-Regular.ttf", 24)
    if not fontOk then
        print("[MapPreview] 警告: 字体加载失败，尝试备用字体")
        text3d:SetFont("Fonts/Inter_18pt-Regular.ttf", 24)
    end
    text3d:SetText(string.format("X:%d Z:%d", selectedCell_.x, selectedCell_.z))
    text3d:SetColor(Color(1, 1, 1, 1))
    text3d:SetTextAlignment(HA_CENTER)
    text3d:SetHorizontalAlignment(HA_CENTER)
    text3d:SetVerticalAlignment(VA_CENTER)
    text3d:SetFaceCameraMode(FC_ROTATE_XYZ)
    text3d:SetFixedScreenSize(true)
    -- 描边效果：必须先设置 TextEffect 类型
    text3d:SetTextEffect(TE_STROKE)
    text3d:SetEffectStrokeThickness(4)
    text3d:SetEffectRoundStroke(true)
    text3d:SetEffectColor(Color(0, 0, 0, 0.9))
    print(string.format("[MapPreview] 坐标标签已创建: X:%d Z:%d at (%.1f, 0.3, %.1f)", selectedCell_.x, selectedCell_.z, cx, cz))
end

return MapPreviewCamera
