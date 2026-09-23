# ============================================================
# CampusNetGuard 状态检查（net-status）
# 用法: net-status.ps1 [-NoPause]   （桌面快捷方式双击 = 带暂停）
# ============================================================
param([switch]$NoPause)
. "$PSScriptRoot\common.ps1"

$ok = [char]0x2714   # ✔
$bad = [char]0x2716  # ✘
$warn = [char]0x26A0 # ⚠

function Line { param([string]$c) Write-Host $c -ForegroundColor Gray }
function Head { param([string]$t) Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }

Write-Host "CampusNetGuard 网络状态  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Yellow

# ---------- 1. 服务状态 ----------
Head "服务"
$core = Get-Process mihomo -ErrorAction SilentlyContinue
if ($core) { Write-Host "$ok 受管内核运行中 (pid $($core.Id -join ','))" -ForegroundColor Green }
else { Write-Host "$bad 受管内核未运行!" -ForegroundColor Red }
$wdTask = Get-ScheduledTask -TaskName "CampusNetGuard-Watchdog" -ErrorAction SilentlyContinue
if ($wdTask -and $wdTask.State -eq "Running") { Write-Host "$ok 看门狗运行中 (计划任务 Running)" -ForegroundColor Green }
else { Write-Host "$bad 看门狗未运行 (计划任务状态: $($wdTask.State))" -ForegroundColor Red }

# ---------- 2. 链路 ----------
Head "链路"
$eth = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match "Realtek" -and $_.InterfaceDescription -notmatch "VPN|Virtual|Tailscale" }
if ($eth) {
    $e = @($eth)[0]
    if ($e.Status -eq "Up") { Write-Host "$ok 有线: $($e.Name) 已连接" -ForegroundColor Green }
    else { Write-Host "$warn 有线: 未插 (国内走 WiFi/热点)" -ForegroundColor Yellow }
}
$ssid = Get-WlanSsid
$wlan = Get-WlanAlias
if ($ssid) {
    $tag = if ($ssid -eq $HotspotSsid) { "(=手机热点)" } elseif ($ssid -eq "guat") { "(=校园WiFi)" } else { "" }
    Write-Host "$ok WiFi: $ssid $tag" -ForegroundColor Green
} else { Write-Host "$warn WiFi: 未连接" -ForegroundColor Yellow }
$usb = Get-UsbTetherAdapter
if ($usb) { Write-Host "$ok USB 热点: $($usb.Name) [$($usb.InterfaceDescription)]" -ForegroundColor Green }
else { Write-Host "$warn USB 热点: 未插/未开共享" -ForegroundColor Yellow }

# ---------- 3. 校园判定 ----------
Head "校园判定 (10.1.2.3 可达性)"
$campus = $false
try { $campus = (Test-Connection -ComputerName 10.1.2.3 -Count 1 -Quiet -ErrorAction Stop) } catch { }
if ($campus) {
    Write-Host "$warn 10.1.2.3 可达 -> 当前处于校园网环境" -ForegroundColor Yellow
    Write-Host "   代理流量已被强制锁定在手机热点出口，校园网仅承载国内直连" -ForegroundColor Gray
} else {
    Write-Host "$ok 10.1.2.3 不可达 -> 非校园网环境（或仅热点在线）" -ForegroundColor Green
}

# ---------- 4. 代理出口状态 ----------
Head "代理出口 (fail-closed)"
$st = Read-State
if ($st) {
    $modeCn = switch ($st.mode) { "usb" { "USB 共享网络" } "wlan" { "WiFi 热点" } "blocked" { "已封锁" } default { $st.mode } }
    $color = if ($st.mode -eq "blocked") { "Yellow" } else { "Green" }
    Write-Host "模式: $modeCn   绑定网卡: $($st.iface)   生效: $($st.appliedOk)   变更: $($st.changedAt)" -ForegroundColor $color
    if ($st.mode -eq "blocked") {
        Write-Host "   -> 国外流量当前被封锁(热点不在线)；国内/特殊站点直连不受影响" -ForegroundColor Gray
    }
} else { Write-Host "$bad 无状态文件(看门狗未运行过?)" -ForegroundColor Red }
$cfgIf = $null
if (Test-Path $AppliedCfg) {
    $cfg = Get-Content $AppliedCfg
    for ($i = 0; $i -lt $cfg.Count; $i++) {
        if ($cfg[$i] -match "name: BIND-EGRESS") { $cfgIf = ($cfg[$i + 2] -replace ".*interface-name:\s*", "").Trim() }
    }
    Write-Host "当前配置文件绑定: $cfgIf" -ForegroundColor Gray
}

