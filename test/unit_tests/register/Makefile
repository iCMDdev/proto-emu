DUT = register

WIDTH ?= 9
WIDTHS ?= 2 4 8 9 16 32 64 128

VERILOG_SOURCES = \
	$(CURDIR)/../../../src/register.v

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
