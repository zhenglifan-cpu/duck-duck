-- ============================================================================
-- MapEditor.lua — 地图编辑模式
-- 在预览模式下编辑障碍物：选中、移动、旋转、缩放、删除、保存
-- ============================================================================

local MapEditor = {}

local Config = require("config.GameConfig")
local Shared = require("network.Shared")
local UI = require("urhox-libs/UI")
local AstroonTheme = require("config.AstroonTheme")

-- ============================================================================
-- 常量
-- ============================================================================

-- 编辑器状态
local STATE_IDLE     = "idle"       -- 等待选中
local STATE_SELECTED = "selected"   -- 已选中，显示菜单
local STATE_MOVING   = "moving"     -- 移动中
local STATE_ROTATING = "rotating"   -- 旋转面板中
local STATE_SCALING  = "scaling"    -- 缩放中
local STATE_ADDING   = "adding"     -- 添加模型中

-- 右键双击检测参数
local DOUBLE_CLICK_TIME = 0.4    -- 两次点击间隔 (s)
local CLICK_MOVE_THRESH = 5      -- 像素移动超过此值视为拖拽

-- 网格对齐
local SNAP_SIZE = 1.0            -- 移动对齐网格边缘 (m)

-- 高亮颜色
local HIGHLIGHT_COLOR = Color(0.0, 1.0, 0.5, 0.8)
local MOVING_COLOR    = Color(0.2, 0.6, 1.0, 0.8)

-- 预设旋转角度
local PRESET_ANGLES = { 45, 90, 135, 180 }

-- 模型中文显示名（key 对应 Config.Models）
local MODEL_DISPLAY_NAMES = {
    TreeTall    = "大树",       TreeMedium  = "中树",     TreeSmall   = "小树",
    Cabin       = "小屋",       HayBale     = "草堆",     WaterTrough = "饮水池",
    Crate       = "木箱",       Barrel      = "木桶",
    RockLarge   = "大岩石",     RockCluster = "石堆",     RockFlat    = "扁石",
    Bush        = "灌木",       LargeLeaf   = "大叶菜",   SmallFlower = "小花",
    SmallGrass  = "小草",       Fence       = "围栏段",   Wall        = "围墙段",
}

-- 模型列表有序显示
local MODEL_LIST_ORDER = {
    "Cabin", "Barrel", "Crate", "HayBale", "WaterTrough",
    "TreeTall", "TreeMedium", "TreeSmall",
    "RockLarge", "RockCluster", "RockFlat",
    "Bush", "LargeLeaf", "SmallFlower", "SmallGrass",
    "Fence", "Wall",
}

-- ============================================================================
-- 状态
-- ============================================================================

---@type Scene
local scene_ = nil
---@type Node
local cameraNode_ = nil

local active_ = false
local state_ = STATE_IDLE

-- 选中的对象
---@type Node
local selectedNode_ = nil
local selectedObsIndex_ = nil    -- obstacle/decoration 时在对应数组中的索引
local selectedType_ = nil        -- "obstacle" / "decoration" / "structure"
local selectedStructIndex_ = nil -- 在 structureList_ 中的索引（structure 类型时）

--- 获取当前选中的配置项（obstacle 或 decoration）
---@return table|nil
local function GetSelectedEntry()
    if selectedType_ == "obstacle" and selectedObsIndex_ then
        return Config.Level1.Obstacles[selectedObsIndex_]
    elseif selectedType_ == "decoration" and selectedObsIndex_ then
        return Config.Exterior.Decorations[selectedObsIndex_]
    end
    return nil
end

-- 结构物列表（围墙/围栏，运行时扫描）
local structureList_ = {}        -- { {node=Node, type="Wall"|"Fence", label=string}, ... }

-- 左键双击检测
local leftClickCount_ = 0
local leftClickTimer_ = 0
local leftDownPos_ = nil         -- 左键按下时的鼠标位置
local leftWasDrag_ = false       -- 本次左键按下期间是否拖拽

-- 移动操作
local moveOrigPos_ = nil         -- 移动前原始位置
local moveCurrent_ = nil         -- 当前移动目标位置

-- 旋转操作
local rotateOrigModelRot_ = nil  -- 旋转前原始模型旋转
local rotateOrigRot_ = nil
local rotateYaw_ = 0             -- 当前水平旋转角度
local rotatePitch_ = 0           -- 当前垂直旋转角度

-- 缩放操作
local scaleOrigScale_ = nil      -- 缩放前原始 modelScale
local scaleCurrent_ = 1.0        -- 当前缩放值

-- UI
local uiRoot_ = nil              -- 外部传入的 UI root（或通过 getter 动态获取）
local uiRootGetter_ = nil        -- UI root getter 函数
local menuPanel_ = nil           -- 操作菜单面板（跟随模型位置）
local rotatePanel_ = nil         -- 旋转面板
local scalePanel_ = nil          -- 缩放滑条面板
local statusHintPanel_ = nil     -- 状态提示
local addButton_ = nil           -- 左下角"添加模型"按钮
local addPanel_ = nil            -- 模型选择面板
local addSelectedKey_ = nil      -- 当前选中的模型 key
local addCounter_ = 0            -- 添加模型自增计数

-- ============================================================================
-- 内部函数前置声明（允许互相调用）
-- ============================================================================
local WorldToScreen
local MergeChildBoundingBoxes
local GetSelectedTopPos
local DetectLeftDoubleClick
local TrySelectAtMouse
local FindSelectableRoot
local SelectNode
local DeselectNode
local CloseAllUI
local ShowMenu
local CloseMenu
local UpdateMenuPosition
local DeleteSelected
local StartMove
local HandleMoveInput
local ConfirmMove
local CancelMove
local StartRotate
local ApplyRotation
local ConfirmRotate
local CancelRotate
local ShowRotatePanel
local CloseRotatePanel
local UpdateRotateLabels
local StartScale
local HandleScaleInput
local ApplyScale
local ConfirmScale
local CancelScale
local ShowScalePanel
local CloseScalePanel
local ShowStatusHint
local CloseStatusHint
local RaycastGround
local RealignVisual
local GetScreenCenterGround
local ShowAddButton
local CloseAddButton
local ShowAddPanel
local CloseAddPanel
local ConfirmAdd

-- ============================================================================
-- 网络同步：将编辑操作发送到服务端
-- ============================================================================

local EVENTS = Config.EVENTS

--- 向服务端发送障碍物/装饰物编辑事件
---@param action string "add"|"move"|"scale"|"delete"
---@param obsName string 名称（唯一标识）
---@param extra table|nil 附加数据
---@param isDec boolean|nil 是否为装饰物（默认 false = 障碍物）
local function SendObsEdit(action, obsName, extra, isDec)
    local serverConn = network:GetServerConnection()
    if not serverConn then return end

    local vm = VariantMap()
    vm["Action"] = Variant(action)
    vm["Name"]   = Variant(obsName)
    if isDec then vm["IsDec"] = Variant(true) end

    if extra then
        if extra.posX then vm["PosX"] = Variant(extra.posX) end
        if extra.posZ then vm["PosZ"] = Variant(extra.posZ) end
        if extra.modelScale then vm["ModelScale"] = Variant(extra.modelScale) end
        if extra.modelKey then vm["ModelKey"] = Variant(extra.modelKey) end
        if extra.scaleX then vm["ScaleX"] = Variant(extra.scaleX) end
        if extra.scaleY then vm["ScaleY"] = Variant(extra.scaleY) end
        if extra.scaleZ then vm["ScaleZ"] = Variant(extra.scaleZ) end
    end

    serverConn:SendRemoteEvent(EVENTS.MAP_EDIT_OBS, true, vm)
    print(string.format("[MapEditor->Server] 发送 %s: %s (dec=%s)", action, obsName, tostring(isDec or false)))
end

