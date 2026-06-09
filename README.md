# Claude Usage Monitor

macOS 菜单栏小工具，监控本机 Claude Code 用量。

- **5 小时窗口 / 周 / 周（Sonnet）** 使用率与剩余百分比 — 直接调 `claude -p "/usage"` 拿 Anthropic 官方算的数字，不需要猜套餐额度
- **今日 / 近 7 天 token** 数与缓存命中明细 — 扫 `~/.claude/projects/*/*.jsonl` 本地聚合
- 完全离线、无需登录、独立 .app

## 构建

```bash
./build_app.sh
open build/ClaudeUsageMonitor.app
```

安装到 Launchpad：

```bash
cp -R build/ClaudeUsageMonitor.app /Applications/
```

## 使用

- 启动后在菜单栏右侧出现 `5h XX%` 文字图标
- **单击图标** 弹出面板：三档使用率 + 进度条 + 重置时间，下面是 token 明细
- 面板右上角 ⚙️ 进入设置：刷新间隔（30s / 1m / 2m / 5m）、菜单栏显示哪一档、显示哪些明细
- 面板右上角 ⋯ → 退出

## 依赖

- macOS 13+
- Swift 5.9+（系统自带 Xcode 即可）
- 本机已安装 `claude` CLI，且能在 PATH 找到（`/opt/homebrew/bin/claude` 等）

## 数据来源说明

- **百分比**：直接 spawn `claude -p "/usage"`，解析三行输出。无需配套餐档位，Anthropic 自己算
- **token 明细**：读 `~/.claude/projects/<encoded>/*.jsonl`，对 `type == "assistant"` 条目按 `requestId` 去重，过滤 streaming 占位（usage 全 0 的条目）
- 缓存命中率 = `cache_read / (cache_read + cache_creation)`

## 项目结构

```
Sources/ClaudeUsageMonitor/
  main.swift            # AppDelegate + 菜单栏 + Popover
  UsageService.swift    # spawn claude /usage 解析
  JSONLAggregator.swift # 扫 JSONL 聚合 token
  UsageStore.swift      # ObservableObject + 定时刷新
  Settings.swift        # 用户设置 (UserDefaults)
  PopoverView.swift     # SwiftUI 面板 + 设置
  Formatters.swift      # 数字格式化
```
