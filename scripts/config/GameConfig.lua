-- ============================================================================
-- GameConfig.lua — 《赶鸭子上架》全局游戏配置
-- 所有数值参数集中管理，便于调试和平衡
-- ============================================================================

local GameConfig = {}

-- ============================================================================
-- 玩家矮人参数
-- ============================================================================
GameConfig.Player = {
    Height        = 1.0,      -- 矮人身高 (m)
    Radius        = 0.35,     -- 碰撞胶囊半径 (m)
    WalkSpeed     = 4.0,      -- 移动速度 (m/s)
    SprintSpeed   = 6.5,      -- 冲刺速度 (m/s)
    ClapCooldown  = 0.8,      -- 拍手冷却 (s)

    -- 矮人颜色配置 (P1~P4)
    Colors = {
        Color(0.85, 0.25, 0.2,  1.0),  -- P1 红色
        Color(0.2,  0.45, 0.85, 1.0),  -- P2 蓝色
        Color(0.25, 0.75, 0.3,  1.0),  -- P3 绿色
        Color(0.9,  0.8,  0.2,  1.0),  -- P4 黄色
    },
}

-- ============================================================================
-- 鸭子 AI 参数（第一关专用）
-- ============================================================================
GameConfig.Duck = {
    MoveSpeed        = 2.0,    -- 鸭子基础移动速度 (m/s)
    AlertRadius      = 5.5,    -- 玩家进入此范围后鸭子进入警觉状态 (m)
    FearRadius       = 3.5,    -- 玩家靠近多远开始逃跑 (m)
    ClapFearRadius   = 5.0,    -- 拍手惊吓范围 (m)
    ClapFearBoost    = 1.8,    -- 拍手额外恐惧力系数
    CohesionRadius   = 4.0,    -- 聚合感知范围 (m)
    SeparationDist   = 0.8,    -- 最小间距 (m)
    WanderStrength   = 0.3,    -- 闲逛随机力
    AlertTime        = 1.4,    -- 警觉→平静恢复时间 (s)
    CalmDownTime     = 2.0,    -- 惊慌→平静恢复时间 (s)
    PanicTime        = 2.4,    -- 拍手/近距离惊吓后的惊慌持续时间 (s)
    SettleTime       = 1.5,    -- 进入目标区后需停留多久算"上架" (s)
    MaxSpeed         = 3.5,    -- 最大速度限制 (m/s)
    PanicSpeedMultiplier = 1.12, -- 惊慌状态最大速度倍率

    -- Boids 权重
    SeparationWeight = 1.5,
    CohesionWeight   = 0.8,
    AlignmentWeight  = 0.3,
    AlertFearWeight  = 1.0,
    FearWeight       = 3.0,
    WanderWeight     = 0.5,
    BoundaryWeight   = 2.0,
    ObstacleWeight   = 2.5,

    -- 上架后行为参数
    SettledWanderSpeed = 0.6,  -- 上架后闲逛速度 (m/s)
    SettledJumpInterval = {3.0, 7.0},  -- 跳跃间隔范围 (s)
    SettledJumpHeight   = 0.25,        -- 跳跃高度 (m)
    SettledJumpDuration = 0.4,         -- 跳跃动画时长 (s)
    EscapeDistance      = 10.0,        -- 所有玩家超过此距离，鸭子有几率逃跑 (m)
    EscapeChance        = 1 / 15,      -- 每次判定逃跑的概率
    EscapeCheckInterval = 15.0,        -- 逃跑判定间隔 (s)

    -- 鸭子视觉参数
    BodyScale    = Vector3(0.35, 0.25, 0.4),   -- 身体(扁椭球)
    HeadScale    = Vector3(0.18, 0.18, 0.18),   -- 头(球)
    BeakScale    = Vector3(0.08, 0.05, 0.12),   -- 嘴(小锥)
    BodyColor    = Color(0.95, 0.95, 0.90, 1.0), -- 白色身体
    HeadColor    = Color(0.95, 0.95, 0.90, 1.0), -- 白色头
    BeakColor    = Color(0.95, 0.65, 0.15, 1.0), -- 橙黄嘴
    SettledColor = Color(0.8,  0.9,  0.8,  1.0), -- 上架后身体微绿
}

