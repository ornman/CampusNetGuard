# 清理 Radmin VPN(不需要用了):停服务 + 禁自启 + 删 132.8 MB 文件
# 用法:右键 PowerShell → "以管理员身份运行" → 进入此目录 → .\cleanup-radmin.ps1

$ErrorActionPreference = "Stop"
$svcName = "RvControlSvc"
$svcPath = "C:\Program Files (x86)\Radmin VPN"

Write-Host "[1/4] 确认管理员..." -ForegroundColor Cyan
$cur = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $cur.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "未以管理员身份运行。请重新以管理员身份打开 PowerShell 再执行本脚本。"
    exit 1
}

Write-Host "[2/4] 停止并禁用服务 $svcName ..." -ForegroundColor Cyan
try {
    Stop-Service -Name $svcName -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    sc.exe config $svcName start= disabled | Out-Null   # sc.exe 绕过 PowerShell cmdlet 权限缓存
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    Write-Host ("    状态: {0}, 启动类型: {1}" -f $svc.Status, $svc.StartType)
    if ($svc.Status -ne "Stopped") {
        $procId = (Get-WmiObject -Class Win32_Service -Filter "Name='$svcName'").ProcessId
        if ($procId -gt 0) { Stop-Process -Id $procId -Force }
        Start-Sleep -Seconds 2
    }
} catch {
    Write-Warning "服务操作失败: $($_.Exception.Message)"
}

Write-Host "[3/4] 移除 Radmin VPN 虚拟网卡(若存在)..." -ForegroundColor Cyan
Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -match "Radmin" } |
    ForEach-Object {
        Write-Host "    禁用网卡: $($_.Name) ($($_.InterfaceDescription))"
        Disable-NetAdapter -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue
    }

Write-Host "[4/4] 删除文件 $svcPath ..." -ForegroundColor Cyan
if (Test-Path $svcPath) {
    $size = (Get-ChildItem $svcPath -Recurse -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
    Remove-Item -Path $svcPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("    已删除,释放 {0:N1} MB" -f ($size / 1MB))
} else {
    Write-Host "    目录不存在,跳过"
}

# 清理驱动残留(Driver.1.0/Driver.1.1 通常已被 Windows 回收;若还在,pnputil 卸载)
$drivers = pnputil /enum-drivers 2>$null | Select-String "Radmin" -Context 2,2
if ($drivers) {
    Write-Host "    发现 Radmin 驱动残留,可手动: pnputil /delete-driver <published-name> /uninstall /force"
}

Write-Host ""
Write-Host "✓ 完成。验证:" -ForegroundColor Green
Get-Service $svcName -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match "Radmin" } | Format-Table Name, Status -AutoSize
Test-Path $svcPath | ForEach-Object { Write-Host "    目录还存在: $_" }