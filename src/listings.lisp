;;;; listings.lisp --- query the gis-csv endpoint and parse results

(in-package #:redfin)

(defparameter +gis-csv-url+
  "https://www.redfin.com/stingray/api/gis-csv")

;;; uipt (property type) codes used by the stingray API.
(defparameter *property-types*
  '((:house       . 1)
    (:condo       . 2)
    (:townhouse   . 3)
    (:multi-family . 4)
    (:land        . 5)
    (:other       . 6)
    (:manufactured . 7)
    (:co-op       . 8))
  "Maps a keyword property type to its uipt code.")

(defparameter +result-cap+ 350
  "Redfin returns at most this many rows per gis-csv request.")

(defstruct listing
  sale-type property-type address city state zip
  price beds baths sqft lot-size year-built days-on-market
  price-per-sqft hoa latitude longitude mls url)

;;; ---------------------------------------------------------------------------
;;; Query construction
;;; ---------------------------------------------------------------------------

(defun property-types->uipt (types)
  "TYPES is a list of keywords from *PROPERTY-TYPES*. Returns the uipt string
e.g. \"1,2,3\". NIL means all residential types."
  (let ((codes (if types
                   (mapcar (lambda (k)
                             (or (cdr (assoc k *property-types*))
                                 (error 'redfin-error
                                        :message (format nil "Unknown property type ~s" k))))
                           types)
                   '(1 2 3 4 5 6 7 8))))
    (format nil "~{~a~^,~}" codes)))

(defun %param (name value)
  "Return a (name . string-value) cons if VALUE is non-nil, else NIL."
  (when value
    (cons name (princ-to-string value))))

(defun build-query-params (&key region-id (region-type 6)
                                min-price max-price
                                min-beds max-beds
                                min-baths
                                min-sqft max-sqft
                                min-year-built max-year-built
                                max-hoa
                                min-stories
                                (property-types nil)
                                (status 1)
                                (num-homes +result-cap+)
                                (page 1))
  "Build the alist of query parameters for a gis-csv request. REGION-ID is
required. STATUS 1 = active for-sale; 9 = active + coming-soon."
  (unless region-id
    (error 'redfin-error :message "REGION-ID is required"))
  (remove nil
          (list (cons "al" "1")
                (cons "v" "8")
                (%param "region_id" region-id)
                (%param "region_type" region-type)
                (%param "status" status)
                (cons "uipt" (property-types->uipt property-types))
                (cons "sf" "1,2,3,5,6,7")
                (%param "num_homes" num-homes)
                (%param "page_number" page)
                (%param "min_price" min-price)
                (%param "max_price" max-price)
                (%param "min_num_beds" min-beds)
                (%param "max_num_beds" max-beds)
                (%param "min_num_baths" min-baths)
                (%param "min_listing_approx_size" min-sqft)
                (%param "max_listing_approx_size" max-sqft)
                (%param "min_year_built" min-year-built)
                (%param "max_year_built" max-year-built)
                (%param "hoa" max-hoa)
                (%param "min_stories" min-stories))))

(defun build-query-url (&rest args)
  "Return the full gis-csv URL string for the given keyword ARGS (see
BUILD-QUERY-PARAMS). Useful for debugging and for pasting into curl."
  (quri:render-uri
   (quri:make-uri :defaults +gis-csv-url+
                  :query (apply #'build-query-params args))))

;;; ---------------------------------------------------------------------------
;;; CSV parsing
;;; ---------------------------------------------------------------------------

;;; The gis-csv header uses human-readable column names. We map the ones we care
;;; about to struct slots. Redfin occasionally tweaks column names, so matching
;;; is done case-insensitively and tolerates missing columns.
(defparameter *column-map*
  '(("SALE TYPE"                       . sale-type)
    ("PROPERTY TYPE"                    . property-type)
    ("ADDRESS"                          . address)
    ("CITY"                             . city)
    ("STATE OR PROVINCE"                . state)
    ("ZIP OR POSTAL CODE"              . zip)
    ("PRICE"                            . price)
    ("BEDS"                             . beds)
    ("BATHS"                            . baths)
    ("SQUARE FEET"                      . sqft)
    ("LOT SIZE"                         . lot-size)
    ("YEAR BUILT"                       . year-built)
    ("DAYS ON MARKET"                   . days-on-market)
    ("$/SQUARE FEET"                    . price-per-sqft)
    ("HOA/MONTH"                        . hoa)
    ("LATITUDE"                         . latitude)
    ("LONGITUDE"                        . longitude)
    ("MLS#"                             . mls)
    ("URL (SEE https://www.redfin.com/buy-a-home/comparative-market-analysis FOR INFO ON PRICING)"
     . url)))

(defun normalize-header (name)
  (string-trim '(#\Space #\Tab #\Return) (string-upcase name)))

(defun slot-for-column (column-name)
  "Return the struct slot symbol for COLUMN-NAME, or NIL. Matches the URL column
by prefix since its header is long and occasionally reworded."
  (let ((norm (normalize-header column-name)))
    (cond
      ((cdr (assoc norm *column-map* :test #'string=)))
      ((and (>= (length norm) 3) (string= (subseq norm 0 3) "URL")) 'url)
      (t nil))))

(defun parse-number (string)
  "Parse a numeric cell, tolerating blanks, currency symbols, commas and a
trailing percent. Returns NIL for empty or non-numeric input.

Does not use READ, so untrusted CSV cells cannot trigger reader macros or
intern symbols."
  (let ((s (and string (string-trim '(#\Space #\Tab #\Return #\$ #\% #\")
                                    string))))
    (when (and s (plusp (length s)))
      ;; strip thousands separators
      (setf s (remove #\, s))
      (let ((dot (position #\. s)))
        (if dot
            ;; decimal: parse integer and fractional parts as double
            (let* ((int-part (subseq s 0 dot))
                   (frac-part (subseq s (1+ dot)))
                   (neg (and (plusp (length int-part))
                             (char= (char int-part 0) #\-)))
                   (int (if (or (string= int-part "") (string= int-part "-"))
                            0
                            (ignore-errors (parse-integer int-part :junk-allowed nil))))
                   (frac (if (string= frac-part "")
                             0
                             (ignore-errors (parse-integer frac-part :junk-allowed nil)))))
              (when (and int frac)
                (let ((val (+ (abs int)
                              (/ (coerce frac 'double-float)
                                 (expt 10 (length frac-part))))))
                  (if neg (- val) val))))
            ;; integer
            (ignore-errors (parse-integer s :junk-allowed nil)))))))

(defparameter *numeric-slots*
  '(price beds baths sqft lot-size year-built days-on-market
    price-per-sqft hoa latitude longitude))

(defun row->listing (header row)
  "Build a LISTING from a parsed CSV ROW given the HEADER (a vector of slot
symbols or NIL per column)."
  (let ((l (make-listing)))
    (loop for slot across header
          for cell in row
          when slot
            do (let ((value (if (member slot *numeric-slots*)
                                (parse-number cell)
                                cell)))
                 (setf (slot-value l slot) value)))
    l))

(defun data-row-p (row)
  "True unless ROW is a blank line or Redfin's single-column MLS-rules
disclaimer note (\"In accordance with local MLS rules, some MLS listings are
not included in the download\"), which follows the header and would otherwise
become an all-NIL phantom listing."
  (and (> (length row) 1)
       (some (lambda (cell)
               (plusp (length (string-trim '(#\Space #\Tab #\Return) cell))))
             row)))

(defun parse-csv (body)
  "Parse gis-csv BODY into a list of LISTING structs. Signals REDFIN-ERROR if
the body looks like a JSON error payload rather than CSV."
  (let ((clean (strip-guard body)))
    ;; A gis-csv error path returns JSON (possibly guarded). Detect and raise.
    (when (and (plusp (length clean))
               (char= (char clean 0) #\{))
      (let* ((json (ignore-errors (yason:parse clean)))
             (msg (and (hash-table-p json) (gethash "errorMessage" json)))
             (code (and (hash-table-p json) (gethash "resultCode" json))))
        (error 'redfin-error :code code
                             :message (or msg "gis-csv returned JSON, not CSV"))))
    (let ((rows (cl-csv:read-csv clean)))
      (when (null rows)
        (return-from parse-csv nil))
      (let ((header (map 'vector #'slot-for-column (first rows))))
        (loop for row in (rest rows)
              when (data-row-p row)
                collect (row->listing header row))))))

;;; ---------------------------------------------------------------------------
;;; Fetch
;;; ---------------------------------------------------------------------------

(defun fetch-page (&rest args)
  "Fetch a single gis-csv page and return a list of LISTINGs."
  (let ((body (http-get +gis-csv-url+
                        :parameters (apply #'build-query-params args))))
    (parse-csv body)))

(defun search-listings (&rest args
                        &key region-id location
                             min-price max-price
                             (tile-when-capped nil)
                             (band-count 8)
                        &allow-other-keys)
  "Search Redfin for-sale listings.

Provide either REGION-ID (with optional REGION-TYPE) or LOCATION (free text,
resolved via RESOLVE-REGION). Remaining keywords are passed through to
BUILD-QUERY-PARAMS: MIN-PRICE MAX-PRICE MIN-BEDS MAX-BEDS MIN-BATHS MIN-SQFT
MAX-SQFT MIN-YEAR-BUILT MAX-YEAR-BUILT MAX-HOA MIN-STORIES PROPERTY-TYPES
STATUS.

If TILE-WHEN-CAPPED is true and a query returns the +RESULT-CAP+ ceiling, the
price range is split into BAND-COUNT sub-ranges and each fetched separately,
then results are merged and de-duplicated on MLS#. This works around Redfin's
350-row-per-query limit for dense areas.

Performs network requests to redfin.com; subject to Redfin's ToS. Keep usage
low-volume and personal."
  ;; Resolve LOCATION -> region if no explicit id was given.
  (when (and (not region-id) location)
    (let ((region (resolve-region location)))
      (setf region-id (region-id region))
      (setf args (list* :region-id region-id
                        :region-type (region-type region)
                        (alexandria:remove-from-plist args :location)))))
  (unless region-id
    (error 'redfin-error :message "Provide :region-id or :location"))
  ;; Ensure region-id is in ARGS for the pass-through call.
  (unless (getf args :region-id)
    (setf args (list* :region-id region-id args)))
  (let* ((clean-args (alexandria:remove-from-plist
                      args :location :tile-when-capped :band-count))
         (page (apply #'fetch-page clean-args)))
    (if (and tile-when-capped
             (>= (length page) +result-cap+)
             (numberp min-price) (numberp max-price)
             (> max-price min-price))
        (tile-by-price clean-args min-price max-price band-count)
        page)))

(defun tile-by-price (base-args min-price max-price band-count)
  "Split [MIN-PRICE, MAX-PRICE] into BAND-COUNT contiguous bands, fetch each,
and merge de-duplicated on MLS#."
  (let ((seen (make-hash-table :test #'equal))
        (result '())
        (step (max 1 (floor (- max-price min-price) band-count))))
    (loop for lo from min-price below max-price by step
          for hi = (min max-price (+ lo step))
          do (let* ((band-args (list* :min-price lo :max-price hi
                                       (alexandria:remove-from-plist
                                        base-args :min-price :max-price)))
                    (listings (apply #'fetch-page band-args)))
               (dolist (l listings)
                 (let ((key (or (listing-mls l)
                                (list (listing-address l) (listing-zip l)))))
                   (unless (gethash key seen)
                     (setf (gethash key seen) t)
                     (push l result))))))
    (nreverse result)))
