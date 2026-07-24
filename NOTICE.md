# Third-party notice

## LyricFever

- Source: https://github.com/aviwad/LyricFever
- Reviewed revision: `20a44f0fc18a39f28824bf288dc8f368b17b9a99`
- License: MIT
- Use: product and interaction inspiration. This small AppKit implementation is original code and does not copy LyricFever source files.

## LRCLIB

- Website/API: https://lrclib.net
- Source: https://github.com/tranxuanthang/lrclib
- License: MIT
- Use: runtime lookup of synchronized lyrics through `/api/get` and `/api/search`. Responses are cached locally per track.

## Apple Music Lyrics

- Source: https://github.com/Takpap/apple-music-lyrics
- Reviewed revision: `c2d8e75382814af16d882579ea532dae147fda3b`
- License: MIT; included at `ThirdPartyLicenses/AppleLyricsReferences-LICENSES`.
- Use: the Music.app CFNetwork cache-index and strict metadata-matching approach informed the local Apple lyrics provider. This project adds event-driven cache adoption and Mainland Simplified replacement handling.

## MusanovaKit

- Source: https://github.com/rryam/MusanovaKit
- Reviewed revision: `17793dc4ecfb3e8cacd6a117fcbcc273b78501e2`
- License: MIT; included at `ThirdPartyLicenses/AppleLyricsReferences-LICENSES`.
- Use: structured TTML parsing and timed-segment semantics informed the parser. Its privileged-token network client is deliberately not included.

## LyricsOnMacOSBar

- Source: https://github.com/motian566/LyricsOnMacOSBar
- Reviewed release: `v1.8.4` (`a5bd39358eb6483ce2b923548443d25307ecef9f`).
- License: MIT.
- Use: menu-bar source fallback behavior was reviewed. No source code, embedded developer token, or user-token storage was copied.

## MediaRemoteAdapter

- Source: https://github.com/ejbills/mediaremote-adapter
- Reviewed revision: `cf30c4f1af29b5829d859f088f8dbdf12611a046`
- Bundled binary origin: Lyric Fever 3.3; the verified universal framework and bridge script are pinned under `Vendor/MediaRemoteAdapter`.
- SHA-256: framework `2383ebcce6519d32388134cc19ae86973064b61e8841394182acf7bd9dc85a1b`; script `8184ba95ae79e8e0dc26d14ee803c2cf03d87f767649db383ad4c0cc8b2d164b`.
- License note: bridge source files declare the BSD 3-Clause License; the reviewed repository revision does not include a root license file.
- Use: event-driven Apple Music position and seek updates. The pinned adapter is copied into the local app bundle at build time.

## OpenCC dictionaries

- Source: https://github.com/BYVoid/OpenCC
- Version: `1.3.1`
- Reviewed revision: `2f569603954f1cddfdef7b648e71e1aa0d1f47a3`
- License: Apache License 2.0; bundled at `ThirdPartyLicenses/OpenCC-LICENSE`.
- Use: the `tw2sp` conversion-chain data for Taiwan Traditional Chinese to Mainland Simplified Chinese. Only the five required text dictionaries are bundled.

## Apple frameworks

- AppKit, CoreServices, Foundation, and ServiceManagement are system frameworks supplied with macOS.

## GitHub Actions

- [actions/checkout](https://github.com/actions/checkout), version `v7.0.1`, pinned at commit `3d3c42e5aac5ba805825da76410c181273ba90b1`.
- License: MIT.
- Use: read-only repository checkout in the macOS continuous-integration workflow; it is not included in the app.
