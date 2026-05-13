-- ============================================================================
-- AstroonTheme.lua — Astroon v1.1.0 Cosmic Cartoon UI 主题
-- 基于 Pencil 设计规范 (.pen) 提取的 Design Tokens
-- ============================================================================

local UI = require("urhox-libs/UI")

local AstroonTheme = {}

-- ============================================================================
-- Design Tokens (颜色值，RGBA 0-255)
-- ============================================================================

AstroonTheme.Tokens = {
    -- 背景 / 表面
    background      = { 26,  17,  64,  255 },   -- #1A1140  BG Deep
    backgroundMid   = { 45,  27,  105, 255 },   -- #2D1B69  BG Mid
    surface         = { 42,  31,  94,  255 },   -- #2A1F5E  Base panel fill
    surfaceHover    = { 61,  42,  138, 255 },   -- #3D2A8A  Elevated / hover
    overlay         = { 0,   0,   0,   180 },   -- #000000B4  Modal overlay 70%
    highlight       = { 255, 255, 255, 48 },    -- #FFFFFF30  Highlight wash 19%

    -- 主色 (Gold)
    primary         = { 255, 213, 79,  255 },   -- #FFD54F
    primaryHover    = { 255, 224, 102, 255 },   -- #FFE066
    primaryPressed  = { 240, 160, 48,  255 },   -- #F0A030

    -- 次色 (Blue)
    secondary       = { 74,  139, 245, 255 },   -- #4A8BF5
    secondaryHover  = { 91,  156, 246, 255 },   -- #5B9CF6
    secondaryPressed= { 51,  102, 204, 255 },   -- #3366CC

    -- 强调色 (Cyan)
    accent          = { 61,  214, 232, 255 },   -- #3DD6E8

    -- 文本
    text            = { 255, 255, 255, 255 },   -- #FFFFFF
    textSecondary   = { 255, 255, 255, 170 },   -- #FFFFFFAA  67%
    textMuted       = { 255, 255, 255, 85 },    -- #FFFFFF55  33%
    textDisabled    = { 255, 255, 255, 64 },    -- #FFFFFF40  25%

    -- 边框
    border          = { 255, 255, 255, 24 },    -- #FFFFFF18  9%
    borderFocus     = { 74,  139, 245, 255 },   -- #4A8BF5

    -- 禁用
    disabled        = { 61,  42,  138, 255 },   -- #3D2A8A
    disabledText    = { 255, 255, 255, 85 },    -- #FFFFFF55

    -- 状态色
    success         = { 46,  204, 113, 255 },   -- #2ECC71
    successHover    = { 61,  216, 138, 255 },   -- #3DD88A
    error           = { 255, 71,  87,  255 },   -- #FF4757
    errorHover      = { 255, 107, 122, 255 },   -- #FF6B7A
    warning         = { 255, 217, 61,  255 },   -- #FFD93D
    warningHover    = { 255, 224, 102, 255 },   -- #FFE066
    info            = { 61,  214, 232, 255 },   -- #3DD6E8

    -- HUD
    hudHP           = { 255, 71,  87,  255 },   -- #FF4757  红
    hudMP           = { 74,  139, 245, 255 },   -- #4A8BF5  蓝
    hudStamina      = { 255, 217, 61,  255 },   -- #FFD93D  黄
    hudXP           = { 46,  204, 113, 255 },   -- #2ECC71  绿

    -- 稀有度
    rarityCommon    = { 96,  96,  128, 255 },   -- #606080
    rarityUncommon  = { 46,  204, 113, 255 },   -- #2ECC71
    rarityRare      = { 74,  139, 245, 255 },   -- #4A8BF5
    rarityEpic      = { 168, 85,  247, 255 },   -- #A855F7
    rarityLegendary = { 255, 213, 79,  255 },   -- #FFD54F

    -- 阴影
    shadow          = { 0,   0,   0,   96 },    -- #00000060  38%
}

-- ============================================================================
-- 间距 Tokens
-- ============================================================================

AstroonTheme.Spacing = {
    xs  = 4,
    sm  = 8,
    md  = 12,
    lg  = 16,
    xl  = 24,
    xxl = 32,
}

-- ============================================================================
-- 圆角 Tokens
-- ============================================================================

AstroonTheme.Radius = {
    none = 0,
    sm   = 6,
    md   = 10,
    lg   = 16,
    xl   = 20,
    pill = 9999,
    full = 9999,
}

-- ============================================================================
-- 字体大小 Tokens (px)
-- ============================================================================

AstroonTheme.FontSize = {
    h1        = 28,
    h2        = 22,
    h3        = 18,
    body      = 14,
    bodySmall = 12,
    caption   = 10,
    button    = 18,
}

-- ============================================================================
-- 构建 UI 主题对象（供 UI.Init 使用）
-- ============================================================================

function AstroonTheme.BuildUITheme()
    local T = AstroonTheme.Tokens
    local S = AstroonTheme.Spacing
    local R = AstroonTheme.Radius

    return {
        colors = {
            primary         = T.primary,
            primaryHover    = T.primaryHover,
            primaryPressed  = T.primaryPressed,
            secondary       = T.secondary,
            secondaryHover  = T.secondaryHover,
            secondaryPressed= T.secondaryPressed,
            background      = T.background,
            surface         = T.surface,
            surfaceHover    = T.surfaceHover,
            text            = T.text,
            textSecondary   = T.textSecondary,
            textDisabled    = T.disabledText,
            border          = T.border,
            borderFocus     = T.borderFocus,
            success         = T.success,
            successHover    = T.successHover,
            warning         = T.warning,
            warningHover    = T.warningHover,
            error           = T.error,
            errorHover      = T.errorHover,
            info            = T.info,
            disabled        = T.disabled,
            disabledText    = T.disabledText,
            overlay         = T.overlay,
            transparent     = { 0, 0, 0, 0 },
            hover           = T.highlight,
        },
        spacing = {
            xs  = S.xs,
            sm  = S.sm,
            md  = S.md,
            lg  = S.lg,
            xl  = S.xl,
            xxl = S.xxl,
        },
        radius = {
            none = R.none,
            sm   = R.sm,
            md   = R.md,
            lg   = R.lg,
            xl   = R.xl,
            full = R.full,
        },
        typography = {
            fontFamily = "longzhu",
            h1        = { fontSize = 21 },  -- 28px -> ~21pt
            h2        = { fontSize = 17 },  -- 22px -> ~17pt
            h3        = { fontSize = 14 },  -- 18px -> ~14pt
            body      = { fontSize = 11 },  -- 14px -> ~11pt
            bodySmall = { fontSize = 9 },   -- 12px -> ~9pt
            caption   = { fontSize = 8 },   -- 10px -> ~8pt
        },
        components = {
            Button = {
                height = 48,
                paddingHorizontal = 24,
                fontSize = 14,   -- 18px -> ~14pt
            },
        },
    }
end

-- ============================================================================
-- 初始化 UI（客户端统一入口）
-- ============================================================================

function AstroonTheme.InitUI()
    local theme = AstroonTheme.BuildUITheme()

    UI.Init({
        fonts = {
            { family = "inter", weights = {
                normal = "Fonts/Inter_18pt-Regular.ttf",
                bold   = "Fonts/Inter_18pt-Bold.ttf",
            } },
            { family = "longzhu", weights = {
                normal = "Fonts/LongZhuTi-Regular.ttf",
            } },
        },
        theme = theme,
        scale = UI.Scale.DEFAULT,
    })
end

return AstroonTheme
