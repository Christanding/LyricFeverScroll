# Project context

## Overview

`Lyric Fever Scroll` is a local macOS menu bar client for full-line synchronized Apple Music lyrics, with separate Chinese and Latin font settings.

## Architecture and data flow

- `AppleMusicClient` reads the current track and position through Apple Events.
- `LyricsProvider` normalizes metadata to Simplified Chinese before matching and keeps at most 500 raw-LRC cache files. Manual reload bypasses cache; mismatched-duration cache entries are rejected.
- `LRCParser` parses timestamps and converts Traditional Chinese to Simplified Chinese.
- `MainlandChineseConverter` applies the fixed OpenCC 1.3.1 `tw2sp` dictionary chain, followed by narrowly scoped Mainland-preference and lyric typo corrections.
- `AppDelegate` receives event-driven seek updates through the bundled MediaRemoteAdapter, reconciles immediately after wake and every 15 seconds otherwise, and schedules a zero-tolerance one-shot timer for the next lyric boundary.
- `MediaRemotePositionStream` restarts a failed adapter with exponential backoff from 1 to 30 seconds and resets the delay after a valid event.
- `AttributedLyricFormatter` fits the whole line into at most 420pt and selects fonts per character.
- `SettingsStore.syncOffset` controls the live lyric offset from -1.5s to +1.5s; the preserved default is +0.65s.
- `PlaybackDiagnostics` keeps only the latest 100 important events in memory; the menu can copy them for troubleshooting.

## Runbook

- Build: `./scripts/build.sh`
- Logic tests: use the commands in `README.md`.
- The built app is `build/Lyric Fever Scroll.app`.

## Constraints

- Keep resource use low: no display-link or high-frequency animation/polling.
- Never truncate a lyric line; shrink it to fit.
- MediaRemoteAdapter is the only non-system runtime component; its verified universal framework and bridge script are pinned under `Vendor/MediaRemoteAdapter` and documented in `NOTICE.md`.
- Keep Simplified Chinese conversion enabled.