--- 向服务端发送地形网格同步事件
---@param gridData string 序列化的地形网格数据
local function SendTerrainSync(gridData)
    local serverConn = network:GetServerConnection()
    if not serverConn then return end

    local vm = VariantMap()
    vm["GridData"] = Variant(gridData)
    serverConn:SendRemoteEvent(EVENTS.MAP_EDIT_TERRAIN, true, vm)
    print("[MapEditor->Server] 发送地形网格同步")
end

-- 导出给 TerrainEditor 使用
MapEditor.SendTerrainSync = SendTerrainSync

-- ============================================================================
-- API
-- ============================================================================

--- 初始化
---@param camNode Node
---@param scene Scene
---@param rootOrGetter any  UI root 面板或 getter 函数
function MapEditor.Init(camNode, scene, rootOrGetter)
    cameraNode_ = camNode
    scene_ = scene
    if type(rootOrGetter) == "function" then
        uiRootGetter_ = rootOrGetter
        uiRoot_ = rootOrGetter()
    else
        uiRoot_ = rootOrGetter
        uiRootGetter_ = nil
    end
end

--- 获取当前有效的 UI root（优先使用 getter 动态获取）
local function GetUIRoot()
    if uiRootGetter_ then
        uiRoot_ = uiRootGetter_()
    end
    return uiRoot_
end

--- 扫描场景中的围墙和围栏的每个子段节点，建立结构物列表（单段可编辑）
local function ScanStructures()
    structureList_ = {}
    if not scene_ then return end

    local wallSegCount = 0
    local fenceSegCount = 0

    for i = 0, scene_:GetNumChildren(false) - 1 do
        local child = scene_:GetChild(i)
        if child.name == "Wall" or child.name == "Fence" then
            local typeName = child.name
            if typeName == "Wall" then
                -- 围墙：按子段（WallSeg）逐个编辑
                for j = 0, child:GetNumChildren(false) - 1 do
                    local seg = child:GetChild(j)
                    if seg:GetComponent("StaticModel") then
                        wallSegCount = wallSegCount + 1
                        table.insert(structureList_, {
                            node = seg,
                            parentNode = child,
                            type = "Wall",
                            label = "围墙段" .. wallSegCount,
                        })
                    end
                end
            else
                -- 围栏：整个 Fence 父节点作为一个可编辑单元（包含多个 FenceSeg 子模型）
                -- 用位置识别方向（避免依赖创建顺序）
                local ta = Config.Level1.TargetArea
                local cx, cz = ta.Center.x, ta.Center.z
                local hw, hh = ta.Size.x / 2, ta.Size.z / 2
                local fp = child.position
                local side = "unknown"
                if fp.x > cx + hw * 0.5 then
                    side = "right"
                elseif fp.z > cz + hh * 0.5 then
                    side = "top"
                elseif fp.z < cz - hh * 0.5 then
                    side = "bottom"
                end
                fenceSegCount = fenceSegCount + 1
                local label = "围栏段" .. fenceSegCount
                table.insert(structureList_, {
                    node = child,           -- 整个 Fence 父节点
                    parentNode = nil,       -- 顶层节点，无父级
                    type = "Fence",
                    label = label,
                    side = side,            -- 物理方向标识
                })
                print(string.format("[MapEditor] 围栏段: %s → side=%s pos=(%.1f,%.1f,%.1f)",
                    label, side, fp.x, fp.y, fp.z))
            end
        end
    end

    print(string.format("[MapEditor] 扫描到 %d 个围墙段, %d 个围栏段", wallSegCount, fenceSegCount))
end

--- 获取当前选中对象的名称
local function GetSelectedName()
    if (selectedType_ == "obstacle" or selectedType_ == "decoration") and selectedObsIndex_ then
        local entry = GetSelectedEntry()
        return entry and entry.name or "Unknown"
    elseif selectedType_ == "structure" and selectedStructIndex_ then
        return structureList_[selectedStructIndex_].label
    end
    return "Unknown"
end

--- 开启编辑模式
function MapEditor.Enable()
    active_ = true
    state_ = STATE_IDLE
    selectedNode_ = nil
    selectedObsIndex_ = nil
    selectedType_ = nil
    selectedStructIndex_ = nil
    rightClickCount_ = 0
    rightClickTimer_ = 0
    ScanStructures()
    CloseAllUI()

    -- 防御性清理：强制移除 TerrainEditor 可能残留的菜单
    local root = GetUIRoot()
    if root then
        local terrainMenu = root:FindById("terrainMenu")
        if terrainMenu then
            terrainMenu:Remove()
            print("[MapEditor] 强制移除残留的地形菜单")
        end
    end

    ShowAddButton()
    print(string.format("[MapEditor] 编辑模式已开启, uiRoot_=%s", tostring(GetUIRoot())))
end

--- 关闭编辑模式
function MapEditor.Disable()
    -- 如果正在操作中，取消操作
    if state_ == STATE_MOVING then
        CancelMove()
    elseif state_ == STATE_ROTATING then
        CancelRotate()
    elseif state_ == STATE_SCALING then
        CancelScale()
    elseif state_ == STATE_ADDING then
        CloseAddPanel()
    end
    active_ = false
    state_ = STATE_IDLE
    selectedNode_ = nil
    selectedObsIndex_ = nil
    selectedType_ = nil
    selectedStructIndex_ = nil
    CloseAllUI()
    CloseAddButton()
    CloseAddPanel()
    print("[MapEditor] 编辑模式已关闭")
end

--- 是否处于编辑模式
---@return boolean
function MapEditor.IsActive()
    return active_
end

--- 是否正在添加模型（面板打开中）
function MapEditor.IsAddingModel()
    return state_ == STATE_ADDING
end

--- 是否正在进行需要屏蔽左键的操作（移动时左键点击设置位置）
---@return boolean
function MapEditor.IsOperating()
    return active_ and state_ == STATE_MOVING
end

--- 每帧更新
---@param dt number
function MapEditor.Update(dt)
    if not active_ then return end

    -- 左键双击计时
    if leftClickTimer_ > 0 then
        leftClickTimer_ = leftClickTimer_ - dt
        if leftClickTimer_ <= 0 then
            leftClickCount_ = 0
        end
    end

    -- 只在 state_ == IDLE 或 SELECTED 时检测左键双击
    if state_ == STATE_IDLE or state_ == STATE_SELECTED then
        DetectLeftDoubleClick()
    end

    -- 根据状态处理输入
    if state_ == STATE_MOVING then
        HandleMoveInput(dt)
    elseif state_ == STATE_SCALING then
        HandleScaleInput(dt)
    end

    -- Esc 键：取消当前操作或取消选中
    if input:GetKeyPress(KEY_ESCAPE) then
        if state_ == STATE_MOVING then
            CancelMove()
        elseif state_ == STATE_ROTATING then
            CancelRotate()
        elseif state_ == STATE_SCALING then
            CancelScale()
        elseif state_ == STATE_ADDING then
            CloseAddPanel()
            state_ = STATE_IDLE
            ShowAddButton()
        elseif state_ == STATE_SELECTED then
            DeselectNode()
        end
    end

    -- Enter 键：确认当前操作
    if input:GetKeyPress(KEY_RETURN) then
        if state_ == STATE_MOVING then
            ConfirmMove()
        elseif state_ == STATE_ROTATING then
            ConfirmRotate()
        elseif state_ == STATE_SCALING then
            ConfirmScale()
        end
    end

    -- 每帧更新菜单位置（跟随模型）
    UpdateMenuPosition()
end

--- 在 PostRenderUpdate 中绘制选中高亮
function MapEditor.DrawGizmos()
    if not active_ or not selectedNode_ then return end
    if not scene_ then return end

    local debugRenderer = scene_:GetComponent("DebugRenderer")
    if not debugRenderer then return end

    local color = (state_ == STATE_MOVING) and MOVING_COLOR or HIGHLIGHT_COLOR

    -- 结构段 / 障碍物 / 通用：统一查找 StaticModel
    local model = nil
    if selectedType_ == "structure" then
        -- 单段节点本身有 StaticModel
        model = selectedNode_:GetComponent("StaticModel")
    else
        -- 障碍物优先查 Visual 子节点
        local visualNode = selectedNode_:GetChild("Visual")
        if visualNode then
            model = visualNode:GetComponent("StaticModel")
        else
            model = selectedNode_:GetComponent("StaticModel")
        end
    end

    if model then
        debugRenderer:AddBoundingBox(model.worldBoundingBox, color, false)
    end
