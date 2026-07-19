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
                             (:file "regions")
                             (:file "listings"))))
  :in-order-to ((test-op (test-op #:redfin/tests))))

(asdf:defsystem #:redfin/tests
  :description "FiveAM test suite for REDFIN."
  :depends-on (#:redfin
               #:fiveam)
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "main"))))
  :perform (asdf:test-op (op c)
             (uiop:symbol-call :fiveam :run!
                               (uiop:find-symbol* :redfin :redfin/tests))))
