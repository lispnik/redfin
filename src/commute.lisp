;;;; commute.lisp --- weekday commute-time estimates via the Mapbox APIs
;;;;
;;;; Geocode a destination (Mapbox Geocoding v6), then sample the driving-
;;;; traffic Directions API at several weekday departure times and report the
;;;; mean and standard deviation of the predicted trip. All HTTP goes through
;;;; HTTP-GET, so results share the on-disk response cache. The pure pieces
;;;; (label simplification, JSON parsing, weekday math, mean/stddev) are split
;;;; out so they can be unit-tested offline.

(in-package #:redfin)

(defparameter *mapbox-base* "https://api.mapbox.com")

(defparameter *mapbox-token* nil
  "Mapbox access token. NIL means read MAPBOX_TOKEN / MAPBOX_ACCESS_TOKEN from
the environment at runtime (see MAPBOX-TOKEN).")

(defparameter *commute-sample-times*
  '("07:00" "07:30" "08:00" "08:30" "09:00")
  "Weekday departure times (origin-local, HH:MM) sampled to build the commute
distribution; the mean and stddev are computed over these departures.")

(defun mapbox-token ()
  "The Mapbox access token, from *MAPBOX-TOKEN* or the environment. Signals
REDFIN-ERROR if none is configured."
  (or *mapbox-token*
      (uiop:getenv "MAPBOX_TOKEN")
      (uiop:getenv "MAPBOX_ACCESS_TOKEN")
      (error 'redfin-error
             :message "No Mapbox token; set MAPBOX_TOKEN (or bind *mapbox-token*)")))

;;; ---------------------------------------------------------------------------
;;; Destinations (geocoding)
;;; ---------------------------------------------------------------------------

(defstruct (commute-target (:constructor %make-commute-target))
  (label nil :type (or null string))
  (lon nil :type (or null real))
  (lat nil :type (or null real)))

(defun simplify-commute-label (location)
  "A short column label for a commute destination: LOCATION's first comma-
separated segment, trimmed. Falls back to LOCATION if that is empty."
  (let* ((segment (first (uiop:split-string location :separator ",")))
         (trimmed (string-trim '(#\Space #\Tab) (or segment ""))))
    (if (plusp (length trimmed)) trimmed location)))

(defun parse-geocode (body)
  "Extract (values LON LAT) from a Mapbox v6 forward-geocode response BODY, or
NIL if there is no usable feature."
  (let* ((json (parse-json body))
         (features (jget json "features")))
    (when (and features (plusp (length features)))
      (let ((coords (jget (jget (elt features 0) "geometry") "coordinates")))
        (when (and coords (>= (length coords) 2))
          (values (elt coords 0) (elt coords 1)))))))

(defun resolve-commute-target (location)
  "Geocode LOCATION via Mapbox and return a COMMUTE-TARGET (short label +
lon/lat). Signals REDFIN-ERROR if the token is missing or nothing matches."
  (let* ((token (mapbox-token))
         (body (handler-case
                   (http-get (concatenate 'string *mapbox-base*
                                          "/search/geocode/v6/forward")
                             :parameters `(("q" . ,location)
                                           ("limit" . "1")
                                           ("access_token" . ,token)))
                 (redfin-error (e) (error e))
                 (error (e)
                   (error 'redfin-error
                          :message (format nil "Mapbox geocoding failed for ~s: ~a"
                                           location e))))))
    (multiple-value-bind (lon lat) (parse-geocode body)
      (unless lat
        (error 'redfin-error
               :message (format nil "No geocoding match for ~s" location)))
      (%make-commute-target :label (simplify-commute-label location)
                            :lon lon :lat lat))))

;;; ---------------------------------------------------------------------------
;;; Directions (per-departure duration)
;;; ---------------------------------------------------------------------------

(defun coord (x)
  "Format a coordinate as a plain decimal (no CL float exponent) for a URL."
  (format nil "~f" x))

(defun directions-url (o-lon o-lat d-lon d-lat)
  (format nil "~a/directions/v5/mapbox/driving-traffic/~a,~a;~a,~a"
          *mapbox-base* (coord o-lon) (coord o-lat) (coord d-lon) (coord d-lat)))

(defun parse-duration (body)
  "Route duration in seconds from a Mapbox Directions response BODY, or NIL if
the response has no usable route."
  (let ((json (ignore-errors (parse-json body))))
    (when (and (hash-table-p json)
               (equal "Ok" (jget json "code")))
      (let ((routes (jget json "routes")))
        (when (and routes (plusp (length routes)))
          (jget (elt routes 0) "duration"))))))

(defun mapbox-duration (token o-lon o-lat d-lon d-lat depart-iso)
  "Predicted driving duration in seconds for one DEPART-ISO departure, or NIL
if the request or route fails (so one bad sample doesn't sink the estimate)."
  (handler-case
      (parse-duration
       (http-get (directions-url o-lon o-lat d-lon d-lat)
                 :parameters `(("access_token" . ,token)
                               ("depart_at" . ,depart-iso)
                               ("overview" . "false"))))
    (error () nil)))

;;; ---------------------------------------------------------------------------
;;; Weekday departure sampling + statistics
;;; ---------------------------------------------------------------------------

(defun next-weekday-date (&optional (now (get-universal-time)))
  "Return (values YEAR MONTH DAY) of the next weekday strictly after NOW's
date, so generated depart-at timestamps are always in the future."
  (loop for u = (+ now 86400) then (+ u 86400)
        do (multiple-value-bind (s mi h d mo y dow) (decode-universal-time u)
             (declare (ignore s mi h))
             (when (<= dow 4)              ; 0 = Monday .. 6 = Sunday
               (return (values y mo d))))))

(defun weekday-departures (&optional (now (get-universal-time))
                                     (times *commute-sample-times*))
  "ISO-8601 depart-at strings (no UTC offset, so Mapbox reads them as origin-
local) for the next weekday at each of TIMES."
  (multiple-value-bind (y mo d) (next-weekday-date now)
    (mapcar (lambda (hhmm)
              (format nil "~4,'0d-~2,'0d-~2,'0dT~a" y mo d hhmm))
            times)))

(defun mean-stddev (samples)
  "Return (values MEAN STDDEV N) over the real list SAMPLES using the sample
standard deviation (n-1). MEAN/STDDEV are NIL for empty input; STDDEV is 0 for
a single sample."
  (let ((n (length samples)))
    (if (zerop n)
        (values nil nil 0)
        (let ((mean (/ (reduce #'+ samples) n)))
          (values mean
                  (if (> n 1)
                      (sqrt (/ (reduce #'+ samples
                                       :key (lambda (x) (expt (- x mean) 2)))
                               (1- n)))
                      0)
                  n)))))

(defun listing-commute (listing target &key (departures (weekday-departures)))
  "Weekday commute time from LISTING to TARGET, in MINUTES. Samples the Mapbox
driving-traffic Directions API over DEPARTURES and returns (values MEAN-MIN
STDDEV-MIN N-SAMPLES). MEAN/STDDEV are NIL when LISTING has no coordinates or
every sample failed."
  (let ((olat (listing-latitude listing))
        (olon (listing-longitude listing)))
    (if (and (realp olat) (realp olon))
        (let* ((token (mapbox-token))
               (seconds (loop for dep in departures
                              for s = (mapbox-duration token olon olat
                                                       (commute-target-lon target)
                                                       (commute-target-lat target)
                                                       dep)
                              when s collect s)))
          (multiple-value-bind (mean sd n) (mean-stddev seconds)
            (values (and mean (/ mean 60d0))
                    (and sd (/ sd 60d0))
                    n)))
        (values nil nil 0))))
