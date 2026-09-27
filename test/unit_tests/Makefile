# Search all subfolders - each should be a unit test
TEST_DIRS := $(patsubst %/,%,$(dir $(wildcard */Makefile)))

.PHONY: all clean $(TEST_DIRS)

all: $(TEST_DIRS)

$(TEST_DIRS):
	$(MAKE) -C $@

clean:
	@for dir in $(TEST_DIRS); do \
		$(MAKE) -C $$dir clean; \
	done