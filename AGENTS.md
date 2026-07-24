# Project context

## Overview

`Lyric Fever Scroll` is a local macOS menu bar client for full-line synchronized Apple Music lyrics, with separate Chinese and Latin font settings.

## Architecture and data flow

- `AppleMusicClient` reads the current track and position through Apple Events.
- `AppleMusicCacheLyricsProvider` reads Music.app's local CFNetwork catalog cache, strictly matches title/artist/duration, and parses official TTML. A short-lived FSEvents stream adopts cache writes after track changes without polling, blocked directory descriptors, or account tokens.
- `LyricsProvider` races that Apple-local source against LRCLIB fallback, normalizes metadata before matching, and writes at most 500 verified lyric documents through one utility queue.
- `LRCParser` parses timestamps and converts Traditional Chinese to Simplified Chinese.
- `MainlandChineseConverter` applies the fixed OpenCC 1.3.1 `tw2sp` dictionary chain, followed by narrowly scoped Mainland-preference and lyric typo corrections.
- `AppDelegate` receives event-driven seek updates through the bundled MediaRemoteAdapter, reconciles Music.app on a serial background queue after wake and every 15 seconds otherwise, and schedules a zero-tolerance one-shot timer for the next lyric boundary.
- `MediaRemotePositionStream` restarts a failed adapter with exponential backoff from 1 to 30 seconds and resets the delay after a valid event.
- `AttributedLyricFormatter` fits the whole line into at most 420pt and selects fonts per character.
- `SettingsStore.syncOffset` controls the live lyric offset from -1.5s to +1.5s; the preserved default is +0.65s.
- `PlaybackDiagnostics` keeps only the latest 100 important events in memory; the menu can copy them for troubleshooting.
- `SMAppService.mainApp` controls the optional launch-at-login menu item on macOS 13 or later.

## Runbook

- Build: `./scripts/build.sh`
- Logic tests: use the commands in `README.md`.
- CI: `.github/workflows/ci.yml` runs the logic tests, app build, signature verification, and vendored-adapter checksum on macOS.
- The built app is `build/Lyric Fever Scroll.app`.

## Constraints

- Keep resource use low: no display-link or high-frequency animation/polling.
- Never truncate a lyric line; shrink it to fit.
- The Music cache schema is private and may change after macOS updates; keep LRCLIB as the no-token fallback and verify both source paths.
- MediaRemoteAdapter is the only bundled executable runtime component; its verified universal framework and bridge script are pinned under `Vendor/MediaRemoteAdapter` and documented in `NOTICE.md`.
- Keep Simplified Chinese conversion enabled.