-- ============================================================================
-- 鸭子分型（v3.0 / v2.2 实施）
-- 每只鸭子在 DuckRoster 中的 type 字段决定其使用的参数
-- normal/leader/stubborn/mom 仍走完整 Boids；duckling 受母鸭牵引（>tether 进入哀鸣）
-- ============================================================================
GameConfig.DuckTypes = {
    normal = {
        scale = 1.0, speedMult = 1.0, fearImmune = false,
    },
    leader = {
        scale = 1.3, speedMult = 0.95, fearImmune = false,
        leaderRadius = 5.0,        -- 对周围多远的普通鸭施加跟随力
        leaderInfluence = 0.7,     -- 跟随力强度（与领头鸭速度差的比例）
    },
    stubborn = {
        scale = 1.1, speedMult = 0.85, fearImmune = true,
        breadAttractMult = 1.5,
    },
    mom = {
        scale = 1.15, speedMult = 0.95, fearImmune = false,
        callRadius = 2.0, callBoost = 1.5,
    },
    duckling = {
        scale = 0.55, speedMult = 1.1, fearImmune = false,
        motherTetherRadius = 4.0,  -- 距母鸭超过此距离 → 进入哀鸣态
        motherDependence = true,
    },
}

-- ============================================================================
-- 连击系统（Combo）
-- 短时间内连续上架多只鸭子 → 倍率金币奖励
-- 设计目的：奖励"集群驱赶"策略，让"何时一起赶"成为决策点
-- ============================================================================
GameConfig.Combo = {
    Window         = 3.0,    -- 连击窗口时间 (s)：每次上架后窗口重置为该值
    -- 连击数 → 倍率（index = 连击数；超过最大 index 后取最后值）
    -- 1 只 = 不算连击，2 只 ×2，3 只 ×3，4 只及以上 ×5
    Multipliers    = { 1, 2, 3, 5, 5 },
    PopupDuration  = 1.6,    -- HUD 连击弹窗显示时长 (s)
    MinComboToShow = 2,      -- 至少 2 连才弹窗（1 连不算"连击"）
}

