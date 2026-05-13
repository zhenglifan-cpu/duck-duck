-- ============================================================================
-- AudioManager.lua — 音频管理器
-- 管理背景音乐和音效播放：拍手声、鸭子嘎嘎叫
-- ============================================================================

local AudioManager = {}

-- ============================================================================
-- 音频路径配置
-- ============================================================================

local MUSIC_PATH = "audio/music_1778480378412.ogg"

local SFX_CLAP = "audio/sfx/clap.ogg"

local SFX_DUCK_QUACKS = {
    "audio/sfx/duck_quack_1.ogg",
    "audio/sfx/duck_quack_2.ogg",
    "audio/sfx/duck_quack_3.ogg",
    "audio/sfx/duck_quack_4.ogg",
    "audio/sfx/duck_quack_5.ogg",
}

-- ============================================================================
-- 内部状态
-- ============================================================================

---@type Node
local musicNode_ = nil
---@type SoundSource
local musicSource_ = nil

---@type Node
local sfxNode_ = nil

-- 音乐播放状态标记（用于循环回退检测）
local musicShouldPlay_ = false

-- 鸭子嘎嘎叫冷却（避免同时太多鸭子一起叫）
local duckQuackCooldown_ = 0
local DUCK_QUACK_MIN_INTERVAL = 0.6  -- 两次嘎嘎叫之间最短间隔

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化音频系统，在场景创建后调用
---@param scene Scene
function AudioManager.Init(scene)
    -- 创建音乐节点
    musicNode_ = scene:CreateChild("BGMusic")
    musicSource_ = musicNode_:CreateComponent("SoundSource")
    musicSource_.soundType = "Music"
    musicSource_.gain = 0.35  -- 背景音乐音量适中

    -- 创建音效节点
    sfxNode_ = scene:CreateChild("SFX")

    -- 设置 SoundListener（挂在场景根节点即可，因为是固定视角游戏）
    local listener = scene:CreateComponent("SoundListener")
    audio:SetListener(listener)

    print("[AudioManager] 音频系统初始化完成")
end

-- ============================================================================
-- 背景音乐
-- ============================================================================

--- 播放背景音乐（循环）
function AudioManager.PlayMusic()
    if not musicSource_ then return end

    local sound = cache:GetResource("Sound", MUSIC_PATH)
    if sound then
        sound.looped = true
        musicSource_:Play(sound)
        musicShouldPlay_ = true
        print("[AudioManager] 开始播放背景音乐 (looped=" .. tostring(sound.looped) .. ")")
    else
        print("[AudioManager] 警告: 找不到背景音乐文件: " .. MUSIC_PATH)
    end
end

--- 停止背景音乐
function AudioManager.StopMusic()
    if musicSource_ then
        musicSource_:Stop()
    end
    musicShouldPlay_ = false
end

--- 设置音乐音量 (0.0 ~ 1.0)
function AudioManager.SetMusicVolume(vol)
    if musicSource_ then
        musicSource_.gain = vol
    end
end

-- ============================================================================
-- 拍手音效
-- ============================================================================

--- 播放拍手音效
function AudioManager.PlayClap()
    if not sfxNode_ then return end

    local sound = cache:GetResource("Sound", SFX_CLAP)
    if not sound then return end

    local source = sfxNode_:CreateComponent("SoundSource")
    source.soundType = "Effect"
    source.gain = 0.7
    source.autoRemoveMode = REMOVE_COMPONENT
    source:Play(sound)
end

-- ============================================================================
-- 鸭子嘎嘎叫
-- ============================================================================

--- 播放随机鸭子嘎嘎叫（带冷却，防止叫声堆叠过多）
---@return boolean 是否成功播放
function AudioManager.PlayDuckQuack()
    if not sfxNode_ then return false end
    if duckQuackCooldown_ > 0 then return false end

    -- 随机选一种嘎嘎叫
    local idx = math.random(1, #SFX_DUCK_QUACKS)
    local sound = cache:GetResource("Sound", SFX_DUCK_QUACKS[idx])
    if not sound then return false end

    local source = sfxNode_:CreateComponent("SoundSource")
    source.soundType = "Effect"
    source.gain = 0.4 + math.random() * 0.2  -- 0.4~0.6 随机音量，增加自然感
    source.autoRemoveMode = REMOVE_COMPONENT
    -- 微调音高，让每次叫声略有不同
    local pitchVariation = 0.9 + math.random() * 0.2  -- 0.9~1.1
    source:Play(sound, sound.frequency * pitchVariation)

    duckQuackCooldown_ = DUCK_QUACK_MIN_INTERVAL
    return true
end

-- ============================================================================
-- 每帧更新（更新冷却计时器）
-- ============================================================================

---@param dt number 帧间隔时间
function AudioManager.Update(dt)
    if duckQuackCooldown_ > 0 then
        duckQuackCooldown_ = duckQuackCooldown_ - dt
    end

    -- 音乐循环回退：如果音乐应播放但已停止（looped 属性对 OGG 流式解码未生效），则重新播放
    if musicShouldPlay_ and musicSource_ and not musicSource_.playing then
        local sound = cache:GetResource("Sound", MUSIC_PATH)
        if sound then
            sound.looped = true
            musicSource_:Play(sound)
            print("[AudioManager] 背景音乐循环重播")
        end
    end
end

return AudioManager
