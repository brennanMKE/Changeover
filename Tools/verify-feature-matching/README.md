# verify-feature-matching

Compiles the shipping `DiscLabelSplit` and `FeatureMatching` standalone and
runs them against the two captured double features with **live TMDB**, so the
identification chain is checked against real data rather than only against
fixtures shaped to it.

Run it on a host that has the TMDB key in `UserDefaults` (joe):

```sh
scp Tools/verify-feature-matching/main.swift \
    Changeover/{DiscInfo,DiscNameSearchTerm,DiscLabelSplit,FeatureMatching}.swift \
    joe:/tmp/e2e/
ssh joe 'cd /tmp/e2e && swiftc -O -o e2e main.swift DiscInfo.swift \
    DiscNameSearchTerm.swift DiscLabelSplit.swift FeatureMatching.swift &&
    ./e2e "$(defaults read co.sstools.Changeover tmdbAPIKey)"'
```

Expected, verified 2026-09-28:

```
UNCLE_BUCK_GREAT_OUTDOORS -> 3 splits
  title 1 <- The Great Outdoors (1988) tmdb-2617  0.6 min out
  title 2 <- Uncle Buck (1989)         tmdb-2616  0.4 min out
7000078778_1 -> 0 splits, no assignment
```

Exit code is non-zero if either case stops matching. It touches no disc and no
drive; the runtimes are the captured ones from
`ChangeoverTests/Fixtures/discs/*/scan.json`.

It is deliberately **not** part of the unit suite: it needs the network and a
key, and the suite must stay hermetic.