-- ============================================================================
-- 关卡一：阳光牧场
-- ============================================================================
GameConfig.Level1 = {
    Name = "阳光牧场",
    MapWidth  = 18,   -- X 方向 (m) — 参考概念图比例
    MapHeight = 12,   -- Z 方向 (m) — 参考概念图比例

    -- 星级目标（v3.0：9 只鸭子，含 1 头鸭 + 1 倔鸭 + 1 母鸭 + 3 小鸭仔 + 4 普通鸭）
    Star1 = 6,   -- ★☆☆
    Star2 = 8,   -- ★★☆
    Star3 = 9,   -- ★★★（必须连母带仔全部上架）

    -- 玩家出生点（地图底部中央）
    SpawnPoints = {
        Vector3(7,  0, 1.5),  -- P1
        Vector3(9,  0, 1.5),  -- P2
        Vector3(11, 0, 1.5),  -- P3
        Vector3(8,  0, 3),    -- P4
    },

    -- 鸭子名册（v2.2 引入分型系统）
    -- 每条目: { type = <DuckTypes key>, pos = Vector3, [ducklings = {Vector3, ...}] }
    -- mom 类型可附带 ducklings 数组，加载时自动展开为独立小鸭仔实体（自动绑母）
    DuckRoster = {
        { type = "normal",   pos = Vector3(4,  0, 7) },     -- 中左
        { type = "normal",   pos = Vector3(11, 0, 3) },     -- 玩家右前方，最易上手
        { type = "normal",   pos = Vector3(13, 0, 3) },     -- 右下
        { type = "normal",   pos = Vector3(15, 0, 2.5) },   -- 紧邻目标区
        { type = "leader",   pos = Vector3(8,  0, 5.5) },   -- 中央 — 头鸭 👑
        { type = "stubborn", pos = Vector3(2,  0, 10) },    -- 走失角入口 — 倔鸭 ⬛
        { type = "mom",      pos = Vector3(4,  0, 4),       -- 母鸭 + 3 小鸭仔
          ducklings = {
              Vector3(3.5, 0, 3),
              Vector3(4.5, 0, 3),
              Vector3(5.5, 0, 3),
          } },
    },

    -- 目标区域 (U形围栏，开口朝左)
    TargetArea = {
        Center  = Vector3(15, 0, 6),     -- 区域中心（右侧）
        Size    = Vector3(4, 0.1, 5),    -- 内部面积 4×5
        OpenDir = Vector3(-1, 0, 0),     -- 开口朝左
        OpenWidth = 3.0,                 -- 开口宽度 (m)
    },

    -- 场景装饰物 — 按概念图布局排列
    -- 概念图: 木屋左上, 岩石中央聚集, 目标区右侧含水槽和干草
    Obstacles = {
        -- ====== 小屋（左上角，自然2m高, scale 1.25 → 约2.5m高）======
        { pos = Vector3(3,  0,  10),  scale = Vector3(2.5, 2.5, 3),   name = "Cabin",   modelKey = "Cabin",       modelScale = 1.25 },

        -- ====== 岩石（中央偏右聚集，概念图中集中在场地中部）======
        { pos = Vector3(10, 0,  8),   scale = Vector3(1.2, 0.8, 1.2), name = "RockA",   modelKey = "RockLarge",   modelScale = 1.2 },
        { pos = Vector3(9,  0,  7),   scale = Vector3(1.0, 0.6, 1.0), name = "RockB",   modelKey = "RockCluster", modelScale = 0.8 },
        { pos = Vector3(10.5,0, 7.5), scale = Vector3(1.0, 0.4, 1.0), name = "RockC",   modelKey = "RockFlat",    modelScale = 1.0 },

        -- ====== 木桶（1个靠近小屋，2个靠近岩石群）======
        { pos = Vector3(4.5,0,  10),  scale = Vector3(0.5, 0.5, 0.5), name = "Barrel1", modelKey = "Barrel",      modelScale = 0.65 },
        { pos = Vector3(10.5,0, 9),   scale = Vector3(0.5, 0.5, 0.5), name = "Barrel2", modelKey = "Barrel",      modelScale = 0.65 },
        { pos = Vector3(11, 0,  8),   scale = Vector3(0.5, 0.5, 0.5), name = "Barrel3", modelKey = "Barrel",      modelScale = 0.65 },
        { pos = Vector3(9.5,0,  8.5), scale = Vector3(0.5, 0.5, 0.5), name = "Barrel4", modelKey = "Barrel",      modelScale = 0.60 },

        -- ====== 木箱（岩石群旁边，概念图中2个木箱）======
        { pos = Vector3(9,  0,  6),   scale = Vector3(0.6, 0.6, 0.6), name = "Crate1",  modelKey = "Crate",       modelScale = 0.7 },
        { pos = Vector3(10, 0,  5.5), scale = Vector3(0.6, 0.6, 0.6), name = "Crate2",  modelKey = "Crate",       modelScale = 0.7 },

        -- ====== 树木（沿地图边缘/角落，概念图中5棵大树）======
        { pos = Vector3(1.2,0,  7),   scale = Vector3(0.8, 3.5, 0.8), name = "Tree1",   modelKey = "TreeTall",    modelScale = 3.5 },
        { pos = Vector3(1.2,0,  2.5), scale = Vector3(0.7, 2.5, 0.7), name = "Tree2",   modelKey = "TreeMedium",  modelScale = 2.5 },
        { pos = Vector3(16.5,0, 1.5), scale = Vector3(0.6, 2.0, 0.6), name = "Tree3",   modelKey = "TreeSmall",   modelScale = 2.0 },
        { pos = Vector3(16.5,0, 10.5),scale = Vector3(0.7, 2.5, 0.7), name = "Tree4",   modelKey = "TreeMedium",  modelScale = 2.8 },
        { pos = Vector3(9,  0,  11),  scale = Vector3(0.8, 3.5, 0.8), name = "Tree5",   modelKey = "TreeTall",    modelScale = 3.5 },

        -- ====== 草料堆（1个在目标区内，概念图中鸭圈里有干草）======
        { pos = Vector3(16, 0,  7.5), scale = Vector3(0.6, 0.5, 0.6), name = "HayBale1", modelKey = "HayBale",   modelScale = 1.7 },
        { pos = Vector3(6,  0,  11),  scale = Vector3(0.5, 0.5, 0.5), name = "HayBale2", modelKey = "HayBale",   modelScale = 1.5 },

        -- ====== 饮水池（目标区内，概念图中鸭圈里有水槽）======
        { pos = Vector3(15, 0,  5),   scale = Vector3(0.8, 0.5, 0.5), name = "WaterTrough1", modelKey = "WaterTrough", modelScale = 1.0, modelRotation = Quaternion(90, Vector3.RIGHT) },

        -- ====== 灌木（沿墙边点缀）======
        { pos = Vector3(0.6,0,  4.5), scale = Vector3(0.5, 0.4, 0.5), name = "Bush1",   modelKey = "Bush",        modelScale = 2.0, noCollision = true },
        { pos = Vector3(11, 0,  11.5),scale = Vector3(0.5, 0.4, 0.5), name = "Bush2",   modelKey = "Bush",        modelScale = 2.0, noCollision = true },
        { pos = Vector3(17.2,0, 6),   scale = Vector3(0.5, 0.4, 0.5), name = "Bush3",   modelKey = "Bush",        modelScale = 2.0, noCollision = true },
        { pos = Vector3(17.2,0, 3),   scale = Vector3(0.5, 0.4, 0.5), name = "Bush4",   modelKey = "Bush",        modelScale = 1.8, noCollision = true },
        { pos = Vector3(0.6,0,  10.5),scale = Vector3(0.5, 0.4, 0.5), name = "Bush5",   modelKey = "Bush",        modelScale = 1.8, noCollision = true },

        -- ====== 大叶菜 ======
        { pos = Vector3(4.5,0,  7.5), scale = Vector3(0.4, 0.3, 0.4), name = "LargeLeaf1", modelKey = "LargeLeaf", modelScale = 0.7, noCollision = true },
        { pos = Vector3(14, 0,  11),  scale = Vector3(0.4, 0.3, 0.4), name = "LargeLeaf2", modelKey = "LargeLeaf", modelScale = 0.7, noCollision = true },

        -- ====== 小花 ======
        { pos = Vector3(3,  0,  5.5), scale = Vector3(0.2, 0.2, 0.2), name = "Flower1", modelKey = "SmallFlower", modelScale = 0.7, noCollision = true },
        { pos = Vector3(15, 0,  2),   scale = Vector3(0.2, 0.2, 0.2), name = "Flower2", modelKey = "SmallFlower", modelScale = 0.7, noCollision = true },
        { pos = Vector3(7,  0,  10),  scale = Vector3(0.2, 0.2, 0.2), name = "Flower3", modelKey = "SmallFlower", modelScale = 0.6, noCollision = true },

        -- ====== 小草（贴墙边角落）======
        { pos = Vector3(5,  0,  0.5), scale = Vector3(0.2, 0.15, 0.2), name = "Grass1", modelKey = "SmallGrass",  modelScale = 0.6, noCollision = true },
        { pos = Vector3(12, 0,  0.5), scale = Vector3(0.2, 0.15, 0.2), name = "Grass2", modelKey = "SmallGrass",  modelScale = 0.6, noCollision = true },
        { pos = Vector3(17.2,0, 9),   scale = Vector3(0.2, 0.15, 0.2), name = "Grass3", modelKey = "SmallGrass",  modelScale = 0.5, noCollision = true },
        { pos = Vector3(2,  0,  8),   scale = Vector3(0.2, 0.15, 0.2), name = "Grass4", modelKey = "SmallGrass",  modelScale = 0.6, noCollision = true },
    },

    -- 面包屑道具位置
    BreadcrumbPos = Vector3(4, 0.3, 1),
}