end

--- 保存当前地图到日志
function MapEditor.SaveToLog()
    local L = Config.Level1
    local output = "-- ============================================================\n"
    output = output .. "-- 地图编辑器导出 — " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n"
    output = output .. "-- 可直接粘贴到 GameConfig.lua 的 Level1.Obstacles 中\n"
    output = output .. "-- ============================================================\n"
    output = output .. "Obstacles = {\n"

    for i, obs in ipairs(L.Obstacles) do
        -- 从场景中读取实际位置（编辑后的）
        local node = scene_:GetChild(obs.name)
        local pos = obs.pos
        local ms = obs.modelScale or 1.0

        if node then
            pos = Vector3(node.position.x, 0, node.position.z)
            local visual = node:GetChild("Visual")
            if visual then
                ms = visual.scale.x
            end
        end

        local line = string.format(
            '    { pos = Vector3(%g, 0, %g), scale = Vector3(%g, %g, %g), name = "%s"',
            pos.x, pos.z,
            obs.scale.x, obs.scale.y, obs.scale.z,
            obs.name
        )

        if obs.modelKey then
            line = line .. string.format(', modelKey = "%s"', obs.modelKey)
        end

        line = line .. string.format(', modelScale = %g', ms)

        -- 读取旋转
        if node then
            local visual = node:GetChild("Visual")
            if visual then
                local angle = visual.rotation:EulerAngles()
                if math.abs(angle.x) > 0.1 or math.abs(angle.y) > 0.1 or math.abs(angle.z) > 0.1 then
                    line = line .. string.format(', modelRotation = Quaternion(%g, %g, %g)', angle.x, angle.y, angle.z)
                end
            end
        elseif obs.modelRotation then
            local angle = obs.modelRotation:EulerAngles()
            if math.abs(angle.x) > 0.1 or math.abs(angle.y) > 0.1 or math.abs(angle.z) > 0.1 then
                line = line .. string.format(', modelRotation = Quaternion(%g, %g, %g)', angle.x, angle.y, angle.z)
            end
        end

        if obs.noCollision then
            line = line .. ', noCollision = true'
        end

        line = line .. ' },'
        output = output .. line .. "\n"
    end

    output = output .. "}\n\n"

    -- 导出结构物（围墙/围栏）位置信息
    if #structureList_ > 0 then
        output = output .. "-- 结构物（围墙/围栏）当前位置\n"
        output = output .. "-- 注意：这些位置需要手动更新到 Shared.lua 的创建代码中\n"
        for i, struct in ipairs(structureList_) do
            local node = struct.node
            if node then
                local pos = node.position
                local rot = node.rotation:EulerAngles()
                local scl = node.scale
                output = output .. string.format(
                    '-- %s: pos=(%.2f, %.2f, %.2f), rot=(%.1f, %.1f, %.1f), scale=(%.2f, %.2f, %.2f)\n',
                    struct.label,
                    pos.x, pos.y, pos.z,
                    rot.x, rot.y, rot.z,
                    scl.x, scl.y, scl.z
                )
            end
        end
    end

    print("=== MAP EDITOR EXPORT START ===")
    print(output)
    print("=== MAP EDITOR EXPORT END ===")
end

-- ============================================================================
-- 世界坐标投影到屏幕坐标
-- ============================================================================

--- 将世界坐标投影到屏幕像素坐标
---@param worldPos Vector3
---@return number|nil x, number|nil y  屏幕像素坐标，不可见时返回 nil
WorldToScreen = function(worldPos)
    if not cameraNode_ then return nil, nil end
    local camera = cameraNode_:GetComponent("Camera")
    if not camera then return nil, nil end

    -- 先检查点是否在相机前方
    local camDir = cameraNode_:GetDirection()
    local toTarget = worldPos - cameraNode_:GetWorldPosition()
    if camDir:DotProduct(toTarget) <= 0 then return nil, nil end

    -- WorldToScreenPoint 返回 Vector2 (归一化 0~1)
    local screenPos = camera:WorldToScreenPoint(worldPos)
    if not screenPos then return nil, nil end

    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local dpr = graphics:GetDPR()
    local logicalW = physW / dpr
    local logicalH = physH / dpr

    return screenPos.x * logicalW, screenPos.y * logicalH
end

--- 合并节点所有子节点的世界包围盒（用于围墙/围栏等多段结构）
---@param node Node
---@return BoundingBox|nil
MergeChildBoundingBoxes = function(node)
    local minX, minY, minZ =  1e9,  1e9,  1e9
    local maxX, maxY, maxZ = -1e9, -1e9, -1e9
    local found = false

    for i = 0, node:GetNumChildren(false) - 1 do
        local child = node:GetChild(i)
        local model = child:GetComponent("StaticModel")
        if model then
            local bb = model.worldBoundingBox
            minX = math.min(minX, bb.min.x)
            minY = math.min(minY, bb.min.y)
            minZ = math.min(minZ, bb.min.z)
            maxX = math.max(maxX, bb.max.x)
            maxY = math.max(maxY, bb.max.y)
            maxZ = math.max(maxZ, bb.max.z)
            found = true
        end
    end

    if found then
        return BoundingBox(Vector3(minX, minY, minZ), Vector3(maxX, maxY, maxZ))
    end
    return nil
end

--- 获取选中模型的顶部世界坐标
---@return Vector3|nil
GetSelectedTopPos = function()
    if not selectedNode_ then return nil end

    -- 结构段：直接使用段节点自身的 StaticModel
    if selectedType_ == "structure" then
        local model = selectedNode_:GetComponent("StaticModel")
        if model then
            local bb = model.worldBoundingBox
            return Vector3(
                (bb.min.x + bb.max.x) / 2,
                bb.max.y + 0.3,
                (bb.min.z + bb.max.z) / 2
            )
        end
        local wp = selectedNode_.worldPosition
        return Vector3(wp.x, wp.y + 1, wp.z)
    end

    -- 障碍物：使用 Visual 子节点
    local visualNode = selectedNode_:GetChild("Visual")
    local model = visualNode and visualNode:GetComponent("StaticModel") or selectedNode_:GetComponent("StaticModel")
    if model then
        local bb = model.worldBoundingBox
        return Vector3(
            (bb.min.x + bb.max.x) / 2,
            bb.max.y + 0.3,
            (bb.min.z + bb.max.z) / 2
        )
    end

    return Vector3(selectedNode_.position.x, selectedNode_.position.y + 2, selectedNode_.position.z)
end

-- ============================================================================
-- 左键双击检测
-- ============================================================================

local leftWasDown_ = false

DetectLeftDoubleClick = function()
    -- UI 上方不检测
    if UI.IsPointerOverUI() then return end

    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)

    -- 检测左键释放瞬间
    if leftWasDown_ and not leftDown then
        if not leftWasDrag_ then
            leftClickCount_ = leftClickCount_ + 1
            leftClickTimer_ = DOUBLE_CLICK_TIME

            if leftClickCount_ >= 2 then
                leftClickCount_ = 0
                leftClickTimer_ = 0
                TrySelectAtMouse()
            end
        else
            leftClickCount_ = 0
            leftClickTimer_ = 0
        end
    end

    -- 检测左键按下瞬间
    if leftDown and not leftWasDown_ then
        leftDownPos_ = { x = input.mousePosition.x, y = input.mousePosition.y }
        leftWasDrag_ = false
    end

    -- 追踪按住期间的移动
    if leftDown and leftDownPos_ then
        local mx = input.mousePosition.x
        local my = input.mousePosition.y
        local dx = mx - leftDownPos_.x
        local dy = my - leftDownPos_.y
        if math.abs(dx) > CLICK_MOVE_THRESH or math.abs(dy) > CLICK_MOVE_THRESH then
            leftWasDrag_ = true
        end
    end

    leftWasDown_ = leftDown
