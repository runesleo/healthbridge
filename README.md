# HealthBridge

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**English** · [中文](README.zh.md)

Get your Apple Watch data out of the iPhone and onto your own Mac — every day, automatically, encrypted, with no cloud in between.

> **Install with an AI agent:** "Set up HealthBridge on this computer by following the official instructions at https://github.com/runesleo/healthbridge/blob/main/install.md."

## What you get

- **Daily export** — steps, active energy, exercise minutes, heart rate (avg/max), resting heart rate, HRV, walking HR, sleep (total/deep/REM), blood oxygen, respiratory rate, VO₂ max, blood pressure, weight, and every workout (type, duration, kcal, avg/max HR, distance)
- **Full history** — one tap backfills everything in Apple Health, back to your first recorded day
- **Automatic** — iOS wakes the app when the watch syncs a new workout; the Mac stores one JSON file per day
- **A readable archive** — a Markdown file with yearly and monthly summaries plus a list of every workout (English or Chinese)
- **Private by design** — encrypted on the phone, sent only to your Mac on your home Wi-Fi, no third-party server

## How it works

```text
Apple Watch ──sync──▶ iPhone Health ──▶ HealthBridge app ──AES-256-GCM──▶ home Wi-Fi ──▶ Mac receiver
                                                                                         ├─ data/2026-10-22.json …
                                                                                         └─ archive.md
```

Apple does not let anything read watch data over the network. The only door is the Health app on the iPhone, and only an app installed on that phone and approved by you can read it. HealthBridge is that small app, plus a receiver on your Mac.

**One day of output** (`data/2026-10-22.json`, illustrative numbers):

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

## Requirements

- An iPhone with Apple Health data (an Apple Watch for heart rate and workouts)
- A Mac on the same Wi-Fi, with **Xcode** and `xcodegen` (`brew install xcodegen`), Python 3.9+ and `cryptography`
- An Apple ID signed in to Xcode. A free account works, but the app must be reinstalled every 7 days; a paid Apple Developer account ($99/year) signs it for a year
- **Privacy:** nothing leaves your home network. The receiver only accepts payloads sealed with your secret; the secret lives in `~/.config/healthbridge/config.json` (mode 600) and in the git-ignored `ios/HealthBridge/Config.swift`

## Quick start

```bash
git clone https://github.com/runesleo/healthbridge.git
cd healthbridge
python3 -m pip install --user cryptography
python3 mac/healthbridge.py init --team YOUR_TEAM_ID     # secret + config + iOS Config.swift
python3 mac/healthbridge.py serve                        # keep running (run at login: docs/healthbridge.receiver.plist)
cd ios && xcodegen generate && open HealthBridge.xcodeproj
```

In Xcode pick your iPhone and press Run. On the phone: Settings → General → VPN & Device Management → trust your developer account; open HealthBridge → **Allow Health access** → **Sync now** (allow local network). Then **Backfill all history** once.

Check everything at any time:

```bash
python3 mac/healthbridge.py doctor          # or --json
```

## Scheduled sync

iOS wakes the app after new workouts, but only on its own schedule, and the Mac has to be reachable at that moment. For a fixed schedule, use the Shortcuts app: **Automation → New → Time of Day** (say 08:00 and 22:30) and/or **Wi-Fi → your home network**, action **HealthBridge → Sync health data**, set to *Run Immediately*. Each run resends every day since the last accepted sync, so a missed one fills itself in. Health data can't be read while the phone is locked; such runs are skipped and retried on unlock.

## Hook your own analysis

Set `"post_sync_cmd": ["python3", "~/my_health_rules.py"]` in `~/.config/healthbridge/config.json` and the receiver runs it after every successful archive rebuild (timeout 5 min) — e.g. to flag a resting-HR spike or write numbers into your own notes. Restart `serve` after editing the config; the receiver refuses to start if the config is readable by other users.

Sleep is counted for the night window 18:00 → 12:00, so daytime naps are not included.

## Security

- Payload: AES-256-GCM; key = SHA-256 of a 256-bit random secret. The secret itself never travels
- Rejected with 401: anything that does not decrypt, or was sealed more than 10 minutes ago
- Replays cannot overwrite newer data: each day keeps the payload with the latest `sent_at`
- An empty day never replaces a recorded one, and the phone never sends a day it couldn't fully read (locked phone, failed Health query). So if you delete the only sample of a day in Health, the Mac keeps its old copy of that day
- The Mac answers with a sealed ack of the payload's `sent_at`; the phone only counts a sync as delivered when that ack decrypts, so another service answering 200 on the same address can't make it skip days
- Every date is validated (`YYYY-MM-DD`) before anything is written; bodies are capped at 4 MB; stalled connections time out after 15 s; data files are created with mode 600
- The phone only falls back to the Mac's LAN IP when the `.local` name cannot be reached at all, never after an HTTP answer
- Transport is plain HTTP on your LAN; confidentiality and integrity come from the sealed payload

## Verified

| Case | Environment | Result |
|------|-------------|--------|
| Daily sync + full backfill | iPhone 15 Pro Max (iOS 26), MacBook (macOS 26.5), Xcode 26.5, personal team (free Apple ID) | ~10 years of history received in one backfill; archive generated |
| Receiver rejects tampering | local test | valid 200 · plaintext 401 · wrong key 401 · stale 401 · bad date 400 |

## Known limitations (v0.1)

- You build the iPhone app yourself with Xcode; there is no App Store build
- Free Apple ID signing expires after 7 days
- Syncs only when the phone and Mac share a Wi-Fi; days missed while away are re-sent on the next sync, up to 60 days back (older gaps: Backfill all history)
- iOS decides when background delivery runs (at most hourly); opening the app always syncs
- If your phone runs a VPN/proxy app, make sure local network traffic goes direct
- Workout types are mapped from Apple's `HKWorkoutActivityType` numbers; unknown ones show as `#<number>`

## Roadmap

- [x] Sleep, HRV, VO₂ max, blood oxygen, blood pressure (v0.2)
- [ ] Optional HTTPS with a pinned self-signed certificate
- [ ] CSV export and simple charts in the archive

## About the author

*Leo ([@runes_leo](https://x.com/runes_leo)) — AI × Crypto independent builder. Trading on [Polymarket](https://polymarket.com/?via=runes-leo&r=runesleo&utm_source=github&utm_content=healthbridge), building data and content pipelines with Claude Code and Codex.*

*[leolabs.me](https://leolabs.me) — writing · community · open-source tools · indie projects · all platforms.*

*[X Subscription](https://x.com/runes_leo/creator-subscriptions/subscribe) — paid content weekly, or just buy me a coffee 😁*

*Learn in public, Build in public.*

## License

MIT — see [LICENSE](LICENSE).
