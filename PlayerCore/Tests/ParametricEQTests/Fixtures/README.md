# ParametricEQTests fixtures

## `Sennheiser HD 650 ParametricEQ.txt`

An **unmodified** AutoEq profile, committed verbatim so the parser is tested
against real upstream output rather than a hand-written approximation of it.

- **Source:** [AutoEq](https://github.com/jaakkopasanen/AutoEq) —
  `results/oratory1990/over-ear/Sennheiser HD 650/Sennheiser HD 650 ParametricEQ.txt`
- **Measurement:** oratory1990, over-ear target
- **Retrieved:** 2026-09-19
- **Bytes:** 480, LF line endings, trailing newline present
- **License:** AutoEq results are published under MIT (see the upstream repo).

### Why this profile

It is a single file that exercises every branch of the grammar the parser has to
get right:

| Property | Value | Exercises |
|---|---|---|
| `Preamp: -6.1 dB` | negative decimal | preamp line, signed number |
| `Filter 1: … LSC … Q 0.70` | low shelf | `LSC` (not legacy `LS`) |
| `Filter 6: … HSC … Q 0.70` | high shelf | `HSC` (not legacy `HS`) |
| Both shelf Q values | `0.70` | **inside** the ±20% band around 0.71 → NOT flagged as an approximated shelf slope |
| `Filter 3: … Gain -3.1 dB` | negative gain | signed gain |
| `Filter 4: … Fc 37 Hz` | two-digit Fc | integer frequency |
| `Filter 10:` | two-digit index | multi-digit `Filter N:` token |
| 10 enabled filters | — | under the 16-band ceiling |

Deviating shelf Q values, legacy `LS`/`HS` files, and malformed lines are
synthesised inline in `AutoEqProfileParserTests` — those are negative cases, and
committing a hand-corrupted "real" file would misrepresent upstream output.
