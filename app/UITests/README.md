# Workjet click user stories

The existing Swift package builds `WorkjetApp` as an executable target, not as
an Xcode application/UI-test target. Consequently `swift test` cannot launch the
menu-bar application through `XCUIApplication`, and adding a pretend duplicate
view hierarchy here would repeat the exact failure mode these stories are meant
to catch.

`ClickUserStoryContractTests` is the maximum honest coverage available without
changing `Package.swift` or production files. It exercises the real public
`WorkerDraft`, `WorkjetViewModel`, `ManagedPrompt`, filtering, and persistence
boundaries used by `RootView`, `WorkerListView`, and `WorkerEditorView`.

## Required click stories

1. **Every worker row shows its own state**
   - Launch Workjet with one connected worker, one missing provider route, and
     one active run.
   - Assert every row exposes a status accessibility value: `Ready`, `Running`,
     `Unavailable`, or `Error`, plus a concise reason where applicable.
   - Assert status belongs to the row's stable worker UUID, not only to the
     global header.
2. **The Completion Engine pencil edits that exact worker**
   - Click `Completion Engine bearbeiten`.
   - Assert title `Worker bearbeiten` and the persisted name, harness, provider
     route, model, reasoning, instructions, computer, and invocation fields.
   - Change nothing, save, reopen, and assert the same worker UUID remains.
3. **The model block has one source**
   - Open Completion Engine and record the visible model-specific text.
   - Open Settings/Prompt and assert the `GPT-5.6 Sol` block is byte-identical.
4. **Edit, save, reopen, compose**
   - Change worker instructions and the associated model block, save, close the
     popover, reopen it, then open Settings/Prompt.
   - Assert both persisted values and their exact managed-prompt output.
5. **A missing provider route does not hide editable worker data**
   - Remove the provider route from a configured worker.
   - Assert model, reasoning, model block, and worker instructions stay visible
     and editable; show the provider error inline without collapsing fields.
6. **Switch computers and move a worker**
   - Select a remote computer button and assert only its workers are listed.
   - Edit Completion Engine, select the remote computer, save, then assert it
     disappears from Local and appears under the remote computer.
7. **Settings tabs navigate the one-page settings view**
   - From the top, click every settings tab.
   - Assert its real section header becomes visible and is aligned below the
     sticky tab bar. Repeat after manual scrolling and in reverse order.

## Minimal test architecture required for real clicks

The production app needs a small Xcode project (or generated `.xcodeproj`) whose
application target continues compiling the existing `Sources/WorkjetApp` files
and links `WorkjetCore`. Add one UI-test target that launches the real app via
`XCUIApplication` with a test-only launch argument pointing at a temporary
configuration/state root. The launch argument must only replace storage and
telemetry dependencies; it must not select alternate or duplicated views.

The production views then need stable accessibility identifiers on:

- computer buttons and add/edit controls;
- each worker row and its pencil, keyed by worker UUID;
- every WorkerEditor field, validation message, and save outcome;
- prompt/model blocks, keyed by canonical model name;
- settings tabs and their actual scroll targets.

Finally, expose row status as a pure Core presentation value keyed by worker UUID
and render that same value in `WorkerRow`. This is currently absent: capacity and
global health inputs exist, but there is no public per-worker operational-status
contract a UI test can assert. Likewise, `RootView.Screen` and the settings scroll
position are private SwiftUI state, so a Core-only test cannot prove pencil routing
or tab scrolling.

Until those minimal hooks exist, stories 1 and 7 and the actual click portion of
story 2 remain intentionally open rather than falsely marked covered.
