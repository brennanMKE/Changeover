# Changeover — Remote Control

**Status:** Proposal — not yet implemented
**Related:** `Plan.md` (Phases 1–12 complete), `Montages.md`

---

## What the remote is actually for

Not "rip a DVD from across the room." Discs have to be swapped by hand, so
someone is walking to the mini for every single disc regardless. Starting a rip
remotely saves nothing.

The value is in the **decision steps**, which are the slow part of the loop and
the only part that needs a screen, a keyboard, and attention:

- Which movie is this? (TMDB search, poster confirmation)
- Which titles on the disc do we actually want? (main feature vs. bonus
  features vs. alternate angles vs. the 90-second FBI warning)
- Which audio and subtitle tracks? (`mac_plex_dvd_workflow.md` already
  documents this as a manual MakeMKV step: keep English and Spanish, drop the
  rest)
- Is it done, and did it work?

Those are couch activities. The disc swap is a 15-second errand. So the right
model is a **disc triage console**: the mini handles discs and long-running
work, the remote handles judgement.

### The intended loop

```
1. Walk over, insert disc                        ← physical, unavoidable
2. Walk back to the couch
3. Mini detects the disc, scans it, pushes disc info to clients
4. On MacBook / iPhone / iPad:
     search TMDB, confirm the movie
     review the title list, pick the main feature (+ any extras)
     pick audio and subtitle tracks
     start
5. Rip → encode → move, progress streamed to the client
6. Disc auto-ejects; client notifies "done, next disc"
7. Walk over, swap disc, repeat from 2
```

The human is never blocked on the machine and the machine is never blocked on
the human, except for the 15-second errand in step 7.

**Two consequences for the existing plan:**

- **Auto-eject (`Plan.md` 11.4) and completion notification (11.5) are not
  enhancements — they are what closes this loop.** Without eject, step 7 needs a
  trip to the machine just to open the tray. They should ship with this work.
- **Disc title/asset selection is a new core feature, not part of the remote
  work as such.** It is worth building even with no remote at all, and it
  changes the pipeline. See "Disc scanning and title selection" below.

---

## Which steps need to be remote-capable

| Step | Runs where | Needs remote UI? |
|---|---|---|
| Insert disc | Mini, by hand | — |
| Detect disc | Mini (`NSWorkspace`) | push an event |
| **Scan disc titles** | Mini (`makemkvcon info`) | push the result |
| Search TMDB, pick movie | **Client** — pure HTTP | ✅ |
| **Pick titles / audio / subtitles** | Client decides, mini executes | ✅ |
| Start rip | Command to mini | ✅ |
| Watch progress | Stream from mini | ✅ |
| Encode, move into Plex | Mini (SSD is attached there) | status only |
| Eject | Mini, automatic | ✅ override |

**Key design consequence:** TMDB search is client-side, so the client does its
own searching and sends only the *chosen result*. Combined with disc info
flowing the other way, the wire protocol stays small — a handful of commands and
events — and `MetadataEntryView` / `MovieSearchViewModel` can be shared between
the host app and every client nearly unchanged.

---

## Constraints

- Same LAN is sufficient — no requirement to control from outside the house.
- Paid Apple Developer account available; entitlements and managed capabilities
  are on the table.
- **Not a single-user app.** Intended for anyone managing a DVD collection into
  Plex or a similar media server. Any pairing design that assumes one Apple ID
  across all devices must degrade gracefully to a household with several Apple
  IDs, or to a user with no iCloud at all.
- Clients wanted: macOS (MacBook Air), iOS (iPhone), iPadOS (iPad).

---

## Options evaluated

| Option | Latency | Client platforms | Effort | Verdict |
|---|---|---|---|---|
| **Bonjour + Network framework** | sub-second | macOS, iOS, iPadOS | Medium | ✅ **Recommended** |
| Wi-Fi Aware | sub-second | iOS, iPadOS only | Medium | ⛔ Shipped on macOS but API-gated — design for it, can't use it yet (see below) |
| Embedded HTTP server + web UI | sub-second | anything with a browser | Medium | ➕ Worth adding later as a universal fallback |
| CloudKit private DB + silent push | seconds | all Apple | High | ❌ Overkill for same-LAN; adds APNs + container setup |
| iCloud Drive job-drop folder | seconds–minutes | all Apple | Low | ❌ Unpredictable sync latency; terrible for live logs |
| Remote Apple Events + AppleScript `sdef` | sub-second | macOS only | Medium | ❌ No push of progress; legacy TCC surface |
| SSH + `changeover` CLI | sub-second | anything | Low | ➕ Keep as a debug/backup path |
| MultipeerConnectivity | sub-second | all Apple | Low | ❌ Formally deprecated as of Xcode 27 |