end

-- ============================================================================
-- 选中逻辑
-- ============================================================================

TrySelectAtMouse = function()
    if not cameraNode_ or not scene_ then return end

    local camera = cameraNode_:GetComponent("Camera")
    if not camera then return end

    local mousePos = input.mousePosition
    local screenW = graphics:GetWidth()
    local screenH = graphics:GetHeight()
    if screenW <= 0 or screenH <= 0 then return end

    local nx = mousePos.x / screenW
    local ny = mousePos.y / screenH

    local ray = camera:GetScreenRay(nx, ny)

    local octree = scene_:GetComponent("Octree")
    if not octree then return end

    local result = octree:RaycastSingle(ray, RAY_TRIANGLE, 200.0, DRAWABLE_GEOMETRY)
    if not result or not result.drawable then
        if state_ == STATE_SELECTED then
            DeselectNode()
        end
        return
    end

    local hitNode = result.drawable:GetNode()
    local rootNode, idx, nodeType = FindSelectableRoot(hitNode)

    if rootNode and idx and nodeType then
        SelectNode(rootNode, idx, nodeType)
    else
        if state_ == STATE_SELECTED then
            DeselectNode()
        end
    end
end

--- 从节点向上查找可选中的根节点（障碍物或结构物）
---@param node Node
---@return Node|nil node
---@return number|nil index
---@return string|nil type "obstacle" or "structure"
FindSelectableRoot = function(node)
    local current = node
    for _ = 1, 5 do
        if not current then break end
        local name = current.name

        -- 检查障碍物
        for i, obs in ipairs(Config.Level1.Obstacles) do
            if obs.name == name then
                return current, i, "obstacle"
            end
        end

        -- 检查外围装饰物
        for i, dec in ipairs(Config.Exterior.Decorations) do
            if dec.name and dec.name == name then
                return current, i, "decoration"
            end
        end

        -- 检查结构物（围墙/围栏）
        for i, struct in ipairs(structureList_) do
            if current == struct.node then
                return current, i, "structure"
            end
        end

        current = current:GetParent()
    end
    return nil, nil, nil
end

SelectNode = function(node, idx, nodeType)
    selectedNode_ = node
    selectedType_ = nodeType
    if nodeType == "obstacle" or nodeType == "decoration" then
        selectedObsIndex_ = idx
        selectedStructIndex_ = nil
    else
        selectedStructIndex_ = idx
        selectedObsIndex_ = nil
    end
    state_ = STATE_SELECTED

    print(string.format("[MapEditor] 选中: %s (类型 %s, 索引 %d)", GetSelectedName(), nodeType, idx))
    ShowMenu()
end

DeselectNode = function()
    selectedNode_ = nil
    selectedObsIndex_ = nil
    selectedType_ = nil
    selectedStructIndex_ = nil
    state_ = STATE_IDLE
    CloseAllUI()
    print("[MapEditor] 取消选中")
end

-- ============================================================================
-- 关闭所有 UI
-- ============================================================================

CloseAllUI = function()
    CloseMenu()
    CloseRotatePanel()
    CloseScalePanel()
    CloseStatusHint()
    CloseAddPanel()
end

-- ============================================================================
-- 菜单 UI（跟随模型位置）
-- ============================================================================

ShowMenu = function()
    CloseAllUI()

    local root = GetUIRoot()
    if not selectedNode_ or not root then return end

    -- 防御性清理：移除可能残留的地形编辑菜单
    local terrainMenu = root:FindById("terrainMenu")
    if terrainMenu then
        terrainMenu:Remove()
        print("[MapEditor] ShowMenu: 移除残留的地形菜单")
    end

    local displayName = GetSelectedName()
    local T = AstroonTheme.Tokens

    menuPanel_ = UI.Panel {
        id = "editorMenu",
        position = "absolute",
        top = 0,
        left = 0,
        translateX = -1,   -- 水平居中
        translateY = -1,   -- 完全在锚点上方
        width = 280,
        padding = 10,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 230 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = T.border,
        boxShadow = {
            { x = 0, y = 4, blur = 12, spread = 0, color = T.shadow },
        },
        alignItems = "center",
        gap = 6,
        children = {
            UI.Label {
                text = "编辑: " .. displayName,
                fontSize = 14,
                fontWeight = "bold",
                fontColor = T.text,
            },
            UI.Panel {
                flexDirection = "row",
                gap = 6,
                children = {
                    UI.Button {
                        text = "移动",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 12, paddingRight = 12,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 33, 69, 138, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() StartMove() end,
                    },
                    UI.Button {
                        text = "旋转",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 12, paddingRight = 12,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 33, 69, 138, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() StartRotate() end,
                    },
                    UI.Button {
                        text = "缩放",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 12, paddingRight = 12,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 33, 69, 138, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() StartScale() end,
                    },
                    UI.Button {
                        text = "删除",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 12, paddingRight = 12,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 160, 30, 30, 255 },
                        hoverBackgroundColor = { 200, 40, 40, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() DeleteSelected() end,
                    },
                },
            },
            UI.Label {
                text = "右键双击选择其他模型 | Esc 取消选中",
                fontSize = 11,
                fontColor = T.textMuted,
                textAlign = "center",
            },
        },
    }

    root:AddChild(menuPanel_)

    -- 立即更新位置
    UpdateMenuPosition()
    print(string.format("[MapEditor] ShowMenu: 编辑菜单已创建 - %s", displayName))
end

CloseMenu = function()
    if menuPanel_ then
        menuPanel_:Remove()
        menuPanel_ = nil
    end
end

--- 每帧更新菜单面板位置（跟随模型的世界坐标投影）
UpdateMenuPosition = function()
    local panel = menuPanel_ or rotatePanel_ or scalePanel_
    if not panel or not selectedNode_ then return end

    local topPos = GetSelectedTopPos()
    if not topPos then return end

    local sx, sy = WorldToScreen(topPos)
    if sx and sy then
        -- 获取逻辑屏幕尺寸
        local dpr = graphics:GetDPR()
        local logicalW = graphics:GetWidth() / dpr
        local logicalH = graphics:GetHeight() / dpr

        -- 面板使用 translateX=-1, translateY=-1，即向左偏移 100% 宽度、向上偏移 100% 高度
        -- 估算面板尺寸（menuPanel=280, rotatePanel=340, scalePanel=320）
        local panelW = 340  -- 取最大值以确保所有面板都可见
        local panelH = 200  -- 面板高度估算

        -- 夹紧 sx：确保面板左边缘不超出屏幕左边（sx - panelW >= 0）
        sx = math.max(sx, panelW)
        -- 夹紧 sx：确保面板右边缘不超出屏幕右边
        sx = math.min(sx, logicalW)

        -- 夹紧 sy：确保面板上边缘不超出屏幕上方（sy - panelH >= 0）
        sy = math.max(sy, panelH)
        -- 夹紧 sy：确保面板不超出屏幕下方
        sy = math.min(sy, logicalH)

        panel.left = sx
        panel.top = sy
    end
end

-- ============================================================================
-- 删除操作
-- ============================================================================

