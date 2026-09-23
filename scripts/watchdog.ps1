# ============================================================
# CampusNetGuard 看门狗 —— 代理出口安全状态机
# 规则（防泄露核心）:
#   1) USB 热点网卡在线            -> 代理绑定 USB 网卡
#   2) 无 USB 且 WiFi SSID=vivo X200s -> 代理绑定 WLAN（此时 WLAN 即手机热点）
#   3) 其余任何情况                -> 代理绑定到不存在的网卡（国外强制封锁，国内直连不受影响）
# 通过 mihomo 本地 API 热重载配置；核心进程消失/卡死时自动拉起计划任务
# ============================================================
. "$PSScriptRoot\common.ps1"

# === TUI 配置读取(SSID 白/黑名单) ===
# 优先读 <Root>/state/cng-config.json(TUI 后台 worker 写入),
# 读不到或字段为空 → 退回 common.ps1 里的 $HotspotSsid 单值
$CngConfigFile = "$Root\state\cng-config.json"
$script:ProxySsids = @($HotspotSsid)   # 默认 = common.ps1 单值
$script:DirectSsids = @()
if (Test-Path $CngConfigFile) {
    try {
        $cfg = Get-Content $CngConfigFile -Raw | ConvertFrom-Json
        if ($cfg.proxy_ssids -and @($cfg.proxy_ssids).Count -gt 0) {
            $script:ProxySsids = @($cfg.proxy_ssids | ForEach-Object { "$_" })
        }
        if ($cfg.direct_ssids) {
            $script:DirectSsids = @($cfg.direct_ssids | ForEach-Object { "$_" })
        }
        Write-Log "INFO" "TUI SSID 配置: proxy=[$($script:ProxySsids -join ',')] direct=[$($script:DirectSsids -join ',')]"
    } catch {
        Write-Log "WARN" "cng-config.json 解析失败,退回 common.ps1: $($_.Exception.Message)"
    }
}

$LoopSec = 5
$ApiFailLimit = 6          # 连续 6 次(约30s) API 不通 -> 重启核心任务
$apiFailCount = 0
$script:lastCoreKick = Get-Date "2000-01-01"

# 兼容旧状态文件（首次运行没有 state.json，视为 blocked 以触发首次应用）
$state = Read-State
if (-not $state) {
    Write-State -Mode "init" -EgressIf "?" -AppliedOk $false
    $state = Read-State
}

Write-Log "INFO" "watchdog 启动 (pid=$PID)，热点 SSID 判定: '$HotspotSsid'"

# ---- 热点自动连接（热点出现且 USB 未插时，把 WiFi 切到手机热点）----
$script:lastWifiTry = Get-Date "2000-01-01"
$script:wifiFails = 0
$script:loopCount = 0

function Test-HotspotVisible {
    try {
        $out = netsh wlan show networks 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        foreach ($line in $out) {
            if ($line -match '^\s*SSID \d+\s*:\s*(.+?)\s*$' -and $Matches[1] -eq $script:HotspotSsid) { return $true }
        }
    } catch { }
    return $false
}

function Invoke-AutoConnectHotspot {
    param([string]$CurrentSsid)
    if ($CurrentSsid -eq $script:HotspotSsid) { $script:wifiFails = 0; return }   # 已在热点上
    if (Get-UsbTetherAdapter) { return }        # USB 已覆盖代理出口，不动 WiFi（留给国内链路）
    $gap = ((Get-Date) - $script:lastWifiTry).TotalSeconds
    $backoff = if ($script:wifiFails -ge 3) { 600 } else { 60 }   # 连败3次退避10分钟
    if ($gap -lt $backoff) { return }
    if (-not (Test-HotspotVisible)) { return }
    $script:lastWifiTry = Get-Date
    $script:wifiFails++
    Write-Log "INFO" "发现热点 '$HotspotSsid'，自动连接 WiFi (尝试 #$($script:wifiFails))"
    $null = netsh wlan connect name="$script:HotspotSsid" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Log "WARN" "netsh 连接指令返回 $LASTEXITCODE" }
}

