# ============================================================
# GatewayGuard 一次性管理员设置（需 UAC 提权运行）
#  1) 清理 Radmin VPN / Wi-Fi Direct 的垫底默认路由
#  2) 物理网卡禁用 IPv6（封死 v6 旁路；走 IPv6 资源将不可用，README 有恢复方法）
#  3) 退出 FlClash 并移除其开机自启（避免与受管内核抢 7890/TUN）
#  4) 注册并启动两个计划任务：Core / Watchdog
# 注:任务名保留 "CampusNetGuard-*" 前缀以兼容已部署的计划任务
# ============================================================
#requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

# 自动探测安装根目录(从 admin-setup.ps1 所在目录)
$Root = $PSScriptRoot
Start-Transcript -Path "$Root\logs\admin-setup.log" -Force

Write-Host "[1/5] 清理垃圾默认路由..."
route.exe delete 0.0.0.0 mask 0.0.0.0 26.0.0.1 2>&1 | Out-Null
route.exe delete 0.0.0.0 mask 0.0.0.0 192.168.49.1 2>&1 | Out-Null
Write-Host "  done"

Write-Host "[2/5] 物理网卡禁用 IPv6..."
Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $b = Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
        if ($b -and $b.Enabled) {
            Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction Stop
            Write-Host "  $($_.Name): IPv6 -> 已禁用"
        } else {
            Write-Host "  $($_.Name): IPv6 已是禁用状态"
        }
    } catch { Write-Host "  $($_.Name): 失败 $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host "[3/5] 退出 FlClash 并移除自启..."
Stop-Process -Name "FlClash" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "FlClashCore" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "FlClash" -ErrorAction SilentlyContinue
Write-Host "  done"

Write-Host "[4/5] 注册计划任务..."
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$user = "$env:USERDOMAIN\$env:USERNAME"

$coreInner = "& '$Root\core\mihomo.exe' -d '$Root\core' -f '$Root\configs\applied\current.yaml' *> '$Root\logs\core.log'"
$coreAction = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$coreInner`""

$wdInner = "& '$Root\scripts\watchdog.ps1' *> '$Root\logs\watchdog-task.log'"
$wdAction = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$wdInner`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable

Register-ScheduledTask -TaskName "CampusNetGuard-Core" -Action $coreAction -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Register-ScheduledTask -TaskName "CampusNetGuard-Watchdog" -Action $wdAction -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "  CampusNetGuard-Core / CampusNetGuard-Watchdog 已注册(登录自启,最高权限)"

Write-Host "[5/5] 启动任务..."
Start-ScheduledTask -TaskName "CampusNetGuard-Core"
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName "CampusNetGuard-Watchdog"
Start-Sleep -Seconds 4
Get-ScheduledTask -TaskName "CampusNetGuard-*" | ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo
    Write-Host "  $($_.TaskName): $($_.State) (lastRun=$($i.LastRunTime))"
}

# ---- 配置看门狗的 SSID 白/黑名单(自动探测 + 用户确认)----
Write-Host "`n[6/6] 配置看门狗的 SSID 白/黑名单..."
& "$Root\scripts\configure-ssids.ps1"

Write-Host "`n完成。日志: $Root\logs\admin-setup.log"
Write-Host ""
Write-Host "下一步:"
Write-Host "  - UI 用 FlClash(连 127.0.0.1:9090 看 mihomo 数据)"
Write-Host "  - 想换 SSID 配置,跑 scripts\configure-ssids.ps1"
Write-Host "  - 看状态:scripts\net-status.ps1"
Stop-Transcript
