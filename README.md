# DropFrame

DropFrame is a personal SwiftUI video library for iPhone and iPad. Paste a page
or direct media URL, inspect the available qualities, choose a collection, and
download the file into the app's local library.

## What is implemented

- Original editorial SwiftUI design with an app-specific generated hero asset
- Automatic on-device extraction for direct files and webpage media
- WebKit fallback for video players that reveal media only after JavaScript runs
- MP4/MOV/M4V downloads and native offline HLS packages saved on the iPhone
- Quality picker that adapts to the formats actually returned
- Download queue and persistent local JSON library
- Custom folders/collections
- Custom `AVPlayerLayer` player with fit/fill, ±10 seconds, scrubbing, speed,
  autoplay, AirPlay route picking, and full-screen controls
- Native Liquid Glass treatment on iOS 26 with a material fallback on iOS 17–18

## Open and run

The generated project targets iOS 17 or later.

```bash
xcodegen generate
open DropFrame.xcodeproj
```

Select your personal development team in Xcode, choose an iPhone, and run.
No Python process, `start.command`, Mac server, address, or token is required.

## How resolution works

DropFrame runs on the iPhone without a Mac or server. It first inspects the
page response for standard video sources. If those are created by JavaScript,
it loads the page with WebKit and inspects the actual video elements and media
resources. Cookies and the page referrer are retained for downloads. Adaptive
HLS streams are saved with `AVAssetDownloadURLSession` as Apple-managed offline
media packages and are played directly by DropFrame without unreliable
HLS-to-MP4 conversion.

Source discovery is strategy-based. Shared HTML, WebKit, HLS expansion, and
format validation stay in the main resolver. Player-specific JavaScript
inspection lives in `EmbeddedPlayerSourceStrategy.swift`, so another discovery
strategy can be added later without changing working download logic.

Some websites intentionally hide URLs behind site-specific code, separate
audio and video into DASH tracks, require an authenticated browser session, or
use DRM. Those cases cannot be guaranteed by a standalone native app and
DropFrame does not bypass DRM. Only download media you have permission to save.