-- ============================================================================
-- 第一关最小协作/道具系统
-- ============================================================================
GameConfig.Ping = {
    Duration = 3.0,
    ForwardOffset = 1.5,
    Types = {
        go    = { label = "去这里", color = Color(0.2, 0.75, 1.0, 1.0) },
        block = { label = "堵这里", color = Color(1.0, 0.45, 0.15, 1.0) },
        help  = { label = "帮我",   color = Color(1.0, 0.25, 0.25, 1.0) },
        watch = { label = "看守",   color = Color(0.35, 1.0, 0.45, 1.0) },
    },
}

GameConfig.Bread = {
    PickupRadius = 1.4,
    UseOffset = 1.0,
    AttractRadius = 6.0,
    AttractWeight = 4.0,
    ActiveTime = 8.0,
    RespawnTime = 12.0,
    EatSlowRadius = 0.65,
}

-- ============================================================================
-- 相机参数（固定等距俯瞰，Overcooked 风格）
-- ============================================================================
GameConfig.Camera = {
    TargetPos = Vector3(9, 0, 5.5),  -- 看向地图中心（略偏南，露出前方道路）
    Distance  = 17,                  -- 距中心距离 (m) — 农场填满画面，外围可见边缘
    Yaw       = 0,                   -- 水平旋转角 (度, 0=围栏与屏幕平行)
    Pitch     = -55,                 -- 垂直俯角 (度, 负=向下)
    Fov       = 42,                  -- 视野角度（略宽于40，确保底部两角可见）
    NearClip  = 0.5,
    FarClip   = 200.0,
}

