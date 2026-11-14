# HealthBridge

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**English** · [中文](README.zh.md)

Get your Apple Watch data out of the iPhone and onto a paired Mac receiver with encrypted sync and optional automatic triggers — no HealthBridge-operated cloud relay.

> **Install with an AI agent:** "Set up HealthBridge on this computer by following the official instructions at https://github.com/runesleo/healthbridge/blob/main/install.md."

> **Beta availability:** A TestFlight build is available to invited testers, but neither a public App Store install path nor a public TestFlight enrollment link has been verified. See [installation paths](install.md) before installing.

## What you get

- **Daily export** — steps, active energy, exercise minutes, heart rate (avg/max), resting heart rate, HRV, walking HR, sleep (total/deep/REM), blood oxygen, respiratory rate, VO₂ max, blood pressure, weight, and every workout (type, duration, kcal, avg/max HR, distance)
- **Daily routine** — bedtime, wake time, night wake-ups, water, time in daylight and mood (State of Mind, iOS 18+) in each day's file; a **Today** screen and an **Apple Watch** voice note log water, meals, mood and check-ins with one tap or one sentence
- **Full history** — one tap backfills everything in Apple Health, back to your first recorded day
- **Automatic** — iOS wakes the app when the watch syncs a new workout; the Mac stores one JSON file per day
- **A readable archive** — a Markdown file with yearly and monthly summaries plus a list of every workout (English or Chinese)
- **Health context for any AI** — `context` prints a one-page Markdown summary (baselines, last 7 days vs baseline, unusual days, long-term yearly trend, training load) to paste into ChatGPT, Claude or any other AI, local or cloud
- **Private by design** — health payloads are encrypted on the phone and sent to the configured receiver (normally your Mac on the same Wi-Fi), without a HealthBridge cloud relay. TestFlight diagnostics are separate; see below

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

- An iPhone with Apple Health data (iOS 17.0+ for the invited TestFlight build); a compatible Apple Watch is needed for watch features (the source target is watchOS 10.0+)
- A Mac reachable from the iPhone, with Python 3.9+ and `cryptography` for the receiver
- **Only if building the iPhone app yourself:** Xcode, `xcodegen` (`brew install xcodegen`) and an Apple ID signed in to Xcode. Free-account signing may require reinstalling after 7 days
- **Health-data privacy:** the receiver accepts payloads encrypted with a shared secret stored in `~/.config/healthbridge/config.json` (mode 600) and, for self-built apps, the git-ignored `ios/HealthBridge/Config.swift`. The network destination is configurable, so keep it on a trusted network. Watch voice notes are transcribed on the iPhone

