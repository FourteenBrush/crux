rwildcard = $(wildcard $1) $(foreach d,$1,$(call rwildcard,$(addsuffix /$(notdir $d),$(wildcard $(dir $d)*))))

PROG = crux
SRC = src
SOURCE_FILES = $(call rwildcard,$(SRC)/*.odin)
TESTS = tests
COLLECTIONS = -collection:src=src -collection:lib=lib

CC = odin
CFLAGS = -out:$(BUILD_DIR)/$(PROG) -strict-style -vet-semicolon -vet-cast -vet-using-param $(COLLECTIONS)
BUILD_DIR = build

all: release

release: CFLAGS += -vet-unused -o:speed -microarch:native
release: $(PROG)

debug: CFLAGS += -debug -o:none # -define:TRACY_ENABLE=true
debug: $(PROG)

test: CFLAGS += -define:ODIN_TEST_LOG_LEVEL=warning -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_SHORT_LOGS=true -debug -keep-executable
test: $(SOURCE_FILES)
	$(CC) test $(TESTS) $(CFLAGS)

$(PROG): $(SOURCE_FILES)
	mkdir $(BUILD_DIR) -p
	$(CC) build $(SRC) $(CFLAGS)

run: debug
	./$(BUILD_DIR)/$(PROG)

check: CFLAGS := $(filter-out -out:$(BUILD_DIR)/$(PROG),$(CFLAGS))
check: $(SOURCE_FILES)
check:
	$(CC) check $(SRC) $(CFLAGS) -debug

clean:
	-@rm $(BUILD_DIR)/$(PROG)
	-@rm $(BUILD_DIR) -r

.PHONY: all release clean debug run test check
