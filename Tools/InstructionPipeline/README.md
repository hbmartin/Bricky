# Bricky instruction parity pipeline

This isolated Python 3.12+ tool uses pyldraw3 1.5.0 as Bricky's development-time
semantic oracle. Python and pyldraw3 are never linked, copied, or packaged into
the iOS application.

```sh
uv sync --frozen
uv run python generate_golden.py --ldraw-root /path/to/extracted-asset/ldraw
```

`--ldraw-root` must be the `ldraw` directory inside the extracted, verified
release asset. The script runs pyldraw3 inside a hermetic scratch `HOME` with
a config pointing only at that library, so pyldraw3's per-user download cache
can never leak machine-local paths or unpinned parts into the corpus. The
pinned `complete.zip` ships without `parts.lst`; the script generates it on
first use with pyldraw3's own deterministic generator.

For every valid fixture the pipeline executes pyldraw3's public commands:

```sh
ldraw instructions validate model.mpd --strict
ldraw instructions export model.mpd -o manifest.json
ldraw instructions snapshots model.mpd --out snapshots
```

Before generating, the script also checks every file in `fixtures/invalid` and
fails unless each one is rejected — either by `ldraw instructions validate
--strict` or by Bricky's stepped-model invariant (a model with no explicit
`0 STEP` is not an instruction set, even though pyldraw3 tolerates it as one
implicit step). Valid fixtures are held to the same invariant. The rejection
corpus is therefore exercised on every run, including CI's `--check`.

The checked-in normalized artifacts are compared with `SwiftParityTests`. CI
must regenerate them and fail on either pyldraw3 drift or a Swift semantic diff.

Normalization replaces the output directory, the fixture directory, the
`--ldraw-root` library path, and the tool root (most specific first) with
`<name>` tokens so no machine-local absolute path can leak into the corpus.
The `generator.version` reported by pyldraw3 must equal the pinned `1.5.0`;
the script fails on mismatch rather than overwriting provenance.

The expected LDraw root is the unpacked, verified 2026-07 archive. Nothing in
this directory downloads or reads from `../Lego_Assembly`.

The verified immutable app download is published at
[`hbmartin/Bricky` release `ldraw-2026-07`](https://github.com/hbmartin/Bricky/releases/tag/ldraw-2026-07).
Its `complete.zip` is 144,722,356 bytes with SHA-256
`6009f2e94204c4d3a63a4c812010b5c90bad8c5acb19b882c859fdac63734eae`.

To reproduce verification and staging for this version from the official
archive:

```sh
uv run python prepare_release_asset.py /path/to/complete.zip --out-dir release/ldraw-2026-07
```

The verifier rejects any archive that differs from the locked byte length or
SHA-256 and rejects traversal members. A future LDraw version must update the
locks, app URL, CI URL, and tool constants together and publish a new tag; never
replace an already-published versioned asset.
