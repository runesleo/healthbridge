# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `context` command: a Markdown health background for pasting into any AI — 7/30/90-day averages with change vs baseline, unusual days in the last two weeks (≥2 SD), yearly long-term trend, training by type and weekly load; includes your own `profile.md` notes. Today's still-growing activity totals are left out
- **Sync health data** action for the Shortcuts app: a personal automation (a time of day, or joining your home Wi-Fi) can sync without opening the app
- Receiver `extra_ports` config: listen on more ports, e.g. for a Tailscale address where `port` is taken
- Opening the app syncs; unlocking the phone after a locked background run syncs

### Fixed
- A failed send no longer leaves a gap: each run resends every day since the last sync the Mac accepted (up to 60 days)
- Runs while the phone is locked are skipped instead of sending empty days that overwrote good data on the Mac

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
