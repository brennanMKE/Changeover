# Changelog

Notes for each release, newest first. `scripts/update-website.sh` turns the
section under `## X.Y.Z` into the Sparkle release notes and into
`website/changelog.html`, so the wording here is what users read in the update
dialog.

## 1.0.0

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
