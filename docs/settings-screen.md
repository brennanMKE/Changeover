# Building a Settings screen on macOS

What the platform expects a Settings window to be, how to build one in
SwiftUI, and the specific decisions worth making deliberately rather than
by accident.

Written against the project's macOS 26.2 deployment target, so everything
here — the `Settings` scene, `SettingsLink`, `@Observable`, grouped form
styling — is available without back-compatibility work.

---

## What macOS expects

A Settings window on macOS is not a modal dialog and not a page in your
app. It is a specific, conventional thing, and users have expectations
about it that predate your app:

- **It opens with ⌘,** and from an app menu item named "Settings…"
  (renamed from "Preferences…" in Ventura).
- **It applies changes immediately.** There is no Save button and no
  Cancel. Flip a switch, the setting takes effect. This is the single
  biggest difference from settings UI on other platforms, and the one most
  often gotten wrong.
- **It is a single window**, reused. Invoking Settings twice brings the
  existing window forward; it never opens a second one.
- **It is not resizable in most apps**, or resizes only within narrow
  bounds. The content defines the size.
- **It sits above the app's other windows** but is not modal — the rest of
  the app stays usable.
- **Multiple panes use a toolbar-style tab bar** at the top, with icons and
  short labels, when there is enough content to warrant splitting.

The most useful mental model: a Settings window is a *control panel for a
running app*, not a *form you fill in and submit*.

---

## Where this project stands today

Facts, read from the current source:

- `ChangeoverApp.swift` declares `Settings { EmptyView() }` — a real
  Settings scene registered with an empty body.
- `AppDelegate.showSettings()` builds an `NSWindow` by hand
  (`styleMask: [.titled, .closable]`, 460×300), hosts `SettingsView` in an
  `NSHostingView`, and reuses the window across closes via
  `isReleasedWhenClosed = false`.
- `SettingsView` is a `VStack` of three `GroupBox`es with a **Save button**
  that calls `settings.persist()` and then closes the window.
- `AppSettings` is `@Observable`, loads from `UserDefaults` in `init()`,
  and writes on an explicit `persist()` call.
- `choosePlexRoot()` calls `persist()` immediately after the panel returns —
  so some changes already save on the spot while others wait for Save.
- `AppDelegate` calls `showSettings()` at launch when
  `!settings.isConfigured`.
- `INFOPLIST_KEY_LSUIElement = YES` — no Dock icon, no app menu bar.

Four things in that list are worth revisiting, in rough order of impact.

### 1. Two settings windows are declared, and one is empty

`Settings { EmptyView() }` registers the system Settings scene. The real UI
is a separate hand-built `NSWindow`. Anything that reaches the system scene
— ⌘, if a menu is ever present, `SettingsLink`, or AppKit's
`showSettingsWindow:` action — opens an empty window, while the real one
opens only from your own code path.

Pick one. The two reasonable choices are covered below.

### 2. The Save button contradicts the platform

macOS settings apply immediately. The current mix — `choosePlexRoot()`
persists right away, the text fields wait for Save — means closing the
window with the red button silently discards typed changes while keeping a
chosen folder. That is the kind of inconsistency users experience as data
loss.

### 3. The TMDB API key is in `UserDefaults`

`SecureField` masks the value on screen, but `UserDefaults` writes it in
plaintext to a plist any process running as the user can read. Secrets
belong in the Keychain. See "Secrets" below.

### 4. The window cannot resize and may not fit

`SettingsView` sets `.frame(width: 460)` while the window is created at
460×300. The content — three group boxes, derived path previews, help text
— is taller than 300 points, and with `styleMask` lacking `.resizable` the
user cannot do anything about it. Let the content drive the size.

---

## Choosing how to present it

### Option A — the SwiftUI `Settings` scene

```swift
@main
struct ChangeoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.settings)
        }
    }
}
```

The system owns the window: single-instance behavior, correct title,
correct ⌘, binding, standard placement and restoration. You write content,
not window management. `AppDelegate.settingsWindow` and its reuse logic go
away.

**The wrinkle for this app:** `LSUIElement = YES` means there is no app
menu, so there is no "Settings…" item and ⌘, has nothing to attach to. You
must supply your own entry point — which you already do from the status
item.

From SwiftUI, use `SettingsLink` rather than poking at AppKit selectors:

```swift
SettingsLink {
    Label("Settings…", systemImage: "gearshape")
}
```

`SettingsLink` is the supported way to open the Settings scene from your own
UI. Avoid `NSApp.sendAction(Selector(("showSettingsWindow:")), ...)` — the
selector name has changed across releases and a wrong guess fails silently.

