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