### Detail on the rejected options

**CloudKit private database + silent push.** Would work from anywhere, not just
the LAN. But it requires the APNs entitlement, a CloudKit container and schema,
and adds multi-second latency to every log line. It also breaks the multi-user
goal — a household on different Apple IDs would need CloudKit sharing, which is
far more machinery than a LAN socket. Since the user has to be in the house to
swap discs anyway, off-LAN control has no use case here.

**iCloud Drive job-drop folder.** The `Automated_DVD_to_Plex_Workflow.md`
job-queue idea over iCloud: the client writes a job JSON, the mini watches the
folder. Almost no networking code. But sync latency is unpredictable — seconds
on a good day, minutes on a bad one — and streaming a rip log through a synced
file is miserable. Fatal for the triage loop, where the client needs disc scan
results *while the user is still holding the next disc*.

**Remote Apple Events.** Still supported in macOS Tahoe 26. Would mean giving
Changeover an AppleScript dictionary (`sdef` + `NSScriptCommand` plumbing),
enabling Remote Apple Events in Sharing, and authenticating with account
credentials. It is request/response, so there is no natural way to push disc
scan results or progress to the client, and Apple Events are a steadily
tightening TCC surface.

**SSH + CLI.** Lowest effort, and worth having — a `changeover status` /
`changeover start --tmdb 78 --title 3` helper talking to the app over a local
Unix socket is useful for debugging and headless setups. But no poster art and
no title browser, so it complements the real answer rather than replacing it.

---

## Wi-Fi Aware — status

Wi-Fi Aware is the industry-standard peer-to-peer Wi-Fi technology Apple exposed
at WWDC25, roughly the open equivalent of the AWDL link behind AirDrop. Two
things make it attractive here: it needs no access point at all, and its pairing
model is a **mandatory six-digit PIN exchange** handled by the system via
`DevicePairingView` — exactly the authentication a multi-user version of this app
needs, with no passphrase plumbing to write. Given that the remote can write into
the media repository, having the OS own the pairing handshake is a real benefit.

**It is shipped on macOS but gated off.** This is worth stating precisely,
because the situation is better than the public commentary suggests.

`WiFiAware.framework` is a **public** framework present at
`/System/Library/Frameworks/WiFiAware.framework` on macOS 26.4.1, and it ships in
the macOS SDK (verified against `MacOSX26.5.sdk`) with a complete Swift module.
The full API surface is there:

| Type | Role |
|---|---|
| `WAPublisherListener` | conforms to `Network.ListenerProvider` |
| `WASubscriberBrowser` | conforms to `Network.BrowserProvider` |
| `WAEndpoint` | conforms to `Network.Connectable` |
| `WAPairedDevice` | paired-peer registry, `allDevices` async sequence |
| `WASharedSecret` | shared-secret material for paired links |
| `WACapabilities` | `supportedFeatures`, device limits |

However, **every public symbol carries `@available(macOS, unavailable)`** — 28
such annotations in the module interface — and the gate is enforced by the
compiler, not cosmetic:

```
$ xcrun swiftc -target arm64-apple-macos26.0 -typecheck wa.swift
error: 'WACapabilities' is unavailable in macOS
note: 'WACapabilities' has been explicitly marked unavailable here
```

Apple DTS confirmed the macOS gap on the developer forums and pointed at
enhancement request FB17988268; no roadmap has been announced.

Since the Changeover *host* is always a Mac, both relevant topologies are
blocked today:

| Link | Wi-Fi Aware possible today? |
|---|---|
| MacBook Air ↔ Mac mini | ❌ API unavailable on macOS |
| iPhone / iPad ↔ Mac mini | ❌ the Mac end is unavailable |

The private `WiFiPeerToPeer.framework` and `CoreWiFi.framework` are also present
and are the underlying NAN/AWDL plumbing, but private API is not an option for a
distributable app.

**Why this matters for the design.** Because the framework is shipped rather
than missing, enabling it on macOS is an availability-annotation change on
Apple's side, not new framework work — so it is reasonably likely to arrive. And
the shape of the eventual migration is already visible: `WAPublisherListener`
and `WASubscriberBrowser` conform to the **same** `Network.ListenerProvider` and
`Network.BrowserProvider` protocols that the Bonjour listener and browser use.

