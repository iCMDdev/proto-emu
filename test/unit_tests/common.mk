# Common cocotb configuration for unit tests

SIM ?= icarus
TOPLEVEL_LANG ?= verilog
FST ?= -fst

TOPLEVEL = $(DUT)
COCOTB_TEST_MODULES = test

SIM_BUILD = sim_build

COMPILE_ARGS += -I$(CURDIR)/../../../src

include $(shell cocotb-config --makefiles)/Makefile.sim