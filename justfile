# Owner-specific values live outside git: .env.local (server, release account; see .env.local.example),
# Local.xcconfig (bundle ID, team; see Local.xcconfig.example) and an optional local.just for your own recipes.
set dotenv-filename := ".env.local"
import? 'local.just'

# The app's bundle ID and team as Xcode sees them: Config.xcconfig, then Local.xcconfig when present.
bundle_id := `cat Config.xcconfig Local.xcconfig 2>/dev/null | awk -F= '{gsub(/[[:space:]]/, "")} $1 == "HEYDAN_BUNDLE_ID" {v = $2} END {print v}'`
team_id := `cat Config.xcconfig Local.xcconfig 2>/dev/null | awk -F= '{gsub(/[[:space:]]/, "")} $1 == "DEVELOPMENT_TEAM" {v = $2} END {print v}'`

# Regenerate HeyDan.xcodeproj from project.yml (only its Package.resolved is committed).
gen:
    xcodegen generate

test:
    cd HeyDanCore && swift test

# Compile-check for a device without signing.
build: gen
    xcodebuild -project HeyDan.xcodeproj -scheme HeyDan -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# HEYDAN_SIM picks another Simulator and HEYDAN_DERIVED_DATA its build folder, so two runs can share the Mac.
sim_name := env("HEYDAN_SIM", "Hey Dan iPhone")
sim_build := env("HEYDAN_DERIVED_DATA", "build")
# The test line's call link on stdout, for `link=$(just _test-link)` only: the link travels by env, never printed.
# Test calls belong on a test line, never your main agent's: a test turn keeps that agent busy on your own calls.
# TEST_CALL_LINK is the link itself; otherwise it is read from the server's nanoclaw .env over ssh
# (NANOCLAW_SSH, NANOCLAW_DIR): VOICE_PUBLIC_URL and the TEST_CALL_LINE-th (1-based) VOICE_LINK_TOKEN, or their
# protocol 6 names VOICE_MODE_PUBLIC_URL and VOICE_MODE_LINK_TOKEN.
[private]
_test-link:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "${TEST_CALL_LINK:-}" ]; then printf '%s' "$TEST_CALL_LINK"; exit 0; fi
    if [ -z "${NANOCLAW_SSH:-}" ]; then
        echo "no test line: set TEST_CALL_LINK, or NANOCLAW_SSH and NANOCLAW_DIR, in .env.local (see .env.local.example)" >&2
        exit 1
    fi
    ssh "$NANOCLAW_SSH" bash -s -- "${NANOCLAW_DIR:-~/nanoclaw}" "${TEST_CALL_LINE:-1}" <<'SH'
    cd "${1/#\~/$HOME}" && awk -F= -v n="$2" '/^VOICE_(MODE_)?PUBLIC_URL=/{u=$2} /^VOICE_(MODE_)?LINK_TOKEN=/{split($2,a,","); t=a[n]} END{if (u != "" && t != "") printf "%s/voice?t=%s", u, t}' .env
    SH

# Build, install and launch in the Simulator with the test line's call link; calls go through CallKit as on the phone.
sim: gen
    #!/usr/bin/env bash
    set -euo pipefail
    udid=$(xcrun simctl list devices available -j | jq -r --arg n "{{sim_name}}" '.devices[][] | select(.name == $n) | .udid' | head -1)
    [ -n "$udid" ] || udid=$(xcrun simctl create "{{sim_name}}" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-27-0)
    xcrun simctl bootstatus "$udid" -b >/dev/null
    open "$(xcode-select -p)/../Applications/DeviceHub.app"
    xcodebuild -project HeyDan.xcodeproj -scheme HeyDan -destination "id=$udid" -derivedDataPath "{{sim_build}}" build -quiet
    xcrun simctl install "$udid" "{{sim_build}}/Build/Products/Debug-iphonesimulator/HeyDan.app"
    xcrun simctl privacy "$udid" grant microphone {{bundle_id}}
    link=$(just _test-link)
    [ -n "$link" ] || { echo "no call link for the test line (empty VOICE_PUBLIC_URL or token on the server?)" >&2; exit 1; }
    # Every HEYDAN_* variable set for the recipe reaches the app: the DEBUG hooks in HeyDanApp.swift read them.
    for name in $(compgen -e | grep '^HEYDAN_' || true); do export "SIMCTL_CHILD_$name=${!name}"; done
    SIMCTL_CHILD_HEYDAN_CALL_LINK="$link" xcrun simctl launch --terminate-running-process "$udid" {{bundle_id}}

