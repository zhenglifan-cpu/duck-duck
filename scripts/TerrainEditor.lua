-- ============================================================================
-- TerrainEditor.lua — 地形规划模式
-- 在预览模式下标注网格类型：空地(passable) / 障碍(blocked) / 目标区(target)
-- 支持可视化覆盖、左键选择、Ctrl 多选、类型转换、导出
-- ============================================================================

local TerrainEditor = {}

local Config = require("config.GameConfig")
local Shared = require("network.Shared")
local UI = require("urhox-libs/UI")
local AstroonTheme = require("config.AstroonTheme")

local EVENTS = Config.EVENTS

-- ============================================================================
-- 常量
-- ============================================================================

-- 地形类型
local CELL_OPEN     = "open"       -- 空地（可通行）
local CELL_BLOCKED  = "blocked"    -- 障碍（不可通行）
local CELL_TARGET   = "target"     -- 目标区

-- 覆盖颜色（空地不绘制填充，障碍/目标用较高不透明度确保清晰）
local COLOR_OPEN    = Color(0.3, 0.5, 1.0, 0.25)   -- 浅蓝（仅用于图例参考，不绘制填充）
local COLOR_BLOCKED = Color(1.0, 0.2, 0.2, 0.3)    -- 红色半透明
local COLOR_TARGET  = Color(0.7, 0.2, 1.0, 0.3)    -- 紫色半透明

-- 选中高亮
local COLOR_SELECTED = Color(1.0, 1.0, 0.2, 0.6)   -- 黄色高亮边框

-- 网格高度（depthTest=true，地面节点已隐藏，覆盖层贴近 Y=0 充当地面颜色）
local OVERLAY_Y     = -0.01   -- 覆盖层高度（略低于地面，确保被3D模型遮挡）
local SELECT_Y      =  0.005  -- 选中框高度（略高于覆盖层，但低于模型底部）

-- (填充改用 AddTriangle，无需线密度常量)

-- ============================================================================
-- 状态
-- ============================================================================

---@type Scene
local scene_ = nil
---@type Node
local cameraNode_ = nil
local uiRoot_ = nil
local uiRootGetter_ = nil

local active_ = false

-- 地面节点引用（地形模式下隐藏）
local hiddenGroundNodes_ = {}

-- 地形网格数据: grid_[x][z] = "open" | "blocked" | "target"
-- 坐标范围: x = gridMinX_..gridMaxX_-1, z = gridMinZ_..gridMaxZ_-1
local grid_ = {}
local mapW_ = 0       -- 农场宽度 (用于居中计算)
local mapH_ = 0       -- 农场高度
local gridMinX_ = 0   -- 网格最小 X (含外围)
local gridMaxX_ = 0   -- 网格最大 X (不含)
local gridMinZ_ = 0   -- 网格最小 Z (含外围)
local gridMaxZ_ = 0   -- 网格最大 Z (不含)

-- 选中的格子集合: { {x=N, z=N}, ... }
local selectedCells_ = {}

-- UI
local menuPanel_ = nil         -- 左侧编辑菜单

-- ============================================================================
-- 前向声明（避免全局污染）
-- ============================================================================
local HideGroundNodes
local RestoreGroundNodes
local InitGridFromConfig
local IsCellBlocked
local HandleClickInput
local FindSelectedIndex
local SetSelectedType
local RaycastGroundPlane
local GetCellColor
local DrawFilledCell
local DrawCellBorder
local ShowMenu
local CloseMenu
local UpdateMenuState

-- ============================================================================
-- 地形网络同步
-- ============================================================================

