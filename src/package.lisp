;;;; package.lisp

(defpackage #:redfin
  (:use #:cl)
  (:export
   ;; listing struct + accessors
   #:listing
   #:listing-p
   #:listing-sale-type
   #:listing-property-type
   #:listing-address
   #:listing-city
   #:listing-state
   #:listing-zip
   #:listing-price
   #:listing-beds
   #:listing-baths
   #:listing-sqft
   #:listing-lot-size
   #:listing-year-built
   #:listing-days-on-market
   #:listing-price-per-sqft
   #:listing-hoa
   #:listing-latitude
   #:listing-longitude
   #:listing-mls
   #:listing-url
   ;; query
   #:search-listings
   #:build-query-url
   #:*property-types*
   ;; regions
   #:resolve-region
   #:region
   #:region-id
   #:region-type
   #:region-name
   ;; response cache
   #:*cache-enabled*
   #:*cache-ttl*
   #:*cache-directory*
   #:cache-dir
   #:clear-cache
   ;; conditions
   #:redfin-error
   #:redfin-error-message
   #:redfin-error-code))
