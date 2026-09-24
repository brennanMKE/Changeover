# Why the disc would not eject: the screen was locked

Measured on joe, 2026-09-23/24. This closes the question six rounds of code
changes did not.

## The finding

While a Mac's screen is locked, `loginwindow` refuses **both** halves of the
disc's life. It dissents *mount approval* for a disc going in, ejecting it
within half a second, and it dissents *unmount approval* for a disc coming
out, which is what a finished rip needs.

Both refusals carry `kDAReturnNotPermitted` (`0xF8DA0008`) — the status this
project spent a week attributing to a missing entitlement.

From the system log, a disc inserted while locked:

```
00:15:32.192  diskarbitrationd  Lock notification received - device is locked
00:20:48.987  diskarbitrationd  created disk                      ← the disc goes in
00:20:49.471  diskarbitrationd  probed disk, success              ← it reads fine
00:20:49.485  loginwindow       CopySLMountApprovalCallback - Allow = NO
00:20:49.488  loginwindow       wholeDisk != nil, calling DADiskEject
00:20:49.512  loginwindow       Allow = NO, set return value to kDAReturnNotPermitted
00:20:49.514  diskarbitrationd  ejected disk
```

The disc never mounts, so **Changeover never sees it** — `DVDMonitor` only
watches mounted `VIDEO_TS` volumes. An eject that looks like the app's doing
leaves no trace in the app's log, because the app was not involved.

And a rip's eject failing, from the same night:

```
21:54:43  device is locked
22:06:01  unmount approval … dissented, status = 0xF8DA0008   ┐
22:06:08  unmount approval … dissented, status = 0xF8DA0008   │ the retry
22:06:09  unmount approval … dissented, status = 0xF8DA0008   │ budget,
22:06:11  unmount approval … dissented, status = 0xF8DA0008   │ spent
22:06:15  unmount approval … dissented, status = 0xF8DA0008   │ against a
22:06:22  unmount approval … dissented, status = 0xF8DA0008   │ locked
22:06:30  unmount approval … dissented, status = 0xF8DA0008   ┘ screen
22:06:30.584  device is unlocked
```

The last refusal and the unlock are **half a second** apart. The retries were
not too few or too short; they were aimed at the wrong thing.

## Why every earlier theory fit and was still wrong

| What was seen | What it actually was |
|---|---|
| "The menu's Eject works every time" | Clicking it means being at the machine, which means unlocked |
| End-of-job ejects fail | A rip runs 45–60 minutes; the screen locks partway through |
| The same `diskutil eject` works over SSH | An SSH session is not behind the screen-lock gate |
| "It finally ejected" | It ejected when somebody came back and unlocked |
| `kDAReturnNotPermitted`, always | Not a missing usage string — a locked screen |

The asymmetry that looked impossible — one command, two outcomes, same machine,
seconds apart — was never about TCC or about which binary was asking. It was
about whether anybody was logged in and looking at the screen.

`NSRemovableVolumesUsageDescription` was genuinely missing and is genuinely
required, so declaring it was right. It just was not the thing that was
biting.

## What triggers the lock on joe

```
displaysleep  20        # the display sleeps after 20 minutes
```

with the login window set to require a password once the display is off. The
screensaver is not involved (`idleTime 0`). So on any unattended rip longer
than twenty minutes — which is all of them — the screen is locked by the time
the encode finishes.

## The fix

**Not** turning off the screen lock. An earlier version of this document
recommended exactly that — *Require password → Never*, or
`sudo pmset -a displaysleep 0` — and it was wrong. It trades a real security
control for a convenience, on a machine that sits unattended, and no user
should be asked to accept it. It is recorded here only so the next person does
not rediscover it and think it is the answer.

`loginwindow` has a preference for precisely this, which turns off **only the
disk-mount blocking** and leaves the lock itself untouched. From its own
strings:

```
DisableScreenLockDiskPolicy
EnableScreenLockDiskPolicy to block disk mounts during screen lock
DiskArb - screen locked; blocking removable disk mounts
DiskArb - screen unlocked; allowing removable disk mounts
```

Set in the **system** domain — a write to the user domain is read and ignored,
confirmed by locking the screen and watching loginwindow still take the
`EnableScreenLockDiskPolicy` branch:

```bash
sudo defaults write /Library/Preferences/com.apple.loginwindow \
    DisableScreenLockDiskPolicy -bool true
```

The screen still locks, the password is still required, the display still
hides. What changes is that an inserted disc is allowed to mount instead of
being ejected unread.

It is not a free trade, and it should be described honestly rather than sold:
the policy exists so that a machine nobody is watching will not mount whatever
is pushed into it. Turning it off on a Plex host in a house is a small risk;
turning it off on a laptop that travels is not. It is narrow, reversible with
`sudo defaults delete`, and it is the only part of the lock being given up.

To confirm it took effect, lock the screen and look for the branch name:

```bash
log show --last 2m --predicate 'process == "loginwindow"' --style compact \
  | grep -i DiskPolicy
```

`DisableScreenLockDiskPolicy | DiskArb - …` means it is honoured.