-- ============================================================================
-- 3D 模型引用（导入的 GLB 模型）
-- ============================================================================
GameConfig.Models = {
    -- 树木（碰撞仅按树干，canopy 不阻挡）
    TreeMedium  = { model = "Meshes/tree_medium.mdl", material = "Materials/tree_medium_00_tripo_material_31688310-3e73-4a2f-9df1-1c8d3576cf33.xml", footprintRadius = 0.08 },
    TreeSmall   = { model = "Meshes/tree_small.mdl", material = "Materials/tree_small_00_tripo_material_64281c72-0987-4d3c-a18c-25c5cd3c8ca1.xml", footprintRadius = 0.08 },
    TreeTall    = { model = "Meshes/tree_tall.mdl", material = "Materials/tree_tall_00_tripo_material_f1a86222-ec87-4085-9bd0-6404b9a209cc.xml", footprintRadius = 0.08 },
    -- 道具
    -- footprintRadius: 模型自然 XZ 碰撞半径（米），实际碰撞 = footprintRadius × modelScale
    Crate       = { model = "Meshes/crate.mdl", material = "Materials/crate_00_tripo_material_36212d2c-ff1e-421d-9117-891f0fa2ae34.xml", footprintRadius = 0.51 },
    Barrel      = { model = "Meshes/barrel.mdl", material = "Materials/barrel_00_tripo_material_17731955-aff0-49b4-a68c-d63e65303142.xml", footprintRadius = 0.24 },
    -- 岩石
    RockLarge   = { model = "Meshes/rock_large.mdl", material = "Materials/rock_large_00_tripo_material_e7c017da-f3e3-4b0d-bae1-7765256a0c6d.xml", footprintRadius = 0.30 },
    RockCluster = { model = "Meshes/rock_cluster.mdl", material = "Materials/rock_cluster_00_tripo_material_a35f769e-97bb-4bf7-a898-415df063e99a.xml", footprintRadius = 0.25 },
    RockFlat    = { model = "Meshes/rock_flat.mdl", material = "Materials/rock_flat_00_tripo_material_adc8b6d6-7fa9-4ea1-b26d-3d4704ad3551.xml", footprintRadius = 0.30 },
    -- 建筑 & 设施
    Cabin       = { model = "Meshes/cabin.mdl", material = "Materials/cabin_00_tripo_material_4a4dd059-0cd7-45b5-aee5-3807b58fdb89.xml", footprintRadius = 1.13 },
    HayBale     = { model = "Meshes/HayBale.mdl", material = "Materials/HayBale_00_tripo_material_ec43415f-599b-4a88-8d96-75d9734c38de.xml", footprintRadius = 0.18 },
    WaterTrough = { model = "Meshes/water_trough.mdl", material = "Materials/water_trough_00_tripo_material_f602d9cf-acef-4af7-984e-2bb984d9dee9.xml", footprintRadius = 0.31 },
    Fence       = { model = "Meshes/fence_new.mdl", material = "Materials/fence_new_00_tripo_material_537a4ce7-641d-48c6-8a67-67fb81f47cd1.xml" },
    Wall        = { model = "Meshes/wall.mdl", material = "Materials/wall_00_model.xml" },
    -- 杂草植被（noCollision，无需 footprintRadius）
    Bush        = { model = "Meshes/bush.mdl", material = "Materials/bush_00_tripo_material_c57b7664-9b41-48e3-91d2-1d1a1321ba8f.xml" },
    LargeLeaf   = { model = "Meshes/large_leaf.mdl", material = "Materials/large_leaf_00_tripo_material_164bb92b-9b4a-41c7-8a1b-75b0522d64c6.xml" },
    SmallFlower = { model = "Meshes/small_flower.mdl", material = "Materials/small_flower_00_tripo_material_13663123-70fe-4d53-a463-1efe364261a8.xml" },
    SmallGrass  = { model = "Meshes/small_grass.mdl", material = "Materials/small_grass_00_tripo_material_142eb6f4-f255-4094-90b1-c923b58f93c3.xml" },
}