Because the app is an accessory (no Dock icon), also activate so the window
comes to the front:

```swift
NSApp.activate(ignoringOtherApps: true)
```

Without this, a menu bar app's Settings window can open behind whatever the
user is looking at. Test it specifically.

### Option B — keep the hand-built `NSWindow`

Legitimate if you need something the scene will not give you. If you keep
it:

- **Delete `Settings { EmptyView() }`** so nothing can reach a dead window.
  An `App` needs at least one scene; if this is the only one, keep a scene
  that makes sense for the app rather than an empty settings placeholder.
- Add `.resizable` to the style mask, or size the window from the hosting
  view's fitting size so the content is never clipped.
- Keep the existing reuse logic — testing for *existence* rather than
  visibility, with `isReleasedWhenClosed = false`, is correct and the
  comment explaining why is worth preserving.

**Recommendation: Option A.** The window-management code you would keep
writing is exactly what the scene already does correctly.

---

## Apply immediately

Drop the Save button. Every control writes through to the model, and the
model persists on change.

With `@Observable`, the cleanest form is to persist in `didSet` on each
stored property, so there is no way to change a value without saving it:

```swift
@Observable
final class AppSettings {
    var plexMediaRoot: String = "" {
        didSet { UserDefaults.standard.set(plexMediaRoot, forKey: Keys.plexMediaRoot) }
    }
}
```

That removes the class of bug where a new setting is added and someone
forgets to extend `persist()`.

Keep a `persist()` method if something still needs to force a flush, but it
should stop being the only path that writes.

### Text fields need a moment

Persisting on every keystroke is usually harmless for `UserDefaults`, but
for a value that triggers real work — validating a path, hitting a network
API — debounce or commit on `.onSubmit` and focus loss instead. The
distinction is whether the write is cheap; for a plain string it is.

### What replaces Save

Nothing. The window's close button is the only dismissal, and it discards
nothing because everything is already saved. If a value is invalid, show
that inline (below), rather than blocking dismissal.

---

## Structuring the model

### `@AppStorage` or an `@Observable` class?

`@AppStorage` is the shortest path for simple, independent values:

```swift
@AppStorage("handbrakePath") private var handbrakePath = "/opt/homebrew/bin/HandBrakeCLI"
```

It reads and writes `UserDefaults` and re-renders on change, with no model
layer at all.

It stops being the right tool when you have **derived values** — which this
project does. `plexMoviesPath`, `plexTVPath`, `workingRipPath`, and
`workingEncodePath` are all computed from `plexMediaRoot`, and
`isConfigured` combines two settings into a launch decision. That logic
belongs in a type where it can be read, tested, and shared with the rest of
the app.

Keep the `@Observable` class. It is the right choice here. Use
`@AppStorage` only for genuinely standalone toggles that nothing else
derives from.

### Injection

`AppDelegate` already passes `settings` via `.environment(settings)` to
`StatusMenuView` and `MetadataEntryView`, but `SettingsView` takes it as an
`@Bindable` init parameter. Pick one convention. `.environment` plus

```swift
@Environment(AppSettings.self) private var settings
```

is the more consistent choice given the rest of the app, and it means the
Settings scene does not need a reference threaded through the app struct.
Note that to get bindings from an environment `@Observable` object you
declare a local `@Bindable`:

```swift
@Bindable var settings = settings
```

inside `body`, before using `$settings.someProperty`.

---

## Secrets

Do not put the TMDB API key in `UserDefaults`. Plists under
`~/Library/Preferences` are readable by anything running as the user and
get swept into backups and sync.

Use the Keychain. The shape that fits here is a generic password item keyed
by service name and account, wrapped so the call sites stay clean:

```swift
enum KeychainStore {
    static func set(_ value: String, service: String, account: String) throws
    static func get(service: String, account: String) throws -> String?
    static func remove(service: String, account: String) throws
}
```

Then `AppSettings.tmdbAPIKey` becomes a computed property backed by that
store rather than a stored `String`, so the UI code does not change.

Two practical notes:

- **Migrate the existing value.** If a key is already in `UserDefaults` on
  someone's machine, read it once, write it to the Keychain, and remove the
  defaults entry. A silent one-way migration on first launch is enough.
- **Keychain access can fail**, and the failure is visible to the user
  (a prompt, or a denial). Surface it rather than treating an empty read as
  "not configured yet", which would send the user back through first-run
  setup for no reason.

---

## Layout

### Use `Form`, not stacked `GroupBox`es

`Form` with grouped styling is what produces the standard System
Settings look — aligned labels, correct spacing, correct section headers —
without hand-tuning `.frame(width: 90, alignment: .trailing)` on every
label:

