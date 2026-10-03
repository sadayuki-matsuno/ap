PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

# With Command Line Tools only (no Xcode), swift-testing's Testing.framework is not on the
# default search paths, so pass the framework and lib_TestingInterop.dylib locations explicitly.
# With Xcode selected (e.g. GitHub's macos-15 runner), plain `swift test` works and no flags are added.
DEVELOPER_DIR_PATH := $(shell xcode-select -p 2>/dev/null)
CLT_DEVELOPER := /Library/Developer/CommandLineTools/Library/Developer
ifeq ($(DEVELOPER_DIR_PATH),/Library/Developer/CommandLineTools)
ifneq ($(wildcard $(CLT_DEVELOPER)/Frameworks/Testing.framework),)
TESTING_FLAGS ?= -Xswiftc -F -Xswiftc $(CLT_DEVELOPER)/Frameworks \
	-Xlinker -F -Xlinker $(CLT_DEVELOPER)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEVELOPER)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEVELOPER)/usr/lib
endif
endif

.PHONY: build debug test app install clean

build:
	swift build -c release

debug:
	swift build

test:
	swift test $(TESTING_FLAGS)

# build/Ap.app (menu bar picker + the ap CLI in Contents/MacOS)
app:
	scripts/build-app.sh

install: build
	install -d $(BINDIR)
	install -m 755 .build/release/ap $(BINDIR)/ap

clean:
	swift package clean
	rm -rf build