-- ============================================================================
-- 场景颜色
-- ============================================================================
GameConfig.Colors = {
    Ground       = Color(0.35, 0.65, 0.2,  1.0),  -- 草绿色地面
    TargetGround = Color(0.85, 0.78, 0.5,  1.0),  -- 浅黄色目标区地面
    Fence        = Color(0.55, 0.35, 0.15, 1.0),  -- 棕色围栏
    Wall         = Color(0.45, 0.38, 0.2,  1.0),  -- 边界围墙
    Rock         = Color(0.5,  0.48, 0.45, 1.0),  -- 岩石灰
    Wood         = Color(0.6,  0.4,  0.2,  1.0),  -- 木质棕
    Cabin        = Color(0.55, 0.35, 0.18, 1.0),  -- 木屋棕
    Breadcrumb   = Color(0.95, 0.85, 0.3,  1.0),  -- 面包屑金黄
}

-- ============================================================================
-- 农场外围环境
-- ============================================================================
GameConfig.Exterior = {
    -- 外围地面总尺寸（比农场大很多，覆盖相机可见范围）
    GroundWidth  = 50,  -- X (m)
    GroundHeight = 40,  -- Z (m)
    GroundColor  = Color(0.30, 0.60, 0.18, 1.0),  -- 稍深的绿色，与农场内区分

    -- 土路（农场正门前方，沿 Z 轴向下延伸）
    Roads = {
        -- 主路：从农场底边中央向南延伸
        {
            center = Vector3(9, 0.02, -4),
            size   = Vector3(3.5, 0.02, 10),
            color  = Color(0.62, 0.52, 0.35, 1.0),  -- 泥土路颜色
        },
        -- 小岔路：向左拐
        {
            center = Vector3(3, 0.02, -8.5),
            size   = Vector3(9, 0.02, 2.5),
            color  = Color(0.62, 0.52, 0.35, 1.0),
        },
    },

    -- 外围装饰（树木、灌木、岩石等，坐标都在围墙外面）
    -- 每个装饰都有唯一 name，与 Obstacles 格式对齐以便 MapEditor 统一编辑
    Decorations = {
        -- ====== 大树（围墙外围散布）======
        { pos = Vector3(-3,   0, 10),   modelKey = "TreeTall",    modelScale = 3.8, name = "Ext_TreeTall_1",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(-2.5, 0, 4),    modelKey = "TreeMedium",  modelScale = 2.8, name = "Ext_TreeMedium_1",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(-3,   0, -2),   modelKey = "TreeTall",    modelScale = 3.5, name = "Ext_TreeTall_2",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(4,    0, -5),   modelKey = "TreeMedium",  modelScale = 2.5, name = "Ext_TreeMedium_2",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(14,   0, -4),   modelKey = "TreeSmall",   modelScale = 2.2, name = "Ext_TreeSmall_1",   scale = Vector3(2, 2, 2) },
        { pos = Vector3(21,   0, -2),   modelKey = "TreeTall",    modelScale = 3.6, name = "Ext_TreeTall_3",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(22,   0, 5),    modelKey = "TreeMedium",  modelScale = 2.8, name = "Ext_TreeMedium_3",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(21.5, 0, 10),   modelKey = "TreeTall",    modelScale = 3.2, name = "Ext_TreeTall_4",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(22,   0, 14),   modelKey = "TreeMedium",  modelScale = 2.5, name = "Ext_TreeMedium_4",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(14,   0, 15),   modelKey = "TreeTall",    modelScale = 3.0, name = "Ext_TreeTall_5",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(5,    0, 15.5), modelKey = "TreeMedium",  modelScale = 2.6, name = "Ext_TreeMedium_5",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(-2,   0, 14),   modelKey = "TreeSmall",   modelScale = 2.4, name = "Ext_TreeSmall_2",   scale = Vector3(2, 2, 2) },

        -- ====== 远处更多树（填充更远的背景）======
        { pos = Vector3(-6,   0, 7),    modelKey = "TreeTall",    modelScale = 4.0, name = "Ext_TreeTall_6",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(-5,   0, 0),    modelKey = "TreeMedium",  modelScale = 3.0, name = "Ext_TreeMedium_6",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(0,    0, -6),   modelKey = "TreeTall",    modelScale = 3.5, name = "Ext_TreeTall_7",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(9,    0, -8),   modelKey = "TreeSmall",   modelScale = 2.0, name = "Ext_TreeSmall_3",   scale = Vector3(2, 2, 2) },
        { pos = Vector3(20,   0, -6),   modelKey = "TreeTall",    modelScale = 3.8, name = "Ext_TreeTall_8",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(24,   0, 8),    modelKey = "TreeMedium",  modelScale = 3.2, name = "Ext_TreeMedium_7",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(24,   0, 0),    modelKey = "TreeSmall",   modelScale = 2.6, name = "Ext_TreeSmall_4",   scale = Vector3(2, 2, 2) },
        { pos = Vector3(10,   0, 17),   modelKey = "TreeTall",    modelScale = 3.4, name = "Ext_TreeTall_9",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(-4,   0, 17),   modelKey = "TreeMedium",  modelScale = 2.8, name = "Ext_TreeMedium_8",  scale = Vector3(2, 2, 2) },

        -- ====== 灌木（路边和围墙外点缀）======
        { pos = Vector3(-1,   0, 6),    modelKey = "Bush",        modelScale = 2.2, name = "Ext_Bush_1",        scale = Vector3(2, 2, 2) },
        { pos = Vector3(-1.5, 0, 12),   modelKey = "Bush",        modelScale = 1.8, name = "Ext_Bush_2",        scale = Vector3(2, 2, 2) },
        { pos = Vector3(19.5, 0, 2),    modelKey = "Bush",        modelScale = 2.0, name = "Ext_Bush_3",        scale = Vector3(2, 2, 2) },
        { pos = Vector3(19.5, 0, 8),    modelKey = "Bush",        modelScale = 1.6, name = "Ext_Bush_4",        scale = Vector3(2, 2, 2) },
        { pos = Vector3(6,    0, -2.5), modelKey = "Bush",        modelScale = 1.8, name = "Ext_Bush_5",        scale = Vector3(2, 2, 2) },
        { pos = Vector3(12,   0, -2),   modelKey = "Bush",        modelScale = 2.0, name = "Ext_Bush_6",        scale = Vector3(2, 2, 2) },
        { pos = Vector3(7,    0, 14),   modelKey = "Bush",        modelScale = 1.6, name = "Ext_Bush_7",        scale = Vector3(2, 2, 2) },
        { pos = Vector3(19,   0, 13),   modelKey = "Bush",        modelScale = 2.0, name = "Ext_Bush_8",        scale = Vector3(2, 2, 2) },

        -- ====== 岩石（道路旁和外围散布）======
        { pos = Vector3(6,    0, -4),   modelKey = "RockFlat",    modelScale = 0.8, name = "Ext_RockFlat_1",    scale = Vector3(2, 2, 2) },
        { pos = Vector3(12,   0, -5),   modelKey = "RockCluster", modelScale = 0.6, name = "Ext_RockCluster_1", scale = Vector3(2, 2, 2) },
        { pos = Vector3(-1,   0, 1),    modelKey = "RockLarge",   modelScale = 0.7, name = "Ext_RockLarge_1",   scale = Vector3(2, 2, 2) },
        { pos = Vector3(20,   0, 12),   modelKey = "RockFlat",    modelScale = 0.9, name = "Ext_RockFlat_2",    scale = Vector3(2, 2, 2) },

        -- ====== 小草小花（地面自然点缀）======
        { pos = Vector3(2,    0, -3),   modelKey = "SmallGrass",  modelScale = 0.7, name = "Ext_SmallGrass_1",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(16,   0, -3),   modelKey = "SmallFlower", modelScale = 0.8, name = "Ext_SmallFlower_1", scale = Vector3(2, 2, 2) },
        { pos = Vector3(-1,   0, 8),    modelKey = "SmallGrass",  modelScale = 0.6, name = "Ext_SmallGrass_2",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(20,   0, 6),    modelKey = "SmallFlower", modelScale = 0.7, name = "Ext_SmallFlower_2", scale = Vector3(2, 2, 2) },
        { pos = Vector3(8,    0, 14.5), modelKey = "SmallGrass",  modelScale = 0.6, name = "Ext_SmallGrass_3",  scale = Vector3(2, 2, 2) },
        { pos = Vector3(19,   0, 0),    modelKey = "SmallFlower", modelScale = 0.7, name = "Ext_SmallFlower_3", scale = Vector3(2, 2, 2) },
    },
}

