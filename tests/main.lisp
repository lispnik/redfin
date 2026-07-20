;;;; tests/main.lisp

(in-package #:redfin/tests)

(def-suite redfin :description "Redfin listings client test suite.")
(in-suite redfin)

;;; ---------------------------------------------------------------------------
;;; Guard stripping
;;; ---------------------------------------------------------------------------

(test strip-guard-removes-prefix
  (is (string= "{\"a\":1}" (redfin::strip-guard "{}&&{\"a\":1}"))))

(test strip-guard-leaves-plain-csv
  (is (string= "A,B,C" (redfin::strip-guard "A,B,C"))))

(test user-agent-is-a-valid-header-value
  ;; No CR/LF: an embedded newline makes an illegal (line-folded) header that
  ;; strict servers (e.g. Mapbox) reject with HTTP 400.
  (is (null (find #\Newline redfin::+user-agent+)))
  (is (null (find #\Return redfin::+user-agent+)))
  (is (null (find #\~ redfin::+user-agent+))))

(test strip-guard-handles-short-input
  (is (string= "" (redfin::strip-guard "")))
  (is (string= "{}" (redfin::strip-guard "{}"))))

;;; ---------------------------------------------------------------------------
;;; Property-type -> uipt
;;; ---------------------------------------------------------------------------

(test uipt-default-is-all-types
  (is (string= "1,2,3,4,5,6,7,8" (redfin::property-types->uipt nil))))

(test uipt-selected-types
  (is (string= "1,2,3"
               (redfin::property-types->uipt '(:house :condo :townhouse)))))

(test uipt-unknown-type-signals
  (signals redfin:redfin-error
    (redfin::property-types->uipt '(:mansion))))

;;; ---------------------------------------------------------------------------
;;; Query building
;;; ---------------------------------------------------------------------------

(test build-requires-region-id
  (signals redfin:redfin-error
    (redfin::build-query-params :min-price 100000)))

(test build-omits-nil-params
  (let ((params (redfin::build-query-params :region-id "30818"
                                            :min-price 500000)))
    ;; min_price present, max_price absent
    (is (assoc "min_price" params :test #'string=))
    (is (not (assoc "max_price" params :test #'string=)))))

(test build-includes-core-params
  (let ((params (redfin::build-query-params :region-id "30818"
                                            :region-type 6
                                            :min-beds 3
                                            :min-baths 2)))
    (flet ((val (k) (cdr (assoc k params :test #'string=))))
      (is (string= "30818" (val "region_id")))
      (is (string= "6" (val "region_type")))
      (is (string= "3" (val "num_beds")))
      (is (string= "2" (val "num_baths")))
      (is (string= "1" (val "status")))
      (is (string= "350" (val "num_homes"))))))

(test build-query-url-is-wellformed
  (let ((url (redfin:build-query-url :region-id "30818"
                                     :min-price 500000
                                     :max-price 760000
                                     :min-beds 3)))
    (is (search "stingray/api/gis-csv" url))
    (is (search "region_id=30818" url))
    (is (search "min_price=500000" url))
    (is (search "num_beds=3" url))))

;;; ---------------------------------------------------------------------------
;;; Region URL parsing
;;; ---------------------------------------------------------------------------

(test region-id-from-url
  (is (string= "30818" (redfin::region-id-from-url "/city/30818/TX/Austin"))))

(test region-type-from-city-url
  (is (= 6 (redfin::region-type-from-url "/city/30818/TX/Austin"))))

(test region-type-from-zip-url
  (is (= 2 (redfin::region-type-from-url "/zipcode/78704"))))

(test region-type-unknown-signals
  (signals redfin:redfin-error
    (redfin::region-type-from-url "/bogus/123/TX")))

;;; ---------------------------------------------------------------------------
;;; JSON access (jzon) and autocomplete parsing
;;; ---------------------------------------------------------------------------

(test jget-maps-null-and-missing-to-nil
  (let ((h (redfin::parse-json "{\"a\":1,\"b\":null}")))
    (is (= 1 (redfin::jget h "a")))
    (is (null (redfin::jget h "b")))          ; JSON null -> NIL
    (is (null (redfin::jget h "missing")))    ; absent key -> NIL
    (is (null (redfin::jget 42 "a")))))       ; non-object -> NIL

(test region-from-autocomplete-exact-match
  (let ((r (redfin::region-from-autocomplete
            "{}&&{\"payload\":{\"exactMatch\":{\"url\":\"/city/30818/TX/Austin\",\"name\":\"Austin, TX\"},\"sections\":[]}}")))
    (is (string= "30818" (redfin:region-id r)))
    (is (= 6 (redfin:region-type r)))
    (is (string= "Austin, TX" (redfin:region-name r)))))

(test region-from-autocomplete-null-exactmatch-falls-back
  ;; exactMatch is JSON null (jzon yields CL:NULL) -> must fall back to the
  ;; first section's first row rather than treating null as a match.
  (let ((r (redfin::region-from-autocomplete
            "{\"payload\":{\"exactMatch\":null,\"sections\":[{\"rows\":[{\"url\":\"/zipcode/78704\",\"name\":\"78704\"}]}]}}")))
    (is (string= "78704" (redfin:region-id r)))
    (is (= 2 (redfin:region-type r)))))

(test region-from-autocomplete-no-match-signals
  (signals redfin:redfin-error
    (redfin::region-from-autocomplete
     "{\"payload\":{\"exactMatch\":null,\"sections\":[]}}")))

;;; ---------------------------------------------------------------------------
;;; Number parsing
;;; ---------------------------------------------------------------------------

(test parse-number-basics
  (is (= 500000 (redfin::parse-number "500000")))
  (is (= 3 (redfin::parse-number " 3 ")))
  (is (null (redfin::parse-number "")))
  (is (null (redfin::parse-number "   ")))
  (is (null (redfin::parse-number nil))))

(test parse-number-float
  (is (< (abs (- 30.2679d0 (redfin::parse-number "30.2679"))) 1d-6)))

;;; ---------------------------------------------------------------------------
;;; CSV parsing
;;; ---------------------------------------------------------------------------

(defparameter +sample-csv+
  (concatenate 'string
   "SALE TYPE,PROPERTY TYPE,ADDRESS,CITY,STATE OR PROVINCE,ZIP OR POSTAL CODE,"
   "PRICE,BEDS,BATHS,SQUARE FEET,LOT SIZE,YEAR BUILT,DAYS ON MARKET,"
   "$/SQUARE FEET,HOA/MONTH,LATITUDE,LONGITUDE,MLS#,"
   "URL (SEE https://www.redfin.com/buy-a-home/comparative-market-analysis FOR INFO ON PRICING)"
   (string #\Newline)
   ;; Redfin inserts this one-column disclaimer note right after the header.
   ;; It is a single quoted field (it contains a comma), exactly as returned.
   "\"In accordance with local MLS rules, some MLS listings are not included in the download\""
   (string #\Newline)
   "MLS Listing,Single Family Residential,123 Main St,Austin,TX,78704,"
   "650000,3,2,1800,7000,1995,12,361,0,30.2500,-97.7500,ACT1234,"
   "https://www.redfin.com/TX/Austin/123-Main-St-78704/home/12345"
   (string #\Newline)
   "MLS Listing,Condo/Co-op,456 Oak Ave,Austin,TX,78745,"
   "525000,2,2,1200,,2005,3,437,250,30.2100,-97.8000,ACT5678,"
   "https://www.redfin.com/TX/Austin/456-Oak-Ave-78745/home/67890"
   (string #\Newline)))

(test parse-csv-row-count
  (let ((listings (redfin::parse-csv +sample-csv+)))
    ;; two real listings; the one-column disclaimer note is skipped
    (is (= 2 (length listings)))))

(test parse-csv-skips-disclaimer-note
  ;; The first parsed listing must be the real row, not the MLS-rules note.
  (let ((l (first (redfin::parse-csv +sample-csv+))))
    (is (string= "123 Main St" (redfin:listing-address l)))
    (is (string= "MLS Listing" (redfin:listing-sale-type l)))))

(test parse-csv-fields
  (let ((l (first (redfin::parse-csv +sample-csv+))))
    (is (string= "123 Main St" (redfin:listing-address l)))
    (is (string= "Austin" (redfin:listing-city l)))
    (is (string= "78704" (redfin:listing-zip l)))
    (is (= 650000 (redfin:listing-price l)))
    (is (= 3 (redfin:listing-beds l)))
    (is (= 2 (redfin:listing-baths l)))
    (is (= 1800 (redfin:listing-sqft l)))
    (is (= 1995 (redfin:listing-year-built l)))
    (is (string= "ACT1234" (redfin:listing-mls l)))
    (is (search "123-Main-St" (redfin:listing-url l)))))

(test parse-csv-blank-numeric-is-nil
  (let ((l (second (redfin::parse-csv +sample-csv+))))
    ;; second row has empty LOT SIZE
    (is (null (redfin:listing-lot-size l)))
    (is (= 250 (redfin:listing-hoa l)))))

(test parse-csv-detects-json-error
  (signals redfin:redfin-error
    (redfin::parse-csv
     (concatenate 'string
      "{}&&{\"errorMessage\":\"GISParameterParser did not receive any region\","
      "\"resultCode\":101}"))))

(test parse-csv-error-carries-code
  (handler-case
      (redfin::parse-csv "{\"errorMessage\":\"no region\",\"resultCode\":101}")
    (redfin:redfin-error (e)
      (is (eql 101 (redfin:redfin-error-code e)))
      (is (string= "no region" (redfin:redfin-error-message e))))))

;;; ---------------------------------------------------------------------------
;;; Header matching robustness
;;; ---------------------------------------------------------------------------

(test slot-for-column-case-insensitive
  (is (eq 'redfin::price (redfin::slot-for-column "price")))
  (is (eq 'redfin::price (redfin::slot-for-column "  PRICE ")))
  (is (eq 'redfin::address (redfin::slot-for-column "ADDRESS"))))

(test slot-for-column-url-prefix
  (is (eq 'redfin::url (redfin::slot-for-column "URL (SEE whatever)")))
  (is (eq 'redfin::url (redfin::slot-for-column "URL"))))

(test slot-for-column-unknown-is-nil
  (is (null (redfin::slot-for-column "SOME NEW COLUMN"))))

;;; ---------------------------------------------------------------------------
;;; CLI --sort
;;; ---------------------------------------------------------------------------

(test cli-parse-sort-defaults-ascending
  (multiple-value-bind (acc descp) (redfin/cli::parse-sort "--sort" "price")
    (is (functionp acc))
    (is (null descp))))

(test cli-parse-sort-desc
  (multiple-value-bind (acc descp) (redfin/cli::parse-sort "--sort" "price:desc")
    (declare (ignore acc))
    (is (eq t descp))))

(test cli-parse-sort-alias
  (multiple-value-bind (acc descp) (redfin/cli::parse-sort "--sort" "ppsf")
    (declare (ignore descp))
    (is (eq acc #'redfin:listing-price-per-sqft))))

(test cli-parse-sort-unknown-field-signals
  (signals redfin:redfin-error
    (redfin/cli::parse-sort "--sort" "bogus")))

(test cli-parse-sort-bad-direction-signals
  (signals redfin:redfin-error
    (redfin/cli::parse-sort "--sort" "price:sideways")))

(test cli-sort-listings-orders-with-nils-last
  (let* ((a (redfin::make-listing :price 500000))
         (b (redfin::make-listing :price 300000))
         (c (redfin::make-listing :price nil))
         (asc  (redfin/cli::sort-listings (list a c b)
                                          #'redfin:listing-price nil))
         (desc (redfin/cli::sort-listings (list a c b)
                                          #'redfin:listing-price t)))
    (is (equal '(300000 500000 nil) (mapcar #'redfin:listing-price asc)))
    ;; descending among present values; NIL still sorts last
    (is (equal '(500000 300000 nil) (mapcar #'redfin:listing-price desc)))))

;;; ---------------------------------------------------------------------------
;;; Response cache (offline; uses a temp directory)
;;; ---------------------------------------------------------------------------

(defmacro with-temp-cache (&body body)
  "Run BODY with the cache pointed at a fresh temp dir, cleaned up after."
  `(let ((redfin:*cache-directory*
           (ensure-directories-exist
            (merge-pathnames "redfin-tests-cache/" (uiop:temporary-directory))))
         (redfin:*cache-enabled* t)
         (redfin:*cache-ttl* 3600))
     (unwind-protect (progn ,@body)
       (redfin:clear-cache))))

(test cache-key-deterministic-and-distinct
  (is (string= (redfin::cache-key "https://x/a")
               (redfin::cache-key "https://x/a")))
  (is (not (string= (redfin::cache-key "https://x/a")
                    (redfin::cache-key "https://x/b"))))
  ;; 16 lowercase hex chars
  (is (= 16 (length (redfin::cache-key "anything"))))
  (is (every (lambda (c) (find c "0123456789abcdef"))
             (redfin::cache-key "anything"))))

(test cache-round-trips-body
  (with-temp-cache
    (is (null (redfin::cache-get "http://u/1")))
    (redfin::cache-put "http://u/1" "hello,csv")
    (is (string= "hello,csv" (redfin::cache-get "http://u/1")))
    ;; distinct URLs don't collide
    (is (null (redfin::cache-get "http://u/2")))))

(test cache-respects-ttl
  (with-temp-cache
    (redfin::cache-put "http://u/ttl" "body")
    (let ((redfin:*cache-ttl* -1))          ; any entry is already stale
      (is (null (redfin::cache-get "http://u/ttl"))))))

(test cache-disabled-neither-reads-nor-writes
  (with-temp-cache
    (let ((redfin:*cache-enabled* nil))
      (redfin::cache-put "http://u/off" "body")   ; must not write
      (is (null (redfin::cache-get "http://u/off"))))
    ;; still absent once re-enabled -> confirms nothing was written
    (is (null (redfin::cache-get "http://u/off")))))

(test cache-clear-removes-entries
  (with-temp-cache
    (redfin::cache-put "http://u/a" "a")
    (redfin::cache-put "http://u/b" "b")
    (is (= 2 (redfin:clear-cache)))
    (is (null (redfin::cache-get "http://u/a")))))

;;; ---------------------------------------------------------------------------
;;; Commute (Mapbox) -- pure logic, offline
;;; ---------------------------------------------------------------------------

(test commute-mean-stddev
  (multiple-value-bind (mean sd n) (redfin::mean-stddev '(10 20 30))
    (is (= 20 mean))
    (is (< (abs (- 10 sd)) 1d-9))          ; sample stddev (n-1)
    (is (= 3 n)))
  (multiple-value-bind (mean sd n) (redfin::mean-stddev '(42))
    (is (= 42 mean)) (is (= 0 sd)) (is (= 1 n)))
  (multiple-value-bind (mean sd n) (redfin::mean-stddev '())
    (is (null mean)) (is (null sd)) (is (= 0 n))))

(test commute-simplify-label
  (is (string= "1600 Amphitheatre Parkway"
               (redfin::simplify-commute-label
                "1600 Amphitheatre Parkway, Mountain View, CA")))
  (is (string= "Downtown Austin"
               (redfin::simplify-commute-label "  Downtown Austin  ")))
  (is (string= "78704" (redfin::simplify-commute-label "78704"))))

(test commute-parse-geocode
  (multiple-value-bind (lon lat)
      (redfin::parse-geocode
       "{\"type\":\"FeatureCollection\",\"features\":[{\"geometry\":{\"type\":\"Point\",\"coordinates\":[-97.74,30.27]}}]}")
    (is (< (abs (- -97.74d0 lon)) 1d-6))
    (is (< (abs (- 30.27d0 lat)) 1d-6)))
  ;; no features -> NIL
  (is (null (redfin::parse-geocode "{\"features\":[]}"))))

(test commute-parse-duration
  (is (< (abs (- 1234.5 (redfin::parse-duration
                         "{\"code\":\"Ok\",\"routes\":[{\"duration\":1234.5}]}")))
         1d-6))
  (is (null (redfin::parse-duration "{\"code\":\"NoRoute\",\"routes\":[]}")))
  (is (null (redfin::parse-duration "{\"code\":\"Ok\",\"routes\":[]}"))))

(test commute-weekday-departures-skips-weekend
  ;; 2024-05-18 is a Saturday -> next weekday is Monday 2024-05-20.
  (let ((sat (encode-universal-time 0 0 12 18 5 2024)))
    (multiple-value-bind (y mo d) (redfin::next-weekday-date sat)
      (is (= 2024 y)) (is (= 5 mo)) (is (= 20 d)))
    (is (equal '("2024-05-20T07:00" "2024-05-20T08:30")
               (redfin::weekday-departures sat '("07:00" "08:30"))))))

(test commute-listing-without-coords-is-empty
  ;; No network: a listing missing lat/lon returns no commute.
  (let ((l (redfin::make-listing :latitude nil :longitude nil))
        (tgt (redfin::%make-commute-target :label "X" :lon -97.7 :lat 30.2)))
    (multiple-value-bind (mean sd n) (redfin:listing-commute l tgt)
      (is (null mean)) (is (null sd)) (is (= 0 n)))))

;;; ---------------------------------------------------------------------------
;;; Optional live test (network). Enabled only when REDFIN_LIVE_TESTS is set,
;;; so CI and offline runs stay green.
;;; ---------------------------------------------------------------------------

(test live-austin-search
  (if (uiop:getenv "REDFIN_LIVE_TESTS")
      (let ((listings (redfin:search-listings
                       :region-id "30818" :region-type 6
                       :min-price 500000 :max-price 760000
                       :min-beds 3 :min-baths 2
                       :property-types '(:house :condo :townhouse))))
        (is (listp listings))
        (when listings
          (is (every #'redfin:listing-p listings))
          (is (every (lambda (l)
                       (let ((p (redfin:listing-price l)))
                         (or (null p) (<= 500000 p 760000))))
                     listings))
          ;; beds/baths filters must actually be honored server-side
          ;; (guards the num_beds/num_baths param names).
          (is (every (lambda (l)
                       (let ((b (redfin:listing-beds l)))
                         (or (null b) (>= b 3))))
                     listings))
          (is (every (lambda (l)
                       (let ((b (redfin:listing-baths l)))
                         (or (null b) (>= b 2))))
                     listings))))
      (skip "Set REDFIN_LIVE_TESTS to run the live network test.")))
