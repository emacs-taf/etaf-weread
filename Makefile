.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L tests -L ../../etaf -L ../../etaf-ui -L ../../etaf-db -L ../../ebox -L ../../ecss
SOURCES = lisp/etaf-weread-theme.el lisp/etaf-weread-service.el lisp/etaf-weread-index.el
SOURCES += lisp/etaf-weread-library.el
SOURCES += lisp/etaf-weread-model.el lisp/etaf-weread-views.el lisp/etaf-weread-app.el etaf-weread.el
SOURCES += $(wildcard examples/*.el)
SOURCES += scripts/weread-gui-probe.el
SOURCES += scripts/weread-gui-acceptance.el

.PHONY: compile load check clean structure-check setup-hooks acceptance api-check test
compile:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
load: compile
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(require (quote etaf-weread))' --eval '(princ "etaf-weread load OK\n")'
check: structure-check compile acceptance api-check
structure-check:
	python3 scripts/check-repository.py
setup-hooks:
	git config --local core.hooksPath .githooks
acceptance:
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"
api-check:
	$(EMACS) -Q --batch -L . $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
clean:
	rm -f *.elc lisp/*.elc tests/*.elc examples/*.elc

test: acceptance