function Resolve-Desired {
    # 返回 @{mode=..; if=..; detail=..}
    $usb = Get-UsbTetherAdapter
    if ($usb) {
        # USB 网卡禁 IPv6，防 v6 旁路（本任务以最高权限运行）
        try {
            $b = Get-NetAdapterBinding -Name $usb.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
            if ($b -and $b.Enabled) {
                Disable-NetAdapterBinding -Name $usb.Name -ComponentID ms_tcpip6 -ErrorStop
                Write-Log "INFO" "已在 $($usb.Name) 上禁用 IPv6 绑定"
            }
        } catch { Write-Log "WARN" "禁用 IPv6 失败($($usb.Name)): $($_.Exception.Message)" }
        return @{ mode = "usb"; if = $usb.Name; detail = $usb.InterfaceDescription }
    }
    $ssid = Get-WlanSsid
    # SSID 匹配:TUI proxy_ssids(任一)→ wlan;TUI direct_ssids(任一)→ blocked
    if ($ssid -and $script:ProxySsids -contains $ssid) {
        $wlan = Get-WlanAlias
        if ($wlan) { return @{ mode = "wlan"; if = $wlan; detail = "SSID=$ssid (proxy)" } }
    }
    if ($ssid -and $script:DirectSsids -contains $ssid) {
        return @{ mode = "blocked"; if = $script:BlockedIf; detail = "SSID=$ssid (direct)" }
    }
    return @{ mode = "blocked"; if = $script:BlockedIf; detail = "无匹配热点 (SSID=$ssid)" }
}

function Apply-Config {
    param([hashtable]$Desired)
    $proxyCsv = $script:ProxySsids -join ','
    $directCsv = $script:DirectSsids -join ','
    & "$PSScriptRoot\make-config.ps1" -Mode $Desired.mode -EgressIf $Desired.if `
        -ProxySsids $proxyCsv -DirectSsids $directCsv | Out-Null
    if ($LASTEXITCODE -ne 0 -and -not (Test-Path $AppliedCfg)) {
        Write-Log "ERROR" "生成配置失败: $($Desired.mode)"
        return $false
    }
    try {
        $body = @{ path = $AppliedCfg.Replace('\', '/'); payload = "" }
        Invoke-MihomoApi -Method Put -Path "/configs?force=true" -Body $body | Out-Null
        Write-Log "INFO" "已应用: mode=$($Desired.mode) if=$($Desired.if) ($($Desired.detail))"
        return $true
    } catch {
        Write-Log "ERROR" "API 热重载失败: $($_.Exception.Message)"
        return $false
    }
}

while ($true) {
    try {
        $script:loopCount++
        # 每 3 轮(约15s)嗅探一次：热点在广播且 USB 未插 -> 自动把 WiFi 切到热点
        if (($script:loopCount % 3) -eq 1) {
            Invoke-AutoConnectHotspot -CurrentSsid (Get-WlanSsid)
        }

        $desired = Resolve-Desired
        $curMode = $state.mode
        $curIf = $state.iface
        $needApply = ($desired.mode -ne $curMode) -or ($desired.if -ne $curIf) -or (-not $state.appliedOk)

        if ($needApply) {
            $ok = Apply-Config -Desired $desired
            $prev = $curMode
            Write-State -Mode $desired.mode -EgressIf $desired.if -AppliedOk $ok
            $state = Read-State
            if ($ok) {
                switch ("$prev->$($desired.mode)") {
                    "blocked->usb"   { Send-Toast "代理已恢复" "出口: USB 共享网络（国外流量已放行）" }
                    "blocked->wlan"  { Send-Toast "代理已恢复" "出口: WiFi 热点 $HotspotSsid" }
                    "usb->blocked"   { Send-Toast "代理已封锁" "热点已断开，国外流量停止（国内不受影响）" }
                    "wlan->blocked"  { Send-Toast "代理已封锁" "热点已断开，国外流量停止（国内不受影响）" }
                    "usb->wlan"      { Send-Toast "代理出口切换" "USB -> WiFi 热点" }
                    "wlan->usb"      { Send-Toast "代理出口切换" "WiFi 热点 -> USB" }
                    "init->blocked"  { } # 启动静默
                    default          { Send-Toast "代理状态" "mode=$($desired.mode)" }
                }
            }
        }

        # 核心健康检查 + 自愈
        $coreAlive = $false
        try {
            $null = Invoke-MihomoApi -Method Get -Path "/version"
            $coreAlive = $true; $apiFailCount = 0
        } catch { $apiFailCount++ }

        if (-not $coreAlive -and $apiFailCount -ge $ApiFailLimit) {
            $kickGap = ((Get-Date) - $script:lastCoreKick).TotalSeconds
            if ($kickGap -gt 120) {
                Write-Log "WARN" "核心 API 持续无响应($apiFailCount 次)，重启 CampusNetGuard-Core 任务"
                try {
                    Stop-ScheduledTask -TaskName "CampusNetGuard-Core" -ErrorAction Stop
                    Start-Sleep -Seconds 2
                } catch { }
                Start-ScheduledTask -TaskName "CampusNetGuard-Core" -ErrorAction SilentlyContinue
                $script:lastCoreKick = Get-Date
                $apiFailCount = 0
            }
        }
    } catch {
        Write-Log "ERROR" "循环异常: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $LoopSec
}