DeleteSelected = function()
    if not selectedNode_ then return end

    local name = GetSelectedName()

    if selectedType_ == "obstacle" and selectedObsIndex_ then
        print(string.format("[MapEditor] 删除障碍物: %s (索引 %d)", name, selectedObsIndex_))
        selectedNode_:Remove()
        table.remove(Config.Level1.Obstacles, selectedObsIndex_)
        Shared.MarkObstacleCollidersDirty()
        SendObsEdit("delete", name)
        print(string.format("[MapEditor] 已删除: %s, 剩余障碍物: %d", name, #Config.Level1.Obstacles))
    elseif selectedType_ == "decoration" and selectedObsIndex_ then
        print(string.format("[MapEditor] 删除装饰物: %s (索引 %d)", name, selectedObsIndex_))
        selectedNode_:Remove()
        table.remove(Config.Exterior.Decorations, selectedObsIndex_)
        SendObsEdit("delete", name, nil, true)
        print(string.format("[MapEditor] 已删除: %s, 剩余装饰物: %d", name, #Config.Exterior.Decorations))
    elseif selectedType_ == "structure" and selectedStructIndex_ then
        local struct = structureList_[selectedStructIndex_]
        local structType = struct.type  -- "Wall" or "Fence"
        local side = struct.side or ""  -- 围栏方向标识 (right/top/bottom)
        print(string.format("[MapEditor] 删除结构物: %s (索引 %d, 类型 %s, side=%s)", name, selectedStructIndex_, structType, side))
        selectedNode_:Remove()
        table.remove(structureList_, selectedStructIndex_)
        -- 向服务端发送结构物删除事件
        local serverConn = network:GetServerConnection()
        if serverConn then
            local vm = VariantMap()
            vm["Action"] = Variant("delete")
            vm["Label"]  = Variant(name)         -- 如 "围栏段1"
            vm["Type"]   = Variant(structType)    -- "Wall" or "Fence"
            vm["Side"]   = Variant(side)          -- 物理方向 (right/top/bottom)
            serverConn:SendRemoteEvent(EVENTS.MAP_EDIT_STRUCT, true, vm)
            print(string.format("[MapEditor->Server] 发送结构物删除: %s (%s, side=%s)", name, structType, side))
        end
        print(string.format("[MapEditor] 已删除: %s, 剩余结构物: %d", name, #structureList_))
    end

    -- 清理状态
    selectedNode_ = nil
    selectedObsIndex_ = nil
    selectedType_ = nil
    selectedStructIndex_ = nil
    state_ = STATE_IDLE
    CloseAllUI()
end

-- ============================================================================
-- 移动操作
-- ============================================================================

StartMove = function()
    if not selectedNode_ then return end
    state_ = STATE_MOVING
    -- 结构段是子节点，用世界坐标；障碍物/装饰物是场景直接子节点，position 即世界坐标
    if selectedType_ == "structure" then
        local wp = selectedNode_.worldPosition
        moveOrigPos_ = Vector3(wp.x, wp.y, wp.z)
    else
        moveOrigPos_ = Vector3(selectedNode_.position.x, selectedNode_.position.y, selectedNode_.position.z)
    end
    moveCurrent_ = Vector3(moveOrigPos_.x, moveOrigPos_.y, moveOrigPos_.z)
    CloseAllUI()

    ShowStatusHint("左键按住拖拽模型移动 | Enter 确认 | Esc 取消")
    print("[MapEditor] 开始移动: " .. GetSelectedName())
end

HandleMoveInput = function(dt)
    if not selectedNode_ then return end

    -- 左键按住期间持续拖拽模型跟随鼠标
    if input:GetMouseButtonDown(MOUSEB_LEFT) and not UI.IsPointerOverUI() then
        local hitPos = RaycastGround()
        if hitPos then
            local snappedX = math.floor(hitPos.x / SNAP_SIZE + 0.5) * SNAP_SIZE
            local snappedZ = math.floor(hitPos.z / SNAP_SIZE + 0.5) * SNAP_SIZE

            if (selectedType_ == "obstacle" or selectedType_ == "decoration") and selectedObsIndex_ then
                local entry = GetSelectedEntry()
                local yOff = entry.scale and entry.scale.y / 2 or 0
                moveCurrent_ = Vector3(snappedX, yOff, snappedZ)
                selectedNode_.position = moveCurrent_
                RealignVisual(selectedNode_, entry)
            else
                -- 结构段：用世界坐标移动（段是 Wall/Fence 的子节点）
                moveCurrent_ = Vector3(snappedX, moveOrigPos_.y, snappedZ)
                selectedNode_.worldPosition = moveCurrent_
            end
        end
    end
end

ConfirmMove = function()
    if not selectedNode_ then return end

    if selectedType_ == "obstacle" and selectedObsIndex_ then
        local obs = Config.Level1.Obstacles[selectedObsIndex_]
        obs.pos = Vector3(selectedNode_.position.x, 0, selectedNode_.position.z)
        Shared.MarkObstacleCollidersDirty()
        SendObsEdit("move", obs.name, { posX = obs.pos.x, posZ = obs.pos.z })
        print(string.format("[MapEditor] 移动确认: %s -> (%.1f, %.1f)", obs.name, obs.pos.x, obs.pos.z))
    elseif selectedType_ == "decoration" and selectedObsIndex_ then
        local dec = Config.Exterior.Decorations[selectedObsIndex_]
        dec.pos = Vector3(selectedNode_.position.x, 0, selectedNode_.position.z)
        SendObsEdit("move", dec.name, { posX = dec.pos.x, posZ = dec.pos.z }, true)
        print(string.format("[MapEditor] 移动确认(装饰): %s -> (%.1f, %.1f)", dec.name, dec.pos.x, dec.pos.z))
    else
        print(string.format("[MapEditor] 移动确认: %s -> (%.1f, %.1f)", GetSelectedName(), selectedNode_.position.x, selectedNode_.position.z))
    end

    state_ = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
end

CancelMove = function()
    if selectedNode_ and moveOrigPos_ then
        if selectedType_ == "structure" then
            selectedNode_.worldPosition = moveOrigPos_
        else
            selectedNode_.position = moveOrigPos_
            if (selectedType_ == "obstacle" or selectedType_ == "decoration") and selectedObsIndex_ then
                local entry = GetSelectedEntry()
                if entry then RealignVisual(selectedNode_, entry) end
            end
        end
    end
    state_ = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
    print("[MapEditor] 移动取消")
end

-- ============================================================================
-- 旋转操作（角度输入面板，支持水平+垂直）
-- ============================================================================

StartRotate = function()
    if not selectedNode_ then return end
    state_ = STATE_ROTATING

    -- 保存原始旋转
    if selectedType_ == "structure" then
        -- 结构物：旋转根节点
        rotateOrigRot_ = Quaternion(selectedNode_.rotation.w, selectedNode_.rotation.x, selectedNode_.rotation.y, selectedNode_.rotation.z)
        rotateOrigModelRot_ = nil
        local euler = selectedNode_.rotation:EulerAngles()
        rotatePitch_ = math.floor(euler.x + 0.5)
        rotateYaw_ = math.floor(euler.y + 0.5)
    else
        -- 障碍物：旋转 Visual 子节点
        local visual = selectedNode_:GetChild("Visual")
        if visual then
            rotateOrigModelRot_ = Quaternion(visual.rotation.w, visual.rotation.x, visual.rotation.y, visual.rotation.z)
            rotateOrigRot_ = nil
            local euler = visual.rotation:EulerAngles()
            rotatePitch_ = math.floor(euler.x + 0.5)
            rotateYaw_ = math.floor(euler.y + 0.5)
        else
            rotateOrigRot_ = Quaternion(selectedNode_.rotation.w, selectedNode_.rotation.x, selectedNode_.rotation.y, selectedNode_.rotation.z)
            rotateOrigModelRot_ = nil
            local euler = selectedNode_.rotation:EulerAngles()
            rotatePitch_ = math.floor(euler.x + 0.5)
            rotateYaw_ = math.floor(euler.y + 0.5)
        end
    end

    CloseAllUI()
    ShowRotatePanel()
    print("[MapEditor] 开始旋转: " .. GetSelectedName())
end

--- 应用旋转角度到模型
ApplyRotation = function()
    if not selectedNode_ then return end
    local newRot = Quaternion(rotatePitch_, rotateYaw_, 0)

    if selectedType_ == "structure" then
        selectedNode_.rotation = newRot
    else
        local visual = selectedNode_:GetChild("Visual")
        if visual then
            visual.rotation = newRot
        else
            selectedNode_.rotation = newRot
        end
        -- 重新对齐底部（障碍物/装饰物）
        if selectedObsIndex_ then
            local entry = GetSelectedEntry()
            if entry then RealignVisual(selectedNode_, entry) end
        end
    end
end

ConfirmRotate = function()
    if not selectedNode_ then return end

    if (selectedType_ == "obstacle" or selectedType_ == "decoration") and selectedObsIndex_ then
        local entry = GetSelectedEntry()
        local visual = selectedNode_:GetChild("Visual")
        if visual and entry then
            entry.modelRotation = Quaternion(visual.rotation.w, visual.rotation.x, visual.rotation.y, visual.rotation.z)
        end
        print(string.format("[MapEditor] 旋转确认: %s, 水平=%d° 垂直=%d°", GetSelectedName(), rotateYaw_, rotatePitch_))
    else
        print(string.format("[MapEditor] 旋转确认: %s, 水平=%d° 垂直=%d°", GetSelectedName(), rotateYaw_, rotatePitch_))
    end

    state_ = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
end

CancelRotate = function()
    if selectedType_ == "structure" then
        if selectedNode_ and rotateOrigRot_ then
            selectedNode_.rotation = rotateOrigRot_
        end
    else
        local visual = selectedNode_ and selectedNode_:GetChild("Visual")
        if visual and rotateOrigModelRot_ then
            visual.rotation = rotateOrigModelRot_
        elseif selectedNode_ and rotateOrigRot_ then
            selectedNode_.rotation = rotateOrigRot_
        end
        -- 重新对齐（障碍物/装饰物）
        if selectedNode_ and selectedObsIndex_ then
            local entry = GetSelectedEntry()
            if entry then RealignVisual(selectedNode_, entry) end
        end
    end

    state_ = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
    print("[MapEditor] 旋转取消")
end

-- ============================================================================
-- 旋转面板 UI
-- ============================================================================

ShowRotatePanel = function()
    CloseRotatePanel()
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens
    local displayName = GetSelectedName()

    -- 预设按钮构建辅助函数
    local function MakePresetBtn(angle, applyFn)
        return UI.Button {
            text = angle .. "°",
            fontSize = 12,
            fontWeight = "bold",
            borderRadius = 4,
            paddingLeft = 8, paddingRight = 8,
            paddingTop = 4, paddingBottom = 4,
            backgroundColor = { 50, 50, 80, 255 },
            hoverBackgroundColor = { 70, 70, 110, 255 },
            fontColor = { 255, 255, 255, 255 },
            onClick = function() applyFn(angle) end,
        }
    end

    -- 水平旋转预设按钮
    local yawPresetChildren = {}
    for _, angle in ipairs(PRESET_ANGLES) do
        table.insert(yawPresetChildren, MakePresetBtn(angle, function(a)
            rotateYaw_ = a
            ApplyRotation()
            UpdateRotateLabels()
        end))
    end

    -- 垂直旋转预设按钮
    local pitchPresetChildren = {}
    for _, angle in ipairs(PRESET_ANGLES) do
        table.insert(pitchPresetChildren, MakePresetBtn(angle, function(a)
            rotatePitch_ = a
            ApplyRotation()
            UpdateRotateLabels()
        end))
    end

    rotatePanel_ = UI.Panel {
        id = "rotatePanel",
        position = "absolute",
        top = 0,
        left = 0,
        translateX = -1,
        translateY = -1,
        width = 360,
        padding = 12,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 230 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = T.border,
        boxShadow = {
            { x = 0, y = 4, blur = 12, spread = 0, color = T.shadow },
        },
        alignItems = "center",
        gap = 8,
        children = {
            UI.Label {
                text = "旋转: " .. displayName,
                fontSize = 14,
                fontWeight = "bold",
                fontColor = T.text,
            },
            -- ── 水平旋转 (Yaw) ──
            UI.Panel {
                width = "100%",
                gap = 4,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 8,
                        children = {
                            UI.Label {
                                text = "水平:",
                                fontSize = 13,
                                fontWeight = "bold",
                                fontColor = T.text,
                                width = 40,
                            },
                            UI.Slider {
                                id = "yawSlider",
                                value = rotateYaw_ + 180,
                                min = 0, max = 360, step = 1,
                                flexGrow = 1,
                                onChange = function(self, v)
                                    rotateYaw_ = math.floor(v - 180 + 0.5)
                                    ApplyRotation()
                                    UpdateRotateLabels()
                                end,
                            },
                            UI.Label {
                                id = "yawValueLabel",
                                text = rotateYaw_ .. "°",
                                fontSize = 14,
                                fontWeight = "bold",
                                fontColor = T.primary,
                                width = 45,
                                textAlign = "right",
                            },
                        },
                    },
                    -- 预设按钮 + 自定义输入
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 4,
                        alignItems = "center",
                        justifyContent = "center",
                        children = {
                            yawPresetChildren[1],
                            yawPresetChildren[2],
                            yawPresetChildren[3],
                            yawPresetChildren[4],
                            UI.TextField {
                                id = "yawInput",
                                value = tostring(rotateYaw_),
                                placeholder = "角度",
                                width = 60,
                                height = 28,
                                fontSize = 12,
                                textAlign = "center",
                                onSubmit = function(self, v)
                                    local num = tonumber(v)
                                    if num then
                                        rotateYaw_ = math.floor(num + 0.5)
                                        ApplyRotation()
                                        UpdateRotateLabels()
                                    end
                                end,
                            },
                        },
                    },
                },
            },
            -- ── 垂直旋转 (Pitch) ──
            UI.Panel {
                width = "100%",
                gap = 4,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 8,
                        children = {
                            UI.Label {
                                text = "垂直:",
                                fontSize = 13,
                                fontWeight = "bold",
                                fontColor = T.text,
                                width = 40,
                            },
                            UI.Slider {
                                id = "pitchSlider",
                                value = rotatePitch_ + 180,
                                min = 0, max = 360, step = 1,
                                flexGrow = 1,
                                onChange = function(self, v)
                                    rotatePitch_ = math.floor(v - 180 + 0.5)
                                    ApplyRotation()
                                    UpdateRotateLabels()
                                end,
                            },
                            UI.Label {
                                id = "pitchValueLabel",
                                text = rotatePitch_ .. "°",
                                fontSize = 14,
                                fontWeight = "bold",
                                fontColor = T.primary,
                                width = 45,
                                textAlign = "right",
                            },
                        },
                    },
                    -- 预设按钮 + 自定义输入
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 4,
                        alignItems = "center",
                        justifyContent = "center",
                        children = {
                            pitchPresetChildren[1],
                            pitchPresetChildren[2],
                            pitchPresetChildren[3],
                            pitchPresetChildren[4],
                            UI.TextField {
                                id = "pitchInput",
                                value = tostring(rotatePitch_),
                                placeholder = "角度",
                                width = 60,
                                height = 28,
                                fontSize = 12,
                                textAlign = "center",
                                onSubmit = function(self, v)
                                    local num = tonumber(v)
                                    if num then
                                        rotatePitch_ = math.floor(num + 0.5)
                                        ApplyRotation()
                                        UpdateRotateLabels()
                                    end
                                end,
                            },
                        },
                    },
                },
            },
            -- ── 操作按钮 ──
            UI.Panel {
                flexDirection = "row",
                gap = 10,
                children = {
                    UI.Button {
                        text = "确认",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 16, paddingRight = 16,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 40, 120, 40, 255 },
                        hoverBackgroundColor = { 50, 150, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() ConfirmRotate() end,
                    },
                    UI.Button {
                        text = "取消",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 16, paddingRight = 16,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 120, 40, 40, 255 },
                        hoverBackgroundColor = { 150, 50, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() CancelRotate() end,
                    },
                },
            },
        },
    }

    root:AddChild(rotatePanel_)
    UpdateMenuPosition()
