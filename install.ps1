# DBD Vision 一键安装 / 升级脚本
# 编码：UTF-8 with BOM（PS 5.1 需要 BOM 才能正确读中文）

param([switch]$Silent)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'DBD Vision 安装程序'

function Write-Step($msg) { Write-Host "  $msg" }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [X]  $msg" -ForegroundColor Red }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcFx     = Join-Path $scriptDir 'Shaders\DBD_Vision.fx'
$srcPreset = Join-Path $scriptDir 'Presets'

Write-Host ''
Write-Host '════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '        DBD Vision  一键安装 / 升级' -ForegroundColor Cyan
Write-Host '════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# ── 0. 检查安装包完整性 ──────────────────────────────
if (-not (Test-Path $srcFx)) {
    Write-Err "安装包不完整：找不到 Shaders\DBD_Vision.fx"
    Write-Step "请把整个压缩包解压后，再双击里面的 安装.cmd"
    if (-not $Silent) { Read-Host '按回车退出' }; exit 1
}

# ── 1. 自动定位游戏目录 ──────────────────────────────
Write-Host '[1/5] 查找游戏目录…'

$candidates = @()

# Steam 注册表主路径
$steamPath = $null
foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
    try {
        $v = (Get-ItemProperty $key -ErrorAction SilentlyContinue).SteamPath
        if ($v) { $steamPath = $v; break }
    } catch {}
}
if (-not $steamPath) {
    try {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
        if ($v) { $steamPath = $v }
    } catch {}
}

# 收集所有 Steam 库（主库 + libraryfolders.vdf 里的其它盘）
$steamLibs = @()
if ($steamPath) {
    $steamPath = $steamPath -replace '/', '\'
    $steamLibs += $steamPath
    $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        (Get-Content $vdf -Raw) -split "`n" | ForEach-Object {
            if ($_ -match '"path"\s+"([^"]+)"') {
                $steamLibs += ($matches[1] -replace '\\\\', '\')
            }
        }
    }
}

foreach ($lib in $steamLibs) {
    $candidates += (Join-Path $lib 'steamapps\common\Dead by Daylight\DeadByDaylight\Binaries\Win64')
}

# 常见默认位置兜底
$candidates += 'C:\Program Files (x86)\Steam\steamapps\common\Dead by Daylight\DeadByDaylight\Binaries\Win64'
$candidates += 'D:\Steam\steamapps\common\Dead by Daylight\DeadByDaylight\Binaries\Win64'
$candidates += 'D:\SteamLibrary\steamapps\common\Dead by Daylight\DeadByDaylight\Binaries\Win64'
$candidates += 'E:\SteamLibrary\steamapps\common\Dead by Daylight\DeadByDaylight\Binaries\Win64'

$gameDir = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'DeadByDaylight-Win64-Shipping.exe'))) {
        $gameDir = $c
        break
    }
}

if (-not $gameDir) {
    Write-Warn2 '没能自动找到游戏目录。'
    Write-Step  '请把你电脑上的这个文件夹直接拖到下面窗口里，然后按回车：'
    Write-Step  '  ...\Dead by Daylight\DeadByDaylight\Binaries\Win64'
    Write-Host ''
    $input = if ($Silent) { '' } else { Read-Host '路径' }
    $input = $input.Trim('"', "'", ' ')
    if (Test-Path (Join-Path $input 'DeadByDaylight-Win64-Shipping.exe')) {
        $gameDir = $input
    } else {
        Write-Err '这个路径下没有 DeadByDaylight-Win64-Shipping.exe，可能选错了。'
        if (-not $Silent) { Read-Host '按回车退出' }; exit 1
    }
}
Write-Ok "游戏目录：$gameDir"

# ── 2. 检查 ReShade ──────────────────────────────────
Write-Host ''
Write-Host '[2/5] 检查 ReShade…'
$reshadeDll = Get-ChildItem -Path $gameDir -Filter '*.dll' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -in @('dxgi.dll','d3d11.dll','d3d9.dll','ReShade64.dll') } |
              Select-Object -First 1