**TestFlight privacy is separate:** Apple collects beta crash diagnostics, usage information, tester details (including email address) and submitted feedback; this information may be linked to the tester and shared with the developer. Check the preconfigured receiver address **before granting Health access**; it may not be your own Mac. Do not include sensitive health values in feedback or screenshots. See [Apple's TestFlight privacy information](https://testflight.apple.com/).

## Installation paths

| Who | Install the iPhone / Watch app | Mac receiver |
|-----|-------------------------------|--------------|
| Invited TestFlight tester | Open your invitation on an iPhone running iOS 17.0+, then accept and install in TestFlight. If available, install the companion Watch app from TestFlight → App Details | Requires a receiver already provisioned with the **same secret as that beta build**; installing TestFlight alone does not pair a new Mac |
| Self-builder | Follow the Xcode steps below to sign and install your own build | `init` creates matching Mac/iPhone settings; this is the supported self-service end-to-end path |
| Visitor without an invitation | No public prebuilt install is currently documented; you may build from source | Not automatically installed |

The TestFlight app lets you edit the receiver URL, but its encryption secret is compiled into the build. Running `init` on a different Mac generates a new secret and **does not pair that Mac with the already-distributed beta**. See [install.md](install.md) for the steps and first-sync checks.

## Quick start — build from source with Xcode

```bash
git clone https://github.com/runesleo/healthbridge.git
cd healthbridge
python3 -m pip install --user cryptography
python3 mac/healthbridge.py init                        # secret + config + iOS Config.swift; --team TEAM_ID is optional
cd ios && xcodegen generate && open HealthBridge.xcodeproj && cd ..
```

In a **separate Terminal** from the repository root, run `python3 mac/healthbridge.py serve` and leave it running (start-at-login template: `docs/healthbridge.receiver.plist`). In Xcode pick your iPhone and press Run. On the phone: Settings → General → VPN & Device Management → trust your developer account if prompted; open HealthBridge → **Allow Health access** → **Sync now** (allow local network). Confirm delivery on the Mac before running **Backfill all history** once.

Check everything at any time:

```bash
python3 mac/healthbridge.py doctor          # or --json
```

The `doctor` command also checks Xcode, `xcodegen` and the locally generated `Config.swift`; its overall `READY` flag is not a TestFlight-only receiver check. A first successful sync needs a confirmed iPhone send plus a newly written dated JSON file on the Mac; see [install.md](install.md).

## Scheduled sync

iOS wakes the app after new workouts, but only on its own schedule, and the Mac has to be reachable at that moment. For a fixed schedule, use the Shortcuts app: **Automation → New → Time of Day** (say 08:00 and 22:30) and/or **Wi-Fi → your home network**, action **HealthBridge → Sync health data**, set to *Run Immediately*. Each run resends every day since the last accepted sync, so a missed one fills itself in. Health data can't be read while the phone is locked; such runs are skipped and retried on unlock.

## Ask an AI about your health

```bash
python3 mac/healthbridge.py context | pbcopy   # then paste into any AI chat
python3 mac/healthbridge.py context --days 180 --out ~/health-context.md
```

Add what the watch can't know — age, conditions, medication, recent lab results, what you're trying to change — to `~/.config/healthbridge/profile.md` (or set `profile_path` in the config); it is included at the top. Nothing is sent anywhere by this command: you decide which AI sees the text.

## Hook your own analysis

Set `"post_sync_cmd": ["python3", "~/my_health_rules.py"]` in `~/.config/healthbridge/config.json` and the receiver runs it after every successful archive rebuild (timeout 5 min) — e.g. to flag a resting-HR spike or write numbers into your own notes. Restart `serve` after editing the config; the receiver refuses to start if the config is readable by other users.

Sleep is counted for the night window 18:00 → 12:00, so daytime naps are not included.

## Security

- Payload: AES-256-GCM; key = SHA-256 of a 256-bit random secret. The secret itself never travels
- Rejected with 401: anything that does not decrypt, or was sealed more than 10 minutes ago
- Replays cannot overwrite newer data: each day keeps the payload with the latest `sent_at`
- An empty day never replaces a recorded one, and the phone never sends a day it couldn't fully read (locked phone, failed Health query). So if you delete the only sample of a day in Health, the Mac keeps its old copy of that day
- Meals, check-ins and notes live only in the app that logged them (90 days on the phone). When a later sync of an earlier day no longer has some of them (reinstall, new phone, backfill), the Mac keeps its copy. Today's entries follow the phone, so swipe-to-undo still reaches the Mac
- The Mac answers with a sealed ack of the payload's `sent_at`; the phone only counts a sync as delivered when that ack decrypts, so another service answering 200 on the same address can't make it skip days
- Every date is validated (`YYYY-MM-DD`) before anything is written; bodies are capped at 4 MB; stalled connections time out after 15 s; data files are created with mode 600
- The phone only falls back to the Mac's LAN IP when the `.local` name cannot be reached at all, never after an HTTP answer
- Transport is HTTP to the configured receiver address (normally on your LAN); confidentiality and integrity come from the sealed payload. The Mac receiver listens on all interfaces by default, so do not expose its port to the public internet

## Verified

| Case | Environment | Result |
|------|-------------|--------|
| Daily sync + full backfill | iPhone 15 Pro Max (iOS 26), MacBook (macOS 26.5), Xcode 26.5, personal team (free Apple ID) | ~10 years of history received in one backfill; archive generated |
| Receiver rejects tampering | local test | valid 200 · plaintext 401 · wrong key 401 · stale 401 · bad date 400 |
| Logged entries survive a reinstall or backfill | local test: `python3 mac/test_receiver.py` | earlier days keep meals/check-ins/notes a resend no longer carries · today's undo still reaches the Mac · concurrent posts keep the newest |

## Known limitations (v0.1)

- TestFlight requires an invitation, and an invited beta is not yet self-service-pairable with an arbitrary new Mac; no public App Store build is currently documented
- Free Apple ID signing for a self-built app expires after 7 days
- Sync requires a reachable receiver, normally on the same Wi-Fi; missed days are re-sent on the next successful sync, up to 60 days back (older gaps: Backfill all history)
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