**Plan:** build the transport against those protocol abstractions rather than
against Bonjour concretely, so the discovery mechanism is a single injected
dependency. If Apple lifts the macOS gate, adding Wi-Fi Aware becomes a provider
swap plus a pairing UI, not a rewrite. Building PIN pairing now (Mode B below)
means the mental model already matches `WAPairedDevice` / `WASharedSecret`.
Worth filing an ER referencing FB17988268.

Hardware floor when it does arrive: iPhone 12 and later; iPad (10th gen), iPad
Air (4th gen), iPad Pro 11" (3rd gen), iPad Pro 12.9" (5th gen), iPad mini
(6th gen) and later.

---

## Recommendation

**Bonjour discovery + TLS over the Network framework**, using the
structured-concurrency API (`NetworkListener`, `NetworkBrowser`,
`NetworkConnection`) introduced in macOS 26 / iOS 26 — which matches the
project's existing deployment target and its `@Observable` + MainActor-by-default
conventions.

Keep the transport layer thin enough that Wi-Fi Aware is a later descriptor
swap, and add an embedded HTTP endpoint eventually as a universal fallback.

---

## Disc scanning and title selection

This is new functionality, independent of the remote, that the remote then
exposes.

**Today** `RipController` runs `makemkvcon mkv disc:0 all <dest>` and then picks
the largest resulting `.mkv`. That rips every title on the disc — bonus
features, trailers, FBI warnings, alternate angles — wasting substantial time and
disk, and the "largest file wins" heuristic is fragile.

**Proposed:** a `DiscScanner` that runs `makemkvcon -r info disc:0` on insertion
and parses robot-mode output into a structured `DiscInfo`:

```
DRV:index,visible,enabled,flags,drive name,disc name
TCOUT:count
CINFO:id,code,value                  ← disc-level attributes
TINFO:title,id,code,value            ← per-title: duration, chapters, size, output name
SINFO:title,stream,id,code,value     ← per-stream: type, language, codec
```

Then rip only what was chosen: `makemkvcon mkv disc:0 <titleIndex> <dest>`,
where the index replaces `all`.

```swift
struct DiscInfo: Codable {
    let volumeName: String
    let titles: [DiscTitle]
}

struct DiscTitle: Codable, Identifiable {
    let id: Int                 // index passed to makemkvcon
    let duration: Duration
    let chapterCount: Int
    let sizeBytes: Int64
    let streams: [DiscStream]   // audio/subtitle tracks with language
    var suggestedRole: Role     // .mainFeature | .extra | .ignore — heuristic default
}
```

The client shows this as a sortable list with a sensible default already applied
(longest title = main feature, everything under ~5 minutes ignored), so the
common case is still one tap.

> **Read the field names carefully.** `TINFO` and `SINFO` are prefixed by the
> title index (and, for `SINFO`, the stream index) *before* the attribute id — a
> parser that assumes the `CINFO` shape will read the title index as the
> attribute id on every line.
>
> **The published documentation is wrong here.** MakeMKV's `usage.txt` prints
> `TINFO:id,code,value` and `SINFO:id,code,value` — three fields, the same shape
> as `CINFO`. Real output has more: `TINFO:0,9,0,"1:47:21"`. The shapes above are
> taken from captured output, not from the doc, and that discrepancy is the
> single best argument for capturing fixtures before writing the parser.
>
> **Also unverified:** the numeric **`id`** values inside `TINFO`/`SINFO`. Note
> `id` is the `apdefs.h` attribute and `code` is a message code for a localized
> display name — easy to transpose. Confirm against real scans; forum posts list
> them but they are not officially specified. Tracked as issue `0021`.

This also feeds `Montages.md` directly — clip selection wants access to bonus
features and specific titles, not just the main feature.

---

## Architecture

