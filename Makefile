EMACS ?= emacs
VUI ?= $(HOME)/.emacs.d/straight/build/vui

BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' -L . -L test -L $(VUI)
SOURCES = deathless-store.el deathless.el

# checkdoc only warns; fail when it did.
CHECKDOC = '(progn (dolist (f command-line-args-left) (checkdoc-file f)) (kill-emacs (if (get-buffer "*Warnings*") 1 0)))'

.PHONY: test lint clean

test:
	$(BATCH) -l test/deathless-test.el -f ert-run-tests-batch-and-exit

lint:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SOURCES)
	$(BATCH) --eval $(CHECKDOC) $(SOURCES)
	rm -f *.elc

clean:
	rm -f *.elc test/*.elc
