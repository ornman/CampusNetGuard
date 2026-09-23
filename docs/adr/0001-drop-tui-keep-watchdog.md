# ADR-0001: 砍掉自研 TUI,看门狗为唯一原创,UI 交给 FlClash

- **状态**:Accepted
- **日期**:2026-09-23
- **决策者**:项目维护者

## 背景

CNG v1 自研了 Rust + ratatui 终端客户端(ui/),号称 "mihomo 仪表盘 + 节点选择 + 订阅解析",定位是替代 FlClash 的 GUI。

问题:
1. **重复造轮子**:FlClash 已有的功能(节点选择 / 订阅解析 / 流量图)被重新实现一份
2. **代码膨胀**:50+ Rust 文件,只为了展示 mihomo 已经在 API 上吐的数据
3. **维护成本**:Rust toolchain + 50 文件 vs FlClash 一键装
4. **用户混淆**:CNG 的真实价值("物理分流"安全模型)被 UI 噪音淹没

## 决策

**v2 架构**:砍掉 ui/ 整个子项目,UI 责任交给现成的 FlClash / clash-verge / zashboard。

CNG 只保留 3 件事:
- `scripts/watchdog.ps1` —— **唯一原创**,5 秒状态机决定代理出口网卡
- `scripts/make-config.ps1` —— mihomo 配置模板生成
- `scripts/admin-setup.ps1` —— 一次性安装

## 取舍

### ✅ 收益
- **代码量**:从 50 个 Rust 文件 + 4 个 PS 脚本,缩到 **5 个 PS 脚本**
- **维护**:不用懂 Rust,所有代码 PowerShell + YAML
- **功能**:FlClash 已经能做的(节点选择 / 订阅 / 流量 / 规则编辑)全白嫖
- **用户认知**:CNG = "mihomo 看门狗",清晰;不是 "mihomo 仪表盘第 N 号选手"

### ⚠️ 代价
- 用户要装 FlClash 看 UI(多一个软件)
- 不能跟 CNG 自带 mihomo 同跑(端口冲突),需要关掉 mihomo 计划任务,让 FlClash 自带 mihomo 跑
- v1 用户如果用过 TUI,迁移需要适应

### ❌ 不做的事
- 不复活 TUI
- 不做自己的节点选择 UI
- 不做自己的订阅解析
- 不跨平台(只 Windows)

## 后果

1. **ui/ 入 .gitignore**(整体私有,本地参考用)
2. **README 重定位**:从 "TUI 客户端" → "mihomo 看门狗"
3. **AGENTS.md / REQUIREMENTS.md 合并到 README**(单一入口)
4. **scripts/install.ps1 弃用**(原本为 TUI 写默认配置)
5. **admin-setup.ps1 待增强**:需要新增 SSID 配置提示(替代原 TUI wizard)

## 后续行动

- [x] README/AGENTS/REQUIREMENTS 重写
- [x] ui/ 入 .gitignore + 撤回 git 跟踪
- [x] config-template.yaml 占位化 secret(make-config.ps1 注入)
- [x] admin-setup.ps1 增加 SSID 配置提示
- [x] 新增 `scripts/configure-ssids.ps1`(用户交互式 / 命令行两种用法)
- [x] 新增 `scripts/cng-config.example.json` 样板
- [ ] 实战验证:装 FlClash + 关 CNG mihomo 任务,确认 UI 正常(用户已确认)
- [ ] 若验证通过,删 scripts/install.ps1 + scripts/verify-cng-tui.ps1

## 验证标准

- `scripts/watchdog.ps1` ≤ 200 行(目前 156 行)✓
- `admin-setup.ps1` 能引导用户填完 SSID 后开机自启 ✓
- FlClash 装上能连 `127.0.0.1:9090` 看到 mihomo 数据 ✓(用户已验证)
- 改 SSID → 5s 内看门狗响应 → mihomo 热重载 → FlClash 看到节点变化
