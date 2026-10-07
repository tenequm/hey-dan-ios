# Hey Dan

Native iPhone voice client for [NanoClaw](https://github.com/tenequm/nanoclaw) voice lines. Press the
Action Button, talk to the agent; the call keeps going with the screen locked.

- **CallKit** owns the call: lock-screen controls, AirPods mute and hangup, interruptions, routing.
- **NanoClaw** admits it: `POST /voice/livekit/token?t=<token>&v=6` returns the LiveKit URL, room token,
  call id and the host's `protocol`; `POST /voice/livekit/end` hangs up. The contract lives in `HeyDanCore` and
  mirrors nanoclaw's `src/channels/voice-mode-protocol.ts` and its browser call page,
  `.claude/skills/add-voice-mode/ui/src/lib/livekit-call.ts` (join timeout, end reasons, DTX off).
- **Protocols 6 and 4**: the app asks for protocol 6 on every call. A protocol 6 host says `protocol: 6` and its
  worker uses `nanoclaw.voice-mode.*` names; an older host ignores `v`, names no protocol and is protocol 4, whose
  worker uses `nanoclaw.voice.*` (`voice-livekit-protocol.ts`). The app picks the names per call from the grant
  (`VoiceProtocol.Names`); a grant naming any other protocol is never joined: the app ends that call on the host
  and asks the caller to update. Below, `<ns>` is the call's namespace.
- **LiveKit Swift** carries the audio. The app shows connecting, listening, thinking
  (`<ns>.thinking`), speaking (`lk.agent.state`), and why a call ended.
- **Voice lines**: several call links, kept in one Keychain item (`voice-lines`; the older single
  `call-link` item moves into it on first launch). Each line is named for the agent its host says answers
  it (`GET /voice/info`, or the grant on its first call). Settings picks the line the Action Button calls.
- **Action Button**: a shortcut running the Call agent intent starts the call in the background, on a locked
  phone too, without opening the app (see [Action Button](#action-button)). The Start conversation intent is
  the backup: it opens Hey Dan (on a locked phone after Face ID) and starts the call there; its optional Line
  parameter lets a shortcut call one agent in particular.
- **Tailscale precheck**: the lines are tailnet-only. Before the microphone prompt and before CallKit
  shows a call, the app looks for a tailnet address on the phone's interfaces; with none, and the line's
  host resolving only to tailnet addresses, it still asks the host for the call on a 4 s timeout and says
  Tailscale looks off only when that cannot reach it. A misread never blocks a call, and the app still
  says so when it cannot reach the host later.
- **Transcript and spoken commands**, drawn like the browser page's screen and control rail: the worker's
  captions (`lk.transcription` text streams) and its turn, reply and review topics fold into a live
  transcript the way the browser page folds them, and auto mode's wake switch, pause sending and typing
  sound go to the worker over its `<ns>.settings` RPC (once per call, after setup) when it
  advertises commands vocabulary "2" or "3".
- **Manual mode** (the page's review mode), when the worker sets `<ns>.review` = "1": talk, done,
  read the draft, then send or discard it, over the worker's `<ns>.{mode,talk,done,send,discard}`
  RPCs; the hands-free | Manual pick is kept for the next call.
- **Live Activity** (the `HeyDanActivity` widget extension): the call's agent, state and clock on the lock
  screen and in the Dynamic Island, with an end key.
- **Logs**: subsystem = the app's bundle ID, one category per area, built only from ids, states, codes and
  durations (never a token, URL or anything said). Each call line carries `c=<call> cid=<host callId> +ms`.

## Requirements

- macOS with Xcode 27 (iOS 27 SDK and Simulator runtime); an iPhone on iOS 27 to run it on a device.
- Swift 6.2+ (ships with Xcode 27).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [just](https://github.com/casey/just);
  [jq](https://jqlang.org) for the Simulator and device recipes; [uv](https://docs.astral.sh/uv/) for
  `just testflight`; `ssh` only for the recipes that read your server.
- An Apple Developer team for device builds and TestFlight (Simulator and unsigned builds need none).

## Server

Hey Dan is only a client: it needs your own [NanoClaw](https://github.com/tenequm/nanoclaw) with voice
mode set up by its
[add-voice-mode skill](https://github.com/tenequm/nanoclaw/blob/main/.claude/skills/add-voice-mode/SKILL.md).
Each voice line on that server has an HTTPS call link, `https://<your-host>/voice?t=<token>`; that link is
what the app stores. The phone must reach the host: the app's Tailscale precheck assumes a tailnet-only
host, but any HTTPS host the phone can reach works.

## Local config

Owner-specific values stay out of git; copy the examples and fill them in:

- `Local.xcconfig` (from `Local.xcconfig.example`): `HEYDAN_BUNDLE_ID` and `DEVELOPMENT_TEAM`, read by
  `Config.xcconfig` for every target and by the recipes. Without it the bundle ID is `com.example.HeyDan`
  and there is no team.
- `.env.local` (from `.env.local.example`, loaded by `just`): the test line for Simulator calls
  (`TEST_CALL_LINK`, or `NANOCLAW_SSH`/`NANOCLAW_DIR` to read it from the server), the server for
  `just server-logs`, and `ASC_ENV_CMD`/`ASC_APP_ID` for `just testflight`. A recipe that needs an unset
  value says which one.
- `local.just` (optional): your own recipes or aliases, imported by the `justfile`.

## Setup

1. Fill in the local config above, then `just gen` and open `HeyDan.xcodeproj`.
2. Run on the iPhone (`just device`, automatic signing), or ship it through TestFlight (below).
3. Add each voice line's call link (`https://voice.example.com/voice?t=...`) in Settings and pick the line
   the Action Button calls. With a tailnet-only host, Tailscale must be connected on the phone.
4. Assign the Action Button as [Action Button](#action-button) says.

## Action Button

1. Shortcuts > + > Add Action > Hey Dan > Call agent.
2. Agent: it comes filled in with the line picked in Hey Dan; change it to call another agent.
3. Call type: Audio. Do not choose Ask Each Time.
4. Settings > Action Button > Shortcut > that shortcut.

A press then calls the agent with the phone locked and Hey Dan out of sight: the call shows on the lock screen
and in the Dynamic Island. Call agent is iOS 27's phone start-call intent (`.phone.startCall` schema), and a
call started through it passes CallKit's user-intent check in the background; a plain intent started from the
background does not ("user intent could not be validated"). Both fields must be saved in the shortcut, not
left to Ask Each Time: the saved shortcut is the setup proven on a locked iPhone (iOS 27.2). If iOS still refuses the call, the shortcut says so; then
use Start conversation (Shortcuts > Hey Dan > Start conversation, or Siri: "Talk to Hey Dan"), which opens Hey
Dan after Face ID and starts the call there, or open Hey Dan and call from its screen.

## Development

- `just test` runs the `HeyDanCore` tests on the Mac (no simulator needed); `just build` compile-checks
  for a device without signing.
- `just sim` runs the app in the Simulator (named "Hey Dan iPhone"; `HEYDAN_SIM` and `HEYDAN_DERIVED_DATA`
  pick another one and its build folder) with the test line's call link seeded (see
  [Local config](#local-config)). Use a test line, not your main agent's line: a test turn keeps that agent
  busy on your own calls. `just sim-call <seconds>
  "<what the caller says>"` places a real call to the test line from it: the caller's words are synthesized and fed
  in place of the microphone, and it hangs up after `seconds`. `HEYDAN_STEPS="20:mute,26:manual,33:talk"`
  presses keys mid-call (`mute`, `unmute`, `manual`, `handsfree`, `talk`, `done`, `send`, `discard`, timed
  from launch); `mute` and `unmute` are the same CallKit mute transaction the lock screen and AirPods send.
  `HEYDAN_TURN_MODE=auto|review` (`just sim-call`'s `mode`) sets the pick calls start in, and
  `HEYDAN_HANGUP_AFTER` ends every call, an intent's too. `HEYDAN_AUDIO_METER=1` logs the agent's audio as the app
  renders it (`meter playout` and `meter track`, rms/peak dBFS each second with sound), so a reply is checked
  in the log, not by ear. `HEYDAN_SIMULATE="quick@15,full@40"` runs LiveKit's `debug_simulate` reconnects
  (`quick`, `full`, `node`, `migration`, `leave`) that many seconds after the call went live; DEBUG logs
  `reconnect start/done mode=`. Every `HEYDAN_*` variable set for `just sim` reaches the app.
- `just sim-checks <check>` runs `HeyDanChecks`, a UI test bundle, for what used to need the phone in hand:
  `LiveActivityOnLockScreen` (the Live Activity in the Dynamic Island, then on the Lock Screen with the
  "Allow Live Activities" choice), `IntentStartsCallFromBackground` (the Start conversation intent run out of
  process through AppIntentsTesting with the app in the background; `HEYDAN_CHECK_LOCKED=1` locks first)
  and `ActionButtonStartsCall` (the Action Button, after `SetActionButtonToHeyDan` picked Hey Dan's Start
  conversation in Settings once); both expect the app to come forward and the call to go live. Screenshots
  land in `build/checks`. `xcrun
  devicectl device settings audio --device <sim> --input-device <uid>` picks the Simulator's microphone
  (`systemDefault` is the Mac's).
- Simulator calls go through CallKit as on the phone (provider, start/end/mute transactions), with
  Simulator-only stand-ins for what the Simulator lacks, in Debug and Release Simulator builds and never in a
  device build: the app claims the `facetime` URL scheme, because callservicesd ends a call it finds no FaceTime
  app to show its in-call UI with; it activates the audio session itself after the start action, because
  callservicesd cannot activate it there (`didActivate` never comes); and WebRTC gathers on any address, so
  the Mac's Tailscale tunnel carries the call. DEBUG Simulator builds also take `HEYDAN_PREVIEW_PHASE` (incl. `manual`, `recording`,
  `finishing`, `draft`, `notsent`, `toolong`, `manual-speaking`, `kept`), `HEYDAN_PREVIEW_LINES`,
  `HEYDAN_PREVIEW_SETTINGS` and `HEYDAN_PREVIEW_ACTIVITY` for screenshots.
- `just device` signs, installs and launches on the connected iPhone.
- `just logs [since]` shows the Simulator's app and LiveKit log; `just device-logs` copies the phone's
  DEBUG log file; `just server-logs <cid>` shows the server's side of one call over ssh.

## TestFlight

`just testflight` archives a Release build, signs it for App Store distribution and uploads it to App
Store Connect with an App Store Connect API key from the environment (`ASC_KEY_P8_B64`, the .p8 in
base64, plus `ASC_KEY_ID` and `ASC_ISSUER_ID`; `ASC_ENV_CMD` in `.env.local` can fetch them from a secret
manager; the key lands in a private temp file for the run only). Each upload gets a timestamp build number (`yyMMddHHmm`); the version stays `MARKETING_VERSION`
in `project.yml`. The recipe then waits for App Store Connect (`scripts/testflight-wait.py`, every 30 s
for up to 30 minutes): it prints the upload's state with any error and warning codes, fails when the
upload ends anything but `COMPLETE` or the build anything but `VALID`, and once it passes the build
appears in the TestFlight app on any device in the testing group.
`just testflight dry` runs the same archive and export with a local `destination` and validates the IPA
with `altool --validate-app`, uploading nothing; the export still reserves the build number in App Store
Connect, so a stray `AWAITING_UPLOAD` record stays behind.
LiveKit ships `LiveKitWebRTC` and `RustLiveKitUniFFI` stripped and publishes no dSYMs for them, so the
recipe generates placeholder dSYMs with `dsymutil` (matching UUIDs and exported symbols, no DWARF): they
silence the upload's "Upload Symbols Failed" warnings, but crashes inside those frameworks still
symbolicate only to the nearest exported symbol.

One-time setup:

1. An App Store Connect team API key with the Admin role (Users and Access > Integrations), where
   `ASC_ENV_CMD` finds it. With `-allowProvisioningUpdates` xcodebuild signs through it with a cloud-managed
   distribution certificate and the App Store profiles it creates; an App Manager key cannot (403 on
   `DISTRIBUTION_MANAGED`).
2. [App Store Connect](https://appstoreconnect.apple.com) > Apps > + > New App: platform iOS, name
   Hey Dan, primary language English, your `HEYDAN_BUNDLE_ID`, any SKU (e.g. `heydan`). Put its Apple ID
   (App Information) in `.env.local` as `ASC_APP_ID`: the recipe waits on that app's processing.
3. After the first upload: TestFlight > Internal Testing > + to add a group with yourself, add the
   build, then install it from the TestFlight app on the iPhone.

The app declares no non-exempt encryption (`ITSAppUsesNonExemptEncryption`), so builds skip the
export compliance question.

## License

[MIT](LICENSE). The bundled fonts keep their own licenses: SIL Open Font License, `OFL.txt` beside each.