end

CloseRotatePanel = function()
    if rotatePanel_ then
        rotatePanel_:Remove()
        rotatePanel_ = nil
    end
end

--- 更新旋转面板中的角度数值标签
UpdateRotateLabels = function()
    if not rotatePanel_ then return end
    local yawLabel = rotatePanel_:FindById("yawValueLabel")
    if yawLabel then yawLabel.text = rotateYaw_ .. "°" end
    local pitchLabel = rotatePanel_:FindById("pitchValueLabel")
    if pitchLabel then pitchLabel.text = rotatePitch_ .. "°" end
end

-- ============================================================================
-- 缩放操作
-- ============================================================================

StartScale = function()
    if not selectedNode_ then return end
    state_ = STATE_SCALING

    if (selectedType_ == "obstacle" or selectedType_ == "decoration") and selectedObsIndex_ then
        local entry = GetSelectedEntry()
        scaleOrigScale_ = entry and entry.modelScale or 1.0
    else
        -- 结构物：使用根节点 scale
        scaleOrigScale_ = selectedNode_.scale.x
    end
    scaleCurrent_ = scaleOrigScale_

    CloseAllUI()
    ShowScalePanel()
    print("[MapEditor] 开始缩放: " .. GetSelectedName() .. " 当前: " .. scaleOrigScale_)