# A real call to the test line from the Simulator: starts at launch, hangs up after `seconds`. Speak to it through the Mac.
# Pass `say` to make the caller speak it (synthesized, fed in place of the microphone) 8 s after the app launched.
# HEYDAN_STEPS="12:mute,16:unmute,20:manual,24:talk,30:done" presses keys mid-call, timed from launch.
# `mode` (auto or review) is the turn mode the call starts in; empty keeps the app's last pick.
sim-call seconds="90" say="" mode="":
    #!/usr/bin/env bash
    set -euo pipefail
    feed=""
    if [ -n {{quote(say)}} ]; then
        mkdir -p build && say -o build/feed.aiff {{quote(say)}} && afconvert -f WAVE -d LEF32@48000 -c 1 build/feed.aiff build/feed.wav
        feed="$PWD/build/feed.wav"
    fi
    HEYDAN_AUTOCALL=1 HEYDAN_HANGUP_AFTER={{seconds}} HEYDAN_FEED_WAV="$feed" HEYDAN_TURN_MODE={{quote(mode)}} just sim

# Sign (registering the iPhone with the team on first run), install and launch on the connected iPhone.
device: gen
    #!/usr/bin/env bash
    set -euo pipefail
    list=$(mktemp)
    xcrun devicectl list devices --json-output "$list" >/dev/null
    udid=$(jq -r '[.result.devices[] | select(.hardwareProperties.platform == "iOS" and .hardwareProperties.reality == "physical")][0].hardwareProperties.udid // empty' "$list")
    rm -f "$list"
    [ -n "$udid" ] || { echo "no iPhone connected" >&2; exit 1; }
    xcodebuild -project HeyDan.xcodeproj -scheme HeyDan -destination "platform=iOS,id=$udid" -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
    xcrun devicectl device install app --device "$udid" build/Build/Products/Debug-iphoneos/HeyDan.app
    xcrun devicectl device process launch --terminate-existing --device "$udid" {{bundle_id}}

# Needs the phone unlocked and a line saved on it. The caller says `say` (synthesized, fed in place of the microphone,
# so the phone hears nothing and plays nothing) 8 s after the app launched; build/device-call.png is a screenshot 25 s in.
# A real CallKit call to the phone's picked line, hands off: hangs up after `seconds`, then pulls the log.
device-call seconds="70" say="Hey Dan. What is two plus two? Zulu.": gen
    #!/usr/bin/env bash
    set -euo pipefail
    list=$(mktemp)
    xcrun devicectl list devices --json-output "$list" >/dev/null
    udid=$(jq -r '[.result.devices[] | select(.hardwareProperties.platform == "iOS" and .hardwareProperties.reality == "physical")][0].hardwareProperties.udid // empty' "$list")
    rm -f "$list"
    [ -n "$udid" ] || { echo "no iPhone connected" >&2; exit 1; }
    mkdir -p build
    say -o build/feed.aiff {{quote(say)}} && afconvert -f WAVE -d LEF32@48000 -c 1 build/feed.aiff build/feed.wav
    xcodebuild -project HeyDan.xcodeproj -scheme HeyDan -destination "platform=iOS,id=$udid" -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
    xcrun devicectl device install app --device "$udid" build/Build/Products/Debug-iphoneos/HeyDan.app
    xcrun devicectl device copy to --device "$udid" --domain-type appDataContainer --domain-identifier {{bundle_id}} \
        --source build/feed.wav --destination Library/Caches/feed.wav
    DEVICECTL_CHILD_HEYDAN_AUTOCALL=1 DEVICECTL_CHILD_HEYDAN_HANGUP_AFTER={{seconds}} DEVICECTL_CHILD_HEYDAN_FEED_WAV=feed.wav \
        DEVICECTL_CHILD_HEYDAN_FEED_AFTER="${HEYDAN_FEED_AFTER:-8}" \
        xcrun devicectl device process launch --terminate-existing --device "$udid" {{bundle_id}}
    sleep 25
    xcrun devicectl device capture screenshot --device "$udid" --destination build/device-call.png -q || echo "screenshot failed" >&2
    sleep $(( {{seconds}} - 15 ))
    just device-logs

