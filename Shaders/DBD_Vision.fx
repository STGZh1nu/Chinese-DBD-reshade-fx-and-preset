/*==============================================================================

    DBD_Vision.fx   ·   Dead by Daylight Vision
    去雾 + 三色独立增强 + 高光治理

    ────────────────────────────────────────────────────────────────
      作者    屠皇快雪 / Snow the Great
      版本    v1.0
      许可    MIT（详见同目录 LICENSE）
      仓库    https://github.com/STGZh1nu/Chinese-DBD-reshade-fx-and-preset
    ────────────────────────────────────────────────────────────────

    这是一个 ReShade 后期处理着色器，给《黎明杀机》这类
    「远处发糊 + 部分地图过亮偏色」的画面做色彩与亮度治理。

    它不读取游戏内存、不修改游戏文件、不提供透视或判定信息，
    只对最终呈现的画面做后处理。

    ── 三个 technique ──────────────────────────────────────────────
      1. DBD 去雾       —— 压掉距离雾造成的发白/灰蒙
      2. DBD 三色槽     —— 三个颜色独立增强/削弱
      3. DBD 完整       —— 高光治理 + 去雾 + 三色 + 锐化（推荐）

    ── 安装 ────────────────────────────────────────────────────────
      着色器：<游戏目录>\reshade-shaders\Shaders\DBD_Vision.fx
      预设：  <游戏目录>\  （与游戏 exe 同级）
      改完 .fx 必须重启游戏，ReShade 才会重新编译

    ── 按地图调参速查 ──────────────────────────────────────────────
      过亮地图（如乌鸦巢穴）
        · 高光压缩 0.3 → 0.6
        · 曝光补偿 -0.15 ~ -0.3

      偏色地图（如多巴着陆点）
        · 槽 3 选紫，强度给负数
        · 全局饱和度不动，让色槽精准打击

      想看青色划痕
        · 槽 2 选青 RGB(1,255,252)，强度 +0.5 ~ +1.0

    ── 设计取舍（写给后来的维护者） ────────────────────────────────
      · 过饱和刺眼时优先压高光，不要先降饱和——降饱和会把画面压灰
      · 色槽强度可正可负，同一个 .fx 靠预设翻转符号就能适配不同地图
      · 色槽容差 0.02 = 精准，0.25 = 会连邻近色一起抓
      · ReShade 退出时会把面板状态写回当前预设，调好记得另存

==============================================================================*/

#include "ReShade.fxh"

//------------------------------------------------------------------------------
// 基础函数
//------------------------------------------------------------------------------

