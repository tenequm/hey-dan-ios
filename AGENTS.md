# Hey Dan - agent notes

Commands are `just` recipes: [README.md](README.md#development) lists them and the [justfile](justfile) documents
each. Below: the traps agents hit, how the app talks to the host, and what test runs need.

Agent skills come from [kasetto.yaml](kasetto.yaml) ([kasetto](https://github.com/pivoshenko/kasetto), `kst`): run
`git config core.hooksPath .githooks` once per clone so checkouts sync them (the hook does nothing without `kst`).

- **Notification permission on a new Simulator.** No CLI grants it (`simctl privacy`, `XCUIProtectedResource` and
  `devicectl device settings` have no notifications entry). On a Simulator that never ran the app,
  `MessageNotificationTests` fails until the prompt is answered: run `just sim` once and tap Allow, or use a Simulator
  that already granted it (a clone keeps the grant). Do not try to automate the grant in `just app-test`. CI runs
  on a Simulator that never ran the app, so its workflow skips that test by name (`HEYDAN_SKIP_TESTS`).
- **`just sim-checks` selectors.** `ChatThreadChecks` (or any `*Checks` class) runs that class,
  `ChatThreadChecks/testRichCardTable` one method, and a bare name like `LiveActivityOnLockScreen` the
  `HeyDanChecks/test<name>` method. A selector that matches no test, or whose tests all skip (the stack checks in
  `ChatChecks` without a local stack), fails instead of passing.
- **Build once.** `just app-test` and `just sim-checks` share one build-for-testing per HEAD and working tree
  (`build/HeyDanSimulatorTests.key`); a changed tree rebuilds, an unchanged one reuses the products.
- **UI checks run without animations.** Checks launch the app with `HEYDAN_UITEST=1`, which DEBUG builds read to turn
  animations off; Release never reads it. Test videos are off; the checks' own screenshots land in `build/checks`.
- Bump `SwiftDataThreadStore.schemaVersion` when the thread decoder gains a field, card part or entity kind.
  Cached JSON contains only what its writer understood. The version change rebuilds history from the host and
  preserves the outbox. A cached unknown item also invalidates that thread's pages on the next load.

## How the app talks to the host

`HeyDanCore` holds the contract and mirrors nanoclaw: chat is its
[app channel](https://github.com/tenequm/nanoclaw/blob/main/docs/app-channel.md) (`src/channels/app/`), calls are its
voice mode (`src/channels/voice-mode-protocol.ts` and the browser call page,
`.claude/skills/add-voice-mode/ui/src/lib/livekit-call.ts`). `app-contract.fixtures.json` in `HeyDanCoreTests` is a
copy of the host's `src/channels/app/app-contract.fixtures.json`; take contract changes from there.

- **Chat, app protocol 1.** Routes live under `/app` on each paired host. Only `hello`, `pair` and ticketed uploads go
  unsigned; every other request carries `HeyDan-Sig`, signed by that host's own Secure Enclave key. One SSE stream,
  `GET /app/events?after=<seq>`, feeds the list, threads, statuses and badge. `hello`'s `features` (`files`, `calls`,
  `push`, `voice-picker`) gate the UI and are re-read on every connect.
- **Pushes.** `HeyDanNotificationService` turns the host's pushes into communication notifications. The app and the
  extension share the App Group `group.$(HEYDAN_BUNDLE_ID)` to total the last unread counts of all paired hosts into
  one badge.
- **Paired calls.** `POST /app/calls` with an `attemptId` (a retry recovers the same call) returns the grant;
  `POST /app/calls/<callId>/end` hangs up, and `POST /app/calls/attempts/<attemptId>/cancel` drops a start still
  pending. Paired calls connect with relay-only ICE.
- **Voice lines.** `POST /voice/livekit/token?t=<token>&v=6` admits a call and returns the LiveKit URL, room token,
  call id and the host's `protocol`; `POST /voice/livekit/end` hangs up; `GET /voice/info` names the agent without a
  call. The lines live in one Keychain item, `voice-lines`, on this device only; the older single `call-link` item
  moves into it on first load.
- **Protocols 6 and 4.** The app asks for 6 on every call. A protocol 6 host answers `protocol: 6` and its worker uses
  `nanoclaw.voice-mode.*`; an older host ignores `v`, names no protocol and is 4, whose worker uses `nanoclaw.voice.*`.
  `VoiceProtocol.Names` picks the names per call. A grant naming any other protocol is never joined: the app ends that
  call on the host and asks the caller to update. Below, `<ns>` is the call's namespace.
- **Tailscale precheck** (voice lines only). Before the microphone prompt and CallKit, the app looks for a tailnet
  address on the phone's interfaces. With none, and the line's host resolving only to tailnet addresses, it still asks
  the host for the call on a 4 s timeout and says Tailscale looks off only when that cannot reach it. A misread never
  blocks a call.
- **In the call.** CallKit owns it (lock screen, AirPods, interruptions, routing); LiveKit carries the audio. The screen
  shows connecting, listening, thinking (`<ns>.thinking`), speaking (`lk.agent.state`) and why a call ended. Captions
  (`lk.transcription` text streams) and the worker's `<ns>.turn`, `<ns>.reply` and `<ns>.review` topics fold into the
  transcript the way the browser page folds them. When the worker sets `<ns>.commands` to "2" or "3", the caller's
  picks (wake switch, pause sends, typing sound) go to it over the `<ns>.settings` RPC, once per call after setup.
- **Manual mode** (the page's review mode) is offered only when the worker sets `<ns>.review` = "1": talk, done, read
  the draft, then send or discard it over `<ns>.{mode,talk,done,send,discard}`. The Hands-free or Manual pick is kept
  for the next call.
- **Live Activity** (`HeyDanActivity`): the call's agent, state and clock on the lock screen and in the Dynamic
  Island; its end key is a `LiveActivityIntent`, which runs in the app's process, where the call is.
- **Logs**: subsystem = the bundle ID, one category per area, built only from ids, states, codes and durations, never
  a token, URL or anything said. Each call line carries `c=<call> cid=<first 8 of the host callId> +ms`, and
  `just server-logs <cid>` shows the host's side of that call.

## Test runs

- Test calls go to a test line (`TEST_CALL_LINK` in `.env.local`, or `HEYDAN_E2E_CALL_LINK` for `just sim-e2e`),
  never the main agent's: a test turn keeps that agent busy on the owner's own calls.
- A DEBUG build launched with `HEYDAN_FIXTURE_CHAT=1` gets a paired fixture host and no network; the fixture
  `Chat*Checks` and `just screens` run on it.
- The stack checks in `ChatChecks` run as the `app-*` rows of `just sim-e2e` and need a local nanoclaw stack:
  `HEYDAN_LOCAL_BASE` (its base URL) and `HEYDAN_PAIR_CMD` (prints one fresh pairing link, a secret), optionally
  `HEYDAN_LOCAL_CA`, `HEYDAN_STACK_RESTART_CMD`, `HEYDAN_REVOKED_CMD` and `HEYDAN_CHAT_ONLY` (`scripts/sim-e2e.py`).
  Without a stack those rows skip; with one, the saved-line call does.
- Every `HEYDAN_*` variable set for `just sim` (and so `just sim-call`) reaches the app; `just sim-checks` hands them
  to the checks too, except links and `*_CMD`. Most DEBUG hooks that read them are in `HeyDanApp.swift`;
  `rg 'HEYDAN_' HeyDan` finds the rest.
