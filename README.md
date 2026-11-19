# Hey Dan

Native iPhone app for your [NanoClaw](https://github.com/tenequm/nanoclaw) agents: chat, push, calls.

<p align="center">
  <img src="docs/screenshots/list.png" width="200" alt="Chat list with three agents: one working, one done, one waiting for input">
  <img src="docs/screenshots/thread.png" width="200" alt="A thread with a markdown reply, a code block and a photo">
  <img src="docs/screenshots/call.png" width="200" alt="A call in the chat with a live caption, mute, options and end controls">
  <img src="docs/screenshots/push.png" width="200" alt="An agent's reply as a notification on the lock screen">
</p>

<details>
<summary>More screens</summary>

<p align="center">
  <img src="docs/screenshots/pairing.png" width="160" alt="Pair a host: paste the one-time pairing link">
  <img src="docs/screenshots/paired.png" width="160" alt="Paired: the host is ready and lists its agents">
  <img src="docs/screenshots/composer.png" width="160" alt="The composer with a file staged to send">
  <img src="docs/screenshots/rich-card.png" width="160" alt="A rich card with a table and a bar chart">
</p>
<p align="center">
  <img src="docs/screenshots/call-options.png" width="160" alt="Call options: the agent's voice and the typing sound">
  <img src="docs/screenshots/host.png" width="160" alt="A paired host: status, agents, active host and unpair">
  <img src="docs/screenshots/voice-picker.png" width="160" alt="Voice picker: an agent's provider and voice, saved on the host">
</p>

</details>

## What it does

- **Chat** with markdown and code, photos and files, question cards you answer with a tap, and rich cards with
  fields, tables and charts. What you send offline goes out when the host is back.
- **Replies on the lock screen** as communication notifications, with one unread badge across all your hosts.
- **Calls** through CallKit, so they keep going on the lock screen: start one from a thread or the Action Button,
  talk hands-free and follow live captions in the same thread. The call bar has mute, Call options and End.
  Call options lets you change the agent's voice or the typing sound.
- **Pairing** by one-time link: each host gets its own Secure Enclave key on the phone, and requests to the host are
  signed with it. Pair several hosts and pick the active one.
- **Live Activity**: the call's agent, state and clock on the lock screen and in the Dynamic Island, with an end key.

## How it works

Chat goes to your NanoClaw host's [app channel](https://github.com/tenequm/nanoclaw/blob/main/docs/app-channel.md) as
signed HTTPS requests, and one server-sent event stream keeps the chat list, threads and unread counts current. New
replies arrive as APNs pushes, which the notification service extension turns into communication notifications.
Calls use relay-only ICE over [LiveKit](https://github.com/livekit/client-sdk-swift). Each call belongs to its chat.
See [AGENTS.md](AGENTS.md#how-the-app-talks-to-the-host) for the protocol.

## Requirements

- A Mac with Xcode 27 (iOS 27 SDK and Simulator runtime) and an iPhone on iOS 27.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), [just](https://github.com/casey/just) and [jq](https://jqlang.org);
  Python 3.9+ and GNU `timeout` (from [coreutils](https://www.gnu.org/software/coreutils/)) for the test recipes;
  [uv](https://docs.astral.sh/uv/) for `just testflight`.
- A paid Apple Developer Program team for device builds and TestFlight (the push entitlements rule out a free
  personal team), with Xcode signed in to it; Simulator and unsigned builds need none.
- A [NanoClaw](https://github.com/tenequm/nanoclaw) host the phone reaches over HTTPS: its
  [app channel](https://github.com/tenequm/nanoclaw/blob/main/docs/app-channel.md) supports chat, pushes and calls.

## Getting started

1. Copy the local config, which stays out of git:
   - `Local.xcconfig` from [Local.xcconfig.example](Local.xcconfig.example): your `HEYDAN_BUNDLE_ID` and
     `DEVELOPMENT_TEAM`. Without it the bundle ID is `com.example.HeyDan` and there is no team.
   - Copy [.env.local.example](.env.local.example) to `.env.local`. Set `HEYDAN_CALL_PAIR_CMD` for test calls.
     The command prints a fresh one-time pairing link restricted to Stan. Each call run unpairs its own device.
     Set `NANOCLAW_SSH` and `NANOCLAW_DIR` for server logs, and `ASC_ENV_CMD` and `ASC_APP_ID` for TestFlight.
   - `local.just` (optional): your own recipes, imported by the [justfile](justfile).
2. `just gen` generates `HeyDan.xcodeproj` from [project.yml](project.yml).
3. Install: `just device` signs, installs and launches the app on the connected iPhone; or ship it through
   [TestFlight](#testflight).
4. Pair a host: send `/pair` to your agent in Telegram, or run `ncl devices pair --user <user-id> --agents <agent-id>`
   on the host. Hey Dan opens pairing on first launch. Tap **Paste** and **Pair with ...**. To pair another host,
   open Settings from the chat list. For pushes, set your team's APNs key and `APP_APNS_TOPIC` to your bundle ID (see the
   [app channel](https://github.com/tenequm/nanoclaw/blob/main/docs/app-channel.md) doc); a `just device` build
   registers for sandbox pushes.
5. Open a chat and tap **Call**, or set up the Action Button.

### Action Button

1. Shortcuts > + > Add Action > Hey Dan > Call agent.
2. Pick **Default agent**. Set it in Hey Dan under **Settings > Calls > Default agent**. With no selection, it
   calls the active host's first agent. Pick a specific agent in the shortcut to always call that agent.
   Update an existing saved-line shortcut by choosing **Default agent** again.
3. Call type: Audio, not Ask Each Time.
4. iOS Settings > Action Button > Shortcut > that shortcut.

A press then calls with the phone locked and Hey Dan out of sight: Call agent uses iOS 27's start-call intent schema,
which lets CallKit start a call from the background. Keep both fields saved in the shortcut; that setup is proven on
a locked iPhone (iOS 27.2). If iOS still refuses the call, the shortcut says so. Then use Start conversation
(Shortcuts > Hey Dan > Start conversation, or Siri: "Talk to Hey Dan"): it opens Hey Dan after Face ID and starts the
call there.

## Development

| Recipe | What it does |
| --- | --- |
| `just test` | `HeyDanCore` tests on the Mac (no Simulator) and the `sim-e2e` harness's own tests |
| `just build` | Compile-checks a device build without signing |
| `just app-test` | The app-hosted `HeyDanTests` in that Simulator (run `just sim` once to create it); shares one build with `sim-checks` |
| `just sim` | Creates the named Simulator if needed, installs the app and opens it |
| `just sim-checks <check>` | Runs a UI check, such as `ChatCallChecks` or `LiveActivityOnLockScreen` |
| `just sim-e2e` | Writes checks to `build/e2e`. Call rows use a temporary Stan pairing. Stack rows use a local NanoClaw host. |
| `just screens` | Captures the fixture screens in that Simulator into `.local/screens/<commit>/`; resets its keychain |
| `just device` | Signs, installs and launches on the connected iPhone |
| `just logs [since]` | The Simulator's app and LiveKit log for the last `since` (default `15m`) |
| `just testflight [dry]` | Archives, signs, uploads and waits for processing; `dry` validates without uploading |

`just --list` shows the rest (`gen`, `sim-call`, `device-call`, `device-logs`, `server-logs`, `lane-ready`), and
[AGENTS.md](AGENTS.md) has the traps and what the stack checks need. CI: [ci.yml](.github/workflows/ci.yml) runs the
core tests, the device build and the app tests on pull requests and pushes to `main`;
[ui-checks.yml](.github/workflows/ui-checks.yml) runs the fixture UI checks by hand.

## TestFlight

`just testflight` archives a Release build, signs it for App Store distribution with an App Store Connect API key,
uploads it with a timestamp build number and waits for App Store Connect to process it, failing on a rejection.
`just testflight dry` exports and validates the IPA locally and uploads nothing, though the export still reserves a
build number in App Store Connect. The version is `MARKETING_VERSION` in [project.yml](project.yml).

One-time setup:

1. An App Store Connect team API key with the Admin role (Users and Access > Integrations). The recipe reads
   `ASC_KEY_P8_B64` (the .p8 in base64), `ASC_KEY_ID` and `ASC_ISSUER_ID` from the environment; `ASC_ENV_CMD` in
   `.env.local` can prefix the run with a command that sets them. An App Manager key cannot create the cloud-managed
   distribution certificate (403 on `DISTRIBUTION_MANAGED`).
2. In your [Apple Developer account](https://developer.apple.com/account), register the App Group
   `group.<HEYDAN_BUNDLE_ID>` and enable it on both App IDs, `<HEYDAN_BUNDLE_ID>` and
   `<HEYDAN_BUNDLE_ID>.NotificationService` (create them there if `just device` has not). The API key cannot do this,
   and `just testflight` cannot sign until it is done.
3. [App Store Connect](https://appstoreconnect.apple.com) > Apps > + > New App: platform iOS, a name of your choice,
   your `HEYDAN_BUNDLE_ID`, any SKU. Put its Apple ID (App Information) in `.env.local` as `ASC_APP_ID`.
4. After the first upload: TestFlight > Internal Testing > + to add a group with yourself, add the build, then install
   it from the TestFlight app.

A TestFlight build registers for production pushes, so the host needs its production APNs key. The app declares no
non-exempt encryption, so builds skip the export compliance question.

## Privacy

- Each paired host gets its own Secure Enclave key, which never leaves the phone. The app signs its requests to that
  host with it; only the version check, the pairing request and ticketed file uploads go unsigned.
- The thread cache and the outbox stay on the phone and out of its backups.
- Logs carry only ids, states, codes and durations: never a token, a link or anything said or written.
- No analytics or tracking. A push carries a preview of the message through Apple's push service.

## License

[MIT](LICENSE). The bundled fonts keep their own licenses: SIL Open Font License, `OFL.txt` beside each.