float3 RGBtoHSV(float3 c)
{
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float  d = q.x - min(q.w, q.y);
    float  e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

float3 HSVtoRGB(float3 c)
{
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

float Luma(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

//------------------------------------------------------------------------------
// 全局参数
//------------------------------------------------------------------------------

uniform float fExposure <
    ui_type = "slider"; ui_min = -4.0; ui_max = 4.0;
    ui_label = "曝光补偿";
    ui_tooltip = "单位 EV。乌鸦巢穴这种过亮图先给 -0.2 试试。";
> = 0.0;

uniform float fHighlightCompress <
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0;
    ui_label = "高光压缩";
    ui_tooltip = "把过亮区域压回可看范围，保留色相不洗白。过曝地图 0.4~0.6，普通图 0.2 就够。";
> = 0.30;

uniform float fShadowLift <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0;
    ui_label = "暗部提亮";
    ui_tooltip = "压完高光后暗部容易发死，这里捞回来一点。0.05~0.12 比较自然。";
> = 0.05;

uniform float fContrast <
    ui_type = "slider"; ui_min = 0.3; ui_max = 2.5;
    ui_label = "对比度";
> = 1.04;

uniform float fGlobalSaturation <
    ui_type = "slider"; ui_min = 0.0; ui_max = 3.0;
    ui_label = "全局饱和度";
    ui_tooltip = "总闸。颜色整体太重（多巴的紫粉）就先收到 0.85~0.9，再用槽3 精准补刀。";
> = 1.00;

uniform float fNeonTame <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.5;
    ui_label = "霓虹压制";
    ui_tooltip = "只削极高饱和度的像素（霓虹灯、荧光招牌），普通物体不动。赛博朋克地图专用。";
> = 0.00;

uniform float fNeonThreshold <
    ui_type = "slider"; ui_min = 0.05; ui_max = 1.0;
    ui_label = "霓虹阈值";
    ui_tooltip = "饱和度超过这个值开始压制。0.58~0.65 比较准，太低会削到正常鲜艳物体。";
> = 0.62;

//------------------------------------------------------------------------------
// 去雾参数
//------------------------------------------------------------------------------

uniform float fDehazeStrength <
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0;
    ui_label = "去雾强度";
    ui_tooltip = "0 = 关闭。DBD 建议 0.45~0.75。";
> = 0.55;

uniform float fAtmosLight <
    ui_type = "slider"; ui_min = 0.1; ui_max = 1.0;
    ui_label = "大气光阈值";
    ui_tooltip = "雾的颜色基准。雾偏白就 0.82~0.88，偏灰就再调低。";
> = 0.84;

uniform float fFogOnly <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0;
    ui_label = "只处理雾区";
    ui_tooltip = "1 = 只动低饱和发灰区域，彩色物体不受影响（推荐）。";
> = 1.0;

uniform float fDehazeRadius <
    ui_type = "slider"; ui_min = 1.0; ui_max = 24.0;
    ui_label = "取样半径";
> = 4.0;

//------------------------------------------------------------------------------
// 颜色槽 1（默认：血迹 / 红光）
//------------------------------------------------------------------------------

uniform float3 cSlot1Color <
    ui_type = "color";
    ui_label = "槽1 颜色";
    ui_tooltip = "默认是血红色。";
> = float3(1.0, 0.18, 0.18);

uniform float fSlot1Tol <
    ui_type = "slider"; ui_min = 0.005; ui_max = 1.0;
    ui_label = "槽1 容差";
    ui_tooltip = "0.10 精准，0.25 会连橙色一起抓。";
> = 0.12;

uniform float fSlot1Str <
    ui_type = "slider"; ui_min = -3.0; ui_max = 4.0;
    ui_label = "槽1 强度";
    ui_tooltip = "正 = 凸显（加饱和+提亮），负 = 削弱（去色+压暗），0 = 关。";
> = 0.60;

uniform float fSlot1Weight <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0;
    ui_label = "槽1 权重";
    ui_tooltip = "这个槽最多能影响到什么程度，1 = 全效。";
> = 1.0;

//------------------------------------------------------------------------------
// 颜色槽 2（默认：蓝色划痕 / 气场）
//------------------------------------------------------------------------------

uniform float3 cSlot2Color <
    ui_type = "color";
    ui_label = "槽2 颜色";
    ui_tooltip = "默认是冷蓝色。想要青绿就往上挪。";
> = float3(0.30, 0.60, 1.00);

uniform float fSlot2Tol <
    ui_type = "slider"; ui_min = 0.005; ui_max = 1.0;
    ui_label = "槽2 容差";
> = 0.14;

uniform float fSlot2Str <
    ui_type = "slider"; ui_min = -3.0; ui_max = 4.0;
    ui_label = "槽2 强度";
> = 0.50;

uniform float fSlot2Weight <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0;
    ui_label = "槽2 权重";
> = 1.0;

//------------------------------------------------------------------------------
// 颜色槽 3（默认：紫色，用于压制多巴的紫粉）
//------------------------------------------------------------------------------

uniform float3 cSlot3Color <
    ui_type = "color";
    ui_label = "槽3 颜色";
    ui_tooltip = "默认紫色。多巴着陆点把它强度设为 -0.6 就能压下去。";
> = float3(0.70, 0.35, 0.90);

uniform float fSlot3Tol <
    ui_type = "slider"; ui_min = 0.005; ui_max = 1.0;
    ui_label = "槽3 容差";
> = 0.15;

uniform float fSlot3Str <
    ui_type = "slider"; ui_min = -3.0; ui_max = 4.0;
    ui_label = "槽3 强度";
    ui_tooltip = "默认 0（不干预）。多巴给 -0.6；想凸显紫色再给正数。";
> = 0.0;

uniform float fSlot3Weight <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0;
    ui_label = "槽3 权重";
> = 1.0;

//------------------------------------------------------------------------------
// 颜色槽公共
//------------------------------------------------------------------------------

uniform float fMinSat <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0;
    ui_label = "最低饱和度";
    ui_tooltip = "低于此值不参与（保护灰白墙、天空）。三个槽共用。";
> = 0.10;

uniform float fDimOthers <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0;
    ui_label = "压暗未命中颜色";
    ui_tooltip = "0 = 不动。0.3 = 命中色跳出来，其余退后。";
> = 0.0;

//------------------------------------------------------------------------------
// 锐化
//------------------------------------------------------------------------------

uniform float fSharpness <
    ui_type = "slider"; ui_min = 0.0; ui_max = 4.0;
    ui_label = "锐化强度";
> = 0.40;

//------------------------------------------------------------------------------
// 高光滚降：在亮度空间压缩，色相不跑偏
//------------------------------------------------------------------------------

float3 CompressHighlights(float3 col, float amount)
{
    if (amount < 0.001)
        return col;

    float l = Luma(col);
    float knee = 0.72;                    // 拐点以下不动
    if (l <= knee)
        return col;

    float ex = l - knee;
    // 软肩：超出部分被逐级压缩，上限趋近 knee + 1/(4*amount)
    float compressed = knee + ex / (1.0 + amount * ex * 3.5);

    return col * (compressed / max(l, 1.0e-5));
}

//------------------------------------------------------------------------------
// 暗部提升
//------------------------------------------------------------------------------

float3 LiftShadows(float3 col, float amount)
{
    if (amount < 0.001)
        return col;
    // 只在暗部生效，亮部不受影响
    float3 lifted = col + amount * (1.0 - col) * (1.0 - saturate(Luma(col) * 2.2));
    return lerp(col, lifted, 1.0);
}

//------------------------------------------------------------------------------
// 霓虹压制：只对饱和度极高的像素降饱和，正常物体不受影响
//------------------------------------------------------------------------------

float3 TameNeon(float3 col)
{
    if (fNeonTame < 0.001)
        return col;

    float3 hsv = RGBtoHSV(col);

    // 超过阈值的部分才开始削，smoothstep 保证过渡平滑
    float excess = smoothstep(fNeonThreshold, 1.0, hsv.y);
    if (excess < 0.001)
        return col;

    hsv.y *= (1.0 - excess * fNeonTame);
    // 顺带压一点点亮度，减少"发光刺眼"感
    hsv.z *= (1.0 - excess * fNeonTame * 0.15);

    return HSVtoRGB(hsv);
}

//------------------------------------------------------------------------------
// 去雾
//------------------------------------------------------------------------------

float3 ApplyDehaze(float3 col, float2 uv)
{
    float2 px = ReShade::PixelSize * fDehazeRadius;

    float dark = 1.0;
    float3 s;
    s = tex2D(ReShade::BackBuffer, uv + float2( px.x, 0)).rgb;
    dark = min(dark, min(s.r, min(s.g, s.b)));
    s = tex2D(ReShade::BackBuffer, uv + float2(-px.x, 0)).rgb;
    dark = min(dark, min(s.r, min(s.g, s.b)));
    s = tex2D(ReShade::BackBuffer, uv + float2(0,  px.y)).rgb;
    dark = min(dark, min(s.r, min(s.g, s.b)));
    s = tex2D(ReShade::BackBuffer, uv + float2(0, -px.y)).rgb;
    dark = min(dark, min(s.r, min(s.g, s.b)));

    float t = saturate(1.0 - dark / max(fAtmosLight, 0.001));
    float3 J = (col - fAtmosLight) / max(t, 0.18) + fAtmosLight;

    float3 hsv = RGBtoHSV(col);
    float fogMask = (1.0 - smoothstep(0.04, 0.22, hsv.y)) * smoothstep(0.30, 0.62, hsv.z);
    fogMask = lerp(1.0, fogMask, saturate(fFogOnly));

    return lerp(col, J, fDehazeStrength * fogMask);
}

//------------------------------------------------------------------------------
// 单个颜色槽处理
//------------------------------------------------------------------------------

float3 ApplySlot(float3 col, float3 pickColor, float tol, float str, float weight,
                 out float hitMask)
{
    hitMask = 0.0;
    if (abs(str) < 0.001 || weight <= 0.001)
        return col;

    float3 hsv = RGBtoHSV(col);
    float3 sel = RGBtoHSV(pickColor);

    float dh = abs(hsv.x - sel.x);
    dh = min(dh, 1.0 - dh);

    float w = 1.0 - smoothstep(tol * 0.45, tol, dh);
    w *= smoothstep(max(fMinSat * 0.6, 0.001), max(fMinSat, 0.002), hsv.y);
    w *= smoothstep(0.02, 0.10, hsv.z);
    w = saturate(w * weight);

    hitMask = w;

    if (w < 0.001)
        return col;

    float3 t = col;
    if (str >= 0.0)
    {
        hsv.y = saturate(hsv.y * (1.0 + str * 1.2));
        hsv.z = saturate(hsv.z * (1.0 + str * 0.15));
        t = HSVtoRGB(hsv);
    }
    else
    {
        float k = -str;
        hsv.y = saturate(hsv.y * (1.0 - k));
        hsv.z = saturate(hsv.z * (1.0 - k * 0.35));
        t = HSVtoRGB(hsv);
    }

    return lerp(col, t, w);
}

//------------------------------------------------------------------------------
// 三槽串联
//------------------------------------------------------------------------------

float3 ApplyAllSlots(float3 col)
{
    float m1, m2, m3;
    float3 c = col;

    c = ApplySlot(c, cSlot1Color, fSlot1Tol, fSlot1Str, fSlot1Weight, m1);
    c = ApplySlot(c, cSlot2Color, fSlot2Tol, fSlot2Str, fSlot2Weight, m2);
    c = ApplySlot(c, cSlot3Color, fSlot3Tol, fSlot3Str, fSlot3Weight, m3);

    if (fDimOthers > 0.001)
    {
        float hit = saturate(max(max(m1, m2), m3));
        c *= 1.0 - fDimOthers * (1.0 - hit);
    }

    return c;
}

//------------------------------------------------------------------------------
// 锐化
//------------------------------------------------------------------------------

float3 ApplySharpen(float2 uv)
{
    if (fSharpness < 0.001)
        return tex2D(ReShade::BackBuffer, uv).rgb;

    float2 px = ReShade::PixelSize;

    float3 c = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 n = tex2D(ReShade::BackBuffer, uv - float2(0.0, px.y)).rgb;
    float3 s = tex2D(ReShade::BackBuffer, uv + float2(0.0, px.y)).rgb;
    float3 w = tex2D(ReShade::BackBuffer, uv - float2(px.x, 0.0)).rgb;
    float3 e = tex2D(ReShade::BackBuffer, uv + float2(px.x, 0.0)).rgb;

    float3 blur = (n + s + w + e) * 0.25;
    float3 diff = c - blur;
    float edge = saturate(dot(abs(diff), float3(0.333, 0.333, 0.333)) * 4.0);

    return c + diff * fSharpness * lerp(0.35, 1.0, edge);
}

//------------------------------------------------------------------------------
// 像素着色器
//------------------------------------------------------------------------------

float3 PS_DehazeOnly(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 col = tex2D(ReShade::BackBuffer, uv).rgb;
    return saturate(ApplyDehaze(col, uv));
}

float3 PS_SlotsOnly(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 col = tex2D(ReShade::BackBuffer, uv).rgb;
    return saturate(ApplyAllSlots(col));
}

float3 PS_Full(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 col = ApplySharpen(uv);
    col = ApplyDehaze(col, uv);

    // 曝光
    col *= exp2(fExposure);

    // 高光滚降 + 暗部捞回
    col = CompressHighlights(col, fHighlightCompress);
    col = LiftShadows(col, fShadowLift);

    // 对比度
    col = (col - 0.5) * fContrast + 0.5;

    // 全局饱和度：治"整张图偏色太重"，再交给三色槽精准处理
    if (abs(fGlobalSaturation - 1.0) > 0.001)
    {
        float gl = Luma(col);
        col = lerp(float3(gl, gl, gl), col, fGlobalSaturation);
    }

    // 霓虹压制：只削极端饱和像素（赛博朋克/霓虹地图）
    col = TameNeon(col);

    // 三色槽
    col = ApplyAllSlots(col);

    return saturate(col);
}

//------------------------------------------------------------------------------
// technique
//------------------------------------------------------------------------------

technique DBD_Dehaze <
    ui_label = "DBD 去雾";
    ui_tooltip = "只压距离雾，不动颜色。 · 屠皇快雪";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_DehazeOnly; }
}

technique DBD_ColorSlots <
    ui_label = "DBD 三色槽";
    ui_tooltip = "三个颜色独立增强/削弱，可同时开。 · 屠皇快雪";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_SlotsOnly; }
}

technique DBD_Full <
    ui_label = "DBD 完整（去雾+三色+高光治理）";
    ui_tooltip = "推荐。所有功能串起来，按地图微调即可。 · 屠皇快雪";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_Full; }
}
