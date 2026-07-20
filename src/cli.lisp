;;;; cli.lisp --- command-line interface for the redfin client
;;;;
;;;; Lives in its own system (:redfin/cli) and package so the core library
;;;; stays free of CLI concerns. Built into a standalone binary via
;;;; `asdf:make :redfin/cli` (see redfin.asd / the Makefile `build` target).

(defpackage #:redfin/cli
  (:use #:cl)
  (:export #:toplevel #:main))

(in-package #:redfin/cli)

;;; ---------------------------------------------------------------------------
;;; Argument parsing
;;; ---------------------------------------------------------------------------

;;; Options that map straight through to SEARCH-LISTINGS keyword args. Each row
;;; is (flag keyword type); TYPE is :string, :int, or :keywords.
(defparameter *options*
  '(("--location"        :location        :string)
    ("--region-id"       :region-id       :string)
    ("--region-type"     :region-type     :int)
    ("--min-price"       :min-price       :int)
    ("--max-price"       :max-price       :int)
    ("--min-beds"        :min-beds        :int)
    ("--max-beds"        :max-beds        :int)
    ("--min-baths"       :min-baths       :int)
    ("--min-sqft"        :min-sqft        :int)
    ("--max-sqft"        :max-sqft        :int)
    ("--min-year-built"  :min-year-built  :int)
    ("--max-year-built"  :max-year-built  :int)
    ("--max-hoa"         :max-hoa         :int)
    ("--min-stories"     :min-stories     :int)
    ("--status"          :status          :int)
    ("--property-types"  :property-types  :keywords)
    ("--band-count"      :band-count      :int)))

(defun require-value (opt value)
  (unless value
    (error 'redfin:redfin-error
           :message (format nil "Option ~a requires a value" opt)))
  value)

(defun parse-int (opt string)
  (multiple-value-bind (n end) (ignore-errors (parse-integer string :junk-allowed t))
    (if (and n (= end (length string)))
        n
        (error 'redfin:redfin-error
               :message (format nil "Option ~a expects an integer, got ~s"
                                opt string)))))

(defun parse-keyword-list (string)
  "Split a comma-separated property-type list into keywords, e.g.
\"house,multi-family\" -> (:HOUSE :MULTI-FAMILY)."
  (mapcar (lambda (s) (intern (string-upcase (string-trim " " s)) :keyword))
          (remove "" (uiop:split-string string :separator ",")
                  :test #'string=)))

;;; Numeric fields --sort can order by; some have short aliases.
(defparameter *sort-keys*
  (list (cons "price"          #'redfin:listing-price)
        (cons "beds"           #'redfin:listing-beds)
        (cons "baths"          #'redfin:listing-baths)
        (cons "sqft"           #'redfin:listing-sqft)
        (cons "lot-size"       #'redfin:listing-lot-size)
        (cons "year-built"     #'redfin:listing-year-built)
        (cons "year"           #'redfin:listing-year-built)
        (cons "days-on-market" #'redfin:listing-days-on-market)
        (cons "dom"            #'redfin:listing-days-on-market)
        (cons "price-per-sqft" #'redfin:listing-price-per-sqft)
        (cons "ppsf"           #'redfin:listing-price-per-sqft)
        (cons "hoa"            #'redfin:listing-hoa)))

(defparameter +sort-field-help+
  ;; A plain string (spliced via ~a into error text), so no ~ directives here.
  "price, beds, baths, sqft, lot-size, year-built (year), days-on-market (dom), price-per-sqft (ppsf), hoa")

(defun parse-sort (opt value)
  "Parse a --sort spec like \"price\" or \"price:desc\" into
(values ACCESSOR DESCP). Direction defaults to ascending."
  (let* ((colon (position #\: value))
         (field (string-downcase (if colon (subseq value 0 colon) value)))
         (dir (and colon (string-downcase (subseq value (1+ colon)))))
         (accessor (cdr (assoc field *sort-keys* :test #'string=))))
    (unless accessor
      (error 'redfin:redfin-error
             :message (format nil "Unknown ~a field ~s (want one of: ~a)"
                              opt field +sort-field-help+)))
    (values accessor
            (cond ((or (null dir) (string= dir "asc")) nil)
                  ((string= dir "desc") t)
                  (t (error 'redfin:redfin-error
                            :message (format nil "~a direction must be asc or desc, got ~s"
                                             opt dir)))))))

(defun sort-listings (listings accessor descp)
  "Return LISTINGS sorted by ACCESSOR (ascending, or descending when DESCP).
Listings with a NIL value for the field always sort last."
  (let ((cmp (if descp #'> #'<)))
    (stable-sort (copy-list listings)
                 (lambda (a b)
                   (let ((x (funcall accessor a))
                         (y (funcall accessor b)))
                     (cond ((and x y) (funcall cmp x y))
                           (x t)        ; present sorts before missing
                           (t nil)))))))

(defun parse-args (args)
  "Parse ARGS (a list of strings) into (values SEARCH-PLIST FORMAT LIMIT SORT).
SEARCH-PLIST is passed straight to REDFIN:SEARCH-LISTINGS. FORMAT is :table
or :csv. LIMIT is NIL or a positive integer. SORT is NIL or a
(ACCESSOR . DESCP) cons. Signals REDFIN-ERROR on bad input; prints usage and
exits for --help."
  (let ((search '())
        (format :table)
        (limit nil)
        (sort nil))
    (loop while args
          for arg = (pop args)
          do (cond
               ((or (string= arg "--help") (string= arg "-h"))
                (print-usage)
                (uiop:quit 0))
               ((string= arg "--tile")
                (setf search (list* :tile-when-capped t search)))
               ((string= arg "--format")
                (let ((v (require-value arg (pop args))))
                  (setf format
                        (cond ((string-equal v "table") :table)
                              ((string-equal v "csv") :csv)
                              (t (error 'redfin:redfin-error
                                        :message (format nil "Unknown --format ~s (want table or csv)" v)))))))
               ((string= arg "--limit")
                (let ((n (parse-int arg (require-value arg (pop args)))))
                  (when (minusp n)
                    (error 'redfin:redfin-error :message "--limit must be >= 0"))
                  (setf limit n)))
               ((string= arg "--sort")
                (multiple-value-bind (accessor descp)
                    (parse-sort arg (require-value arg (pop args)))
                  (setf sort (cons accessor descp))))
               (t
                (let ((spec (assoc arg *options* :test #'string=)))
                  (unless spec
                    (error 'redfin:redfin-error
                           :message (format nil "Unknown option ~a (try --help)" arg)))
                  (destructuring-bind (flag key type) spec
                    (let* ((raw (require-value flag (pop args)))
                           (val (ecase type
                                  (:string raw)
                                  (:int (parse-int flag raw))
                                  (:keywords (parse-keyword-list raw)))))
                      (setf search (list* key val search))))))))
    (values search format limit sort)))

;;; ---------------------------------------------------------------------------
;;; Output
;;; ---------------------------------------------------------------------------

(defun fmt-price (p)
  (if p (format nil "$~:d" (round p)) ""))

(defun truncate-str (s n)
  (if (> (length s) n)
      (concatenate 'string (subseq s 0 (1- n)) "…")
      s))

(defun cell (x)
  "Render a listing slot for display: NIL as empty, integers as-is, and
floats without CL's exponent noise (2.5d0 -> \"2.5\", 2.0d0 -> \"2\")."
  (cond ((null x) "")
        ((integerp x) (princ-to-string x))
        ((floatp x)
         (let ((s (format nil "~f" x)))
           (if (and (>= (length s) 2)
                    (string= s ".0" :start1 (- (length s) 2)))
               (subseq s 0 (- (length s) 2))
               s)))
        (t (princ-to-string x))))

(defun print-table (listings)
  (let ((fmt "~13@a  ~4@a  ~5@a  ~7@a  ~28a  ~16a  ~a~%"))
    (format t fmt "PRICE" "BEDS" "BATHS" "SQFT" "ADDRESS" "CITY" "URL")
    (dolist (l listings)
      (format t fmt
              (fmt-price (redfin:listing-price l))
              (cell (redfin:listing-beds l))
              (cell (redfin:listing-baths l))
              (cell (redfin:listing-sqft l))
              (truncate-str (cell (redfin:listing-address l)) 28)
              (cell (redfin:listing-city l))
              (cell (redfin:listing-url l))))))

(defun csv-field (x)
  "Render X as a CSV field, quoting when it contains a comma, quote, or newline."
  (let ((s (cell x)))
    (if (or (find #\, s) (find #\" s) (find #\Newline s))
        (with-output-to-string (o)
          (write-char #\" o)
          (loop for c across s
                do (when (char= c #\") (write-char #\" o))
                   (write-char c o))
          (write-char #\" o))
        s)))

(defun print-csv (listings)
  (format t "~&price,beds,baths,sqft,address,city,state,zip,year_built,~
             days_on_market,hoa,mls,url~%")
  (dolist (l listings)
    (format t "~{~a~^,~}~%"
            (mapcar #'csv-field
                    (list (redfin:listing-price l)
                          (redfin:listing-beds l)
                          (redfin:listing-baths l)
                          (redfin:listing-sqft l)
                          (redfin:listing-address l)
                          (redfin:listing-city l)
                          (redfin:listing-state l)
                          (redfin:listing-zip l)
                          (redfin:listing-year-built l)
                          (redfin:listing-days-on-market l)
                          (redfin:listing-hoa l)
                          (redfin:listing-mls l)
                          (redfin:listing-url l))))))

(defun print-usage ()
  (format t "~
Usage: redfin (--location LOC | --region-id ID [--region-type N]) [filters] [output]

A Common Lisp client for Redfin's internal gis-csv endpoint. Prints active
for-sale listings for a region. Low-volume, personal use only.

Location (one required):
  --location TEXT        free-text place, e.g. \"Austin, TX\" or a zip code
  --region-id ID         explicit Redfin region id (e.g. 30818 for Austin)
  --region-type N        region_type for --region-id (default 6 = city;
                         2 = zip, 5 = county)

Filters:
  --min-price N          --max-price N
  --min-beds N           --max-beds N
  --min-baths N
  --min-sqft N           --max-sqft N
  --min-year-built N     --max-year-built N
  --max-hoa N
  --min-stories N
  --status N             1 = active (default), 9 = active + coming soon
  --property-types LIST  comma-separated: house,condo,townhouse,multi-family,
                         land,other,manufactured,co-op
  --tile                 split the price range into bands to beat the 350-row
                         cap (needs --min-price and --max-price)
  --band-count N         number of bands when --tile is set (default 8)

Output:
  --format table|csv     default table
  --sort FIELD[:DIR]     sort by a field, DIR = asc (default) or desc; e.g.
                         --sort price:desc. Fields: price, beds, baths, sqft,
                         lot-size, year-built (year), days-on-market (dom),
                         price-per-sqft (ppsf), hoa. Applied before --limit,
                         so it doubles as a top-N. Missing values sort last.
  --limit N              show at most N listings
  -h, --help             show this help

Example:
  redfin --location \"Austin, TX\" --min-price 500000 --max-price 760000 \\
         --min-beds 3 --min-baths 2 --property-types house,condo,townhouse \\
         --sort price:desc --limit 20
"))

;;; ---------------------------------------------------------------------------
;;; Entry points
;;; ---------------------------------------------------------------------------

(defun main (args)
  "Run the CLI over ARGS (command-line arguments, program name excluded).
Performs network requests to redfin.com."
  (multiple-value-bind (search format limit sort) (parse-args args)
    (unless (or (getf search :location) (getf search :region-id))
      (error 'redfin:redfin-error
             :message "Provide --location or --region-id (try --help)"))
    (let ((listings (apply #'redfin:search-listings search)))
      (when sort
        (setf listings (sort-listings listings (car sort) (cdr sort))))
      (when (and limit (> (length listings) limit))
        (setf listings (subseq listings 0 limit)))
      (ecase format
        (:table (print-table listings))
        (:csv (print-csv listings)))
      (format *error-output* "~&~d listing~:p~%" (length listings)))))

(defun first-line (string)
  "The first line of STRING, so error reports don't dump multi-line HTML
bodies (e.g. a CloudFront 403 page) to the terminal."
  (let ((nl (position #\Newline string)))
    (if nl (subseq string 0 nl) string)))

(defun toplevel ()
  "Executable entry point: parse args, run, and exit with a status code.
Errors are reported to stderr instead of dropping into the debugger."
  (handler-case
      (progn
        (main (uiop:command-line-arguments))
        (uiop:quit 0))
    (error (e)
      (format *error-output* "~&redfin: ~a~%" (first-line (princ-to-string e)))
      (uiop:quit 1))))
