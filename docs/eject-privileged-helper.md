# Ejecting from a privileged helper

Fallback option. Nothing here is built.

## Why this is on the table

Every eject the app has attempted from inside its own process has been
refused, and the refusals point at one thing: **who macOS thinks is asking.**

- `DADiskUnmount` returns `kDAReturnNotPermitted` (0xF8DA0008) on every
  end-of-job attempt. Using a removable volume is gated by TCC
  (`kTCCServiceSystemPolicyRemovableVolumes`), and until recently the bundle
  declared no `NSRemovableVolumesUsageDescription` at all — so macOS could not
  even ask, and denied outright.
- `diskutil eject` succeeds from an SSH session and is dissented by
  `loginwindow` from inside Changeover, on the same machine seconds apart.
  Shelling out does not escape the gate: a spawned child is attributed to its
  **responsible process**, which for a subprocess of Changeover is Changeover.
  So `diskutil` from SSH and `diskutil` from the app are two different
  identities running the same binary.

Declaring the usage string and launching through LaunchServices is the
ordinary fix, and it is the one being tried first (see
`Changeover/LaunchAttribution.swift` for why the launch path matters —
a run from Xcode or from a shell attaches the grant to Xcode or Terminal
instead of to the app, which would make the fix look like it failed).

This document is what to do if that is not enough.

## The shape of it

A small privileged daemon, registered with
`SMAppService.daemon(plistName:)`, that does exactly one thing: take a disk
identifier, call `DADiskUnmount` with `kDADiskUnmountOptionWhole` and then
`DADiskEject`, and report the `DAReturn`. The app talks to it over XPC.

Running as root sidesteps TCC entirely, which is precisely why the same
command works over SSH today — and unlike the SSH route it is a supported,
signed, on-machine mechanism rather than a person typing into a terminal.

This matters more, not less, if Changeover is ever to run unattended on joe.
Auto-start already removes every manual step **except** getting the finished
disc out of the drive; an eject that depends on a GUI consent dialog having
been clicked at some point is the one remaining thing that can silently stop
a headless run.

## What it would take

1. **A daemon target** — a bare executable, not an app bundle, with its
   launchd plist embedded in `Contents/Library/LaunchDaemons/`, listing a
   `MachServices` name.
2. **`SMAppService.daemon(plistName:).register()`** on first run. A daemon
   (unlike an agent) needs an admin to approve it once, in System Settings →
   General → Login Items. One approval, not one per disc.
3. **An XPC listener** in the daemon with a code-signing-requirement check on
   the connecting client — `SecCodeCheckValidity` against the app's team
   identifier and bundle id — so nothing else on the machine can drive the
   tray.
4. **A one-method protocol.** Take a **BSD disk identifier** (`disk4`), not a
   path. A root helper that unmounts an arbitrary caller-supplied path is a
   much larger promise than this needs to make, and the app already knows the
   device node from `DiscInsertion`.
5. **Refuse anything that is not an optical disc.** The daemon re-checks with
   `DADiskCopyDescription` that the target is ejectable removable media,
   rather than trusting the caller. `DiscInsertion`'s existing classifier is
   the model, and the check belongs on the privileged side of the boundary.
6. **A seam in `JobController`.** The `Ejector` typealias already exists and is
   already injected, so this arrives as one more implementation of it and
   every existing test keeps working untouched.

## Why not do this first

It is the right answer to the wrong question if the ordinary fix works.

A root daemon is a permanent increase in what this app can do to the machine,
it needs its own signing and notarization, it adds an approval step to
installation, and it has to be got right — a privileged XPC service with a
weak client check is a local privilege escalation, not a convenience. Against
that, the usage string plus a correct launch is two lines and no new
attack surface.

So: ship the ladder, read `/tmp/changeover-flow.log`, and find out whether a
declared and correctly-attributed app can eject a disc. If it can, this file
stays a note. If the refusals survive a proper grant, this is the answer and
the reason will be documented rather than guessed.

## The other fallback: DiscRecording's `DRDevice`

`DRDevice` (DiscRecording.framework) exposes `ejectDevice`, which is roughly
what `drutil` does underneath — it commands the *drive* rather than asking
the arbiter to release a *volume*.

That difference is the reason to try it. Everything refused so far has been
refused by `diskarbitrationd` deciding who is allowed to touch a mounted
removable volume. A device-level eject may be evaluated somewhere else
entirely, or it may inherit exactly the same TCC decision and fail
identically. **Which of those is true is unknown and untested** — this is a
thing to measure, not a fix to reach for.

It is cheap to find out, and cheaper than the daemon:

1. Enumerate with `DRDevice.devices()` and match the one whose properties
   carry the mounted volume's BSD name, rather than assuming a single drive.
2. Call `ejectDevice`, then watch for the volume to disappear — the same
   verdict the ladder already uses, because a device-level call has even less
   reason than `drutil` to know whether anything came out.
3. Keep the unmount first. `DRDevice` ejecting a still-mounted volume is how
   a half-eject happens, and #0049 has already been paid for once.

Worth noting what it does *not* solve: if the refusal really is TCC on
removable media, a device-level route is at best a loophole, and a loophole
is a poor thing to build an unattended pipeline on. The daemon above is the
answer that stays true.

## Confirmed, so it does not get re-investigated

The DiskArbitration sequence already matches what Apple documents, and the
`kDAReturnNotPermitted` is **not** a sequencing mistake:

- the whole-disk object is resolved with `DADiskCopyWholeDisk`, not the
  per-volume slice `DADiskCreateFromVolumePath` returns;
- `DADiskUnmount` is called on that object with `kDADiskUnmountOptionWhole`,
  so every volume the disc mounted comes down together;
- `DADiskEject` follows on the same object, which is resolved once and reused
  — re-deriving it per attempt would turn a retryable eject into "could not
  find a disk", because after a successful unmount the volume path no longer
  resolves.

Both the retrying path in `eject` and the single-pass rung in
`diskArbitrationEject` do this. So the permission story above is the
remaining explanation, not the code's order of operations.

## Open questions

- **Does the grant survive a headless boot?** A TCC grant is per user and
  evaluated in a GUI session. If joe reboots with nobody logged in, an app
  launched by a login item may have no session to be granted in — which would
  make the daemon route not merely more robust but necessary.
- **Is `drutil` still needed?** It commands the drive rather than a volume, so
  it opens the tray after an unmount that leaves the disc in place (#0049's
  half-eject). The daemon does `DADiskEject` directly, which should make that
  unnecessary — worth confirming rather than assuming.
- **`SMAppService` registration on an unsigned local build.** Daemons require
  a Developer ID signature; a `CODE_SIGNING_ALLOWED=NO` build cannot register
  one, so the development loop changes shape.