# ASC_ENV_CMD (e.g. a secret manager's `env <entry> --`) prefixes the run to put the key in its environment.
# Archive, sign and upload to TestFlight with the App Store Connect API key; waits for processing, fails on a rejection.
# `just testflight dry` stops short of the upload: it exports the IPA locally and runs App Store validation on it
# (the export still reserves its build number in App Store Connect, left AWAITING_UPLOAD).
testflight mode="upload": gen
    ${ASC_ENV_CMD:-} just _testflight {{mode}}

# Needs ASC_KEY_P8_B64 (the .p8 as one base64 line), ASC_KEY_ID and ASC_ISSUER_ID; an upload also ASC_APP_ID.
[private]
_testflight mode:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{mode}}" in upload) destination=upload ;; dry) destination=export ;; *) echo "mode is upload or dry" >&2; exit 2 ;; esac
    [ -n "{{team_id}}" ] || { echo "no DEVELOPMENT_TEAM: set it in Local.xcconfig (see Local.xcconfig.example)" >&2; exit 1; }
    needed="ASC_KEY_P8_B64 ASC_KEY_ID ASC_ISSUER_ID"
    [ "{{mode}}" = dry ] || needed="$needed ASC_APP_ID"
    for name in $needed; do
        [ -n "${!name:-}" ] || { echo "$name is not set: see .env.local.example (ASC_ENV_CMD, ASC_APP_ID)" >&2; exit 1; }
    done
    keydir=$(mktemp -d)
    key="$keydir/AuthKey_$ASC_KEY_ID.p8"
    trap 'rm -f "$key"; rmdir "$keydir"' EXIT
    (umask 077 && printf '%s' "$ASC_KEY_P8_B64" | base64 -d > "$key")
    auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    build_number=$(date +%y%m%d%H%M)
    archive=build/testflight/HeyDan-$build_number.xcarchive
    options=build/testflight/ExportOptions.plist
    mkdir -p build/testflight
    cat > "$options" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>method</key><string>app-store-connect</string>
        <key>destination</key><string>$destination</string>
        <key>teamID</key><string>{{team_id}}</string>
        <key>signingStyle</key><string>automatic</string>
        <key>manageAppVersionAndBuildNumber</key><false/>
        <key>uploadSymbols</key><true/>
    </dict>
    </plist>
    PLIST
    xcodebuild -project HeyDan.xcodeproj -scheme HeyDan -configuration Release -destination 'generic/platform=iOS' \
        -derivedDataPath build -archivePath "$archive" "${auth[@]}" \
        CURRENT_PROJECT_VERSION="$build_number" archive -quiet
    # LiveKit's binary xcframeworks ship stripped and without dSYMs (none upstream either), so the upload warns.
    # A dsymutil dSYM carries only their UUID and exported symbol table, no DWARF: it silences the warning, nothing more.
    for fw in LiveKitWebRTC RustLiveKitUniFFI; do
        dsym="$archive/dSYMs/$fw.framework.dSYM"
        [ -e "$dsym" ] || xcrun dsymutil "$archive/Products/Applications/HeyDan.app/Frameworks/$fw.framework/$fw" -o "$dsym" 2>/dev/null
    done
    xcodebuild -exportArchive -archivePath "$archive" -exportPath build/testflight/export \
        -exportOptionsPlist "$options" "${auth[@]}" -quiet
    if [ "{{mode}}" = dry ]; then
        xcrun altool --validate-app build/testflight/export/HeyDan.ipa --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$key"
        rm -f "$key"
        echo "dry run: build $build_number exported to build/testflight/export and validated; nothing uploaded"
        exit 0
    fi
    # The wait reads the key from the environment: the decoded file goes now, not after half an hour.
    rm -f "$key"
    echo "uploaded build $build_number; waiting for App Store Connect to process it"
    uv run -q scripts/testflight-wait.py "$build_number"

log_predicate := 'subsystem == "' + bundle_id + '" OR subsystem == "io.livekit.sdk"'

# The Simulator's app and LiveKit log for the last `since` (e.g. 15m), debug lines included.
logs since="15m":
    #!/usr/bin/env bash
    set -euo pipefail
    udid=$(xcrun simctl list devices booted -j | jq -r '.devices[][] | select(.name == "{{sim_name}}") | .udid' | head -1)
    [ -n "$udid" ] || { echo "the Simulator {{sim_name}} is not booted" >&2; exit 1; }
    xcrun simctl spawn "$udid" log show --last {{since}} --info --debug --style compact --predicate '{{log_predicate}}'

