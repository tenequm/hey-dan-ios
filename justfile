# Owner-specific values live outside git: .env.local (server, release account; see .env.local.example),
# Local.xcconfig (bundle ID, team; see Local.xcconfig.example) and an optional local.just for your own recipes.
set dotenv-filename := ".env.local"
import? 'local.just'

# The app's bundle ID and team as Xcode sees them: Config.xcconfig, then Local.xcconfig when present.
bundle_id := `cat Config.xcconfig Local.xcconfig 2>/dev/null | awk -F= '{gsub(/[[:space:]]/, "")} $1 == "HEYDAN_BUNDLE_ID" {v = $2} END {print v}'`
team_id := `cat Config.xcconfig Local.xcconfig 2>/dev/null | awk -F= '{gsub(/[[:space:]]/, "")} $1 == "DEVELOPMENT_TEAM" {v = $2} END {print v}'`

# Regenerate HeyDan.xcodeproj from project.yml (only its Package.resolved is committed). The cache skips the rewrite,
# and with it xcodebuild's re-planning, when the spec and the file list are unchanged.
gen:
    if [ -d HeyDan.xcodeproj ]; then xcodegen generate --use-cache; else xcodegen generate; fi

test:
    cd HeyDanCore && swift test
    python3 scripts/sim-e2e-test.py

# Compile-check for a device without signing.
build: gen
    xcodebuild -project HeyDan.xcodeproj -scheme HeyDan -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build

# HEYDAN_SIM picks another Simulator and HEYDAN_DERIVED_DATA its build folder, so two runs can share the Mac.
sim_name := env("HEYDAN_SIM", "Hey Dan iPhone")
sim_build := env("HEYDAN_DERIVED_DATA", "build")
sim: gen
    #!/usr/bin/env bash
    set -euo pipefail
    udid=$(xcrun simctl list devices available -j | jq -r --arg n "{{sim_name}}" '.devices[][] | select(.name == $n) | .udid' | head -1)
    if [ -z "$udid" ]; then
        # Newest generic iOS runtime; the -iPhone<N> variants are device-specific downloads.
        runtime=$(xcrun simctl list runtimes available -j | jq -r '[.runtimes[] | select(.platform == "iOS" and (.identifier | test("-iPhone") | not))] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty')
        [ -n "$runtime" ] || { echo "no iOS Simulator runtime: run xcodebuild -downloadPlatform iOS" >&2; exit 1; }
        udid=$(xcrun simctl create "{{sim_name}}" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max "$runtime")
    fi
    xcrun simctl bootstatus "$udid" -b >/dev/null
    open "$(xcode-select -p)/../Applications/DeviceHub.app"
    xcodebuild -project HeyDan.xcodeproj -scheme HeyDan -destination "id=$udid" -derivedDataPath "{{sim_build}}" build -quiet
    xcrun simctl install "$udid" "{{sim_build}}/Build/Products/Debug-iphonesimulator/HeyDan.app"
    xcrun simctl privacy "$udid" grant microphone {{bundle_id}}
    for name in $(compgen -A export HEYDAN_); do
        case "$name" in *_CMD|*_LINK) continue ;; esac
        export "SIMCTL_CHILD_$name=${!name}"
    done
    xcrun simctl launch --terminate-running-process "$udid" {{bundle_id}}

# A hands-free call with a disposable test pairing and per-row evidence.
sim-call seconds="65" say="":
    @HEYDAN_SIM={{quote(sim_name)}} HEYDAN_DERIVED_DATA={{quote(sim_build)}} HEYDAN_CALL_SECONDS={{quote(seconds)}} HEYDAN_CALL_SAY={{quote(say)}} python3 scripts/sim-e2e.py {{bundle_id}} call

# A hands-free Simulator call with machine-readable evidence in HEYDAN_RUN_DIR (default build/e2e).
sim-e2e:
    @python3 scripts/sim-e2e.py {{bundle_id}}

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

# Build and install on the unlocked phone, then call with an isolated test pairing.
device-call seconds="65" say="": gen
    #!/usr/bin/env bash
    set -euo pipefail
    list=$(mktemp)
    xcrun devicectl list devices --json-output "$list" >/dev/null
    udid=$(jq -r '[.result.devices[] | select(.hardwareProperties.platform == "iOS" and .hardwareProperties.reality == "physical")][0].hardwareProperties.udid // empty' "$list")
    rm -f "$list"
    [ -n "$udid" ] || { echo "no iPhone connected" >&2; exit 1; }
    xcodebuild -project HeyDan.xcodeproj -scheme HeyDan -destination "platform=iOS,id=$udid" -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
    xcrun devicectl device install app --device "$udid" build/Build/Products/Debug-iphoneos/HeyDan.app
    HEYDAN_CALL_SECONDS={{quote(seconds)}} HEYDAN_CALL_SAY={{quote(say)}} python3 scripts/sim-e2e.py {{bundle_id}} device-call "$udid"

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

# Fixture and system checks on the selected Simulator. Failed result bundles may contain private data.
sim-checks check="LiveActivityOnLockScreen":
    @python3 scripts/sim_tests.py sim-checks {{quote(sim_name)}} {{quote(sim_build)}} {{quote(bundle_id)}} {{quote(check)}}

# App-hosted tests and UI checks share the same Simulator test products.
app-test:
    @python3 scripts/sim_tests.py app-test {{quote(sim_name)}} {{quote(sim_build)}} {{quote(bundle_id)}}

# Treehouse runs this in every slot it hands out: copy the owner's untracked config from the main checkout.
# .env.local stays out (release account, test pairing command): copy it by hand for testflight, calls and HeyDanChecks.
lane-ready:
    #!/usr/bin/env bash
    set -euo pipefail
    main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
    [ "$main" != "$PWD" ] || exit 0
    for f in Local.xcconfig local.just; do
        if [ -f "$main/$f" ]; then cp -p "$main/$f" "$f"; fi
    done

# Capture the fixture gallery for the current commit on an existing Simulator.
[positional-arguments]
screens *args:
    @python3 -B scripts/screens.py {{quote(sim_name)}} {{quote(sim_build)}} {{quote(bundle_id)}} "$@"
