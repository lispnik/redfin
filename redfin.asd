;;;; redfin.asd

(asdf:defsystem #:redfin
  :description "Fetch for-sale listings from Redfin's stingray gis-csv endpoint."
  :author "Matthew"
  :license "MIT"
  :version "0.1.0"
  :serial t
  :depends-on (#:dexador
               #:quri
               #:cl-csv
               #:yason
               #:alexandria)
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "cache")
                             (:file "regions")
                             (:file "listings"))))
  :in-order-to ((test-op (test-op #:redfin/tests))))

(asdf:defsystem #:redfin/cli
  :description "Standalone command-line interface for the redfin client."
  :author "Matthew"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:redfin)
  :serial t
  :components ((:module "src"
                :components ((:file "cli"))))
  ;; `asdf:make :redfin/cli` builds a standalone executable at bin/redfin.
  :build-operation "program-op"
  :build-pathname "bin/redfin"
  :entry-point "redfin/cli:toplevel")

(asdf:defsystem #:redfin/tests
  :description "FiveAM test suite for REDFIN."
  :depends-on (#:redfin
               #:redfin/cli
               #:fiveam)
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "main"))))
  :perform (asdf:test-op (op c)
             (uiop:symbol-call :fiveam :run!
                               (uiop:find-symbol* :redfin :redfin/tests))))