# The phone's DEBUG log file (every level, kept across launches) copied to build/device-heydan.log.
device-logs:
    #!/usr/bin/env bash
    set -euo pipefail
    list=$(mktemp)
    xcrun devicectl list devices --json-output "$list" >/dev/null
    udid=$(jq -r '[.result.devices[] | select(.hardwareProperties.platform == "iOS" and .hardwareProperties.reality == "physical")][0].hardwareProperties.udid // empty' "$list")
    rm -f "$list"
    [ -n "$udid" ] || { echo "no iPhone reachable" >&2; exit 1; }
    mkdir -p build
    xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer --domain-identifier {{bundle_id}} --source Library/Caches/heydan.log --destination build/device-heydan.log
    tail -n 200 build/device-heydan.log

# Over ssh to NANOCLAW_SSH, with nanoclaw in NANOCLAW_DIR (.env.local).
# The server's side of one call (host, worker, LiveKit) by the app log's `cid=` (first 8 characters of the host callId).
server-logs cid:
    #!/usr/bin/env bash
    [ -n "${NANOCLAW_SSH:-}" ] || { echo "set NANOCLAW_SSH and NANOCLAW_DIR in .env.local (see .env.local.example)" >&2; exit 1; }
    ssh "$NANOCLAW_SSH" bash -s -- "{{cid}}" "${NANOCLAW_DIR:-~/nanoclaw}" <<'SH'
    cid=$1
    dir=${2/#\~/$HOME}
    journalctl --user -u nanoclaw-voice-worker -u nanoclaw-voice-mode-worker -u livekit --since -6h -o short-iso --no-pager | grep -F "$cid"
    grep -hF "$cid" "$dir/logs/nanoclaw.log" "$dir/logs/nanoclaw.error.log" | tail -50
    SH

# Simulator checks of what used to need the phone in hand (HeyDanChecks, a UI test bundle), in the Simulator
# `sim_name`: `check` is LiveActivityOnLockScreen, IntentStartsCallFromBackground, SetActionButtonToHeyDan (once
# per Simulator) or ActionButtonStartsCall; HEYDAN_CHECK_LOCKED=1 locks first. Every HEYDAN_* variable reaches the
# app, as with `just sim`; screenshots land in build/checks. Calls are real: set HEYDAN_HANGUP_AFTER.
# The call link is seeded by one plain launch (the Simulator's keychain keeps it), never through the test runner's
# environment: a result bundle records that. The bundle itself lives in a temporary folder, gone on exit.
sim-checks check="LiveActivityOnLockScreen": gen
    #!/usr/bin/env bash
    set -euo pipefail
    udid=$(xcrun simctl list devices available -j | jq -r --arg n "{{sim_name}}" '.devices[][] | select(.name == $n) | .udid' | head -1)
    [ -n "$udid" ] || { echo "no Simulator named {{sim_name}}" >&2; exit 1; }
    xcrun simctl bootstatus "$udid" -b >/dev/null
    link=$(just _test-link)
    [ -n "$link" ] || { echo "no call link for the test line (empty VOICE_PUBLIC_URL or token on the server?)" >&2; exit 1; }
    results=$(mktemp -d)
    trap '[ -n "$results" ] && rm -rf -- "$results"' EXIT
    mkdir -p build/checks
    for name in $(compgen -e | grep '^HEYDAN_' | grep -vx 'HEYDAN_CALL_LINK' || true); do export "TEST_RUNNER_$name=${!name}"; done
    xcodebuild build-for-testing -project HeyDan.xcodeproj -scheme HeyDanChecks -destination "id=$udid" -derivedDataPath "{{sim_build}}" -quiet
    xcrun simctl install "$udid" "{{sim_build}}/Build/Products/Debug-iphonesimulator/HeyDan.app"
    xcrun simctl privacy "$udid" grant microphone {{bundle_id}}
    SIMCTL_CHILD_HEYDAN_CALL_LINK="$link" xcrun simctl launch --terminate-running-process "$udid" {{bundle_id}} >/dev/null
    sleep 3
    xcrun simctl terminate "$udid" {{bundle_id}}
    status=0
    TEST_RUNNER_HEYDAN_CHECKS_OUT="$PWD/build/checks" \
        xcodebuild test-without-building -project HeyDan.xcodeproj -scheme HeyDanChecks -destination "id=$udid" \
        -derivedDataPath "{{sim_build}}" -resultBundlePath "$results/HeyDanChecks.xcresult" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -only-testing "HeyDanChecks/HeyDanChecks/test{{check}}" 2>&1 \
        | grep -E '^check:|error|passed|failed' || status=${PIPESTATUS[0]}
    exit "$status"