--- 将地形网格序列化并发送到服务端
local function SyncTerrainToServer()
    if not grid_ then return end

    local serverConn = network:GetServerConnection()
    if not serverConn then return end

    -- 序列化为 "x,z,type;x,z,type;..." 格式
    local parts = {}
    for x, row in pairs(grid_) do
        for z, cellType in pairs(row) do
            parts[#parts + 1] = string.format("%d,%d,%s", x, z, cellType)
        end
    end
    local gridData = table.concat(parts, ";")

    local vm = VariantMap()
    vm["GridData"] = Variant(gridData)
    serverConn:SendRemoteEvent(EVENTS.MAP_EDIT_TERRAIN, true, vm)
    print("[TerrainEditor->Server] 发送地形网格同步, 格子数: " .. #parts)
end

-- ============================================================================
-- API
-- ============================================================================

--- 初始化
---@param camNode Node
---@param scene Scene
---@param rootOrGetter any  UI root 面板或 getter 函数
function TerrainEditor.Init(camNode, scene, rootOrGetter)
    cameraNode_ = camNode
    scene_ = scene
    if type(rootOrGetter) == "function" then
        uiRootGetter_ = rootOrGetter
        uiRoot_ = rootOrGetter()
    else
        uiRoot_ = rootOrGetter
        uiRootGetter_ = nil
    end

    mapW_ = Config.Level1.MapWidth   -- 18
    mapH_ = Config.Level1.MapHeight  -- 12

    -- 计算覆盖整张地图的网格范围（与 MapPreviewCamera.DrawGrid 一致）
    local extW = Config.Exterior.GroundWidth   -- 50
    local extH = Config.Exterior.GroundHeight  -- 40
    gridMinX_ = math.floor(mapW_ / 2 - extW / 2)   -- -16
    gridMaxX_ = math.ceil(mapW_ / 2 + extW / 2)     --  34
    gridMinZ_ = math.floor(mapH_ / 2 - extH / 2)    -- -14
    gridMaxZ_ = math.ceil(mapH_ / 2 + extH / 2)     --  26

    -- 初始化网格数据（自动检测）
    InitGridFromConfig()

    local totalW = gridMaxX_ - gridMinX_
    local totalH = gridMaxZ_ - gridMinZ_
    print(string.format("[TerrainEditor] 初始化完成 (网格范围: X[%d..%d] Z[%d..%d], %dx%d)",
        gridMinX_, gridMaxX_ - 1, gridMinZ_, gridMaxZ_ - 1, totalW, totalH))
end

--- 获取当前有效的 UI root（优先使用 getter 动态获取）
local function GetUIRoot()
    if uiRootGetter_ then
        uiRoot_ = uiRootGetter_()
    end
    return uiRoot_
end

--- 开启地形模式
function TerrainEditor.Enable()
    active_ = true
    selectedCells_ = {}

    -- 防御性清理：强制移除 MapEditor 可能残留的菜单
    local root = GetUIRoot()
    if root then
        for _, menuId in ipairs({"editorMenu", "rotatePanel", "scalePanel", "editorStatusHint"}) do
            local panel = root:FindById(menuId)
            if panel then
                panel:Remove()
                print("[TerrainEditor] 强制移除残留的编辑菜单: " .. menuId)
            end
        end
    end

    HideGroundNodes()
    ShowMenu()
    print("[TerrainEditor] 地形规划模式已开启")
end

--- 关闭地形模式
function TerrainEditor.Disable()
    active_ = false
    selectedCells_ = {}
    RestoreGroundNodes()
    CloseMenu()
    print("[TerrainEditor] 地形规划模式已关闭")
end

--- 是否处于地形模式
---@return boolean
function TerrainEditor.IsActive()
    return active_
end

--- 每帧更新
---@param dt number
function TerrainEditor.Update(dt)
    if not active_ then return end
    HandleClickInput()
end

--- 在 PostRenderUpdate 中绘制地形覆盖
function TerrainEditor.DrawOverlay()
    if not active_ or not scene_ then return end

    local debugRenderer = scene_:GetComponent("DebugRenderer")
    if not debugRenderer then return end

    -- 仅绘制障碍和目标区的填充色（空地不绘制填充，避免半透明蓝色笼罩整个场景）
    -- 网格线已由 MapPreviewCamera.DrawGrid 绘制，空地通过网格线即可辨识
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                local cellType = grid_[x][z]
                if cellType and cellType ~= CELL_OPEN then
                    local color = GetCellColor(cellType)
                    DrawFilledCell(debugRenderer, x, z, OVERLAY_Y, color)
                end
            end
        end
    end

    -- 绘制选中高亮边框
    for _, cell in ipairs(selectedCells_) do
        DrawCellBorder(debugRenderer, cell.x, cell.z, SELECT_Y, COLOR_SELECTED)
    end
end

--- 获取地形数据（用于导出）
---@return string 格式化的地形数据文本
function TerrainEditor.ExportToLog()
    local totalW = gridMaxX_ - gridMinX_
    local totalH = gridMaxZ_ - gridMinZ_

    local output = "-- ============================================================\n"
    output = output .. "-- 地形规划导出 — " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n"
    output = output .. string.format("-- 网格范围: X[%d..%d] Z[%d..%d] (%dx%d, 1格=1m)\n",
        gridMinX_, gridMaxX_ - 1, gridMinZ_, gridMaxZ_ - 1, totalW, totalH)
    output = output .. string.format("-- 农场区域: X[0..%d] Z[0..%d]\n", mapW_ - 1, mapH_ - 1)
    output = output .. "-- 类型: open=空地, blocked=障碍, target=目标区\n"
    output = output .. "-- ============================================================\n\n"

    -- 统计
    local countOpen, countBlocked, countTarget = 0, 0, 0
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                local t = grid_[x][z]
                if t == CELL_OPEN then countOpen = countOpen + 1
                elseif t == CELL_BLOCKED then countBlocked = countBlocked + 1
                elseif t == CELL_TARGET then countTarget = countTarget + 1
                end
            end
        end
    end
    output = output .. string.format("-- 统计: 空地=%d, 障碍=%d, 目标=%d, 总计=%d\n\n",
        countOpen, countBlocked, countTarget, countOpen + countBlocked + countTarget)

    -- 输出障碍格子列表
    output = output .. "TerrainData = {\n"
    output = output .. "    blocked = {\n"
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                if grid_[x][z] == CELL_BLOCKED then
                    output = output .. string.format("        { x = %d, z = %d },\n", x, z)
                end
            end
        end
    end
    output = output .. "    },\n"

    -- 输出目标区格子列表
    output = output .. "    target = {\n"
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                if grid_[x][z] == CELL_TARGET then
                    output = output .. string.format("        { x = %d, z = %d },\n", x, z)
                end
            end
        end
    end
    output = output .. "    },\n"
    output = output .. "}\n"

    -- 输出视觉地图（仅农场区域，Z 从高到低，方便阅读）
    output = output .. "\n-- 视觉地图 — 农场区域 (. = 空地, # = 障碍, T = 目标)\n"
    output = output .. "-- Z↑\n"
    for z = mapH_ - 1, 0, -1 do
        local row = string.format("-- %2d |", z)
        for x = 0, mapW_ - 1 do
            local t = grid_[x] and grid_[x][z] or CELL_OPEN
            if t == CELL_BLOCKED then
                row = row .. "#"
            elseif t == CELL_TARGET then
                row = row .. "T"
            else
                row = row .. "."
            end
        end
        row = row .. "|"
        output = output .. row .. "\n"
    end
    output = output .. "--    +"
    for x = 0, mapW_ - 1 do output = output .. "-" end
    output = output .. "+  → X\n"

    return output
end

-- ============================================================================
-- 地面节点隐藏/恢复（地形模式下隐藏地面贴图以显示地形颜色）
-- ============================================================================

local GROUND_NODE_NAMES = { "Floor", "TargetFloor", "ExteriorFloor", "Road1", "Road2" }

--- 隐藏所有地面节点
HideGroundNodes = function()
    hiddenGroundNodes_ = {}
    if not scene_ then return end
    for _, name in ipairs(GROUND_NODE_NAMES) do
        local node = scene_:GetChild(name, true)
        if node and node.enabled then
            node.enabled = false
            table.insert(hiddenGroundNodes_, node)
            print("[TerrainEditor] 隐藏地面: " .. name)
        end
    end
end

--- 恢复所有隐藏的地面节点
RestoreGroundNodes = function()
    for _, node in ipairs(hiddenGroundNodes_) do
        if node then
            node.enabled = true
        end
    end
    hiddenGroundNodes_ = {}
    print("[TerrainEditor] 地面节点已恢复显示")
end

-- ============================================================================
-- 网格初始化：自动检测地形类型
-- ============================================================================

InitGridFromConfig = function()
    grid_ = {}

    -- 先全部初始化为空地（覆盖整张地图范围）
    for x = gridMinX_, gridMaxX_ - 1 do
        grid_[x] = {}
        for z = gridMinZ_, gridMaxZ_ - 1 do
            grid_[x][z] = CELL_OPEN
        end
    end

    -- 标记目标区格子
    local ta = Config.Level1.TargetArea
    local taMinX = ta.Center.x - ta.Size.x / 2
    local taMaxX = ta.Center.x + ta.Size.x / 2
    local taMinZ = ta.Center.z - ta.Size.z / 2
    local taMaxZ = ta.Center.z + ta.Size.z / 2

    for x = gridMinX_, gridMaxX_ - 1 do
        for z = gridMinZ_, gridMaxZ_ - 1 do
            -- 格子中心点
            local cx = x + 0.5
            local cz = z + 0.5
            if cx >= taMinX and cx <= taMaxX and cz >= taMinZ and cz <= taMaxZ then
                grid_[x][z] = CELL_TARGET
            end
        end
    end

    -- 障碍物不再自动标记为 blocked —— 只有围墙边界和手动标记才算 blocked
    -- 标记地图边界围墙为 blocked（围墙厚度 0.5m，在地图边缘外侧）
    -- 围墙区域：x<0, x>=MapWidth, z<0, z>=MapHeight
    local mapW = Config.Level1.MapWidth
    local mapH = Config.Level1.MapHeight
    for x = gridMinX_, gridMaxX_ - 1 do
        for z = gridMinZ_, gridMaxZ_ - 1 do
            if x < 0 or x >= mapW or z < 0 or z >= mapH then
                grid_[x][z] = CELL_BLOCKED
            end
        end
    end

    print("[TerrainEditor] 地形初始化完成（围墙+目标区）")

    -- 同步地形网格到服务端（本地 + 网络）
    Shared.terrainGrid = grid_
    SyncTerrainToServer()

    -- 刷新目标区地面贴图
    if scene_ then
        Shared.RebuildTargetFloor(scene_)
    end
end

--- 判断格子中心是否被碰撞体覆盖
---@param cx number 格子中心 X
---@param cz number 格子中心 Z
---@param colliders table 碰撞体列表
---@return boolean
IsCellBlocked = function(cx, cz, colliders)
    -- 用一个较小半径做检测（格子中心点是否在碰撞体内或非常接近）
    local testRadius = 0.3
    for _, c in ipairs(colliders) do
        if c.isBox then
            -- 点在 AABB 内或紧邻
            local dx = math.abs(cx - c.x)
            local dz = math.abs(cz - c.z)
            if dx <= c.halfW + testRadius and dz <= c.halfH + testRadius then
                return true
            end
        else
            -- 点在圆内
            local dx = cx - c.x
            local dz = cz - c.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist <= c.radius + testRadius then
                return true
            end
        end
    end
    return false
end

-- ============================================================================
-- 点击输入
-- ============================================================================

HandleClickInput = function()
    if not active_ then return end

    -- 如果鼠标在 UI 控件上（如转换按钮），跳过地面点击处理
    -- 修复：点击"→ 障碍"等按钮时，左键同时触发地面选择导致 selectedCells_ 被重置
    if UI.IsPointerOverUI() then return end

    -- 左键点击选择/取消选择格子
    if input:GetMouseButtonPress(MOUSEB_LEFT) then
        local hitPos = RaycastGroundPlane()
        if hitPos then
            local cellX = math.floor(hitPos.x)
            local cellZ = math.floor(hitPos.z)

            -- 必须在地图范围内（含外围）
            if cellX >= gridMinX_ and cellX < gridMaxX_ and cellZ >= gridMinZ_ and cellZ < gridMaxZ_ then
                local ctrlDown = input:GetKeyDown(KEY_CTRL)

                if ctrlDown then
                    -- Ctrl+点击：追加/移除选择
                    local idx = FindSelectedIndex(cellX, cellZ)
                    if idx then
                        table.remove(selectedCells_, idx)
                    else
                        table.insert(selectedCells_, { x = cellX, z = cellZ })
                    end
                else
                    -- 普通点击：单选
                    local idx = FindSelectedIndex(cellX, cellZ)
                    if idx and #selectedCells_ == 1 then
                        -- 再次点击唯一已选中的格子 → 取消
                        selectedCells_ = {}
                    else
                        selectedCells_ = { { x = cellX, z = cellZ } }
                    end
                end

                UpdateMenuState()
            end
        end
    end
end

--- 在选中列表中查找格子索引
---@return number|nil
FindSelectedIndex = function(x, z)
    for i, cell in ipairs(selectedCells_) do
        if cell.x == x and cell.z == z then
            return i
        end
    end
    return nil
end

-- ============================================================================
-- 地形转换
-- ============================================================================

--- 将选中格子设为指定类型
---@param newType string  "open" | "blocked" | "target"
SetSelectedType = function(newType)
    if #selectedCells_ == 0 then
        print("[TerrainEditor] 无选中格子，跳过转换")
        return
    end

    local typeNames = { open = "空地", blocked = "障碍", target = "目标" }
    local count = 0
    for _, cell in ipairs(selectedCells_) do
        if grid_[cell.x] and grid_[cell.x][cell.z] then
            local oldType = grid_[cell.x][cell.z]
            grid_[cell.x][cell.z] = newType
            count = count + 1
            print(string.format("[TerrainEditor] 格子(%d,%d): %s → %s",
                cell.x, cell.z, typeNames[oldType] or oldType, typeNames[newType] or newType))
        else
            print(string.format("[TerrainEditor] 格子(%d,%d): 数据不存在，跳过", cell.x, cell.z))
        end
    end

    print(string.format("[TerrainEditor] 已将 %d 个格子转换为 %s", count, typeNames[newType] or newType))

    -- 同步地形网格到服务端（本地 + 网络）
    Shared.terrainGrid = grid_
    SyncTerrainToServer()

    -- 刷新目标区地面贴图
    if scene_ then
        Shared.RebuildTargetFloor(scene_)
    end

    -- 转换完成后清空选择（不要清空，让用户能看到转换结果）
    selectedCells_ = {}
    UpdateMenuState()
end

-- ============================================================================
-- 鼠标射线
-- ============================================================================

---@return Vector3|nil
RaycastGroundPlane = function()
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

-- ============================================================================
-- 绘制辅助
-- ============================================================================

--- 获取格子类型对应的颜色
---@param cellType string
---@return Color
GetCellColor = function(cellType)
    if cellType == CELL_BLOCKED then return COLOR_BLOCKED
    elseif cellType == CELL_TARGET then return COLOR_TARGET
    else return COLOR_OPEN
    end
end

--- 用两个三角形绘制实心填充格子
---@param debugRenderer DebugRenderer
---@param x number 格子X坐标 (整数)
---@param z number 格子Z坐标 (整数)
---@param y number 绘制高度
---@param color Color
DrawFilledCell = function(debugRenderer, x, z, y, color)
    -- 格子四个角（稍微内缩 0.02 避免与网格线完全重叠）
    local m = 0.02
    local v1 = Vector3(x + m,     y, z + m)      -- 左下
    local v2 = Vector3(x + 1 - m, y, z + m)      -- 右下
    local v3 = Vector3(x + 1 - m, y, z + 1 - m)  -- 右上
    local v4 = Vector3(x + m,     y, z + 1 - m)  -- 左上

    -- 两个三角形组成一个填充矩形（depthTest=true: 受深度测试，被3D模型正确遮挡）
    -- 顶点绕序：v1→v3→v2 / v1→v4→v3，使法线朝上 (0,1,0)，避免角度变化导致颜色忽明忽暗
    debugRenderer:AddTriangle(v1, v3, v2, color, true)
    debugRenderer:AddTriangle(v1, v4, v3, color, true)
end

--- 绘制格子边框
---@param debugRenderer DebugRenderer
---@param x number
---@param z number
---@param y number
---@param color Color
DrawCellBorder = function(debugRenderer, x, z, y, color)
    debugRenderer:AddLine(Vector3(x, y, z), Vector3(x + 1, y, z), color, true)
    debugRenderer:AddLine(Vector3(x + 1, y, z), Vector3(x + 1, y, z + 1), color, true)
    debugRenderer:AddLine(Vector3(x + 1, y, z + 1), Vector3(x, y, z + 1), color, true)
    debugRenderer:AddLine(Vector3(x, y, z + 1), Vector3(x, y, z), color, true)
end

-- ============================================================================
-- UI：左侧操作菜单
-- ============================================================================

ShowMenu = function()
    CloseMenu()
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens

    menuPanel_ = UI.Panel {
        id = "terrainMenu",
        position = "absolute",
        top = 120,
        left = 10,
        width = 150,
        padding = 8,
        gap = 6,
        backgroundColor = { 0, 0, 0, 255 },
        borderRadius = 0,
        children = {
            UI.Panel {
                padding = 8,
                gap = 6,
                backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 240 },
                borderRadius = 0,
                alignItems = "stretch",
                children = {
                    UI.Label {
                        id = "terrainMenuTitle",
                        text = "地形规划",
                        fontSize = 14,
                        fontWeight = "bold",
                        fontColor = T.text,
                        textAlign = "center",
                    },
                    UI.Label {
                        id = "terrainSelCount",
                        text = "未选中",
                        fontSize = 12,
                        fontColor = T.textMuted,
                        textAlign = "center",
                    },
                    -- 分隔线
                    UI.Panel {
                        width = "100%",
                        height = 1,
                        backgroundColor = T.border,
                    },
                    UI.Button {
                        id = "btnToOpen",
                        text = "→ 空地",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 40, 90, 170, 255 },
                        hoverBackgroundColor = { 55, 110, 200, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function() SetSelectedType(CELL_OPEN) end,
                    },
                    UI.Button {
                        id = "btnToBlocked",
                        text = "→ 障碍",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 170, 50, 50, 255 },
                        hoverBackgroundColor = { 200, 65, 65, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function() SetSelectedType(CELL_BLOCKED) end,
                    },
                    UI.Button {
                        id = "btnToTarget",
                        text = "→ 目标",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 120, 50, 170, 255 },
                        hoverBackgroundColor = { 145, 65, 200, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function() SetSelectedType(CELL_TARGET) end,
                    },
                    UI.Button {
                        id = "btnClearSel",
                        text = "取消选择",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 80, 80, 80, 255 },
                        hoverBackgroundColor = { 110, 110, 110, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function()
                            selectedCells_ = {}
                            UpdateMenuState()
                        end,
                    },
                    -- 图例
                    UI.Panel {
                        width = "100%",
                        height = 1,
                        backgroundColor = T.border,
                        marginTop = 4,
                    },
                    UI.Label {
                        text = "图例:",
                        fontSize = 11,
                        fontColor = T.textMuted,
                        marginTop = 2,
                    },
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 4,
                        children = {
                            UI.Panel { width = 12, height = 12, backgroundColor = { 77, 128, 255, 46 }, borderRadius = 0 },
                            UI.Label { text = "空地", fontSize = 11, fontColor = T.textSecondary },
                        },
                    },
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 4,
                        children = {
                            UI.Panel { width = 12, height = 12, backgroundColor = { 255, 77, 77, 56 }, borderRadius = 0 },
                            UI.Label { text = "障碍", fontSize = 11, fontColor = T.textSecondary },
                        },
                    },
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 4,
                        children = {
                            UI.Panel { width = 12, height = 12, backgroundColor = { 179, 77, 255, 64 }, borderRadius = 0 },
                            UI.Label { text = "目标区", fontSize = 11, fontColor = T.textSecondary },
                        },
                    },
                    UI.Label {
                        text = "左键选择\nCtrl+左键多选",
                        fontSize = 10,
                        fontColor = T.textMuted,
                        textAlign = "center",
                        marginTop = 4,
                    },
                },
            },
        },
    }

    root:AddChild(menuPanel_)
    UpdateMenuState()
