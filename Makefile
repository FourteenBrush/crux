PROG = crux
ifeq ($(OS),Windows_NT)
	PROG := $(addsuffix .exe,$(PROG))
else
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S),Linux)
		OS_LINUX = true
	endif
endif

SRC = src
TESTS = tests
BUILD_DIR = build
COLLECTIONS = -collection:src=$(SRC) -collection:lib=lib

is_true = $(filter 1 true TRUE yes YES on ON,$($(1)))

USE_URING = false
ifneq ($(call is_true,DUSE_URING),)
ifeq ($(OS_LINUX),)
$(error DUSE_URING can only be used on linux)
endif
$(info DUSE_URING is enabled)
USE_URING = true
endif

CC = odin
CFLAGS += \
	-out:$(BUILD_DIR)/$(PROG) \
	-strict-style \
	-vet-semicolon \
	-vet-cast $(COLLECTIONS) \
	-define:CRUX_USE_IO_URING=$(USE_URING) \
	-vet-using-param

	
all: release

release: CFLAGS += -vet-unused -o:speed -microarch:native
release: $(PROG)

debug: CFLAGS += -debug -o:none
debug: $(PROG)

test: CFLAGS += -define:ODIN_TEST_LOG_LEVEL=warning -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_SHORT_LOGS=true -debug -keep-executable
test:
	@mkdir -p $(BUILD_DIR)
	$(CC) test $(TESTS) $(CFLAGS)

$(PROG): codegen
	@mkdir -p $(BUILD_DIR)
	$(CC) build $(SRC) $(CFLAGS)

# we can assume CWD is the root of the project
GENERATED_CODE = src/items/generated.odin
codegen: $(GENERATED_CODE)

DELETE_CONFLICTING_OUTPUTS ?= false

$(GENERATED_CODE): misc/codegen.odin
	$(CC) run misc/codegen.odin -file -out:$(BUILD_DIR)/codegen -- \
		--output-file $(GENERATED_CODE) \
		--delete-conflicting-outputs=$(DELETE_CONFLICTING_OUTPUTS)

run: debug
	./$(BUILD_DIR)/$(PROG) $(ARGS)

# TODO: in non profile modes, tracy threads are also started for some reason, is this because it is being linked in even though its not used?
profile: CFLAGS += -define:TRACY_ENABLE=true -debug
profile: release
	./$(BUILD_DIR)/$(PROG)

check: CFLAGS := $(filter-out -out:$(BUILD_DIR)/$(PROG),$(CFLAGS))
check:
	$(CC) check $(SRC) $(CFLAGS) -debug

clean:
	-@rm -r $(BUILD_DIR)

.PHONY: release debug run test profile check clean codegen
