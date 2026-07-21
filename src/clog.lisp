;;;; clog.lisp --- a CLOG (browser) GUI over the core redfin library
;;;;
;;;; Separate system (:redfin/clog, depends on :redfin + :clog) so the core
;;;; library stays GUI-free. Presents a search form and a results table; uses
;;;; only the exported redfin API (search-listings, the listing accessors, and
;;;; the Mapbox commute helpers). Start it with (redfin/clog:start).

(defpackage #:redfin/clog
  (:use #:cl)
  (:export #:start #:stop))

(in-package #:redfin/clog)

;;; ---------------------------------------------------------------------------
;;; Small helpers (no READ on user input)
;;; ---------------------------------------------------------------------------

(defun blankp (s) (or (null s) (zerop (length (string-trim '(#\Space #\Tab) s)))))

(defun field-int (s)
  "Parse a non-negative-ish integer from form text, or NIL when blank/invalid."
  (let ((s (string-trim '(#\Space #\Tab) (or s ""))))
    (when (plusp (length s))
      (ignore-errors (parse-integer s :junk-allowed nil)))))

(defun field-string (s)
  (let ((s (string-trim '(#\Space #\Tab) (or s "")))) (unless (blankp s) s)))

(defun comma-list (s)
  "Split comma-separated form text into a list of trimmed non-empty strings."
  (remove-if #'blankp
             (mapcar (lambda (x) (string-trim '(#\Space #\Tab) x))
                     (uiop:split-string (or s "") :separator ","))))

(defun semi-list (s)
  "Split a SEMICOLON-separated field into trimmed non-empty strings. Commute
destinations are separated by ';' (not ',') because an address itself
contains commas (e.g. \"Downtown Austin, TX\")."
  (remove-if #'blankp
             (mapcar (lambda (x) (string-trim '(#\Space #\Tab) x))
                     (uiop:split-string (or s "") :separator ";"))))

(defun keyword-list (s)
  (mapcar (lambda (x) (intern (string-upcase x) :keyword)) (comma-list s)))

(defun fmt-price (p) (if p (format nil "$~:d" (round p)) ""))

(defun fmt-num (x)
  "Integers as-is; floats without CL exponent noise (2.5d0 -> 2.5, 2.0d0 -> 2)."
  (cond ((null x) "")
        ((integerp x) (princ-to-string x))
        ((floatp x)
         (let ((s (format nil "~f" x)))
           (if (and (>= (length s) 2) (string= s ".0" :start1 (- (length s) 2)))
               (subseq s 0 (- (length s) 2))
               s)))
        (t (princ-to-string x))))

(defun fmt-commute (cell) (if cell (format nil "~d±~d" (car cell) (cdr cell)) "-"))

(defun html-escape (s)
  (with-output-to-string (o)
    (loop for c across (or s "")
          do (case c
               (#\& (write-string "&amp;" o))
               (#\< (write-string "&lt;" o))
               (#\> (write-string "&gt;" o))
               (#\" (write-string "&quot;" o))
               (t (write-char c o))))))

(defun js-escape (s)
  "Escape S for embedding inside a JS double-quoted string literal."
  (with-output-to-string (o)
    (loop for c across (or s "")
          do (case c
               (#\\ (write-string "\\\\" o))
               (#\" (write-string "\\\"" o))
               (#\Newline (write-string "\\n" o))
               (#\Return nil)
               (t (write-char c o))))))

;;; ---------------------------------------------------------------------------
;;; Mapbox map (client-side; the token is used only in the browser, as Mapbox
;;; GL JS requires, and is read from the server's environment -- never stored
;;; in source).
;;; ---------------------------------------------------------------------------

(defparameter *mapbox-gl-version* "v3.9.3")

(defun map-token ()
  (or redfin:*mapbox-token*
      (uiop:getenv "MAPBOX_TOKEN")
      (uiop:getenv "MAPBOX_ACCESS_TOKEN")))

(defun coord-str (x) (format nil "~f" x))

(defun pin-label (l)
  "Popup HTML for a listing marker."
  (let ((city (redfin:listing-city l)))
    (format nil "<b>~a</b><br>~a~@[, ~a~]"
            (html-escape (fmt-price (redfin:listing-price l)))
            (html-escape (or (redfin:listing-address l) ""))
            (and city (html-escape city)))))

(defun pins-json (listings)
  "A JSON array of {i,lon,lat,label} for listings that have coordinates. `i`
is the listing's row index, so a pin can highlight its table row."
  (format nil "[~{~a~^,~}]"
          (loop for l in listings
                for i from 0
                for lat = (redfin:listing-latitude l)
                for lon = (redfin:listing-longitude l)
                when (and (realp lat) (realp lon))
                  collect (format nil "{\"i\":~a,\"lon\":~a,\"lat\":~a,\"label\":\"~a\"}"
                                  i (coord-str lon) (coord-str lat)
                                  (js-escape (pin-label l))))))

(defun map-init-js (token)
  "Browser JS: init the map and define window.redfinSetPins(pins). Polls until
mapboxgl and the container are ready, so it is robust to script load order."
  (format nil "(function init(){
if(typeof mapboxgl==='undefined'||!document.getElementById('redfin-map')){setTimeout(init,60);return;}
mapboxgl.accessToken='~a';
window.redfinMap=new mapboxgl.Map({container:'redfin-map',style:'mapbox://styles/mapbox/streets-v12',center:[-97.74,30.27],zoom:9});
window.redfinMarkers=[];
window.redfinHighlightRow=function(i){
document.querySelectorAll('[data-redfin-row]').forEach(function(r){r.style.background='';});
var row=document.querySelector('[data-redfin-row=\"'+i+'\"]');
if(row){row.style.background='#fde68a';row.scrollIntoView({behavior:'smooth',block:'center'});}
};
window.redfinSetPins=function(pins){
(window.redfinMarkers||[]).forEach(function(m){m.remove();});
window.redfinMarkers=[];
if(window.redfinHighlightRow){window.redfinHighlightRow(-1);}
if(!pins||!pins.length){return;}
var b=new mapboxgl.LngLatBounds();
pins.forEach(function(p){
var mk=new mapboxgl.Marker().setLngLat([p.lon,p.lat]).setPopup(new mapboxgl.Popup({offset:12}).setHTML(p.label)).addTo(window.redfinMap);
var el=mk.getElement();el.style.cursor='pointer';
el.addEventListener('click',function(){window.redfinHighlightRow(p.i);});
window.redfinMarkers.push(mk);b.extend([p.lon,p.lat]);
});
window.redfinMap.fitBounds(b,{padding:40,maxZoom:14,duration:0});
};
})();" token))

;;; ---------------------------------------------------------------------------
;;; Sorting (local; the library exports accessors, not a sort)
;;; ---------------------------------------------------------------------------

(defparameter *sort-options*
  ;; (label accessor descending-p)
  (list (list "Relevance (default)" nil nil)
        (list "Price (low first)"   #'redfin:listing-price nil)
        (list "Price (high first)"  #'redfin:listing-price t)
        (list "Beds (low first)"    #'redfin:listing-beds nil)
        (list "Sqft (small first)"  #'redfin:listing-sqft nil)
        (list "$/sqft (high first)" #'redfin:listing-price-per-sqft t)
        (list "Days on market"      #'redfin:listing-days-on-market nil)))

(defun sort-listings (listings accessor descp)
  "Stable-sort LISTINGS by ACCESSOR; NIL values sort last. No-op if ACCESSOR
is NIL."
  (if accessor
      (stable-sort (copy-list listings)
                   (lambda (a b)
                     (let ((x (funcall accessor a)) (y (funcall accessor b)))
                       (cond ((and x y) (funcall (if descp #'> #'<) x y))
                             (x t)
                             (t nil)))))
      listings))

;;; ---------------------------------------------------------------------------
;;; UI construction
;;; ---------------------------------------------------------------------------

(defun labeled (parent text kind &key (value "") (width "9rem"))
  "Create a labeled input row and return the input element."
  (let ((row (clog:create-div parent)))
    (setf (clog:style row "margin") "4px 0")
    (let ((lbl (clog:create-label row :content text)))
      (setf (clog:style lbl "display") "inline-block")
      (setf (clog:style lbl "width") "9rem"))
    (let ((inp (clog:create-form-element row kind)))
      (unless (blankp value) (setf (clog:value inp) value))
      (setf (clog:style inp "width") width)
      inp)))

(defun render-results (container listings commute-labels commute-cells)
  "Replace CONTAINER's contents with a results table."
  (setf (clog:inner-html container) "")
  (if (null listings)
      (clog:create-p container :content "No listings.")
      (let ((table (clog:create-table container)))
        (setf (clog:style table "border-collapse") "collapse")
        (setf (clog:style table "width") "100%")
        (setf (clog:style table "font-size") "14px")
        (let ((hr (clog:create-table-row table)))
          (dolist (h (append '("Price" "Beds" "Baths" "Sqft" "Address" "City")
                             commute-labels '("Link")))
            (let ((th (clog:create-table-heading hr :content h)))
              (setf (clog:style th "text-align") "left")
              (setf (clog:style th "padding") "4px 8px")
              (setf (clog:style th "border-bottom") "2px solid #888"))))
        (loop for l in listings
              for i from 0
              for cc in (or commute-cells (make-list (length listings)))
              do (let ((row (clog:create-table-row table)))
                   ;; index used by a map pin to highlight this row
                   (setf (clog:attribute row "data-redfin-row") (princ-to-string i))
                   (flet ((col (content)
                            (let ((td (clog:create-table-column
                                       row :content (html-escape content))))
                              (setf (clog:style td "padding") "3px 8px")
                              (setf (clog:style td "border-bottom") "1px solid #ddd")
                              td)))
                     (col (fmt-price (redfin:listing-price l)))
                     (col (fmt-num (redfin:listing-beds l)))
                     (col (fmt-num (redfin:listing-baths l)))
                     (col (fmt-num (redfin:listing-sqft l)))
                     (col (or (redfin:listing-address l) ""))
                     (col (or (redfin:listing-city l) ""))
                     (loop for m in cc do (col (fmt-commute m)))
                     (let ((td (col "")))
                       (when (redfin:listing-url l)
                         (setf (clog:inner-html td)
                               (format nil "<a href=\"~a\" target=\"_blank\">view</a>"
                                       (html-escape (redfin:listing-url l))))))))))))

(defun run-search (fields status results)
  "Read FIELDS (a plist of input elements), run the search, and render into
RESULTS. Reports counts/errors into the STATUS element."
  (handler-case
      (progn
        (setf (clog:text status) "Searching…")
        (let* ((location (field-string (clog:value (getf fields :location))))
               (region-id (field-string (clog:value (getf fields :region-id))))
               (args (list)))
          (cond (location (setf args (list :location location)))
                (region-id
                 (setf args (list :region-id region-id
                                  :region-type (or (field-int
                                                    (clog:value (getf fields :region-type)))
                                                   6))))
                (t (error 'redfin:redfin-error
                          :message "Enter a location or a region id")))
          (flet ((add (key el &optional (reader #'field-int))
                   (let ((v (funcall reader (clog:value (getf fields el)))))
                     (when v (setf args (append args (list key v)))))))
            (add :min-price :min-price)
            (add :max-price :max-price)
            (add :min-beds :min-beds)
            (add :min-baths :min-baths)
            (add :min-sqft :min-sqft)
            (let ((types (keyword-list (clog:value (getf fields :property-types)))))
              (when types (setf args (append args (list :property-types types))))))
          (let* ((listings (apply #'redfin:search-listings args))
                 (sort-spec (nth (or (field-int (clog:value (getf fields :sort))) 0)
                                 *sort-options*))
                 (limit (field-int (clog:value (getf fields :limit)))))
            (when sort-spec
              (setf listings (sort-listings listings (second sort-spec) (third sort-spec))))
            (when (and limit (> (length listings) limit))
              (setf listings (subseq listings 0 limit)))
            ;; commute columns (optional; needs MAPBOX_TOKEN)
            (let* ((targets (mapcar #'redfin:resolve-commute-target
                                    (semi-list (clog:value (getf fields :commute-to)))))
                   (labels (mapcar #'redfin:commute-target-label targets))
                   (deps (when targets (redfin:weekday-departures)))
                   (cells (when targets
                            (mapcar (lambda (l)
                                      (mapcar (lambda (tg)
                                                (multiple-value-bind (mean sd)
                                                    (redfin:listing-commute
                                                     l tg :departures deps)
                                                  (when mean
                                                    (cons (round mean) (round (or sd 0))))))
                                              targets))
                                    listings))))
              (render-results results listings labels cells))
            ;; drop a pin on the map for each result (no-op if the map is off)
            (clog:js-execute results
                             (format nil "if(window.redfinSetPins){redfinSetPins(~a);}"
                                     (pins-json listings)))
            (setf (clog:text status)
                  (format nil "~d listing~:p" (length listings))))))
    (redfin:redfin-error (e)
      (setf (clog:text status) (format nil "Error: ~a" e)))
    (error (e)
      (setf (clog:text status) (format nil "Error: ~a" e)))))

(defun build-map (parent body)
  "Create the map container beside the form. If a Mapbox token is available,
load Mapbox GL JS and initialize the map; otherwise show a hint."
  (let ((token (map-token)))
    (if token
        (let ((map-div (clog:create-div parent :html-id "redfin-map"))
              (doc (clog:html-document body)))
          (setf (clog:style map-div "width") "560px")
          (setf (clog:style map-div "height") "460px")
          (setf (clog:style map-div "border") "1px solid #ccc")
          (setf (clog:style map-div "border-radius") "4px")
          (clog:load-css doc (format nil "https://api.mapbox.com/mapbox-gl-js/~a/mapbox-gl.css"
                                     *mapbox-gl-version*))
          (clog:load-script doc (format nil "https://api.mapbox.com/mapbox-gl-js/~a/mapbox-gl.js"
                                        *mapbox-gl-version*))
          (clog:js-execute body (map-init-js token)))
        (let ((note (clog:create-p parent :content
                                   "Set MAPBOX_TOKEN in the server environment to show the map.")))
          (setf (clog:style note "color") "#888")))))

(defun on-new-window (body)
  (setf (clog:title (clog:html-document body)) "Redfin")
  (let ((page (clog:create-div body)))
    (setf (clog:style page "max-width") "1200px")
    (setf (clog:style page "margin") "1rem auto")
    (setf (clog:style page "font-family") "system-ui, sans-serif")
    (let ((h (clog:create-section page :h1 :content "Redfin listings")))
      (setf (clog:style h "margin-bottom") "0.25rem"))
    (clog:create-p page :content
                   "Search active for-sale listings. Enter a location (e.g. \"Austin, TX\") or a Redfin region id. Click a map pin to highlight its row.")
    ;; Top row: search form on the left, map on the right.
    (let* ((top (clog:create-div page))
           (form (clog:create-div top))
           (fields
             (list :location      (labeled form "Location" :text :width "18rem")
                   :region-id     (labeled form "…or region id" :text)
                   :region-type   (labeled form "Region type" :text :value "6")
                   :min-price     (labeled form "Min price" :number)
                   :max-price     (labeled form "Max price" :number)
                   :min-beds      (labeled form "Min beds" :number)
                   :min-baths     (labeled form "Min baths" :number)
                   :min-sqft      (labeled form "Min sqft" :number)
                   :property-types (labeled form "Property types" :text :width "18rem")
                   :limit         (labeled form "Limit" :number :value "25")
                   :commute-to    (labeled form "Commute to" :text :width "18rem"))))
      ;; sort select
      (let* ((row (clog:create-div form))
             (lbl (clog:create-label row :content "Sort")))
        (setf (clog:style row "margin") "4px 0")
        (setf (clog:style lbl "display") "inline-block")
        (setf (clog:style lbl "width") "9rem")
        (let ((sel (clog:create-select row)))
          (loop for opt in *sort-options* for i from 0
                do (clog:create-option sel :content (first opt)
                                           :value (princ-to-string i)))
          (setf fields (append fields (list :sort sel)))))
      (clog:create-p form :content
                     "Property types: comma-separated (house, condo, townhouse, …). Commute to: semicolon-separated destinations, e.g. \"Downtown Austin, TX; The Domain, Austin, TX\" (needs MAPBOX_TOKEN).")
      (let ((btn (clog:create-button form :content "Search"))
            (status (clog:create-div form))
            (results (clog:create-div page)))
        (setf (clog:style btn "padding") "6px 16px")
        (setf (clog:style btn "margin") "8px 0")
        (setf (clog:style status "margin") "8px 0")
        (setf (clog:style status "font-weight") "bold")
        (setf (clog:style results "margin-top") "1rem")
        (setf (clog:style results "overflow-x") "auto")
        ;; lay the form and map side by side, then wire the search. The form
        ;; gets a fixed width so its help text wraps instead of stretching the
        ;; column and pushing the map off-screen.
        (setf (clog:style top "display") "flex")
        (setf (clog:style top "gap") "24px")
        (setf (clog:style top "align-items") "flex-start")
        (setf (clog:style form "flex") "0 0 30rem")
        (setf (clog:style form "max-width") "30rem")
        (build-map top body)
        (clog:set-on-click btn (lambda (obj)
                                 (declare (ignore obj))
                                 (run-search fields status results)))))))

;;; ---------------------------------------------------------------------------
;;; Server control
;;; ---------------------------------------------------------------------------

(defun start (&key (port 8080) (open nil))
  "Start the Redfin CLOG web UI on PORT. With OPEN, also launch a browser.
Returns after the server is up; call STOP to shut it down."
  (clog:initialize #'on-new-window :host "0.0.0.0" :port port)
  (when open
    (ignore-errors
     (clog:open-browser :url (format nil "http://127.0.0.1:~a/" port))))
  (format t "~&Redfin CLOG UI running at http://127.0.0.1:~a/~%" port)
  port)

(defun stop ()
  "Shut down the CLOG web server."
  (clog:shutdown))
