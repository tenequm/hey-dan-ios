# Hey Dan - agent notes

Commands are `just` recipes: [README.md](README.md#development) lists them and the [justfile](justfile) documents
each. Below: the traps agents hit, how the app talks to the host, and what test runs need.

Git hooks are [lefthook](https://github.com/evilmartians/lefthook) ([lefthook.yml](lefthook.yml)): run
`lefthook install` once per clone, then `kst sync` once: the hook syncs only on the next checkout. Commits that touch
a workflow run `actionlint`; checkouts sync the agent skills in [kasetto.yaml](kasetto.yaml)
([kasetto](https://github.com/pivoshenko/kasetto), `kst`; skipped without `kst`).

- **Notification permission on a new Simulator.** No CLI grants it (`simctl privacy`, `XCUIProtectedResource` and
  `devicectl device settings` have no notifications entry). On a Simulator that never ran the app,
  `MessageNotificationTests` fails until the prompt is answered: run `just sim` once and
  tap Allow, or use a Simulator that already granted it (a clone keeps the grant). Do not try to automate the grant in
  `just app-test`. CI runs on a Simulator that never ran the app, so its workflow skips that test by name
  (`HEYDAN_SKIP_TESTS`).
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

## Which checks when

- **Tier 0, every edit loop, no Simulator:** `just build`, `just test`.
- **Tier 1, before a lane pushes:** only the UI check class or single test for the code it touched
  (`just sim-checks ChatThreadChecks/testRichCardTable`), on one Simulator, shut down right after. Delete only a
  Simulator the lane created under its own `HEYDAN_SIM`, never `Hey Dan iPhone`.
- **Tier 2, once per integration or release candidate:** the fixture UI checks and `just app-test` (CI only: the
  `ui-checks` shards and App tests run them on every pull request that touches code), plus what CI cannot run, locally:
  `just sim-checks ChatPushChecks` (needs a real bundle ID in `Local.xcconfig`), `just sim-e2e` (the stack rows) and
  one live call, `just sim-call`, with the test agent only.
- **Machine rules:** at most one booted Simulator on the Mac at a time across all agents; review agents never build;
  never run the full UI set or `just app-test` locally.

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
  extension share the App Group `group.$(HEYDAN_APP_ID)` (the beta variant's ids and group end in `.beta`, so the two apps share nothing) to total the last unread counts of all paired hosts into
  one badge.
- **Paired calls.** `POST /app/calls` with an `attemptId` (a retry recovers the same call) returns the grant;
  `POST /app/calls/<callId>/end` hangs up, and `POST /app/calls/attempts/<attemptId>/cancel` drops a start still
  pending. Paired calls connect with relay-only ICE.
- **Call protocol 6.** The signed grant names its protocol. The app ends an unsupported grant on the host before
  joining. The protocol 6 worker uses the namespace `nanoclaw.voice-mode` (`<ns>` below).
- **In the call.** CallKit owns it (lock screen, AirPods, interruptions, routing); LiveKit carries the audio. The screen
  shows connecting, listening, thinking (`<ns>.thinking`), speaking (`lk.agent.state`) and why a call ended. Captions
  (`lk.transcription` text streams) and the worker's `<ns>.turn`, `<ns>.reply` and `<ns>.review` topics fold into the
  transcript the way the browser page folds them. When the worker sets `<ns>.commands` to "2" or "3", the caller's
  picks (wake switch, pause sends, typing sound) go to it over the `<ns>.settings` RPC, once per call after setup.
- **Live Activity** (`HeyDanActivity`): its end key is a `LiveActivityIntent`, which runs in the app's process, where
  the call is.
- **Logs**: subsystem = the bundle ID, one category per area, built only from ids, states, codes and durations, never
  a token, URL or anything said. Each call line carries `c=<call> cid=<first 8 of the host callId> +ms`, and
  `just server-logs <cid>` shows the host's side of that call.

## Test runs

- Test calls use `HEYDAN_CALL_PAIR_CMD` from `.env.local` to mint a link restricted to the single agent named by `HEYDAN_CALL_AGENT`. The DEBUG app keeps
  the test run's pairing and key in their own Keychain namespace and unpairs after the call. The runner retries
  cleanup for the same run on failure. `HEYDAN_E2E_SAY` overrides the synthesized wake phrase and question.
- A DEBUG build launched with `HEYDAN_FIXTURE_CHAT=1` gets a paired fixture host and no network; the fixture
  `Chat*Checks` and `just screens` run on it.
- The stack checks in `ChatChecks` run as the `app-*` rows of `just sim-e2e` and need a local nanoclaw stack:
  `HEYDAN_LOCAL_BASE` (its base URL) and `HEYDAN_PAIR_CMD` (prints one fresh pairing link, a secret), optionally
  `HEYDAN_LOCAL_CA`, `HEYDAN_STACK_RESTART_CMD`, `HEYDAN_REVOKED_CMD` and `HEYDAN_CHAT_ONLY` (`scripts/sim-e2e.py`).
  Without a stack those rows skip. Test call rows can run independently.
- `just sim` forwards debug hooks except commands and links. Most hooks live in `HeyDanApp.swift`.
