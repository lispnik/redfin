# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Common Lisp client for Redfin's internal `stingray/api/gis-csv` endpoint.
Fetches active for-sale listings for a region with filters and parses the CSV
into `listing` structs. There is no official Redfin API; this uses an internal
endpoint and is subject to Redfin's ToS — keep usage low-volume and personal,
and never commit scraped listing data to the repo.

## Layout

- `redfin.asd` — system definitions: `:redfin`, `:redfin/cli`, `:redfin/tests`.
- `src/package.lisp` — package + exports. Add new public symbols here.
- `src/cache.lisp` — the optional on-disk response cache (`*cache-enabled*`,
  `*cache-ttl*`, `*cache-directory*`, `cache-get`/`cache-put`, `clear-cache`).
- `src/regions.lisp` — `resolve-region`, the `redfin-error` condition, and the
  shared `http-get` / user-agent / `strip-guard` helpers.
- `src/listings.lisp` — query building, CSV parsing, the `listing` struct,
  `search-listings`, and `tile-by-price`.
- `src/commute.lisp` — Mapbox-based weekday commute-time estimates
  (`resolve-commute-target`, `listing-commute`): geocode a destination, sample
  the driving-traffic Directions API across weekday departures, return
  mean/stddev minutes. Pure helpers (`parse-geocode`, `parse-duration`,
  `mean-stddev`, `weekday-departures`) are split out for offline tests. Loads
  last (uses `http-get`, `parse-json`/`jget`, and the `listing` accessors).
- `src/cli.lisp` — the standalone CLI (`redfin/cli` package + system): arg
  parsing, table/CSV output, and the `toplevel` executable entry point.
- `src/clog.lisp` — the CLOG browser GUI (`redfin/clog` package + system):
  a search form + results table over the exported `redfin` API. `start`/`stop`.
- `tests/main.lisp` — FiveAM suite.

The core library files (`package → cache → regions → listings → commute`) load
`:serial t`; keep that order, since `http-get` in `regions` calls the cache
helpers, `listings` uses conditions/helpers from `regions`, and `commute` uses
all of the above. Commute needs a Mapbox token in `MAPBOX_TOKEN` /
`MAPBOX_ACCESS_TOKEN` (or `redfin:*mapbox-token*`).
`cli.lisp` and `clog.lisp` are each *separate* systems (`:redfin/cli` and
`:redfin/clog`, both depending on `:redfin`) so the library stays free of
UI concerns — don't fold either into the `:redfin` system. `:redfin/clog` also
depends on `:clog`; both consume only the exported `redfin` API.

## Environment

- SBCL + ocicl. `ocicl` manages dependencies (not Quicklisp here).
- Run `ocicl install` in the repo root to fetch deps into `systems/` before
  first load; `setup.lisp` wires ocicl into the SBCL image.
- Dependencies: `dexador`, `quri`, `cl-csv`, `com.inuoe.jzon`, `alexandria`,
  plus `fiveam` for tests and `clog` for the `:redfin/clog` GUI system. JSON
  parsing goes through the `parse-json` / `jget`
  helpers in `regions.lisp`, not `com.inuoe.jzon:parse` directly — keep it that
  way so the parser stays swappable in one place.

## Common commands

- `make deps` — `ocicl install`.
- `make build` — build the standalone CLI to `bin/redfin` via
  `asdf:make :redfin/cli` (SBCL `program-op`; `bin/` is gitignored).
- `make test` — run the offline FiveAM suite.
- `make test-live` — run tests including the live network test
  (`REDFIN_LIVE_TESTS=1`). Hits redfin.com; needs a US IP.
- `make repl` — start SBCL with the system loaded.
- `make clog` — run the CLOG web GUI in the foreground (`PORT=NNNN` to change
  the default 8080); loads `:redfin/clog`.
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
- The shell-completion scripts in `completions/` (`redfin.bash`, `_redfin`)
  mirror the CLI's `*options*` and extra flags in `src/cli.lisp`. When you add
  or rename a CLI flag, update both completion files too.

## Testing notes

- Offline tests must stay green with no network. Anything requiring a request
  goes behind the `REDFIN_LIVE_TESTS` env var (see `live-austin-search`).
- Austin city is `region_id` 30818, `region_type` 6. Handy for live checks.
- When changing the CSV parser, add a fixture row to `+sample-csv+` rather
  than relying on live data.
- Run one test from the REPL with `(fiveam:run! 'redfin/tests::parse-csv-fields)`
  (or `run` without the `!` to get the results object without a printed report).

## Gotchas

- Redfin prefixes JSON payloads with `{}&&` (anti-hijacking). `strip-guard`
  removes it; the `gis-csv` success path is raw CSV, but the *error* path
  returns guarded JSON — `parse-csv` detects that and signals `redfin-error`.
- The gis-csv body has a one-column MLS-rules disclaimer row (a single quoted
  field) right after the header. `data-row-p` skips it (and blank rows) in
  `parse-csv` so it doesn't become an all-NIL phantom `listing`.
- The endpoint caps results at 350 rows. `search-listings` with
  `:tile-when-capped t` splits a price range into bands to work around it.
- The stingray endpoint is US-IP only and rate-limits by IP. `http-get`
  caches successful responses on disk (keyed on the full URL, `*cache-ttl*`
  default 3600s) to avoid re-hitting it; bind `*cache-enabled*` to NIL (or use
  the CLI `--no-cache`) to bypass. A gis-csv error path that returns HTTP 200
  with guarded JSON *will* be cached — `--clear-cache` or the TTL clears it.
