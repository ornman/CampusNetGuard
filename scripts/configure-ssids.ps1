# 配置看门狗的 SSID 白/黑名单。
#
# 默认流程(自动 + 一次确认):探测当前网络 → 提推荐配置 → 用户回车接受或改
#   - 适合 admin-setup.ps1 末尾调用(用户敲一次回车即完成)
#
# 进阶用法:
#   -Interactive     全手动(逐个问每个 SSID)
#   -ForceAuto      跳过确认,直接用推荐(适合脚本/CI)
#   -ProxySsids / -DirectSsids  命令行直接覆盖
#
# 副作用:写 <install_dir>\state\cng-config.json(被 watchdog.ps1 读)
#
# 幂等:可重复跑,直接覆盖现有配置(除非加 -KeepExisting)。

param(
    [switch]$Interactive,
    [switch]$ForceAuto,
    [switch]$KeepExisting,
    [string]$ProxySsids,
    [string]$DirectSsids
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$StateDir = "$Root\state"
$CngConfigPath = "$StateDir\cng-config.json"

function Convert-CsvToArray([string]$Csv) {
    if ([string]::IsNullOrWhiteSpace($Csv)) { return @() }
    return @($Csv.Split([char[]]@(',', '，')) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-CurrentSsid {
    try {
        $out = netsh wlan show interfaces 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($line in $out) {
            if ($line -match '^\s*SSID\s+:\s*(.+?)\s*$') {
                $ssid = $Matches[1].Trim()
                if ($ssid -and $ssid -ne "BSSID") { return $ssid }
            }
        }
    } catch { }
    return $null
}

function Test-UsbTether {
    try {
        $adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -match "NDIS|NCM|Android|Tethering" } |
            Select-Object -First 1
        return [bool]$adapter
    } catch { return $false }
}

# ============== 决定推荐配置 ==============

$recommendation = $null

if ($ProxySsids -or $DirectSsids) {
    # 命令行直接覆盖,跳过推荐
    $proxyArr = Convert-CsvToArray $ProxySsids
    $directArr = Convert-CsvToArray $DirectSsids
    $mode = "命令行覆盖"
} elseif ($Interactive) {
    # 全手动:逐个问
    $interactive = [Environment]::UserInteractive
    if (-not $interactive) {
        Write-Warning "无 TTY,无法交互。"
        exit 1
    }
    Write-Host ""
    Write-Host "GatewayGuard —— SSID 配置(手动)"
    Write-Host "==================================="
    Write-Host ""
    Write-Host "多个 SSID 用英文逗号或中文逗号分隔。留空 = 该项不加。"
    Write-Host ""
    $p = Read-Host "  proxy_ssids(走代理的 WiFi)"
    $d = Read-Host "  direct_ssids(强制直连的 WiFi)"
    $proxyArr = Convert-CsvToArray $p
    $directArr = Convert-CsvToArray $d
    $mode = "手动交互"
} elseif ($KeepExisting -and (Test-Path $CngConfigPath)) {
    try {
        $existing = Get-Content $CngConfigPath -Raw | ConvertFrom-Json
        $proxyArr = @($existing.proxy_ssids)
        $directArr = @($existing.direct_ssids)
        $mode = "保留现有"
    } catch {
        Write-Warning "现有 cng-config.json 解析失败,改用自动探测"
    }
}

if (-not $proxyArr -and -not $directArr) {
    # ============== 自动探测 + 智能推荐 ==============
    $currentSsid = Get-CurrentSsid
    $hasUsb = Test-UsbTether

    $recommendation = [ordered]@{
        current_ssid = if ($currentSsid) { $currentSsid } else { "(未连接 WiFi)" }
        usb_tether   = $hasUsb
        proxy_ssids  = @()
        direct_ssids = @()
        reason       = ""
    }

    if ($hasUsb -and $currentSsid) {
        # WiFi + USB 都有 → WiFi 是主网络(直连),USB 是代理专用
        $recommendation.proxy_ssids = @()
        $recommendation.direct_ssids = @($currentSsid)
        $recommendation.reason = "检测到 USB tether + 当前 WiFi。USB 会自动接管代理,WiFi 标为直连。"
    } elseif ($hasUsb) {
        # 只有 USB,没连 WiFi
        $recommendation.proxy_ssids = @()
        $recommendation.direct_ssids = @()
        $recommendation.reason = "检测到 USB tether,代理由 USB 自动接管。不需要 SSID 配置。"
    } elseif ($currentSsid) {
        # 只有 WiFi → 默认当代理(但用户可能不同意)
        $recommendation.proxy_ssids = @($currentSsid)
        $recommendation.direct_ssids = @()
        $recommendation.reason = "当前连的是 WiFi(没 USB tether)。默认建议当作代理网络。"
    } else {
        # 啥都没
        $recommendation.proxy_ssids = @()
        $recommendation.direct_ssids = @()
        $recommendation.reason = "没检测到 WiFi 也没 USB。留空(回退 common.ps1 HotspotSsid)。"
    }

    $proxyArr = $recommendation.proxy_ssids
    $directArr = $recommendation.direct_ssids
    $mode = "自动推荐"

    # ============== 展示 + 让用户选 ==============
    $interactive = [Environment]::UserInteractive
    if ($interactive -and -not $ForceAuto) {
        Write-Host ""
        Write-Host "=========================================="
        Write-Host "  看门狗 SSID 配置(自动探测)"
        Write-Host "=========================================="
        Write-Host ""
        Write-Host "  当前网络状态:"
        Write-Host "    WiFi:       $($recommendation.current_ssid)"
        Write-Host "    USB tether: $(if ($recommendation.usb_tether) { '已连接' } else { '未检测' })"
        Write-Host ""
        Write-Host "  推荐配置:"
        Write-Host "    proxy_ssids:  $(if ($proxyArr) { $proxyArr -join ', ' } else { '(空)' })"
        Write-Host "    direct_ssids: $(if ($directArr) { $directArr -join ', ' } else { '(空)' })"
        Write-Host ""
        Write-Host "  原因: $($recommendation.reason)"
        Write-Host ""
        Write-Host "  [Y] 接受  [P] 改 proxy_ssids  [D] 改 direct_ssids  [M] 全手动"
        Write-Host ""

        $choice = (Read-Host "  选择").Trim().ToUpper()
        if ([string]::IsNullOrEmpty($choice)) { $choice = "Y" }

        switch ($choice) {
            "Y" {
                # 接受推荐,啥都不改
            }
            "P" {
                $p = Read-Host "  proxy_ssids(走代理的 WiFi,逗号分隔,留空=不加)"
                $proxyArr = Convert-CsvToArray $p
                $mode = "推荐 + 用户微调"
            }
            "D" {
                $d = Read-Host "  direct_ssids(强制直连的 WiFi,逗号分隔,留空=不加)"
                $directArr = Convert-CsvToArray $d
                $mode = "推荐 + 用户微调"
            }
            "M" {
                Write-Host ""
                Write-Host "全手动模式:"
                $p = Read-Host "  proxy_ssids(走代理的 WiFi)"
                $d = Read-Host "  direct_ssids(强制直连的 WiFi)"
                $proxyArr = Convert-CsvToArray $p
                $directArr = Convert-CsvToArray $d
                $mode = "全手动"
            }
            default {
                Write-Host "  未知选项,接受推荐"
            }
        }
    } elseif ($ForceAuto) {
        # 强制自动模式:不展示不询问,直接用推荐
    } else {
        # 非交互环境(无人值守):用推荐
        Write-Host "  (非交互模式,自动用推荐)"
    }
}

# ============== 写 cng-config.json ==============

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

$payload = [ordered]@{
    proxy_ssids  = $proxyArr
    direct_ssids = $directArr
    updatedAt    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}
$payload | ConvertTo-Json | Set-Content -Path $CngConfigPath -Encoding UTF8

# ============== 反馈 ==============

Write-Host ""
Write-Host "✓ [$mode] 已写入 $CngConfigPath"
Write-Host "  proxy_ssids:  $(if ($proxyArr) { $proxyArr -join ', ' } else { '(空)' })"
Write-Host "  direct_ssids: $(if ($directArr) { $directArr -join ', ' } else { '(空)' })"
Write-Host ""
Write-Host "看门狗 5 秒内自动读到。无需重启。"
