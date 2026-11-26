#!/usr/bin/env bash
# TomLens safety guard. Runs on Linux or macOS (needs ripgrep + python3).
# Fails if forbidden code (input injection, Accessibility writes, telemetry,
# full-screen capture, ...) re-appears, or if the deployment target drops
# below macOS 14.2. Each milestone appends checks; never weaken one.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SOURCES=(leanring-buddy leanring-buddy.xcodeproj leanring-buddyTests leanring-buddyUITests)
PROJECT_FILE="leanring-buddy.xcodeproj/project.pbxproj"
failures=0

# forbid <description> <regex> [paths...]
forbid() {
  local description="$1" pattern="$2"; shift 2
  local paths=("$@"); [ ${#paths[@]} -eq 0 ] && paths=("${APP_SOURCES[@]}")
  local matches
  matches=$(rg -n --hidden -g '!scripts/guard.sh' -g '!.github/**' -g '!AGENTS.md' -g '!*.md' -e "$pattern" "${paths[@]}" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    echo "FAIL  $description"; echo "$matches" | sed 's/^/      /'; failures=$((failures + 1))
  else
    echo "ok    $description"
  fi
}

# require <description> <regex> <file>
require() {
  if rg -q -e "$2" "$3" 2>/dev/null; then echo "ok    $1"; else echo "FAIL  $1 ($3)"; failures=$((failures + 1)); fi
}

echo "== M0: never act on the Mac =="
forbid "no synthetic input events (CGEventPost / CGEvent init)" 'CGEventPost|\.post\(tap:|CGEvent\(keyboardEventSource|CGEvent\(mouseEventSource|CGEventCreateKeyboardEvent|CGEventCreateMouseEvent'
forbid "no cursor warping" 'CGWarpMouseCursorPosition|CGAssociateMouseAndMouseCursorPosition'
forbid "no Accessibility actions" 'AXUIElementPerformAction'
forbid "no AppleScript / scripting bridges" 'NSAppleScript|OSAScript|SBApplication'

echo "== M1: telemetry, paid services, updater, AX, camera, login item removed =="
forbid "no PostHog analytics" '(?i)posthog|ClickyAnalytics'
forbid "no FormSpark" '(?i)submit-form\.com|formspark|submitEmail'
forbid "no Sparkle updater" '(?i)sparkle|SUFeedURL|SUPublicEDKey|appcast'
forbid "no PLCrashReporter" '(?i)plcrashreporter|PLCrash'
forbid "no Mux video" '(?i)mux\.com'
forbid "no Cloudflare Worker proxy" '(?i)workers\.dev|workerBaseURL'
forbid "no paid AI/voice clients" '(?i)anthropic|ClaudeAPI|elevenlabs|assemblyai|OpenAIAudioTranscription|OpenAIAPI\b'
forbid "no computer-use element detector" 'ElementLocationDetector'
forbid "no Accessibility API at all" 'AXUIElement|AXIsProcessTrusted|kAXTrustedCheckOptionPrompt|Privacy_Accessibility'
forbid "no login item" 'SMAppService|ServiceManagement|SMLoginItem'
forbid "no camera entitlement or capture" 'com\.apple\.security\.device\.camera|AVCaptureDevice\.(default|DiscoverySession)\(.*video|NSCameraUsageDescription'
forbid "no remote Swift packages (pbxproj)" 'XCRemoteSwiftPackageReference' leanring-buddy.xcodeproj
if [ -e worker ] || [ -e appcast.xml ]; then echo "FAIL  worker/ or appcast.xml re-added"; failures=$((failures + 1)); else echo "ok    worker/ and appcast.xml absent"; fi

echo "== M2: capture exactly one picked window =="
forbid "no display-wide capture filters" 'SCContentFilter\(\s*display'
forbid "no system content picker (could grant a display)" 'SCContentSharingPicker'
forbid "no legacy full-screen capture APIs" 'CGWindowListCreateImage|CGDisplayCreateImage|CGDisplayStream|/usr/sbin/screencapture|captureAllScreens'
if rg -q 'SCContentFilter\(desktopIndependentWindow:' leanring-buddy/CompanionScreenCaptureUtility.swift \
   && rg -q 'forLiveWindow: liveCandidate' leanring-buddy/CompanionScreenCaptureUtility.swift; then
  echo "ok    capture uses desktopIndependentWindow and re-checks the policy"
else
  echo "FAIL  capture must use SCContentFilter(desktopIndependentWindow:) and TradingWindowCapturePolicy"; failures=$((failures + 1))
fi
missing_denylist_keywords=""
for required_keyword in wallet metamask hyperliquid rabby phantom; do
  rg -q "\"$required_keyword\"" leanring-buddy/TradingWindowCapturePolicy.swift || missing_denylist_keywords="$missing_denylist_keywords $required_keyword"
done
if [ -n "$missing_denylist_keywords" ]; then
  echo "FAIL  denylist lost keywords:$missing_denylist_keywords"; failures=$((failures + 1))
else
  echo "ok    denylist keywords present (wallet, metamask, hyperliquid, rabby, phantom)"
fi

echo "== M3: push-to-talk via Carbon hot key, minimal permissions =="
forbid "no CGEvent taps (need Input Monitoring)" 'tapCreate|CGEventTap|CFMachPortCreateRunLoopSource'
forbid "no keyboard monitoring / Input Monitoring APIs" 'keyDown|keyUp|flagsChanged|IOHIDManager|IOHIDRequestAccess|CGRequestListenEventAccess|CGPreflightListenEventAccess|Privacy_ListenEvent'
forbid "no always-listening voice activity detection" '(?i)voiceActivityDetect|\bVAD\b|alwaysListening'
if rg -q 'RegisterEventHotKey' leanring-buddy/GlobalPushToTalkShortcutMonitor.swift; then
  echo "ok    push-to-talk uses Carbon RegisterEventHotKey"
else
  echo "FAIL  push-to-talk must use Carbon RegisterEventHotKey"; failures=$((failures + 1))
fi
if rg -q 'carbonVirtualKeyCode: UInt32 = 0x06' leanring-buddy/BuddyPushToTalkShortcut.swift \
   && rg -q 'pushToTalkDisplayText = "ctrl \+ option \+ Z"' leanring-buddy/BuddyPushToTalkShortcut.swift \
   && rg -q 'Switch on, then hold Control\+Option\+Z' leanring-buddy/TomLensStatusPresentation.swift; then
  echo "ok    push-to-talk is control + option + Z, and off state says so"
else
  echo "FAIL  push-to-talk must be kVK_ANSI_Z (0x06) and the off hint must say to switch on first"; failures=$((failures + 1))
fi
forbid "no leftover Control+Option+Space hotkey" 'kVK_Space|Control\+Option\+Space|option \+ space' leanring-buddy leanring-buddyTests INSTALL.md AGENTS.md README.md
forbid "no leftover Control+Option+T hotkey" 'option \+ T|kVK_ANSI_T|Ctrl\+Option\+T|Control \+ Option \+ T' leanring-buddy leanring-buddyTests INSTALL.md AGENTS.md
if rg -q 'isTomLensSwitchedOn: Bool = false' leanring-buddy/CompanionManager.swift; then
  echo "ok    TomLens still launches switched off"
else
  echo "FAIL  TomLens must launch switched off"; failures=$((failures + 1))
fi
if rg -q 'NSWindow\(' leanring-buddy/TomLensStatusWindowController.swift \
   && rg -q 'Open TomLens' leanring-buddy/CompanionPanelView.swift; then
  echo "ok    status window is a normal NSWindow opened from the panel"
else
  echo "FAIL  status window must be an NSWindow with an Open TomLens button"; failures=$((failures + 1))
fi
python3 - <<'PY_PERMS' || failures=$((failures + 1))
import plistlib, re, sys
entitlements = plistlib.load(open("leanring-buddy/leanring-buddy.entitlements", "rb"))
allowed_entitlements = {
    "com.apple.security.app-sandbox": False,
    "com.apple.security.network.client": True,
    "com.apple.security.device.audio-input": True,
}
info_plist = plistlib.load(open("leanring-buddy/Info.plist", "rb"))
usage_keys = {key for key in info_plist if key.endswith("UsageDescription")}
project_usage_keys = set(re.findall(r"INFOPLIST_KEY_(NS\w+UsageDescription)", open("leanring-buddy.xcodeproj/project.pbxproj").read()))
allowed_usage_keys = {"NSMicrophoneUsageDescription", "NSScreenCaptureUsageDescription", "NSSpeechRecognitionUsageDescription"}
problems = []
if entitlements != allowed_entitlements:
    problems.append(f"entitlements must be exactly {allowed_entitlements}, got {entitlements}")
if not usage_keys | project_usage_keys <= allowed_usage_keys:
    problems.append(f"unexpected permission usage keys: {sorted((usage_keys | project_usage_keys) - allowed_usage_keys)}")
if info_plist.get("LSUIElement") is not True:
    problems.append("LSUIElement must stay true (menu-bar only app)")
if problems:
    print("FAIL  permissions:"); [print("      " + problem) for problem in problems]; sys.exit(1)
print("ok    permissions limited to Screen Recording, Microphone, Speech Recognition")
PY_PERMS
if rg -q 'isTomLensSwitchedOn' leanring-buddy/MenuBarPanelManager.swift && rg -q 'setTomLensSwitchedOn' leanring-buddy/CompanionPanelView.swift; then
  echo "ok    visible menu-bar on/off switch wired"
else
  echo "FAIL  menu-bar on/off switch missing"; failures=$((failures + 1))
fi

echo "== M4: push-to-talk loop hardening =="
if rg -q 'PushToTalkUtterancePolicy\.maximumHoldDurationSeconds' leanring-buddy/CompanionManager.swift; then
  echo "ok    mic hold is force-capped"
else
  echo "FAIL  mic hold must be capped by PushToTalkUtterancePolicy.maximumHoldDurationSeconds"; failures=$((failures + 1))
fi

echo "== M5: Sign in with ChatGPT, plan usage only =="
require "SIWC first registration uses dynamic_agent_client" '"dynamic_agent_client"' leanring-buddy/ChatGPTSignInProtocol.swift
require "loopback redirect is 127.0.0.1" 'http://127\.0\.0\.1:' leanring-buddy/ChatGPTSignInProtocol.swift
require "PKCE S256" '"S256"' leanring-buddy/ChatGPTSignInProtocol.swift
require "Responses requests are store:false" '"store": false' leanring-buddy/ResponsesAPIProtocol.swift
require "Responses requests are stream:true" '"stream": true' leanring-buddy/ResponsesAPIProtocol.swift
require "hard call cap defaults to 40/hour" 'defaultMaximumCallsPerHour = 40$' leanring-buddy/ResponsesAPIProtocol.swift
require "every AI call passes the call cap" 'callRateLimiter\.reserveCall' leanring-buddy/CompanionBrain.swift
require "tokens live in the Keychain" 'kSecClassGenericPassword' leanring-buddy/ChatGPTSignInService.swift
forbid "no localhost redirect (SIWC requires 127.0.0.1)" 'localhost'
forbid "no ChatGPT backend-api endpoints" 'backend-api'
forbid "no token, key or auth URL in logs" 'print\(.*(accessToken|refreshToken|idToken|bearerToken|apiKey|APIKey|authorizationURL|codeVerifier)'
forbid "no hardcoded API keys" 'sk-[A-Za-z0-9_-]{16,}'
forbid "API-key fallback is never switched on by code" 'set\(true,\s*forKey:\s*(TomLensAPIKeyFallback|"TomLensAPIKeyFallbackEnabled")|register\(defaults:.*TomLensAPIKeyFallbackEnabled'
forbid "never send unsupported sampling/limit fields" '"(temperature|top_p|max_output_tokens|previous_response_id)":'

echo "== M6: draw-only, click-through overlay =="
require "drawing overlay ignores mouse events" 'panel\.ignoresMouseEvents = true' leanring-buddy/TradingWindowDrawingOverlay.swift
require "drawing overlay is excluded from capture" 'panel\.sharingType = \.none' leanring-buddy/TradingWindowDrawingOverlay.swift
require "drawing overlay is short-lived" 'displayDurationSeconds' leanring-buddy/TradingWindowDrawingOverlay.swift
require "drawing overlay follows the live SCWindow frame" 'fromScreenCaptureKitFrame: liveWindow\.frame' leanring-buddy/TradingWindowDrawingOverlay.swift
forbid "no overlay ever takes mouse input" 'ignoresMouseEvents\s*=\s*false'
forbid "no legacy [POINT] tag parsing" '\[POINT:'

echo "== M7: event triggers, ruleset, never place orders =="
if [ -f leanring-buddy/TutorRulesetPrompt.md ] && rg -q 'never place' leanring-buddy/TutorRulesetPrompt.md; then
  echo "ok    ruleset bundled as a resource and forbids placing orders"
else
  echo "FAIL  leanring-buddy/TutorRulesetPrompt.md missing or lacks the no-orders rule"; failures=$((failures + 1))
fi
require "ruleset is loaded from the bundle" 'TutorPromptComposer\.rulesetResourceName' leanring-buddy/CompanionManager.swift
require "app-level no-orders rule is always in the instructions" 'must never claim you did' leanring-buddy/TutorPromptComposer.swift
require "spoken replies pass the order-claim safety filter" 'TutorResponseSafetyFilter\.filtered' leanring-buddy/CompanionManager.swift
require "frame sampling captures only the picked window" 'capturePickedWindowAsJPEG\(pickedSelection:' leanring-buddy/TutorEventMonitor.swift
require "frames are ~1024 px" 'frameMaximumDimension = 1024' leanring-buddy/TutorTriggerPolicy.swift
require "automatic calls go through the trigger policy (cap headroom, pause)" 'TutorTriggerPolicy\.shouldSendAutomaticTrigger' leanring-buddy/CompanionManager.swift
forbid "no order-entry or broker APIs" '(?i)placeorder|placeOCO|modifyorder|cancelorder|liquidateposition|tradovateapi|api\.tradovate|demo\.tradovateapi'

echo "== M8: local session journal only =="
require "journal lives under ~/TomLens/journal" 'appendingPathComponent\("TomLens", isDirectory: true\)' leanring-buddy/SessionJournal.swift
require "journal redacts base64 images" 'redactedRequestBody' leanring-buddy/SessionJournal.swift
require "every model call is journaled" 'appendModelExchange' leanring-buddy/CompanionManager.swift
forbid "journal never sees credentials" '(?i)authorization|bearer|accessToken|refreshToken|apiKey' leanring-buddy/SessionJournal.swift
forbid "no cloud upload of the journal" '(?i)drive\.google|googleapis\.com|dropbox|icloud|CKContainer|NSUbiquitous'
if command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  tracked_media=$(git ls-files | rg -i '\.(jpe?g|png|gif|heic|mov|mp4|m4a|wav|mp3|caf)$' | rg -v '^leanring-buddy/Assets\.xcassets/AppIcon\.appiconset/' || true)
  if [ -n "$tracked_media" ]; then
    echo "FAIL  no media committed (only the app icon)"; echo "$tracked_media" | sed 's/^/      /'; failures=$((failures + 1))
  else
    echo "ok    no media committed (only the app icon)"
  fi
fi

echo "== M10: Ask Tom relay is outbound and capped =="
require "network allowlist names ntfy" 'ntfy\.sh' leanring-buddy/TomNetworkAllowlist.swift
require "responses calls go through the allowlist" 'TomNetworkAllowlist\.validate' leanring-buddy/CompanionBrain.swift
require "sign-in calls go through the allowlist" 'TomNetworkAllowlist\.validate' leanring-buddy/ChatGPTSignInService.swift
require "webhook posts go through the allowlist" 'TomNetworkAllowlist\.validate' leanring-buddy/TomWebhookClient.swift
require "reply stream goes through the allowlist" 'TomNetworkAllowlist\.validate' leanring-buddy/TomReplyListener.swift
require "ask cap is 6 per session" 'maximumAsksPerSession = 6' leanring-buddy/TomRelayProtocol.swift
require "asks are at least 3 minutes apart" 'minimumSecondsBetweenAsks: TimeInterval = 180' leanring-buddy/TomRelayProtocol.swift
require "reply nonce expires in 10 minutes" 'replyNonceLifetimeSeconds: TimeInterval = 600' leanring-buddy/TomRelayProtocol.swift
require "one automatic session end" 'maximumSessionEndPosts = 1' leanring-buddy/TomRelayProtocol.swift
require "session payload file name" 'tom-payload.json' leanring-buddy/TomRelayProtocol.swift
require "observations require screen_read" 'screen_read' leanring-buddy/TomRelayProtocol.swift
require "observations can be what Raza said" 'raza_said' leanring-buddy/TomRelayProtocol.swift
require "webhook key account is the Keychain item" 'tom-webhook-sender-key' leanring-buddy/TomRelaySettings.swift
require "webhook key is saved to the Keychain" 'TomLensKeychainStore\.save' leanring-buddy/TomRelayCoordinator.swift
require "Tom replies are labeled review" 'Tom \(review\)' leanring-buddy/TomRelaySettings.swift
require "thinking state is shown" 'Tom is thinking…' leanring-buddy/TomRelaySettings.swift
require "switch-off ends the relay session" 'finishRelaySession' leanring-buddy/CompanionManager.swift
require "switch-off stops the reply stream" 'setSwitchedOn\(false\)' leanring-buddy/CompanionManager.swift
require "hub signature covers the raw body" 'X-Hub-Signature-256' leanring-buddy/TomRelayProtocol.swift
forbid "ntfy topic is never printed" 'print\(.*[Tt]opic'
forbid "webhook sender key is never printed" 'print\(.*(senderKey|webhookKey)'
python3 - <<'PY_HOSTS' || failures=$((failures + 1))
import re, pathlib, sys
allowed_hosts = {
    "api.openai.com", "auth.openai.com", "chatgpt.com", "ntfy.sh", "127.0.0.1",
    "api.github.com", "github.com", "objects.githubusercontent.com",
    "release-assets.githubusercontent.com", "github-releases.githubusercontent.com",
}
found_hosts = set()
for path in pathlib.Path("leanring-buddy").rglob("*.swift"):
    text = path.read_text()
    for host in re.findall(r"https?://([A-Za-z0-9._-]+)", text):
        found_hosts.add(host.split(":")[0].lower())
unexpected = sorted(found_hosts - allowed_hosts)
if unexpected:
    print("FAIL  outbound hosts outside the allowlist: " + ", ".join(unexpected))
    sys.exit(1)
print(f"ok    hardcoded hosts are on the allowlist ({sorted(found_hosts)})")
PY_HOSTS

echo "== 0.1.8: in-app update replaces Applications only =="
require "menu offers Update TomLens" 'Update TomLens…' leanring-buddy/TomLensUpdatePolicy.swift
require "panel shows the update section" 'TomLensUpdateSection' leanring-buddy/CompanionPanelView.swift
require "status window shows the update section" 'TomLensUpdateSection' leanring-buddy/TomLensStatusWindowController.swift
require "updater checks the TomLens bundle id" 'com.razacodespython.tomlens' leanring-buddy/TomLensUpdatePolicy.swift
require "swap replaces only the Applications copy" '/Applications/TomLens.app' leanring-buddy/TomLensUpdatePolicy.swift
require "swap clears the download attribute" 'xattr -cr' leanring-buddy/TomLensUpdatePolicy.swift
require "update requests stay on the allowlist" 'TomNetworkAllowlist\.validate' leanring-buddy/TomLensUpdateController.swift
require "release checks do not use the latest endpoint" 'releases/latest' leanring-buddy/TomNetworkAllowlist.swift
require "GitHub release host is allowlisted" 'api.github.com' leanring-buddy/TomNetworkAllowlist.swift
require "rate limit is a distinct fallback" 'rateLimited' leanring-buddy/TomLensUpdatePolicy.swift
forbid "updater never resets privacy grants" 'tccutil' leanring-buddy leanring-buddyTests leanring-buddyUITests
forbid "updater does not send an auth header" 'Authorization' leanring-buddy/TomLensUpdateController.swift
forbid "updater does not store a github token" 'github-releases-read-token|githubTokenAccount' leanring-buddy

echo "== M0: deployment target >= 14.2 =="
python3 - "$PROJECT_FILE" <<'PY' || failures=$((failures + 1))
import re, sys
text = open(sys.argv[1]).read()
targets = re.findall(r'MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);', text)
def version_tuple(value): return tuple(int(part) for part in value.split('.')) + (0,) * (3 - len(value.split('.')))
bad = [value for value in targets if version_tuple(value) < (14, 2, 0)]
if not targets or bad:
    print(f"FAIL  MACOSX_DEPLOYMENT_TARGET must be >= 14.2 (found {targets})"); sys.exit(1)
print(f"ok    MACOSX_DEPLOYMENT_TARGET >= 14.2 (found {sorted(set(targets))})")
PY

if [ "$failures" -ne 0 ]; then echo "guard: $failures check(s) failed"; exit 1; fi
echo "guard: all checks passed"