if (-not $reshadeDll) {
    Write-Err '这个目录里没找到 ReShade（dxgi.dll / d3d11.dll）。'
    Write-Step '请先装 ReShade：https://reshade.me'
    Write-Step '安装时选 DeadByDaylight-Win64-Shipping.exe，API 选 DirectX 11'
    Write-Host ''
    $go = if ($Silent) { 'y' } else { Read-Host '仍要继续安装滤镜文件吗？(y/N)' }
    if ($go -ne 'y') { exit 0 }
} else {
    Write-Ok "检测到 ReShade：$($reshadeDll.Name)"
}

# ── 3. 识别旧版本 ────────────────────────────────────
Write-Host ''
Write-Host '[3/5] 检查已安装版本…'
$dstShaderDir = Join-Path $gameDir 'reshade-shaders\Shaders'
$dstFx = Join-Path $dstShaderDir 'DBD_Vision.fx'

$newVer = 'unknown'
$m = Select-String -Path $srcFx -Pattern '版本\s+(v[\d.]+)' -ErrorAction SilentlyContinue
if ($m) { $newVer = $m.Matches[0].Groups[1].Value }

if (Test-Path $dstFx) {
    $oldVer = 'unknown'
    $m2 = Select-String -Path $dstFx -Pattern '版本\s+(v[\d.]+)' -ErrorAction SilentlyContinue
    if ($m2) { $oldVer = $m2.Matches[0].Groups[1].Value }
    Write-Warn2 "已安装旧版：$oldVer  →  将更新到：$newVer"
    $isUpgrade = $true
} else {
    Write-Ok "全新安装（$newVer）"
    $isUpgrade = $false
}

# ── 4. 备份旧文件 ────────────────────────────────────
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $gameDir "_DBD_Vision_备份_$stamp"

if ($isUpgrade) {
    Write-Host ''
    Write-Host '[4/5] 备份旧文件…'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item $dstFx (Join-Path $backupDir 'DBD_Vision.fx') -Force -ErrorAction SilentlyContinue
    Get-ChildItem $gameDir -Filter '00_通用.ini' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $backupDir $_.Name) -Force }
    Get-ChildItem $gameDir -Filter '*定制*.ini' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $backupDir $_.Name) -Force }
    $n = (Get-ChildItem $backupDir -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Ok "已备份 $n 个文件 → $([System.IO.Path]::GetFileName($backupDir))"
} else {
    Write-Host ''
    Write-Host '[4/5] 首次安装，无需备份'
}

# ── 5. 复制文件 ──────────────────────────────────────
Write-Host ''
Write-Host '[5/5] 安装文件…'

if (-not (Test-Path $dstShaderDir)) {
    New-Item -ItemType Directory -Force -Path $dstShaderDir | Out-Null
}

Copy-Item $srcFx $dstFx -Force
Write-Ok "着色器 → reshade-shaders\Shaders\DBD_Vision.fx"

$presetCount = 0
$skipped = 0
if (Test-Path $srcPreset) {
    Get-ChildItem $srcPreset -Filter '*.ini' | ForEach-Object {
        $target = Join-Path $gameDir $_.Name
        if (Test-Path $target) {
            $skipped++
        } else {
            Copy-Item $_.FullName $target -Force
            $presetCount++
        }
    }
}
Write-Ok "预设 → 新建 $presetCount 个"
if ($skipped -gt 0) {
    Write-Warn2 "跳过 $skipped 个已存在的预设（保护你自己调好的数值，旧版已备份）"
}

# ── 完成 ─────────────────────────────────────────────
Write-Host ''
Write-Host '════════════════════════════════════════' -ForegroundColor Green
Write-Host '  安装完成！' -ForegroundColor Green
Write-Host '════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
Write-Host '  下一步：'
Write-Host '    1. 完全退出游戏（包括 Steam 里显示"正在运行"）'
Write-Host '    2. 重新启动游戏'
Write-Host '    3. 按 Home 键打开 ReShade 面板'
Write-Host '    4. 顶部预设下拉框选「00_通用」'
Write-Host ''
if ($isUpgrade) {
    Write-Host "  旧文件备份在：$([System.IO.Path]::GetFileName($backupDir))" -ForegroundColor DarkGray
}
Write-Host '  有疑问看 README.md' -ForegroundColor DarkGray
Write-Host ''
if (-not $Silent) { Read-Host '按回车关闭' }
