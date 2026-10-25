# HealthBridge

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[English](README.md) · **中文**

把 Apple Watch 的数据从 iPhone 里拿出来，每天自动、加密地存到你自己的 Mac 上，中间不经过任何云。

> **让 AI 帮你装：**「按照 https://github.com/runesleo/healthbridge/blob/main/install.md 的官方说明，在这台电脑上安装 HealthBridge。」

## 你能得到什么

- **每天自动导出**：步数、活动消耗、锻炼分钟、心率（平均/最高）、静息心率、HRV、步行心率、睡眠（总时长/深睡/REM）、血氧、呼吸频率、最大摄氧量、血压、体重，以及每一次训练的类型、时长、消耗、心率和距离
- **完整历史**：点一下就把「健康」里所有历史补传过来，一直回到你有记录的第一天
- **不用管它**：手表同步了新训练，iOS 会在后台叫醒 App 自动发；Mac 按天存成 JSON
- **一份能直接看的档案**：Markdown 文件，按年、按月汇总，外加每次训练的明细，中英文可选
- **隐私优先**：手机上先加密，只发到家里 Wi-Fi 下你自己的 Mac，不经过任何第三方服务器

## 它是怎么工作的

```text
Apple Watch ──同步──▶ iPhone「健康」──▶ HealthBridge App ──AES-256-GCM──▶ 家里 Wi-Fi ──▶ Mac 接收端
                                                                                        ├─ data/2026-10-22.json …
                                                                                        └─ archive.md
```

苹果不允许任何东西通过网络直接读手表数据。唯一的出口是 iPhone 上的「健康」，而且只有装在这台手机上、你授权过的 App 能读。HealthBridge 就是这个小 App，再加上 Mac 上的一个接收端。

**一天的输出**（`data/2026-10-22.json`，数字为示意）：

```json
{
  "date": "2026-10-22",
  "steps": 8000,
  "active_kcal": 600.0,
  "exercise_min": 60,
  "heart_rate_avg": 75,
  "heart_rate_max": 150,
  "resting_hr_avg": 55,
  "workouts": [{ "type": 48, "minutes": 60.0, "active_kcal": 400, "hr_avg": 120, "hr_max": 150, "km": 3.0 }]
}
```

## 需要什么

- 一台有「健康」数据的 iPhone（心率和训练需要 Apple Watch）
- 同一 Wi-Fi 下的一台 Mac：装好 **Xcode**、`xcodegen`（`brew install xcodegen`）、Python 3.9+ 和 `cryptography`
- 在 Xcode 里登录 Apple ID。免费账号能用，但每 7 天要重装一次；付费开发者账号（99 美元/年）一次签一年
- **隐私：** 数据不出家里的网络。接收端只收用你的密钥加密过的数据；密钥存在 `~/.config/healthbridge/config.json`（权限 600）和不进 git 的 `ios/HealthBridge/Config.swift`

## 快速开始

```bash
git clone https://github.com/runesleo/healthbridge.git
cd healthbridge
python3 -m pip install --user cryptography
python3 mac/healthbridge.py init --team 你的TeamID   # 生成密钥、配置和 iOS 的 Config.swift
python3 mac/healthbridge.py serve                    # 保持运行（开机自启见 docs/healthbridge.receiver.plist）
cd ios && xcodegen generate && open HealthBridge.xcodeproj
```

在 Xcode 里选你的 iPhone，点运行。手机上：设置 → 通用 → VPN 与设备管理 → 信任你的开发者账号；打开 HealthBridge → **授权健康数据** → **立即同步**（允许本地网络），再点一次 **补传全部历史**。

随时自检：

```bash
python3 mac/healthbridge.py doctor          # 或加 --json
```

## 定时同步

