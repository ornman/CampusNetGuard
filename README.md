# CampusNetGuard

> Route proxy traffic through a designated gateway — keep your main network clean.

A Windows watchdog for [mihomo](https://github.com/MetaCubeX/mihomo) that binds proxy egress to the right physical interface based on your active network (USB tether / WiFi hotspot / fail-closed).

| | CampusNetGuard | FlClash / clash-verge |
|---|---|---|
| Physical interface auto-binding | ✅ | ❌ |
| Fail-closed safety | ✅ | ❌ |
| Auto-connect to designated hotspot | ✅ | ❌ |
| Node selection / subscription UI | ❌ (use FlClash) | ✅ |

---

## Install

Prerequisites: Windows 10/11, [mihomo](https://github.com/MetaCubeX/mihomo/releases) binary, [FlClash](https://github.com/chen08209/FlClash) for UI.

```powershell
git clone https://github.com/<your-org>/CampusNetGuard.git
cd CampusNetGuard
powershell -NoProfile -ExecutionPolicy Bypass -File admin-setup.ps1  # Run as Administrator
```

The installer cleans route pollution, disables IPv6 on physical NICs, registers two scheduled tasks (`CampusNetGuard-Core` + `CampusNetGuard-Watchdog`), and asks once to confirm your SSID config.

## Configuration

Edit `state/cng-config.json`:

```json
{
  "proxy_ssids": ["vivo X200s", "MyPhone-Hotspot"],
  "direct_ssids": ["guat", "company-wifi"]
}
```

The watchdog re-reads this every 5 seconds. No restart needed.

To reconfigure later: run `scripts\configure-ssids.ps1` (auto-detects + recommends + asks Y to confirm).

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