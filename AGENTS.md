# TomLens - Agent Instructions

<!-- Single source of truth for AI coding agents. CLAUDE.md is a symlink to this file. -->

TomLens is a stripped-down, view-only fork of [farzaa/clicky](https://github.com/farzaa/clicky) (MIT, commit `e71105c`). It is a macOS menu-bar tutor that watches **one picked Tradovate window**, listens while a push-to-talk hotkey is held, answers out loud, and draws hints on a click-through overlay. It coaches Raza's own trading rules; it never trades.

## Hard constraints (never weaken; `scripts/guard.sh` enforces them in CI)

- **Never act on the Mac.** No clicking, typing, mouse moves, `CGEventPost`, `CGWarpMouseCursorPosition`, Accessibility (`AXUIElement*`) calls, AppleScript, or anything that links to order entry.
- **One window only.** Capture uses `SCContentFilter(desktopIndependentWindow:)` for the single window the user picked. Never a display-wide filter, never multi-screen capture.
- **Denylist.** Wallet and browser-wallet apps are never capturable (safety net; there are no wallets on the MacBook).
- **Permissions:** Screen Recording, Microphone, Speech Recognition only. No Accessibility, Input Monitoring, camera, or login item.
- **Push-to-talk only.** Carbon `RegisterEventHotKey`; the mic runs only while the key is held. No CGEvent taps, no always-listening VAD.
- **No telemetry, no paid services by default.** PostHog, FormSpark, Sparkle, PLCrashReporter, Mux, the Cloudflare Worker and the Claude/ElevenLabs/AssemblyAI/OpenAI-audio clients are removed. The AI brain is ChatGPT via Sign in with ChatGPT (Responses API, `store:false`, `stream:true`, credits overflow off, <= 40 calls/hour). API keys are an optional Keychain fallback, off by default.
- **Visible on/off switch** in the menu bar. Off means no capture, no mic, no AI calls.
- **Nothing installs on Raza's Mac and nothing costs money** without his explicit OK. CI produces an ad-hoc-signed `.app` he installs himself.
- No media committed to the repo. Session journal goes to `~/TomLens/journal` at runtime.

## Layout

- `leanring-buddy/` app sources (Xcode 16 file-system-synchronized group: adding/removing a `.swift` file needs **no** `project.pbxproj` edit).
- `leanring-buddyTests/` Swift Testing unit tests (`@testable import TomLens`).
- `leanring-buddy.xcodeproj` target `leanring-buddy`, product `TomLens.app`, bundle ID `com.razacodespython.tomlens`, shared scheme `TomLens`, macOS 14.2+.
- `scripts/guard.sh` rg/python safety checks (Linux-friendly). `.github/workflows/ci.yml` runs guard, unit tests, and uploads `TomLens-unsigned-app`.

## Build & test

```bash
./scripts/guard.sh                       # any OS with ripgrep + python3
./scripts/run-pure-swift-tests.sh        # pure-Swift logic tests via SwiftPM (Linux OK)
xcodebuild test -project leanring-buddy.xcodeproj -scheme TomLens -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=   # CI only, not on Raza's Mac
```

Linux agents cannot run `xcodebuild`: keep `project.pbxproj` edits minimal, consistent, and verified by grep.

## Status (milestones)

- **M0** rename, CI, guard. **M1** delete list. **M2** one-window capture (`TradingWindowCapturePolicy`, `CompanionScreenCaptureUtility`, panel window picker). **M3** Carbon hot key push-to-talk (`GlobalPushToTalkShortcutMonitor`, `BuddyPushToTalkShortcut`: ctrl + option + T), menu-bar on/off switch (`CompanionManager.isTomLensSwitchedOn`, launches off), entitlements trimmed.
- Next: M4 Apple STT/TTS polish, M5 SIWC brain (`CompanionBrain` currently throws `notConfigured`), M6 draw overlay, M7 tutor triggers + ruleset prompt, M8 journal (`~/TomLens/journal`), M9 release artifact + install runbook.

## Engineering rules

- Smallest diff. Subtract first. Mirror existing code paths.
- Prefer types (`enum`/`final class`) with static functions over loose module-level helpers.
- Never weaken a guard check. Add pure-Swift tests for logic (parsing, mapping, denylist, rate limits).

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory, folders or target (the "leanring" typo is legacy; renaming risks breaking `project.pbxproj`)
- Do not run `xcodebuild` on Raza's Mac — it invalidates TCC permissions. CI builds the app.

## Git Workflow

- One commit (or small series) per milestone (M0-M9); each can become a PR.
- Commit messages: imperative mood, explain the "why".
- Do not force-push to main.
