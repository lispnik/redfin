;;;; cache.lisp --- optional on-disk cache for GET responses
;;;;
;;;; HTTP-GET (in regions.lisp) serves and stores identical requests here so
;;;; repeated, byte-for-byte-identical queries don't re-hit the rate-limited
;;;; stingray endpoint. Keyed on the fully-rendered request URL; entries expire
;;;; after *CACHE-TTL* seconds. Dependency-free (no external hashing lib).

(in-package #:redfin)

(defparameter *cache-enabled* t
  "When true, HTTP-GET reads/writes an on-disk cache instead of always hitting
the network. Bind to NIL (or pass the CLI's --no-cache) to bypass.")

(defparameter *cache-ttl* 3600
  "Seconds a cached response stays fresh; older entries are re-fetched.")

(defparameter *cache-directory* nil
  "Directory holding cached bodies. NIL means use the XDG cache dir, resolved
at runtime by CACHE-DIR (so a dumped binary honors the running user's HOME).")

(defun cache-dir ()
  "The directory cached responses live in."
  (or *cache-directory* (uiop:xdg-cache-home "redfin/")))

(defun cache-key (string)
  "A stable 16-hex-char FNV-1a (64-bit) hash of STRING, used as a cache
filename. Deterministic across runs and implementations, and dependency-free."
  (let ((hash 14695981039346656037))          ; FNV-1a 64-bit offset basis
    (loop for ch across string
          for byte = (logand (char-code ch) #xff)
          do (setf hash (logand (* (logxor hash byte) 1099511628211)
                                #xffffffffffffffff)))
    (format nil "~(~16,'0x~)" hash)))

(defun cache-path (url)
  (merge-pathnames (concatenate 'string (cache-key url) ".cache")
                   (cache-dir)))

(defun cache-fresh-p (path)
  "True if PATH exists and is younger than *CACHE-TTL* seconds."
  (and (probe-file path)
       (<= (- (get-universal-time) (file-write-date path)) *cache-ttl*)))

(defun cache-get (url)
  "Return the cached body for URL if caching is on and the entry is fresh,
else NIL."
  (when *cache-enabled*
    (let ((path (cache-path url)))
      (when (cache-fresh-p path)
        (ignore-errors (uiop:read-file-string path))))))

(defun cache-put (url body)
  "Store BODY as the cached response for URL (when caching is on). Writes to a
temp file and renames, so a reader never sees a half-written entry. Returns
BODY so callers can `(cache-put url (fetch ...))`."
  (when *cache-enabled*
    (let* ((path (cache-path url))
           (tmp (make-pathname :type "tmp" :defaults path)))
      (ignore-errors
        (ensure-directories-exist path)
        (with-open-file (out tmp :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create
                                 :external-format :utf-8)
          (write-string body out))
        (rename-file tmp path))))
  body)

(defun clear-cache ()
  "Delete every cached response file. Returns the number removed."
  (let ((count 0))
    (dolist (f (ignore-errors (uiop:directory-files (cache-dir) "*.cache")))
      (when (ignore-errors (delete-file f)) (incf count)))
    count))