end

HandleScaleInput = function(dt)
    -- 缩放由 UI Slider 驱动
end

ApplyScale = function(value)
    if not selectedNode_ then return end
    scaleCurrent_ = value

    if selectedType_ == "structure" then
        -- 结构物：缩放根节点
        selectedNode_.scale = Vector3(value, value, value)
    else
        -- 障碍物/装饰物：缩放 Visual 子节点
        local visual = selectedNode_:GetChild("Visual")
        if visual then
            visual.scale = Vector3(value, value, value)
        end
        if selectedObsIndex_ then
            local entry = GetSelectedEntry()
            if entry then RealignVisual(selectedNode_, entry) end
        end
    end
end

ConfirmScale = function()
    if not selectedNode_ then return end

    if selectedType_ == "obstacle" and selectedObsIndex_ then
        local obs = Config.Level1.Obstacles[selectedObsIndex_]
        obs.modelScale = scaleCurrent_
        Shared.MarkObstacleCollidersDirty()
        SendObsEdit("scale", obs.name, { modelScale = scaleCurrent_ })
        print(string.format("[MapEditor] 缩放确认: %s -> %.2f", obs.name, scaleCurrent_))
    elseif selectedType_ == "decoration" and selectedObsIndex_ then
        local dec = Config.Exterior.Decorations[selectedObsIndex_]
        dec.modelScale = scaleCurrent_
        SendObsEdit("scale", dec.name, { modelScale = scaleCurrent_ }, true)
        print(string.format("[MapEditor] 缩放确认(装饰): %s -> %.2f", dec.name, scaleCurrent_))
    else
        print(string.format("[MapEditor] 缩放确认: %s -> %.2f", GetSelectedName(), scaleCurrent_))
    end

    state_ = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
end

CancelScale = function()
    if selectedNode_ then
        if selectedType_ == "structure" then
            if scaleOrigScale_ then
                selectedNode_.scale = Vector3(scaleOrigScale_, scaleOrigScale_, scaleOrigScale_)
            end
        else
            local visual = selectedNode_:GetChild("Visual")
            if visual and scaleOrigScale_ then
                visual.scale = Vector3(scaleOrigScale_, scaleOrigScale_, scaleOrigScale_)
            end
            if selectedObsIndex_ then
                local entry = GetSelectedEntry()
                if entry then RealignVisual(selectedNode_, entry) end
            end
        end
    end

    state_ = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
    print("[MapEditor] 缩放取消")
end

-- ============================================================================
-- 缩放面板 UI
-- ============================================================================

ShowScalePanel = function()
    CloseScalePanel()
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens
    local displayName = GetSelectedName()

    scalePanel_ = UI.Panel {
        id = "scalePanel",
        position = "absolute",
        top = 0,
        left = 0,
        translateX = -1,
        translateY = -1,
        width = 320,
        padding = 12,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 230 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = T.border,
        boxShadow = {
            { x = 0, y = 4, blur = 12, spread = 0, color = T.shadow },
        },
        alignItems = "center",
        gap = 8,
        children = {
            UI.Label {
                text = "缩放: " .. displayName,
                fontSize = 14,
                fontWeight = "bold",
                fontColor = T.text,
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 8,
                children = {
                    UI.Label {
                        text = "0.1x",
                        fontSize = 11,
                        fontColor = T.textMuted,
                    },
                    UI.Slider {
                        id = "scaleSlider",
                        value = scaleCurrent_ * 10,
                        min = 1, max = 100, step = 1,
                        flexGrow = 1,
                        onChange = function(self, v)
                            local realValue = v / 10.0
                            ApplyScale(realValue)
                            local label = scalePanel_ and scalePanel_:FindById("scaleValueLabel")
                            if label then
                                label.text = string.format("%.1fx", realValue)
                            end
                        end,
                    },
                    UI.Label {
                        text = "10x",
                        fontSize = 11,
                        fontColor = T.textMuted,
                    },
                },
            },
            UI.Label {
                id = "scaleValueLabel",
                text = string.format("%.1fx", scaleCurrent_),
                fontSize = 16,
                fontWeight = "bold",
                fontColor = T.primary,
            },
            -- 操作按钮
            UI.Panel {
                flexDirection = "row",
                gap = 10,
                children = {
                    UI.Button {
                        text = "✓ 确认",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 16, paddingRight = 16,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 40, 120, 40, 255 },
                        hoverBackgroundColor = { 50, 150, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() ConfirmScale() end,
                    },
                    UI.Button {
                        text = "✗ 取消",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 16, paddingRight = 16,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 120, 40, 40, 255 },
                        hoverBackgroundColor = { 150, 50, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() CancelScale() end,
                    },
                },
            },
        },
    }

    root:AddChild(scalePanel_)
    UpdateMenuPosition()
end

CloseScalePanel = function()
    if scalePanel_ then
        scalePanel_:Remove()
        scalePanel_ = nil
    end
end

-- ============================================================================
-- 状态提示 UI
-- ============================================================================

ShowStatusHint = function(text)
    CloseStatusHint()
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens

    statusHintPanel_ = UI.Panel {
        id = "editorStatusHint",
        position = "absolute",
        bottom = 50,
        left = "50%",
        translateX = -1,
        padding = 10,
        paddingLeft = 20,
        paddingRight = 20,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 220 },
        borderRadius = 9999,
        borderWidth = 1,
        borderColor = T.border,
        children = {
            UI.Label {
                text = text,
                fontSize = 14,
                fontColor = T.text,
                textAlign = "center",
            },
        },
    }

    root:AddChild(statusHintPanel_)
end

CloseStatusHint = function()
    if statusHintPanel_ then
        statusHintPanel_:Remove()
        statusHintPanel_ = nil
    end
end

-- ============================================================================
-- 辅助函数
-- ============================================================================

--- 射线与地面 Y=0 求交
---@return Vector3|nil
RaycastGround = function()
    if not cameraNode_ then return nil end
    local camera = cameraNode_:GetComponent("Camera")
    if not camera then return nil end

    local mousePos = input.mousePosition
    local screenW = graphics:GetWidth()
    local screenH = graphics:GetHeight()
    if screenW <= 0 or screenH <= 0 then return nil end

    local nx = mousePos.x / screenW
    local ny = mousePos.y / screenH

    local ray = camera:GetScreenRay(nx, ny)

    if math.abs(ray.direction.y) < 0.0001 then return nil end
    local t = -ray.origin.y / ray.direction.y
    if t < 0 then return nil end

    return Vector3(
        ray.origin.x + t * ray.direction.x,
        0,
        ray.origin.z + t * ray.direction.z
    )
end

--- 重新计算 Visual 子节点的底部对齐
---@param node Node
---@param obs table
RealignVisual = function(node, obs)
    if not obs then return end
    local visual = node:GetChild("Visual")
    if not visual then return end

    local model = visual:GetComponent("StaticModel")
    if not model then return end

    visual.position = Vector3(visual.position.x, 0, visual.position.z)

    local worldBB = model.worldBoundingBox
    local worldMinY = worldBB.min.y
    visual.position = Vector3(
        visual.position.x,
        visual.position.y + (node.position.y - obs.scale.y / 2) - worldMinY,
        visual.position.z
    )