```swift
Form {
    Section("Plex Media Root") {
        // rows
    }
    Section("CLI Tools") {
        // rows
    }
}
.formStyle(.grouped)
```

Inside a `Form`, `LabeledContent` handles the label/value pairing and keeps
the label column aligned across sections:

```swift
LabeledContent("HandBrakeCLI") {
    HStack {
        TextField("", text: $settings.handbrakePath)
        Button("Detect") { detect() }
    }
}
```

That replaces the hand-built `cliRow` helper and the manual label widths.

### Sizing

Let content drive width, and set a sensible minimum:

```swift
.frame(minWidth: 480)
```

Avoid a fixed `.frame(width:)` combined with a fixed window height — that
combination is what clips content today. If you keep a hand-built window,
derive its size from the hosting view's `fittingSize`.

### Help text

The existing pattern — caption-styled secondary text under a control — is
right. `Form` also supports it directly:

```swift
TextField("API Key", text: $settings.tmdbAPIKey)
Text("Used for movie metadata and poster art. Free keys are available at themoviedb.org.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

Keep it short. A settings pane is not documentation.

---

## Multiple panes

One pane is correct until it isn't. The current three sections fit
comfortably in one.

When it outgrows that, the conventional structure is a `TabView` with
`.tabViewStyle(.grouped)`, each tab carrying a `Label` with an SF Symbol:

```swift
TabView {
    GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gearshape") }
    ToolsSettingsView()
        .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
}
```

Split by *what the user is trying to change*, not by which type owns the
value. "Plex Media Root" and the derived path previews belong together
because they are one decision, even though they touch several properties.

A rule that ages well: if you cannot name a tab in one word, it is probably
two tabs or none.

---

## Validation and configuration state

`isConfigured` is a genuinely good idea — a single property the rest of the
app consults before doing work. Build on it rather than around it.

### Show problems where they are

The current view colors an unset root path red. Extend that to the
conditions that actually break the pipeline:

- The Plex root does not exist, or is not writable
- `makemkvcon` or `HandBrakeCLI` is not at the configured path, or is not
  executable
- The TMDB key is empty

Each of these is checkable synchronously and cheaply. Show the result
inline next to the control it concerns — a red path, a warning symbol with
a tooltip — rather than as a summary banner. The user's next action is to
fix that specific row.

### Do not block on invalid state

Let the user close a Settings window with a bad path in it. They may be
mid-edit, or waiting on a drive to mount. The app's *work* checks
`isConfigured` before starting; the *window* does not need to.

### First run

`AppDelegate` opens Settings at launch when `!settings.isConfigured`. That
is reasonable for an app that cannot function unconfigured — but for a
menu bar app it means an unexpected window appears at login, possibly over
whatever the user is doing.

Two things make it better:

- **Activate deliberately** when doing this, so the window is visible
  rather than buried.
- **Consider a lighter first-run signal instead** — the status item showing
  a warning badge, with the click opening Settings. It respects that login
  is a busy moment and the user may not have asked for anything yet.

---

## Testing

The window itself is awkward to test; the model is not. Put the logic where
it can be tested:

- **`AppSettings` derived paths.** Set a root, assert each derived path.
  Use a non-default root — a fixture that leaves values at their defaults
  can pass while the code does nothing.
- **`isConfigured` transitions.** Empty root, empty key, both set.
- **Persistence round-trip.** Write, construct a fresh instance, read back.
  Inject a `UserDefaults(suiteName:)` rather than using `.standard`, so
  tests neither read nor corrupt your real preferences.
- **Keychain migration**, once it exists — value present in defaults,
  migrate, assert it is in the store and gone from defaults.

`AppDelegate` already exposes `settingsWindow` as `private(set)`
specifically so a test can assert the window is reused rather than
recreated. If you move to the `Settings` scene, that test goes away with
the code it covered — which is the right trade, but note it deliberately
rather than discovering the coverage gap later.

---

## Checklist

- [ ] One settings surface, not two — no empty `Settings` scene alongside a
      hand-built window
- [ ] Opens from the status item, and activates so it comes to the front
- [ ] Changes apply immediately; no Save button
- [ ] Every stored property persists on change, not via a separate call
      someone can forget
- [ ] API key in the Keychain, with a one-time migration out of
      `UserDefaults`
- [ ] `Form` with grouped style; no hand-tuned label widths
- [ ] Window sized from content, with a minimum width; content never
      clipped
- [ ] Invalid paths and missing tools shown inline, next to their control
- [ ] Closing is never blocked by invalid state
- [ ] Model logic covered by tests using an injected defaults suite