```
Changeover (Mac mini) ─ host
  JobController   @Observable          ← single source of truth
      state:   .idle
             | .discInserted(DiscInfo)
             | .scanning
             | .ripping(progress)
             | .encoding(progress)
             | .organizing
             | .done(folderName)
             | .failed(reason)
      log:     [String]   (ring buffer, capped)
      current: RipRequest?
        ├── MetadataEntryView binds to it (local UI, behavior unchanged)
        ├── DiscScanner    — makemkvcon -r info disc:0 → DiscInfo
        └── RemoteServer
              NetworkListener advertising _changeover._tcp via Bonjour
              fans JobController changes out to every connected client

ChangeoverProtocol ─ Swift package, shared by host and all clients
      RemoteCommand, RemoteEvent, JobState
      MovieMetadata, DiscInfo, DiscTitle, RipRequest

Changeover Remote ─ clients: macOS / iOS / iPadOS, one SwiftUI codebase
      RemoteClient
        NetworkBrowser(.bonjour) → NetworkConnection → mirrors into @Observable
      Reuses MetadataEntryView + MovieSearchViewModel
        TMDB search runs locally on the client
```

### The prerequisite refactor

Pipeline state currently lives inside `MetadataEntryView` as `@State`
(`logLines`, `isProcessing`). Nothing outside that view can observe or drive a
job, so **no remote design of any kind is possible until this is extracted.**

Pulling an `@Observable JobController` out of the view and having `AppDelegate`
own it is the first and largest work item. Worth doing on its own merits — it
also fixes the fact that closing the metadata window today would orphan a
running job.

---

## Protocol sketch

```swift
struct RipRequest: Codable {
    let metadata: MovieMetadata
    let titleIndices: [Int]          // which disc titles to rip
    let audioLanguages: [String]     // e.g. ["eng", "spa"]
    let subtitleLanguages: [String]
}

enum RemoteCommand: Codable {
    case subscribe                   // client attaches; host replies with full state
    case rescanDisc
    case startRip(RipRequest)
    case cancel
    case eject
    case ping
}

enum RemoteEvent: Codable {
    case state(JobState)             // full state, on subscribe and on change
    case discInfo(DiscInfo)          // pushed after a scan completes
    case log(String)
    case logReplay([String])         // buffered backlog, on subscribe
    case finished(folderName: String)
}
```

The `Coder` protocol layer handles Codable framing, so there is no manual
length-prefixing:

```swift
// Mini — host
try await NetworkListener {
    Coder(RemoteCommand.self, using: .json) { TLS() }
}.run { connection in
    for try await (command, _) in connection.messages {
        await jobController.handle(command)
    }
}
```

```swift
// Client
let endpoint = try await NetworkBrowser(for: .bonjour(type: "_changeover._tcp"))
    .run { endpoints in .finish(endpoints.first!) }

let connection = NetworkConnection(to: endpoint) {
    Coder(RemoteEvent.self, using: .json) { TLS() }
}
```

> **Resolved — verified against `MacOSX26.5.sdk`.** The listener takes a
> *provider*, not a `service` property:
>
> ```swift
> public struct BonjourListenerProvider: ListenerProvider { ... }
> extension ListenerProvider where Self == BonjourListenerProvider {
>     public static func bonjour(name: String? = nil, type: String,
>                                domain: String? = nil,
>                                txtRecord: NWTXTRecord? = nil) -> BonjourListenerProvider
> }
> ```
>
> So the shape is `NetworkListener(for: .bonjour(type: "_changeover._tcp"), using: ...)`
> — **not** `NetworkListener(service:)`. `NWTXTRecord` is available for advertising
> a protocol version, and `newConnectionLimit` caps concurrent clients.
> `onServiceRegistrationUpdate` reports the registered name, which matters because
> `mDNSResponder` silently renames collisions to `Changeover (2)` — the instance
> name is not an identity.

---

## Pairing and authentication

Two modes, because the app must serve both the single-user case and a household
— and because the remote can **write into the media repository**, which is the
thing actually worth protecting.

### Mode A — zero-config, same Apple ID

The host generates a random 32-byte key once and stores it in
`NSUbiquitousKeyValueStore`; clients on the same iCloud account read it
automatically and pair with no user interaction. No CloudKit container, schema,
or push.

Three constraints that are easy to miss:

- **The blocker is a provisioning profile, not the sandbox.** iCloud entitlements
  on macOS are *restricted* entitlements requiring an embedded provisioning
  profile — they are not gated on `com.apple.security.app-sandbox`. Developer ID
  has supported iCloud capabilities for years. The symptom of getting this wrong
  is `-67050 "use of entitlement is not allowed"`, which reads like a sandbox
  problem and is not one. Still worth a spike before committing.
- **All targets must share one `ubiquity-kvstore-identifier`.** It defaults to
  `$(TeamIdentifierPrefix)$(CFBundleIdentifier)`, so a separate remote app
  (`co.sstools.ChangeoverRemote`) and the iOS client would silently read
  *different* stores and never pair.
