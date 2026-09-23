# GatewayGuard

> Bind mihomo proxy traffic to a designated gateway — keep your main network clean.

A Windows watchdog for [mihomo](https://github.com/MetaCubeX/mihomo) that auto-switches the proxy egress interface based on your active network. USB tether, WiFi hotspot, or fail-closed — the right physical adapter gets bound, your main network never carries proxy traffic.

| | GatewayGuard | FlClash / clash-verge |
|---|---|---|
| Physical interface auto-binding | ✅ | ❌ |
| Fail-closed safety | ✅ | ❌ |
| Auto-connect to designated hotspot | ✅ | ❌ |
| Node selection / subscription UI | ❌ (use FlClash) | ✅ |

---

## Install

You need Windows 10/11 + the [mihomo](https://github.com/MetaCubeX/mihomo/releases) binary on disk. For node selection / subscription UI, install [FlClash](https://github.com/chen08209/FlClash) and point it at `127.0.0.1:9090`.

```powershell
git clone https://github.com/ornman/GatewayGuard.git
cd GatewayGuard
# Edit configs/config-template.yaml if you want to customize the ruleset
powershell -NoProfile -ExecutionPolicy Bypass -File admin-setup.ps1
```

Right-click the script → "Run as Administrator". It will:

1. Remove leftover default routes from Radmin VPN / Wi-Fi Direct
2. Disable IPv6 on physical network adapters (prevents IPv6 leak)
3. Register two scheduled tasks for auto-start on login (see below)
4. Ask once to confirm your SSID config (smart default based on your current network)

> Note: scheduled tasks are still registered under the legacy names `CampusNetGuard-Core` and `CampusNetGuard-Watchdog` for backward compatibility. New installs create them with the same names. Use `scripts\net-status.ps1` to check status.

## Configuration

Edit `state/cng-config.json`:

```json
{
  "proxy_ssids": ["my-hotspot"],
  "direct_ssids": ["my-campus-wifi"]
}
```

Replace with your real SSID names. The watchdog re-reads this every 5 seconds. No restart needed.

To reconfigure later: run `scripts\configure-ssids.ps1` (auto-detects current network + recommends + asks Y to confirm).

## How it works

```
USB tether plugged in    → bind proxy to USB NIC
WiFi SSID matches config → bind proxy to WLAN NIC
Otherwise                → bind to NO-EGRESS (proxy fails at OS level)
```

Watchdog runs every 5s. When mode changes, it regenerates `mihomo config.yaml` and calls `PUT /configs?force=true`. FlClash reflects the new state automatically.

## Files

```
admin-setup.ps1           # installer
configs/                 # mihomo config template
scripts/
  watchdog.ps1           # 156-line state machine
  make-config.ps1        # template → running config
  configure-ssids.ps1    # SSID setup (auto-detect + confirm)
  common.ps1.example     # public template (real one is gitignored)
  cleanup-*.ps1
  net-status.ps1
state/                   # runtime data (gitignored)
```

See [docs/adr/](docs/adr/) for design decisions.

## License

[MIT](LICENSE)