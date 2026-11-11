# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Daily routine in each day's file: `sleep_start` / `sleep_end` (fell asleep, woke up), `awake_count` / `awake_min` (awake stretches in the night), `water_ml`, `daylight_min` (time in daylight) and `moods` (Health → State of Mind, iOS 18+)
- **Today** screen: one tap for a glass of water, a meal, a mood or a check-in (woke up, meds, outside, exercise, bed); swipe to undo. Water and mood are saved to Apple Health; meals, check-ins and notes ride along with the day's sync
- **Quick log**: type or dictate one line ("had lunch, noodles", "喝了两杯水"); water, meals and check-ins in it are logged and the line is kept as a note. Also as Shortcuts/Siri actions, with **Log a glass of water**
- **Apple Watch app**: opening it, or its watch-face complication, starts a voice note; the iPhone turns it into text on the device and logs it like a quick-log line. The watch then shows what was heard and what was logged, so a misheard note is caught right away
- `context` command: a Markdown health background for pasting into any AI — 7/30/90-day averages with change vs baseline, unusual days in the last two weeks (≥2 SD), yearly long-term trend, training by type and weekly load; includes your own `profile.md` notes. Today's still-growing activity totals are left out
- **Sync health data** action for the Shortcuts app: a personal automation (a time of day, or joining your home Wi-Fi) can sync without opening the app
- Receiver `extra_ports` config: listen on more ports, e.g. for a Tailscale address where `port` is taken
- Opening the app syncs; unlocking the phone after a locked background run syncs

### Fixed
- A reinstall, a new phone or **Backfill all history** no longer wipes earlier days' meals, check-ins and notes on the Mac. They live only in the app that logged them (90 days), so the receiver keeps its copy of any such entry a later sync of an earlier day no longer carries; today's entries still follow the phone, so swipe-to-undo reaches the Mac. Local test: `python3 mac/test_receiver.py`
- The phone only counts a sync as delivered when the Mac's sealed ack decrypts to its own `sent_at`; a plain 200 from anything else at that address no longer makes it skip days
- Overlapping syncs (unlock + open, two observers) share one send, syncs triggered during a backfill are skipped (it already covers today), and the receiver serializes day-file writes, so an older payload can no longer overwrite a newer one
- Workout distance for cycling and swimming (was walking/running only)
- `init --force` rotates only the secret (into `secret_file` if set) and keeps the rest of the config
- A failed send no longer leaves a gap: each run resends every day since the last sync the Mac accepted (up to 60 days)
- Runs while the phone is locked are skipped instead of sending empty days that overwrote good data on the Mac. This now also holds when the phone locks mid-read, when a Health query fails, and during backfill; the receiver also refuses to replace a recorded day with an empty one

### Thanks
- @medy-Liao0530 for #1: the sealed ack, the empty-day guard, reads that fail instead of coming back empty (locked phone, failed Health query, backfill), serialized day-file writes, cycling/swimming distance and `init --force`

### Note
- Update the Mac receiver and the iPhone app together: a new app treats an old receiver's plain `ok` as unconfirmed, keeps resending and stops backfill after the first chunk. Tap **Allow Health access** again to grant cycling/swimming distance

## [0.2.0] - 2026-10-22

### Added
- HRV (SDNN), walking heart rate, sleep (total/deep/REM, overlapping sources merged), blood oxygen, respiratory rate, VO₂ max, blood pressure, weight
- Archive: HRV and sleep columns in yearly/monthly summaries
- `post_sync_cmd` config hook: run your own script after each archive rebuild

### Note
- Existing installs: tap **Allow Health access** again to grant the new types, then **Backfill all history** to fill them in

## [0.1.0] - 2026-10-22

### Added
- iOS app: reads steps, active energy, exercise minutes, heart rate, resting heart rate and workouts from Apple Health; background delivery on new workouts; full-history backfill in 30-day chunks
- AES-256-GCM sealed payloads; fallback to the Mac's LAN IP only on transport errors
- Mac CLI `mac/healthbridge.py`: `doctor`, `init`, `serve`, `archive`
- Receiver: 10-minute freshness window, per-day monotonic `sent_at`, date validation, 4 MB body cap
- Markdown archive with yearly/monthly summaries and a workout list, English or Chinese
