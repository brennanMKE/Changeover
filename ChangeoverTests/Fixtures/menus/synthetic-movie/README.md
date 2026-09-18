# synthetic-movie — a hand-built VIDEO_TS, not a disc

`structure.json` here was produced by `Tools/menudump` reading a **synthetic**
`VIDEO_TS` that `Tools/menudump/make-test-disc.py` writes from the published
DVD-Video table layouts. It is not evidence about any real disc and it must
never be quoted as such.

What it is for: pinning the pure decoders — `VMCommand.decode`,
`MenuStructure.resolvedButtons`, `PlayButtonResolver`, `MenuTVSignal` — on a
structure that contains one of every command shape they claim to handle:

| menu | entry type | buttons |
|---|---|---|
| `vmgm-lu1-pgc1` | title | `JumpTT 1` |
| `vtsm-01-lu1-pgc1` | root | `JumpTT 1`, three `LinkPGCN` |
| `vtsm-01-lu1-pgc2` | chapter | six `JumpVTS_PTT 1:1…1:6` |
| `vtsm-01-lu1-pgc3` | audio | two `SetSTN` |
| `vtsm-01-lu1-pgc4` | none | none — a PGC no button reaches |

Real-disc evidence lives in `Fixtures/discs/<slug>/menus/`, and the corpus
invariants in `DiscCorpusTests` run there. `make-test-disc.py` regenerates
this file; regenerate rather than hand-edit it.
