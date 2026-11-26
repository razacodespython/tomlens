# TomLens

A view-only macOS menu-bar trading tutor: it watches one picked Tradovate window, listens while you hold a push-to-talk hotkey, answers out loud, and draws hints on a click-through overlay. It never clicks, types, or places orders.

Status and constraints: see [AGENTS.md](AGENTS.md). Install steps: [INSTALL.md](INSTALL.md).

Push-to-talk is **Control+Option+Z**. TomLens starts off until you flip the switch.

## Signing

CI builds an ad-hoc signature (`codesign -s -`) and then replaces the designated requirement with the bundle identifier:

```bash
codesign --force --deep --sign - --options runtime \
  --entitlements leanring-buddy/leanring-buddy.entitlements \
  -r 'designated => identifier "com.razacodespython.tomlens"' \
  TomLens.app
```

A plain ad-hoc signature pins Screen Recording to the code directory hash, so every update looks like a new app and macOS shows the grant as revoked. An identifier requirement stays the same across builds, so the existing toggle can keep working without a paid Apple Developer certificate and without storing a private key. CI prints `codesign -d -r-` and fails if that requirement still mentions `cdhash`.

## Attribution

TomLens is a fork of [Clicky](https://github.com/farzaa/clicky) by Farza (commit `e71105c`), used under the MIT License. See [LICENSE](LICENSE).