- **Mode A revocation is per-group, not per-device.** Every device on the Apple
  ID holds the same key, and the host has never seen a given device before it
  connects — so a removed peer can re-enrol with a fresh id and the same key. The
  UI must say "reset all pairings", not offer per-device removal, for Mode A
  peers. Per-device revocation is a Mode B property.

### Mode B — PIN pairing, any other case

The host displays a six-digit code; the user enters it on the client; both
derive a shared key and the host stores the client's identity in its Keychain as
a known peer. Necessary for households on different Apple IDs, for users not
signed into iCloud, and as the manual fallback when KVS sync is slow. Also the
model Wi-Fi Aware enforces natively, so a later Wi-Fi Aware path reuses it.

### Transport security

**Decided by the SDK, not by preference.** A search of the `MacOSX26.5.sdk`
`Network.swiftmodule` interface returns **zero** matches for `preSharedKey`,
`pre_shared`, or `psk`. The modern `TLS` builder exposes only:

```swift
public func localIdentity(_ identity: sec_identity_t) -> TLS
public func certificateValidator(_ handler: @escaping ... async -> Bool) -> TLS
public func peerAuthentication(_ preference: TLS.PeerAuthentication) -> TLS
public func version(min: tls_protocol_version_t?, max: tls_protocol_version_t?) -> TLS
```

