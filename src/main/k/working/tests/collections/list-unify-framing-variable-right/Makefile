include $(CURDIR)/../../../include.mk

KOMPILED := list-unify-framing-variable-right-kompiled
DEFINITION := $(KOMPILED)/definition.kore

$(DEFINITION): list-unify-framing-variable-right.k
	$(KOMPILE) $(KOMPILE_OPTS) $< --syntax-module LIST-UNIFY-FRAMING-VARIABLE-RIGHT

%.output: %.list-unify-framing-variable-right $(DEFINITION) $(KORE_EXEC)
	$(KRUN) $(KRUN_OPTS) $< --output-file $@

%.krun: %.list-unify-framing-variable-right $(DEFINITION) $(KORE_EXEC)
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
