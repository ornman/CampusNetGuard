# 清理 FlClash(全部 5 个价值功能将由 Rust TUI 替代)
# 用法:右键 PowerShell → "以管理员身份运行" → .\cleanup-flclash.ps1

$ErrorActionPreference = "Stop"
$svcName = "FlClashHelperService"
$flDir   = "D:\FlClash"

Write-Host "[1/5] 确认管理员..." -ForegroundColor Cyan
$cur = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $cur.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "未以管理员身份运行。请重新以管理员身份打开 PowerShell 再执行本脚本。"
    exit 1
}

Write-Host "[2/5] 终止所有 FlClash 进程..." -ForegroundColor Cyan
foreach ($p in @("FlClash","FlClashCore")) {
    $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
    foreach ($proc in $procs) {
        Write-Host "    Stop-Process $p PID=$($proc.Id) RAM=$([math]::Round($proc.WorkingSet64/1MB,1))MB"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[3/5] 停止并禁用 $svcName ..." -ForegroundColor Cyan
try {
    Stop-Service -Name $svcName -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    sc.exe config $svcName start= disabled | Out-Null
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    Write-Host ("    状态: {0}, 启动类型: {1}" -f $svc.Status, $svc.StartType)
} catch {
    Write-Warning "服务操作失败: $($_.Exception.Message)"
}

Write-Host "[4/5] 走官方卸载器清注册表 + 文件..." -ForegroundColor Cyan
$uninst = Join-Path $flDir "unins000.exe"
if (Test-Path $uninst) {
    Write-Host "    启动 $uninst /S (静默卸载)"
    $p = Start-Process -FilePath $uninst -ArgumentList "/S" -PassThru -Wait
    Write-Host "    卸载器退出码: $($p.ExitCode)"
} else {
    Write-Warning "    卸载器不存在,跳过官方卸载"
}

# 删除 AppData 残留(配置/缓存/日志)
foreach ($dir in @("$env:APPDATA\FlClash", "$env:LOCALAPPDATA\FlClash")) {
    if (Test-Path $dir) {
        $size = (Get-ChildItem $dir -Recurse -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum).Sum
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ("    已删 {0}, {1:N1} MB" -f $dir, ($size/1MB))
    }
}

Write-Host "[5/5] 清理注册表残留..." -ForegroundColor Cyan
$keys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\FlClash"
)
$regRemoved = 0
foreach ($p in $keys) {
    Get-ItemProperty $p -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "FlClash" } |
        ForEach-Object {
            Write-Host "    删注册表项: $($_.PSPath) ($($_.DisplayName))"
            Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            $regRemoved++
        }
}
Write-Host "    注册表清理项数: $regRemoved"

# 兜底:若目录还在,手动删除
if (Test-Path $flDir) {
    $size = (Get-ChildItem $flDir -Recurse -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
    Remove-Item -Path $flDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("    兜底删除 {0}, 释放 {1:N1} MB" -f $flDir, ($size/1MB))
}

Write-Host ""
Write-Host "✓ 完成。验证:" -ForegroundColor Green
Get-Service $svcName -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
Get-Process | Where-Object { $_.ProcessName -match "FlClash" } | Format-Table Id, ProcessName, @{N='RAM(MB)';E={[math]::Round($_.WorkingSet64/1MB,1)}} -AutoSize
Test-Path $flDir | ForEach-Object { Write-Host "    目录还存在: $_" }