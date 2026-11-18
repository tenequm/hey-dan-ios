# Hey Dan - agent notes

Build, run and test commands are in [README.md](README.md). These are the traps agents hit.

- **Notification permission on a new Simulator.** No CLI grants it (`simctl privacy`, `XCUIProtectedResource` and
  `devicectl device settings` have no notifications entry). On a Simulator that never ran the app,
  `MessageNotificationTests` fails until the prompt is answered: run `just sim` once and tap Allow, or use a Simulator
  that already granted it (a clone keeps the grant). Do not try to automate the grant in `just app-test`.
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