-- ============================================================================
-- 网络/远程事件
-- ============================================================================
GameConfig.EVENTS = {
    CLIENT_READY   = "E_ClientReady",
    ASSIGN_ROLE    = "E_AssignRole",
    PLAYER_CLAP    = "E_PlayerClap",
    PLAYER_PING    = "E_PlayerPing",
    PING_BROADCAST = "E_PingBroadcast",
    BREAD_USE      = "E_BreadUse",
    BREAD_STATE    = "E_BreadState",
    DUCK_SETTLED   = "E_DuckSettled",
    DUCK_ESCAPED   = "E_DuckEscaped",
    COMBO_AWARD    = "E_ComboAward",   -- 连击奖励：携带连击数、倍率、本次净金币奖励
    GAME_RESULT    = "E_GameResult",
    -- 地图编辑器同步事件（客户端 → 服务端）
    MAP_EDIT_OBS     = "E_MapEditObs",      -- 障碍物增删移缩
    MAP_EDIT_TERRAIN = "E_MapEditTerrain",  -- 地形网格同步
    MAP_EDIT_STRUCT  = "E_MapEditStruct",   -- 结构物（围栏/围墙段）增删
}

-- ============================================================================
-- 控制位 (controls.buttons bitmask)
-- ============================================================================
GameConfig.CTRL = {
    FORWARD  = 1,
    BACK     = 2,
    LEFT     = 4,
    RIGHT    = 8,
    SPRINT   = 16,
    CLAP     = 32,
}

