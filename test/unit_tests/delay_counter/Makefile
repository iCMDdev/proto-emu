DUT = delay_counter

WIDTH ?= 9
WIDTHS ?= 4 8 9 16 

VERILOG_SOURCES = \
	$(CURDIR)/../../../src/delay_counter.v

COMPILE_ARGS += -P$(DUT).WIDTH=$(WIDTH)

SIM_BUILD = sim_build/width_$(WIDTH)

include ../common.mk

.PHONY: widths

all: widths

widths:
	@for width in $(WIDTHS); do \
		echo "=== Testing WIDTH=$$width ==="; \
		$(MAKE) WIDTH=$$width sim || exit $$?; \
	done

clean::
	rm -rf sim_build
	rm -f results.xml