end

-- ============================================================================
-- 添加模型功能
-- ============================================================================

--- 画面中心射线投射到 Y=0 地面，返回网格对齐后的世界坐标
GetScreenCenterGround = function()
    if not cameraNode_ then return nil end
    local camera = cameraNode_:GetComponent("Camera")
    if not camera then return nil end

    -- 画面正中心 (0.5, 0.5)
    local ray = camera:GetScreenRay(0.5, 0.5)
    if math.abs(ray.direction.y) < 0.0001 then return nil end
    local t = -ray.origin.y / ray.direction.y
    if t < 0 then return nil end

    local worldX = ray.origin.x + t * ray.direction.x
    local worldZ = ray.origin.z + t * ray.direction.z

    -- 按网格对齐
    local snappedX = math.floor(worldX / SNAP_SIZE + 0.5) * SNAP_SIZE
    local snappedZ = math.floor(worldZ / SNAP_SIZE + 0.5) * SNAP_SIZE
    return Vector3(snappedX, 0, snappedZ)
end

--- 显示左下角"添加模型"按钮
ShowAddButton = function()
    if addButton_ then return end
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens
    addButton_ = UI.Panel {
        id = "addModelBtn",
        position = "absolute",
        bottom = 20,
        left = 20,
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
                text = "+ 添加模型",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 40, 120, 40, 255 },
                hoverBackgroundColor = { 50, 150, 50, 255 },
                pressedBackgroundColor = { 35, 100, 35, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function()
                    ShowAddPanel()
                end,
            },
        },
    }
    root:AddChild(addButton_)
end

--- 隐藏左下角按钮
CloseAddButton = function()
    if addButton_ then
        addButton_:Remove()
        addButton_ = nil
    end
end

--- 显示模型选择面板
ShowAddPanel = function()
    CloseAddPanel()
    CloseAllUI()

    local root = GetUIRoot()
    if not root then return end

    state_ = STATE_ADDING
    addSelectedKey_ = nil

    local T = AstroonTheme.Tokens

    -- 构建模型按钮列表
    local modelButtons = {}
    for _, key in ipairs(MODEL_LIST_ORDER) do
        if Config.Models[key] then
            local displayName = MODEL_DISPLAY_NAMES[key] or key
            local modelKey = key
            table.insert(modelButtons, UI.Button {
                id = "modelItem_" .. modelKey,
                text = displayName,
                fontSize = 13,
                fontWeight = "normal",
                borderRadius = 4,
                width = "100%",
                paddingTop = 8,
                paddingBottom = 8,
                paddingLeft = 12,
                paddingRight = 12,
                backgroundColor = { 50, 50, 60, 255 },
                hoverBackgroundColor = { 70, 70, 90, 255 },
                fontColor = { 220, 220, 220, 255 },
                marginBottom = 4,
                onClick = function(self)
                    -- 取消之前选中项的高亮
                    if addSelectedKey_ and addPanel_ then
                        local prevBtn = addPanel_:FindById("modelItem_" .. addSelectedKey_)
                        if prevBtn then
                            prevBtn.backgroundColor = { 50, 50, 60, 255 }
                            prevBtn.fontColor = { 220, 220, 220, 255 }
                        end
                    end
                    -- 高亮当前
                    addSelectedKey_ = modelKey
                    self.backgroundColor = { 40, 120, 40, 255 }
                    self.fontColor = { 255, 255, 255, 255 }
                end,
            })
        end
    end

    addPanel_ = UI.Panel {
        id = "addModelPanel",
        position = "absolute",
        top = "50%",
        left = "50%",
        translateX = -1,
        translateY = -1,
        width = 260,
        maxHeight = 420,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 240 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = T.border,
        padding = 12,
        boxShadow = {
            { x = 0, y = 4, blur = 16, spread = 0, color = T.shadow },
        },
        children = {
            -- 标题
            UI.Label {
                text = "选择模型",
                fontSize = 16,
                fontWeight = "bold",
                fontColor = T.text,
                marginBottom = 10,
            },
            -- 滚动区域
            UI.ScrollView {
                width = "100%",
                maxHeight = 280,
                flexShrink = 1,
                children = {
                    UI.Panel {
                        width = "100%",
                        children = modelButtons,
                    },
                },
            },
            -- 底部按钮行
            UI.Panel {
                flexDirection = "row",
                gap = 8,
                marginTop = 10,
                justifyContent = "flex-end",
                width = "100%",
                children = {
                    UI.Button {
                        text = "确认添加",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 14, paddingRight = 14,
                        paddingTop = 7, paddingBottom = 7,
                        backgroundColor = { 40, 120, 40, 255 },
                        hoverBackgroundColor = { 50, 150, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function()
                            ConfirmAdd()
                        end,
                    },
                    UI.Button {
                        text = "取消",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 14, paddingRight = 14,
                        paddingTop = 7, paddingBottom = 7,
                        backgroundColor = { 120, 40, 40, 255 },
                        hoverBackgroundColor = { 160, 50, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function()
                            CloseAddPanel()
                            state_ = STATE_IDLE
                            ShowAddButton()
                        end,
                    },
                },
            },
        },
    }
    root:AddChild(addPanel_)

    -- 隐藏左下角添加按钮（面板打开时不需要）
    CloseAddButton()
end

--- 关闭模型选择面板
CloseAddPanel = function()
    if addPanel_ then
        addPanel_:Remove()
        addPanel_ = nil
    end
    addSelectedKey_ = nil
end

--- 确认添加模型到场景
ConfirmAdd = function()
    if not addSelectedKey_ then
        print("[MapEditor] 未选择模型")
        return
    end

    local modelInfo = Config.Models[addSelectedKey_]
    if not modelInfo then
        print("[MapEditor] 模型信息不存在: " .. tostring(addSelectedKey_))
        return
    end

    -- 获取画面中心地面坐标
    local groundPos = GetScreenCenterGround()
    if not groundPos then
        print("[MapEditor] 无法获取画面中心地面坐标")
        return
    end

    -- 自增计数，生成唯一名称
    addCounter_ = addCounter_ + 1
    local uniqueName = "Added_" .. addSelectedKey_ .. "_" .. addCounter_

    -- 根据模型信息计算合理的 scale（用于物理碰撞体回退和 Y 定位）
    -- modelInfo 已在上方获取（行 2030）
    local msDefault = 1.0
    local obsScale
    if modelInfo and modelInfo.footprintRadius then
        local dia = modelInfo.footprintRadius * 2 * msDefault
        obsScale = Vector3(dia, 2, dia)
    else
        obsScale = Vector3(1, 1, 1)
    end

    -- 构造障碍物数据
    local newObs = {
        pos = Vector3(groundPos.x, 0, groundPos.z),
        scale = obsScale,
        name = uniqueName,
        modelKey = addSelectedKey_,
        modelScale = msDefault,
    }

    -- 添加到配置并创建场景节点
    table.insert(Config.Level1.Obstacles, newObs)
    Shared.CreateObstacle(scene_, newObs, false)
    Shared.MarkObstacleCollidersDirty()

    -- 网络同步：通知服务端添加障碍物
    SendObsEdit("add", uniqueName, {
        posX = groundPos.x,
        posZ = groundPos.z,
        modelKey = addSelectedKey_,
        modelScale = msDefault,
        scaleX = obsScale.x, scaleY = obsScale.y, scaleZ = obsScale.z,
    })

    local displayName = MODEL_DISPLAY_NAMES[addSelectedKey_] or addSelectedKey_
    print(string.format("[MapEditor] 已添加: %s (%s) 在 (%.1f, %.1f)",
        displayName, uniqueName, groundPos.x, groundPos.z))

    -- 关闭面板，回到空闲状态
    CloseAddPanel()
    state_ = STATE_IDLE
    ShowAddButton()
end

return MapEditor