### The eject side needs none of this

Getting a disc *out* already works while locked, and the ladder proved which
rung does it — `diskutil unmount force`, which is why it now runs second. See
the commit that reordered it. `loginwindow` dissents *approval*: it is asked
whether the volume may come down, and it says no. Forcing does not ask.

So the two halves have different answers: the eject is solved in this app, and
the mount is solved by the preference above.

### If the preference is not enough

`docs/eject-privileged-helper.md` — a root daemon, outside the login session.
Worth reaching for only if the preference turns out to be MDM-only or removed
in a later macOS.

## The requirement, for whoever sets this Mac up

**Unattended ripping needs one system setting.** Without it, the drive works
only while somebody is looking at the screen, which is the opposite of the
point.

```bash
sudo defaults write /Library/Preferences/com.apple.loginwindow \
    DisableScreenLockDiskPolicy -bool true
```

Read the name as **Disable [ScreenLock Disk Policy]** — the policy *about
disks* during screen lock — not *[Disable ScreenLock]*. The screen still
locks, the password is still required, the display still hides. The only thing
that changes is that an inserted disc is allowed to mount instead of being
ejected unread.

It must be the **system** domain; a user-domain write is read and ignored.

**Then reboot.** `loginwindow` reads this once and caches it for its own
lifetime, which is the lifetime of the login session — on joe it had been
running for nine days when the key was set, and it went on blocking mounts
with the new value sitting right there in the plist. Setting it and testing
without a restart looks exactly like the setting not working. A logout is
enough in principle; a reboot is what to tell a user, because it also proves
the setting survives one, which is the case that matters on a machine expected
to come back up on its own.

Verify afterwards by locking the screen and reading the branch name:

```bash
log show --last 2m --predicate 'process == "loginwindow"' --style compact \
  | grep -i DiskPolicy
```

`DisableScreenLockDiskPolicy | DiskArb - …` means it is honoured.
`EnableScreenLockDiskPolicy | DiskArb - screen locked; blocking removable disk
mounts` means it is not — check the domain, then check whether loginwindow has
been restarted since.

Honestly stated, because it is a real trade and not a formality: this policy
exists so a machine nobody is watching will not mount whatever is pushed into
it. On a Plex host in a house that risk is small. On a laptop that leaves the
house it is not. It is narrow — the lock itself is untouched — and it is
reversible:

```bash
sudo defaults delete /Library/Preferences/com.apple.loginwindow DisableScreenLockDiskPolicy
```

### The app can check this, and should

`/Library/Preferences/com.apple.loginwindow.plist` is world-readable
(`-rw-r--r-- root wheel`), so Changeover can read the key with no privilege,
no helper and no prompt. That makes this a first-run check rather than a line
in a README nobody reads:

- **Detect** on launch and in Settings, beside the HandBrakeCLI check that is
  already there. The same shape: a thing the app needs, a clear statement of
  whether it is present.
- **Explain, in one sentence** — "Discs inserted while this Mac's screen is
  locked are ejected before Changeover can see them." That is the symptom the
  person will actually hit, and it is the sentence that would have saved this
  project a week.
- **Offer the command to copy**, and say what it does and does not change.
  Never run it silently.

**The app must not escalate to set this itself.** Writing to
`/Library/Preferences` needs root, and the ways to get there from an app —
a privileged helper, or the deprecated `AuthorizationExecuteWithPrivileges` —
all mean an app that ships with the power to change a security policy without
being watched. Weakening a lock-screen protection is a decision that belongs
to the person who owns the Mac, taken deliberately, with the trade in front of
them. Detect and explain; let them type it.

The exception is the daemon route below, and only because it makes the
preference unnecessary rather than setting it.

### This or the daemon, not both

These are alternatives:

| | Needs a system setting | Needs privileged code | Survives a Mac nobody has logged into |
|---|---|---|---|
| `DisableScreenLockDiskPolicy` | yes, once, by hand | no | no — the console session must exist |
| Root daemon (`docs/eject-privileged-helper.md`) | no | yes | yes |

If the daemon is ever built, the preference stops being needed: a root daemon
runs outside the login session, which is exactly why `diskutil` already
succeeds over SSH while the screen is locked. Until then, the preference is
the whole of the fix and the setup step above is a real requirement.

## What this means for the app

The app cannot fix this, but it should stop pretending the failure is a
mystery:

- **Say so.** `kDAReturnNotPermitted` on an unmount, with the screen locked, is
  a known condition with a known remedy. "Could not eject the disc" is a worse
  message than "the screen is locked, so macOS will not release the disc —
  unlock joe, or turn off the lock in System Settings."
- **The ladder stays useful**, but its value changed: it is no longer looking
  for a method that works, it is a record of a machine's state. Both rips on
  the night of the 23rd ejected on the *first* rung, `diskutil eject`, in
  around five seconds — because the screen happened to be unlocked.
- **The post-job retry loop is aimed correctly after all.** Retrying for thirty
  minutes is exactly right when the thing being waited for is a person coming
  back. It just never said that was what it was waiting for.