TLS-PSK is therefore **not reachable** from the structured-concurrency API at
all — it would mean dropping to `NWProtocolTLS.Options` and giving up the
`Coder`/`NetworkListener` stack this design is built on. (The TLS-1.2-only
limitation on Apple's PSK support remains true, but is now moot.)

**So: self-signed identity + fingerprint pinning**, via `localIdentity` on the
host and `certificateValidator` on the client, keeping TLS 1.3.

Because pinning alone proves only "same certificate as last time" and not "this
peer knows the pairing secret", pair it with an in-band challenge: the client
sends `HMAC(pairingKey, nonce ‖ SHA-256(presented server certificate))` and the
host verifies against its own identity. **Binding the HMAC to the certificate
the client actually saw is what stops a relay MitM** — without it, first contact
in Mode A is trust-on-first-use and a relay can complete both authentications.

### Authorization

Pairing proves *which device*; also record *what that device may do*. Even at v1,
keep a per-peer capability field distinguishing "can start rips and write to the
library" from "can watch progress only." This matters more once montage editing
(`Montages.md`) lands, since that is a second, broader write path into the same
repository.

---

## Client platforms

One SwiftUI codebase, three destinations. The search-and-select and title-picker
UIs are identical everywhere; only layout adapts.

| Platform | Notes |
|---|---|
| macOS (MacBook Air) | Primary. Window or menu bar popover mirroring the host UI. |
| iOS (iPhone) | The couch case. Compact layout; poster list and title list both adapt well. |
| iPadOS | Same as iOS with a wider split layout — good for the title picker. |

All clients need `NSLocalNetworkUsageDescription` and `NSBonjourServices` in
Info.plist. macOS 15+ and iOS prompt for Local Network access on first run — for
the host, that prompt appearing on a headless mini is a real setup step to
document.

---

## Risks and gotchas

- **Sleep kills discovery.** If the mini sleeps, Bonjour advertisement stops.
  Use `ProcessInfo.beginActivity` to hold off idle sleep during jobs, and
  consider a "stay discoverable" setting.
- **Local Network permission on a headless host** must be accepted at the mini
  once. Document in README setup.
- **TLS-PSK is TLS 1.2 only.** Pin the version or use identity pinning instead.
- **Disc scan timing.** `makemkvcon info` on a DVD takes tens of seconds. The
  client must show a scanning state, not an empty title list — and the user is
  walking back to the couch during it, which is convenient.
- **Reconnection.** Clients must survive host restarts, Wi-Fi drops, and laptop
  sleep. The `subscribe` → `state` + `discInfo` + `logReplay` handshake makes
  recovery clean.
- **Multiple clients.** Two connected clients must not start two rips. The
  `JobController` is the serialization point; commands invalid for the current
  state are rejected with a reason.
- **MakeMKV key expiry** surfaces as a scan failure. Report it as a distinct,
  actionable error rather than a generic failure — it is a recurring real-world
  issue (`MacApp.md` §10 already notes it).

---

## Future: web fallback

An embedded HTTP + Server-Sent-Events endpoint would let any browser — including
a Raspberry Pi kiosk or an Android phone — drive the same `JobController`. It
reuses everything except the SwiftUI layer.

Cost is hand-rolled HTTP parsing on `NetworkListener`, or a Hummingbird/Vapor
dependency. Worth doing *after* the native clients. Note that `Montages.md`
independently wants an HTTP surface for Raspberry Pi display clients — if that
lands, the two should share one server.

---

## Phased plan

Continuing the numbering in `Plan.md`.

### Phase 13 — Close the loop (valuable with or without a remote)

- [ ] **13.1** Extract `@Observable JobController` from `MetadataEntryView`;
      `AppDelegate` owns it. Local UI behavior unchanged. *Prerequisite for
      everything else.*
- [ ] **13.2** `DiscScanner` — parse `makemkvcon -r info disc:0` into `DiscInfo`;
      confirm attribute codes against a real disc.
- [ ] **13.3** Title/track selection UI in the host app; `RipController` ripping
      selected title indices instead of `all`.
- [ ] **13.4** Auto-eject on completion (`Plan.md` 11.4) + completion
      notification (11.5) + working-folder cleanup (11.6).

### Phase 14 — Remote

- [ ] **14.1** `ChangeoverProtocol` Swift package — commands, events, shared models.
- [ ] **14.2** `RemoteServer` — `NetworkListener`, Bonjour `_changeover._tcp`,
      fan-out of `JobController` changes.
- [ ] **14.3** Pairing — Mode A (iCloud KVS) with Mode B (PIN) fallback; Keychain
      storage; per-peer capability field.
- [ ] **14.4** `Changeover Remote` macOS target — browser, connection, reuse of
      `MetadataEntryView` and the title picker.
- [ ] **14.5** Robustness — reconnect, multi-client arbitration, sleep
      prevention, Info.plist keys, first-run permission docs.

### Phase 15 — Mobile clients

- [ ] **15.1** Restructure the remote client as a multiplatform target.
- [ ] **15.2** iOS layout pass.
- [ ] **15.3** iPadOS layout pass.
- [ ] **15.4** Local notification on job completion — "done, next disc."

### Phase 16 — Optional

- [ ] **16.1** HTTP + SSE fallback endpoint (coordinate with `Montages.md`).
- [ ] **16.2** `changeover` CLI over a local Unix socket, for SSH use.
- [ ] **16.3** Wi-Fi Aware discovery descriptor — *blocked on macOS support.*
      File/reference ER FB17988268.

---

## Open questions

1. **Job queue?** If the disc ejects and the next one goes in while the previous
   rip is still encoding, the host needs a queue, not a single current job. Given
   the intended loop explicitly involves swapping discs immediately, this looks
   likely to be required rather than optional — and it is much cheaper to design
   in now (job IDs in the protocol) than to retrofit.
2. **One app or two?** Should a single universal app act as host (on a Mac with a
   drive) or client (everywhere else)? Tidier to distribute, but muddies the menu
   bar and iOS UI stories.
3. **How much of Settings should the remote expose?** Editing the Plex root
   remotely is plausible but expands the trust surface.
4. **Should extras be ripped at all by default?** Ripping bonus features serves
   `Montages.md` but bloats a Plex movie folder. Possibly a separate
   `Extras/` destination per Plex convention.

---

## Sources

- [WWDC25 — Use structured concurrency with Network framework](https://developer.apple.com/videos/play/wwdc2025/250/)
- [Apple Developer Forums — macOS 26 (Tahoe) lacks Wi-Fi Aware support](https://developer.apple.com/forums/thread/787701)
- Local verification: `/System/Library/Frameworks/WiFiAware.framework` on macOS 26.4.1 (build 25E253); `MacOSX26.5.sdk` module interface — all symbols `@available(macOS, unavailable)`
- [Apple Developer Forums — Wi-Fi Aware device support](https://developer.apple.com/forums/thread/787775)
- [com.apple.developer.wifi-aware entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.wifi-aware)
- [Apple Developer Forums — TLS 1.3 with PSK using Network framework](https://developer.apple.com/forums/thread/688508)
- [Allow remote application scripting on Mac](https://support.apple.com/en-gb/guide/mac-help/mchlp1398/mac)
- [NWListener.Service](https://developer.apple.com/documentation/network/nwlistener/service-swift.struct)
- [makemkvcon usage / robot mode](https://www.makemkv.com/developers/usage.txt)
