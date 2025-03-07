rwildcard = $(wildcard $1) $(foreach d,$1,$(call rwildcard,$(addsuffix /$(notdir $d),$(wildcard $(dir $d)*))))

PROG = crux
SRC = src
SOURCE_FILES = $(call rwildcard,$(SRC)/*.odin)
TESTS = tests
COLLECTIONS = -collection:lib=lib

CC = odin
CFLAGS = -out:$(PROG) -strict-style -vet-semicolon -vet-cast -vet-using-param $(COLLECTIONS)

all: release

release: CFLAGS += -vet-unused -o:speed -microarch:native
release: $(PROG)

debug: CFLAGS += -debug -o:none -define:TRACY_ENABLE=true
debug: $(PROG)

test: CFLAGS += -define:ODIN_TEST_LOG_LEVEL=warning -debug
test: $(SOURCE_FILES)
	$(CC) test $(TESTS) $(CFLAGS)

$(PROG): $(SOURCE_FILES)
	$(CC) build $(SRC) $(CFLAGS)

run: debug
	./$(PROG)

check: CFLAGS := $(filter-out -out:$(PROG),$(CFLAGS))
check:
	$(CC) check $(SRC) $(CFLAGS) -debug

clean:
	-@rm $(PROG) 2>/dev/null

.PHONY: release debug clean run test check