-- ============================================================================
-- 网络节点变量键
-- ============================================================================
GameConfig.VARS = {
    IS_ROLE     = StringHash("IsRole"),
    ROLE_INDEX  = StringHash("RoleIndex"),
    CONNECTED   = StringHash("Connected"),   -- 该槽位是否有真实玩家连接
    IS_DUCK     = StringHash("IsDuck"),
    DUCK_STATE  = StringHash("DuckState"),   -- "idle" / "alert" / "panic" / "settled" / "crying"
    DUCK_TYPE   = StringHash("DuckType"),    -- "normal" / "leader" / "stubborn" / "mom" / "duckling"
}

-- ============================================================================
-- 工具函数：从 DuckRoster 计算总鸭数（含展开的小鸭仔）
-- 客户端用于初始化 totalDucks_，服务端用于校验
-- ============================================================================
function GameConfig.CountDucks(roster)
    local n = 0
    for _, entry in ipairs(roster or {}) do
        n = n + 1
        if entry.type == "mom" and entry.ducklings then
            n = n + #entry.ducklings
        end
    end
    return n
end

-- ============================================================================
-- 游戏状态
-- ============================================================================
GameConfig.GameState = {
    PLAYING   = "playing",
    COMPLETE  = "complete",
}

-- ============================================================================
-- 网络配置
-- ============================================================================
GameConfig.Network = {
    MaxPlayers = 4,
}

-- ============================================================================
-- 输入配置
-- ============================================================================
GameConfig.Input = {
    MouseSensitivity = 0.1,
}

return GameConfig
