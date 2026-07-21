LISP ?= sbcl
LOAD = --load setup.lisp

.PHONY: deps build test test-live repl clog clean

deps:
	ocicl install

# Build the standalone CLI binary at bin/redfin via the :redfin/cli
# build-operation (program-op) defined in redfin.asd.
build:
	$(LISP) --non-interactive $(LOAD) \
	  --eval '(asdf:make :redfin/cli)' \
	  --eval '(uiop:quit 0)'

# Offline test suite. Exits non-zero if any test fails.
test:
	$(LISP) --non-interactive $(LOAD) \
	  --eval '(asdf:load-system :redfin/tests)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote redfin/tests:redfin)) 0 1))'

# Includes the live network test (hits redfin.com; needs a US IP).
test-live:
	REDFIN_LIVE_TESTS=1 $(LISP) --non-interactive $(LOAD) \
	  --eval '(asdf:load-system :redfin/tests)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote redfin/tests:redfin)) 0 1))'

# Interactive REPL with the system loaded.
repl:
	$(LISP) $(LOAD) --eval '(asdf:load-system :redfin)'

# Start the CLOG web GUI (foreground) on PORT (default 8080).
PORT ?= 8080
clog:
	$(LISP) $(LOAD) \
	  --eval '(asdf:load-system :redfin/clog)' \
	  --eval '(redfin/clog:start :port $(PORT))' \
	  --eval '(loop (sleep 3600))'

clean:
	find . -name '*.fasl' -delete
