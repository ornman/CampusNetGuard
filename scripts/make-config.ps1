# 从模板生成 mihomo 运行配置(占位符替换 + SSID 注入)
# 用法:
#   make-config.ps1 -Mode usb|wlan|blocked [-EgressIf "网卡名"] `
#                   [-ProxySsids "ssid1,ssid2"] [-DirectSsids "ssid3,ssid4"]
#
# 副作用(闭环关键):
#   1. 生成 <Root>/core/reload/current.yaml + <Root>/configs/applied/current.yaml(双写)
#   2. 把 ProxySsids / DirectSsids 写到 <Root>/state/cng-config.json,
#      watchdog 下次循环(5s 内)读这个 JSON 决定新 mode
param(
    [Parameter(Mandatory = $true)][ValidateSet("usb", "wlan", "blocked")][string]$Mode,
    [string]$EgressIf,
    [string]$ProxySsids = "",
    [string]$DirectSsids = ""
)
. "$PSScriptRoot\common.ps1"

if (-not $EgressIf) {
    switch ($Mode) {
        "usb" {
            $usb = Get-UsbTetherAdapter
            if ($usb) { $EgressIf = $usb.Name } else { throw "USB 热点网卡不存在" }
        }
        "wlan" {
            $EgressIf = Get-WlanAlias
            if (-not $EgressIf) { throw "WLAN 网卡不存在" }
        }
        default { $EgressIf = $script:BlockedIf }
    }
}

$tpl = [IO.File]::ReadAllText("$Root\configs\config-template.yaml", [Text.Encoding]::UTF8)
$out = $tpl.Replace("__EGRESS_IF__", $EgressIf)
# secret 从 common.ps1 注入(template 里是占位符,避免 commit 时泄露密钥)
$out = $out.Replace("__MIHOMO_API_SECRET__", $script:ApiSecret)

# 注入 SSID 头部注释(让用户在 mihomo config 看到当前生效的 SSID 白/黑名单)
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$proxyCsv = if ($ProxySsids) { $ProxySsids } else { "(空)" }
$directCsv = if ($DirectSsids) { $DirectSsids } else { "(空)" }
$header = @(
    "# === TUI 业务字段(由 make-config.ps1 注入) ==="
    "# 生成时间: $ts"
    "# proxy_ssids (走代理): $proxyCsv"
    "# direct_ssids (强制直连): $directCsv"
    "# 这些字段在 mihomo config 中只是文档;实际 SSID→mode 由 watchdog 读 state/cng-config.json 决定"
    ""
)
$out = ($header -join "`n") + "`n" + $out

# 双写:reload 目录(API 热重载)+ applied 目录(计划任务启动路径)
foreach ($p in @($AppliedCfg, $BootCfg)) {
    $d = Split-Path $p -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($p, $out, [Text.Encoding]::UTF8)
}

# 把 SSID 列表写到 state/cng-config.json —— watchdog 下次循环读这个文件
$stateDir = "$Root\state"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

function Convert-CsvToArray([string]$Csv) {
    if (-not $Csv) { return @() }
    return @($Csv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$cngConfig = [ordered]@{
    proxy_ssids = (Convert-CsvToArray $ProxySsids)
    direct_ssids = (Convert-CsvToArray $DirectSsids)
    updatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}
$cngConfig | ConvertTo-Json | Set-Content -Path "$stateDir\cng-config.json" -Encoding UTF8

Write-Output "generated: mode=$Mode if=$EgressIf -> $AppliedCfg"
Write-Output "ssids: proxy=[$proxyCsv] direct=[$directCsv] -> $stateDir\cng-config.json"
