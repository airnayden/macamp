# bs2b crossfeed reference vectors

Ground-truth impulse responses for `PlayerCore/Sources/DSP/CrossfeedKernel.swift`,
produced by compiling **libbs2b 3.1.0's own `bs2b.c`** and recording its output.

This is an **independent oracle**: the generator links the upstream C verbatim and
never sees a line of MacAMP's Swift math, so a test that compares against these
CSVs cannot pass by agreeing with itself.

## Provenance

`provenance: libbs2b-3.1.0-verbatim`

| Field | Value |
|---|---|
| Upstream project | [libbs2b](https://bs2b.sourceforge.net/) (Bauer stereophonic-to-binaural DSP) |
| Version | 3.1.0 |
| Source URL | `https://downloads.sourceforge.net/project/bs2b/libbs2b/3.1.0/libbs2b-3.1.0.tar.gz` |
| Tarball SHA-256 | `6aaafd81aae3898ee40148dd1349aab348db9bfae9767d0e66e0b07ddd4b2528` |
| License | MIT (© 2005 Boris Mikhaylov) — see `vendor/COPYING` |
| Generated | 2026-09-19, macOS arm64, Apple clang `-O2 -std=c99` |

### Source pin cross-check — VERIFIED

The tarball digest was cross-checked against an **independent** pin before use:
Homebrew's `libbs2b` formula ([`homebrew-core`](https://github.com/Homebrew/homebrew-core/blob/master/Formula/lib/libbs2b.rb))
declares the same URL with

```ruby
sha256 "6aaafd81aae3898ee40148dd1349aab348db9bfae9767d0e66e0b07ddd4b2528"
```

which matches the fetched tarball **exactly**. Two independent parties therefore
attest to the same bytes.

> Arch Linux's `libbs2b` PKGBUILD was also consulted but is **not** usable as a
> cross-check here: it packages the `.tar.lzma` variant, a different archive with a
> necessarily different digest.

Per-file digests of the vendored sources are in `vendor/SHA256SUMS` and are
re-verified by `build.sh` on every run.

## Layout

```
vendor/          libbs2b 3.1.0 sources, verbatim (bs2b.c + 3 headers + COPYING)
vendor/SHA256SUMS  per-file digests, checked by build.sh
gen_fixtures.c   ~40-line main that drives bs2b_cross_feed_d and writes the CSVs
build.sh         compile + run; regenerates vectors/
vectors/*.csv    THE COMMITTED FIXTURES — the only thing tests read
```

## The vectors

Three files, one per shipped preset, all at **44.1 kHz**:

| File | Preset | `fcut` | `feed` |
|---|---|---|---|
| `vectors/default-44100.csv` | `BS2B_DEFAULT_CLEVEL` | 700 Hz | 4.5 dB |
| `vectors/cmoy-44100.csv` | `BS2B_CMOY_CLEVEL` | 700 Hz | 6.0 dB |
| `vectors/jmeier-44100.csv` | `BS2B_JMEIER_CLEVEL` | 650 Hz | 9.5 dB |

Each holds the first **256 samples** of the impulse response for an **L-only**
input (`L = 1.0`, `R = 0.0` at `n = 0`, silence afterwards), recording **both**
output channels — `out_l` is the highboosted direct path, `out_r` is the
lowpassed crossfeed path. Two `#` comment lines precede a `n,out_l,out_r` header;
values are `%.17g` round-trip-exact doubles.

`bs2b_cross_feed_d` clips at ±1.0. A unit impulse never reaches that bound, and
`gen_fixtures.c` **asserts** it never does, so the recorded response is the
unclipped kernel output.

## Regenerating

```sh
tools/fixtures/bs2b/build.sh
```

Run this **only** when bumping the libbs2b version. The CSVs are committed
artifacts; **the test suite must never invoke this script** (tests read only
`vectors/*.csv`).

## Finding: the plan's `Fc_h` formula does not match libbs2b

The work plan specified

```
Fc_h = fcut · 2^((Gd − Gd_h) / 12)
```

but libbs2b 3.1.0 (`vendor/bs2b.c`, `init()`) computes

```c
Fc_hi = Fc_lo * pow(2.0, (GB_lo - 20.0 * log10(G_hi)) / 12.0);
```

i.e. it uses **`20·log₁₀(G_h)`** — the dB value of the *linear* highboost gain
`G_h = 1 − 10^(Gd_h/20)` — where the plan wrote the attenuation dB `Gd_h`
directly. These are not the same number: on the `default` preset the plan's
expression gives ≈ 539.8 Hz against libbs2b's ≈ 993.9 Hz, which moves the first
impulse sample from 0.79848 to 0.78752 — a ~1.1e-2 divergence, two orders of
magnitude outside the 1e-4 acceptance tolerance.

`CrossfeedCoefficients` therefore implements **libbs2b's** expression, keeping
every one of the plan's names (`Gd`, `Gd_h`, `Fc_h`, `G`, `G_h`, `x`, `x_h`). The
plan's own acceptance criterion — match this independent oracle to 1e-4 — is what
settles it; the alternative is unsatisfiable by construction.
