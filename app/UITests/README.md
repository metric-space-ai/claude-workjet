# Workjet macOS click suite

`WorkjetClickUITests` launches the production `RootView` through the real
`Workjet` macOS application target. It does not maintain a test-only copy of the
UI. The host uses an ordinary window only when `WORKJET_UI_TEST_WINDOW=1`, so UI
automation can address the menu-bar application's controls reliably without
creating a second status-bar icon.

Each test supplies a unique `WORKJET_UI_TEST_HOME`. Configuration and runtime
state therefore stay in a temporary directory and never touch the user's
Workjet home or credentials. `WORKJET_UI_TEST_SEED=1` creates the deterministic
worker/provider fixture only when that isolated configuration is absent, which
also lets the suite terminate and relaunch the app to prove persistence.

Run the suite from `app/`:

```sh
xcodebuild \
  -project Workjet.xcodeproj \
  -scheme Workjet \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  ONLY_ACTIVE_ARCH=YES \
  test
```

The journey covers the production Completion Engine pencil and editor fields,
save/relaunch persistence, the missing-route recovery action, masked provider
account identity, provider deselection and disconnect, Settings quick
navigation, and the one-click custom compatible-endpoint form.
