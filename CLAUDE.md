# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

A Common Lisp client for Redfin's internal `stingray/api/gis-csv` endpoint.
Fetches active for-sale listings for a region with filters and parses the CSV
into `listing` structs. There is no official Redfin API; this uses an internal
endpoint and is subject to Redfin's ToS — keep usage low-volume and personal,
and never commit scraped listing data to the repo.

## Layout

- `redfin.asd` — system definitions: `:redfin` and `:redfin/tests`.
- `src/package.lisp` — package + exports. Add new public symbols here.
- `src/regions.lisp` — `resolve-region`, the `redfin-error` condition, and the
  shared `http-get` / user-agent / `strip-guard` helpers.
- `src/listings.lisp` — query building, CSV parsing, the `listing` struct,
  `search-listings`, and `tile-by-price`.
- `tests/main.lisp` — FiveAM suite.

`src` files are `:serial t`: package → regions → listings. Keep that order;
`listings` uses conditions and helpers defined in `regions`.

## Environment

- SBCL + ocicl. `ocicl` manages dependencies (not Quicklisp here).
- Run `ocicl install` in the repo root to fetch deps into `systems/` before
  first load; `setup.lisp` wires ocicl into the SBCL image.
- Dependencies: `dexador`, `quri`, `cl-csv`, `yason`, `alexandria`, plus
  `fiveam` for tests.

## Common commands

- `make deps` — `ocicl install`.
- `make test` — run the offline FiveAM suite.
- `make test-live` — run tests including the live network test
  (`REDFIN_LIVE_TESTS=1`). Hits redfin.com; needs a US IP.
- `make repl` — start SBCL with the system loaded.
- `make clean` — remove `.fasl` artifacts.

## Conventions

- Two-space indentation, standard CL style. Keep lines under ~90 columns.
- Public API is exported from `src/package.lisp`; internal helpers stay
  unexported and are referenced from tests with `redfin::`.
- Never parse untrusted input with `read`. The CSV number parser
  (`parse-number`) is deliberately hand-rolled for this reason — don't
  replace it with `read-from-string`.
- Header matching is case-insensitive and tolerant of missing/renamed
  columns. If Redfin renames a column, update `*column-map*` in
  `src/listings.lisp` rather than making the parser strict.
- Query param names in `build-query-params` are reverse-engineered and can
  change; when adding a filter, add both the keyword arg and the mapping, and
  cover it with a test in `tests/main.lisp`.

## Testing notes

- Offline tests must stay green with no network. Anything requiring a request
  goes behind the `REDFIN_LIVE_TESTS` env var (see `live-austin-search`).
- Austin city is `region_id` 30818, `region_type` 6. Handy for live checks.
- When changing the CSV parser, add a fixture row to `+sample-csv+` rather
  than relying on live data.

## Gotchas

- Redfin prefixes JSON payloads with `{}&&` (anti-hijacking). `strip-guard`
  removes it; the `gis-csv` success path is raw CSV, but the *error* path
  returns guarded JSON — `parse-csv` detects that and signals `redfin-error`.
- The endpoint caps results at 350 rows. `search-listings` with
  `:tile-when-capped t` splits a price range into bands to work around it.
- The stingray endpoint is US-IP only and rate-limits by IP.
