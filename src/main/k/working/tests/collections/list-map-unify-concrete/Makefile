include $(CURDIR)/../../../include.mk

KOMPILED := list-map-unify-concrete-kompiled
DEFINITION := $(KOMPILED)/definition.kore

$(DEFINITION): list-map-unify-concrete.k
	$(KOMPILE) $(KOMPILE_OPTS) $< --syntax-module list-map-unify-concrete

%.output: %.list-map-unify-concrete $(DEFINITION) $(KORE_EXEC)
	$(KRUN) $(KRUN_OPTS) $< --output-file $@

%.krun: %.list-map-unify-concrete $(DEFINITION) $(KORE_EXEC)
	$(KRUN) $(KRUN_OPTS) $<

%.test: %.output
	diff -u $<.golden $<

%.output.golden: %.output
	mv $< $<.golden

test: tests/1.test tests/2.test tests/3.test

test-k: tests/1.test tests/2.test tests/3.test

golden: tests/1.output.golden tests/2.output.golden tests/3.output.golden

clean:
	rm -rf $(KOMPILED) tests/*.output

.PHONY: test-k test golden clean %.test %.krun
