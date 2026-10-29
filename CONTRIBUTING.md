# Contributing to AllDrop

Thanks for helping! AllDrop is free and will stay free.

## Getting started

```bash
git clone https://github.com/AndrewXuTurtle/AllDrop.git
cd AllDrop
swift test               # protocol + loopback transfer tests
./scripts/build-app.sh   # builds build/AllDrop.app
open build/AllDrop.app
```

Requires macOS 14+ and Xcode 16.3+ (Swift 6.1+).

## Project layout

| Path | What it is |
| --- | --- |
| `Sources/QuickShare` | The Quick Share protocol: mDNS discovery, UKEY2 key exchange, encrypted channel, payload transfer. No UI. |
| `Sources/AllDrop` | The macOS app (menu-bar icon, windows, settings). |
| `Tests/QuickShareTests` | Unit tests and loopback tests that run a real transfer between two in-process instances. |
| `Protos` | Google's `.proto` files. Regenerate Swift with `scripts/gen-protos.sh` (needs `brew install swift-protobuf`). |

## Guidelines

- Add a test for protocol changes. The loopback tests in `LoopbackTests` make it easy to cover a whole transfer.
- Keep the `QuickShare` library free of AppKit/SwiftUI so it can be reused.
- Real-device reports are gold: include phone model, One UI/Android version, and direction.
- Debugging against Android: `adb logcat | grep -i nearby` is very verbose and usually tells you what the phone disliked.