end

CloseMenu = function()
    if menuPanel_ then
        menuPanel_:Remove()
        menuPanel_ = nil
    end
end

--- 地形类型中文名称
local TYPE_NAMES = { open = "空地", blocked = "障碍", target = "目标区" }

--- 根据选中状态更新菜单按钮可见性
UpdateMenuState = function()
    if not menuPanel_ then return end

    local hasSelection = #selectedCells_ > 0

    local selLabel = menuPanel_:FindById("terrainSelCount")
    if selLabel then
        if hasSelection then
            -- 统计选中格子的地形类型
            local typeCounts = {}
            for _, cell in ipairs(selectedCells_) do
                local t = (grid_[cell.x] and grid_[cell.x][cell.z]) or CELL_OPEN
                typeCounts[t] = (typeCounts[t] or 0) + 1
            end
            -- 构建类型描述
            local parts = {}
            for t, count in pairs(typeCounts) do
                table.insert(parts, string.format("%s×%d", TYPE_NAMES[t] or t, count))
            end
            selLabel.text = string.format("已选 %d 格\n%s", #selectedCells_, table.concat(parts, " "))
        else
            selLabel.text = "未选中"
        end
    end

    local btnOpen = menuPanel_:FindById("btnToOpen")
    local btnBlocked = menuPanel_:FindById("btnToBlocked")
    local btnTarget = menuPanel_:FindById("btnToTarget")
    local btnClear = menuPanel_:FindById("btnClearSel")

    if btnOpen then btnOpen.visible = hasSelection end
    if btnBlocked then btnBlocked.visible = hasSelection end
    if btnTarget then btnTarget.visible = hasSelection end
    if btnClear then btnClear.visible = hasSelection end
end

return TerrainEditor
