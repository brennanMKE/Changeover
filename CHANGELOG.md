# Changelog

Notes for each release, newest first. `scripts/update-website.sh` turns the
section under `## X.Y.Z` into the Sparkle release notes and into
`website/changelog.html`, so the wording here is what users read in the update
dialog.

## 0.1.2

The evidence stays on screen, and the notification stops guessing.

- **How a film was identified now stays visible while it rips.** Reading the menus, interpreting the disc's label and matching against TMDB all happen before the encode starts, and used to leave the screen the moment it did. The Ripping step now shows that story the whole way through — which is the only way to notice a wrong film before forty minutes of encoding files it under the wrong name.
- **Fixed:** the success notification said "The disc has been ejected" after every finished rip, whether or not it had. It had no way to know. It now says what actually happened, and says nothing about the disc when the answer is not known.

## 0.1.1

Smart import shows its work.

- **You can watch it think.** Reading a disc's menus, interpreting its label and matching it against TMDB used to happen in silence — a film simply appeared in the list, already chosen. Each step now writes to the log as it happens: how many menu pages Vision is reading and a sample of what it found on each, which rung of the identification ladder is in play, what the on-device model replied, and the candidate films with their runtimes and billed cast. When it declines to choose it says so, and why.
- **Fixed:** the History window's summary card could be clipped at the top and bottom with no way to scroll to either, on a job whose summary carried a long warning. The card now scrolls.

## 0.1.0

First release.

- **Put a disc in.** Changeover finds the feature, works out which film it is,
  rips it, files it where Plex expects, and ejects the disc so you can load the
  next one.
- **Identification** reads the disc's label — most spell the title with the
  spaces removed — and checks it against TMDB by runtime and billed cast. When
  the evidence is thin it suggests rather than deciding.
- **The right part of the disc:** it prefers the widescreen transfer over a
  cropped one, and will not encode a two-minute trailer because the disc called
  it the main title.
- **Plex naming**, always: `Movies/Title (Year) {tmdb-ID}/Title (Year).mp4`,
  with editions for different cuts of the same film.
- **Keeps going on a locked Mac**, including discs inserted after the screen
  locks, which macOS would otherwise eject unread.