新训练后 iOS 会叫醒 App，但时间由系统定，而且那一刻 Mac 得连得上。想要固定时间同步，用「快捷指令」：**自动化 → 新建 → 特定时间**（比如 08:00 和 22:30）和/或 **无线局域网 → 家里的网络**，操作选 **HealthBridge → Sync health data**，设为「立即运行」。每次都会把上次成功之后的每一天重发一遍，漏一次会自动补上。手机锁屏时读不到健康数据，这种情况会跳过，解锁后再同步。

## 接上你自己的分析

在 `~/.config/healthbridge/config.json` 里加 `"post_sync_cmd": ["python3", "~/my_health_rules.py"]`，接收端每次成功更新档案后就会跑它（超时 5 分钟），比如提醒静息心率异常升高，或把数据写进你自己的笔记。改完配置要重启 `serve`；配置文件如果别的用户也能读写，接收端会拒绝启动。

睡眠按前一晚 18:00 到当天 12:00 统计，白天午睡不算在内。

## 安全设计

- 数据用 AES-256-GCM 加密，钥匙是一个 256 位随机密钥的 SHA-256，密钥本身从不在网上传
- 解不开的、或 10 分钟前封装的数据包，一律 401 拒收
- 重放的旧包覆盖不了新数据：每一天只保留 `sent_at` 最新的那份
- 空的一天不会覆盖已有记录；手机读不全的日子（锁屏、健康查询出错）不会发出去。所以在健康 App 里删掉某天仅有的数据后，Mac 上那天会保留旧的
- Mac 收到后回一个用同一把钥匙封装的 `sent_at` 确认，手机解得开才算发送成功；同一地址上别的服务回 200 也不会让它跳过这些天
- 写入前先校验所有日期（`YYYY-MM-DD`），单次请求上限 4 MB，卡住不发数据的连接 15 秒断开；数据文件权限为 600
- 手机只在完全连不上 `.local` 名字时才改用 Mac 的局域网 IP，收到任何 HTTP 回应后都不会改发别处
- 局域网上走明文 HTTP；保密和防篡改靠的是加密封装

## 已验证

| 场景 | 环境 | 结果 |
|------|------|------|
| 每日同步 + 完整补传 | iPhone 15 Pro Max（iOS 26）、MacBook（macOS 26.5）、Xcode 26.5、个人团队（免费 Apple ID） | 一次补传收到约 10 年历史，档案生成成功 |
| 接收端拒收篡改 | 本机测试 | 正确 200 · 明文 401 · 钥匙错 401 · 过期 401 · 日期非法 400 |

## 已知限制（v0.1）

- iPhone App 需要你自己用 Xcode 编译安装，没有 App Store 版本
- 免费 Apple ID 的签名 7 天过期
- 只有手机和 Mac 在同一 Wi-Fi 时才会同步；不在家的日子会在下次同步时补上，最多往回补 60 天（更早的缺口用「补传全部历史」）
- 后台什么时候跑由 iOS 决定（最多每小时一次）；打开 App 一定会同步
- 手机开着 VPN / 代理 App 的话，要让局域网流量走直连
- 训练类型按苹果的 `HKWorkoutActivityType` 编号对照；不认识的显示为 `#编号`

## 路线图

- [x] 睡眠、HRV、最大摄氧量、血氧、血压（v0.2）
- [ ] 可选 HTTPS（自签证书 + 固定指纹）
- [ ] 档案里加 CSV 导出和简单图表

## 关于作者

*Leo（[@runes_leo](https://x.com/runes_leo)）— AI × Crypto 独立构建者。在 [Polymarket](https://polymarket.com/?via=runes-leo&r=runesleo&utm_source=github&utm_content=healthbridge) 做量化，用 Claude Code 和 Codex 搭数据与内容管线。*

*[leolabs.me](https://leolabs.me) — 写作 · 社群 · 开源工具 · 独立项目*

*[X 订阅](https://x.com/runes_leo/creator-subscriptions/subscribe) — 付费内容周刊*

*Learn in public, Build in public.*

## 许可证

MIT，见 [LICENSE](LICENSE)。