# ---------- 5. 内核 API ----------
Head "内核 (mihomo API)"
try {
    $v = Invoke-MihomoApi -Method Get -Path "/version"
    Write-Host "$ok version=$($v.version)  mode=$($v.mode)" -ForegroundColor Green
    $c = Invoke-MihomoApi -Method Get -Path "/configs"
    Write-Host "   tun=$($c.'tun'.enable)  mode=$($c.mode)  port=$($c.'mixed-port')" -ForegroundColor Gray
    $px = Invoke-MihomoApi -Method Get -Path "/proxies/PROXY"
    Write-Host "   当前节点: $($px.now)" -ForegroundColor Gray
    $sp = Invoke-MihomoApi -Method Get -Path "/proxies/SPECIAL"
    Write-Host "   特殊站点(GitHub等)走: $($sp.now)" -ForegroundColor Gray
} catch { Write-Host "$bad API 不可达: $($_.Exception.Message)" -ForegroundColor Red }

# ---------- 6. 泄露自检 ----------
Head "泄露自检"
# 6.1 物理网卡 IPv6 绑定（应全部禁用）
$bad6 = @()
Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    $b = Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    if ($b -and $b.Enabled) { $bad6 += $_.Name }
}
if ($bad6.Count -eq 0) { Write-Host "$ok 物理网卡 IPv6 已全部禁用（无 v6 旁路）" -ForegroundColor Green }
else { Write-Host "$bad 以下网卡 IPv6 仍启用: $($bad6 -join ', ')" -ForegroundColor Red }
# 6.2 系统代理应关闭（TUN 接管，无需系统代理）
$reg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
if ($reg.ProxyEnable -eq 0) { Write-Host "$ok 系统代理关闭（TUN 全局接管中）" -ForegroundColor Green }
else { Write-Host "$warn 系统代理开启: $($reg.ProxyServer)" -ForegroundColor Yellow }
# 6.3 国外域名解析应得 fake-ip（校园 DNS 看不到国外查询）
$fake = $null
try {
    $r = Resolve-DnsName -Name "www.google.com" -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
    $fake = @($r | Where-Object { $_.IPAddress }).IPAddress | Select-Object -First 1
} catch { }
if ($fake -match "^198\.18\.") { Write-Host "$ok 国外域名解析为 fake-ip($fake)，校园 DNS 零泄露" -ForegroundColor Green }
elseif ($fake) { Write-Host "$warn www.google.com 解析为真实 IP($fake)——请检查 TUN/DNS 劫持" -ForegroundColor Red }
else { Write-Host "$warn 国外域名解析无结果（若处于封锁态属正常）" -ForegroundColor Yellow }

# ---------- 7. 连通性实测 ----------
Head "连通性实测"
$code = 0
try { $code = & curl.exe -s -o NUL -w "%{http_code}" -m 6 "https://www.baidu.com" 2>$null } catch { }
if ($code -eq "200") { Write-Host "$ok 国内直连 (baidu.com): HTTP $code" -ForegroundColor Green }
else { Write-Host "$bad 国内直连异常: HTTP $code" -ForegroundColor Red }
$code = 0
try { $code = & curl.exe -s -o NUL -w "%{http_code}" -m 8 "https://github.com" 2>$null } catch { }
if ($code -eq "200") { Write-Host "$ok 特殊站点 github.com: HTTP $code (代理或直连回落)" -ForegroundColor Green }
else { Write-Host "$warn github.com: HTTP $code" -ForegroundColor Yellow }
$code = 0
try { $code = & curl.exe -s -o NUL -w "%{http_code}" -m 8 "https://www.gstatic.com/generate_204" 2>$null } catch { }
if ($code -eq "204") { Write-Host "$ok 国外代理通路 (gstatic 204): 正常" -ForegroundColor Green }
else { Write-Host "$warn 国外代理通路: HTTP $code（若热点未开属预期封锁）" -ForegroundColor Yellow }

if (-not $NoPause) {
    Write-Host ""
    Read-Host "按回车退出"
}
