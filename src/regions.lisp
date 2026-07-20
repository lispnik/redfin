;;;; regions.lisp --- resolve a place name to a Redfin region id/type

(in-package #:redfin)

(define-condition redfin-error (error)
  ((message :initarg :message :reader redfin-error-message :initform nil)
   (code    :initarg :code    :reader redfin-error-code    :initform nil))
  (:report (lambda (c stream)
             (format stream "Redfin error~@[ ~a~]~@[: ~a~]"
                     (redfin-error-code c)
                     (redfin-error-message c)))))

(defparameter +user-agent+
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ~
   (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
  "Redfin rejects default library user-agents; send a browser-like one.")

(defparameter +autocomplete-url+
  "https://www.redfin.com/stingray/do/location-autocomplete")

;;; Redfin path segment -> stingray region_type code.
(defparameter *region-type-codes*
  '(("address"      . 1)
    ("neighborhood" . 1)
    ("zipcode"      . 2)
    ("street"       . 3)
    ("county"       . 5)
    ("city"         . 6)
    ("school"       . 7)
    ("schooldistrict" . 8)
    ("state"        . 4))
  "Maps the first segment of a Redfin region URL to region_type. Note that
neighborhood and city share the /city/ vs /neighborhood/ prefixes; we key
off the actual leading path segment returned by autocomplete.")

(defstruct (region (:constructor %make-region))
  (id nil :type (or null string))
  (type nil :type (or null integer))
  (name nil :type (or null string))
  (url nil :type (or null string)))

(defun strip-guard (body)
  "Redfin prefixes JSON payloads with {}&& as an anti-hijacking guard.
Remove it if present so the remainder can be parsed as JSON."
  (let ((prefix "{}&&"))
    (if (and (>= (length body) (length prefix))
             (string= body prefix :end1 (length prefix)))
        (subseq body (length prefix))
        body)))

(defun http-get (url &key parameters)
  "GET URL (with optional query PARAMETERS) using a browser user-agent and
return the response body as a string. Signals REDFIN-ERROR on a non-2xx
status. Identical requests are served from / stored in the on-disk cache (see
cache.lisp) unless *CACHE-ENABLED* is NIL; only successful bodies are cached."
  (let ((full (quri:render-uri
               (if parameters
                   (quri:make-uri :defaults url :query parameters)
                   (quri:uri url)))))
    (or (cache-get full)
        (multiple-value-bind (body status)
            (dex:get full
                     :headers `(("User-Agent" . ,+user-agent+))
                     :force-string t)
          (unless (<= 200 status 299)
            (error 'redfin-error :code status
                                 :message (format nil "HTTP ~a for ~a" status url)))
          (cache-put full body)))))

(defun region-type-from-url (url)
  "Given a Redfin region path like \"/city/30818/TX/Austin\", return the
region_type code by looking at the leading path segment."
  (let* ((trimmed (string-left-trim "/" url))
         (slash (position #\/ trimmed))
         (segment (string-downcase (subseq trimmed 0 slash))))
    (or (cdr (assoc segment *region-type-codes* :test #'string=))
        (error 'redfin-error
               :message (format nil "Unknown region segment ~s in ~s"
                                segment url)))))

(defun region-id-from-url (url)
  "Extract the numeric region id from a Redfin region path. The id is the
second path segment, e.g. \"/city/30818/TX/Austin\" -> \"30818\"."
  (let* ((parts (remove "" (uiop:split-string url :separator "/")
                        :test #'string=)))
    (or (second parts)
        (error 'redfin-error
               :message (format nil "No region id in ~s" url)))))

(defun resolve-region (location)
  "Resolve a free-text LOCATION (e.g. \"Austin, TX\" or a zip) to a REGION.
Uses Redfin's location-autocomplete endpoint and parses the exact-match URL.

This performs a network request to redfin.com and is subject to Redfin's
terms of service; keep usage low-volume and personal."
  (let* ((raw (http-get +autocomplete-url+
                        :parameters `(("location" . ,location)
                                      ("v" . "2"))))
         (json (yason:parse (strip-guard raw)))
         (payload (gethash "payload" json))
         (exact (and payload (gethash "exactMatch" payload))))
    (unless exact
      ;; fall back to the first section's first row if no exactMatch
      (let ((sections (and payload (gethash "sections" payload))))
        (when (and sections (plusp (length sections)))
          (let ((rows (gethash "rows" (elt sections 0))))
            (when (and rows (plusp (length rows)))
              (setf exact (elt rows 0)))))))
    (unless exact
      (error 'redfin-error
             :message (format nil "No region match for ~s" location)))
    (let ((url (gethash "url" exact))
          (name (gethash "name" exact)))
      (%make-region :id (region-id-from-url url)
                    :type (region-type-from-url url)
                    :name name
                    :url url))))
