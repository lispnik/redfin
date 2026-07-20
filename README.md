# redfin

A small Common Lisp client for Redfin's internal `stingray/api/gis-csv`
endpoint. Fetches active for-sale listings for a region with filters (price,
beds, baths, size, year, HOA, stories, property type) and parses the CSV into
`listing` structs.

No official Redfin API exists, and this uses an internal endpoint. It is
subject to Redfin's Terms of Service. Keep usage low-volume and personal;
don't redistribute the data.

## Install

Depends on `dexador`, `quri`, `cl-csv`, `yason`, `alexandria` — all in ocicl
and Quicklisp. Drop this directory in your `local-projects` (or an ocicl
systems dir) and:

```lisp
(asdf:load-system :redfin)
```

## Usage

Search by explicit region id (Austin city is `30818`, `region_type` 6):

```lisp
(redfin:search-listings
  :region-id "30818" :region-type 6
  :min-price 500000 :max-price 760000
  :min-beds 3 :min-baths 2
  :property-types '(:house :condo :townhouse))
;; => list of REDFIN:LISTING structs
```

Or resolve a place name automatically:

```lisp
(redfin:search-listings
  :location "Austin, TX"
  :min-price 500000 :max-price 760000 :min-beds 3)
```

Inspect the URL a query will hit (handy for pasting into curl):

```lisp
(redfin:build-query-url :region-id "30818" :min-price 500000 :min-beds 3)
```

### The 350-row cap

Redfin returns at most 350 rows per request. For dense areas, pass
`:tile-when-capped t` with a price range; the search splits the range into
`:band-count` sub-ranges, fetches each, and merges de-duplicated on MLS#:

```lisp
(redfin:search-listings
  :region-id "30818" :region-type 6
  :min-price 300000 :max-price 1200000
  :tile-when-capped t :band-count 12)
```

## Command-line tool

Build a standalone binary (SBCL `program-op`; lands in `bin/`, which is
gitignored):

```sh
make build          # -> bin/redfin
```

```sh
bin/redfin --location "Austin, TX" \
  --min-price 500000 --max-price 760000 \
  --min-beds 3 --min-baths 2 \
  --property-types house,condo,townhouse --limit 20
```

Output is a table by default, or CSV with `--format csv`. Pass a location with
`--location` (free text or zip) or an explicit `--region-id` (with optional
`--region-type`). Add `--tile` with a price range to beat the 350-row cap.

Sort with `--sort FIELD[:asc|:desc]` (default ascending), applied before
`--limit` so it doubles as a top-N — e.g. `--sort price:desc --limit 10` for
the ten priciest. Sortable fields: `price`, `beds`, `baths`, `sqft`,
`lot-size`, `year-built` (`year`), `days-on-market` (`dom`), `price-per-sqft`
(`ppsf`), `hoa`; listings missing that field sort last. See
`bin/redfin --help` for the full option list.

### Shell completion

Completion scripts for every flag (with value completion for `--sort`,
`--format`, `--property-types`, `--status`, and `--region-type`) live in
`completions/`.

Bash — source it from `~/.bashrc`, or install into a bash-completion dir:

```sh
source /path/to/redfin/completions/redfin.bash
```

Zsh — put `_redfin` on your `$fpath` before `compinit`:

```sh
mkdir -p ~/.zsh/completions
cp completions/_redfin ~/.zsh/completions/
# in ~/.zshrc, before `compinit`:  fpath=(~/.zsh/completions $fpath)
```

### Listing slots

`sale-type property-type address city state zip price beds baths sqft
lot-size year-built days-on-market price-per-sqft hoa latitude longitude
mls url`. Numeric slots are parsed to numbers; blanks become `nil`.

## Filter reference

These map to reverse-engineered stingray params and can change without notice:

| keyword | param |
|---|---|
| `:min-price` / `:max-price` | `min_price` / `max_price` |
| `:min-beds` / `:max-beds` | `min_num_beds` / `max_num_beds` |
| `:min-baths` | `min_num_baths` |
| `:min-sqft` / `:max-sqft` | `min_listing_approx_size` / `max_listing_approx_size` |
| `:min-year-built` / `:max-year-built` | `min_year_built` / `max_year_built` |
| `:max-hoa` | `hoa` |
| `:min-stories` | `min_stories` |
| `:status` | `status` (1 = active, 9 = active + coming soon) |
| `:property-types` | `uipt` (`:house :condo :townhouse :multi-family :land :other :manufactured :co-op`) |

## Tests

FiveAM suite. Pure-logic tests run offline; the live network test is gated
behind an env var so normal runs stay green:

```lisp
(asdf:test-system :redfin)                 ; offline tests
```

```sh
REDFIN_LIVE_TESTS=1 sbcl --eval '(asdf:test-system :redfin)' --quit
```

## Caveats

- The stingray endpoint is US-IP only and rate-limits by IP; from a
  datacenter/VPN address you may get empty bodies or challenges.
- Column names and param names occasionally change; the CSV parser matches
  headers case-insensitively and tolerates unknown/missing columns, and the
  `url` column is matched by prefix.
- `region_type` codes: 1 neighborhood, 2 zip, 5 county, 6 city.
