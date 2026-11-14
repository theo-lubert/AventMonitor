# Common tasks. The Xcode project is generated from project.yml by XcodeGen.

PROJECT := AventMonitor.xcodeproj
DERIVED := .build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme AventMonitor -derivedDataPath $(DERIVED)

.PHONY: all project build release test test-go test-swift install clean

all: build

$(PROJECT): project.yml
	xcodegen generate

project: $(PROJECT)

build: $(PROJECT)
	$(XCODEBUILD) -configuration Debug build; status=$$?; Scripts/unregister-builds.sh; exit $$status

release: $(PROJECT)
	$(XCODEBUILD) -configuration Release build; status=$$?; Scripts/unregister-builds.sh; exit $$status

test: test-go test-swift

# The Go tests need Core/keys_gen.go, which the core build generates.
test-go:
	Scripts/build-core.sh
	cd Core && go vet ./... && go test ./...

test-swift: $(PROJECT)
	$(XCODEBUILD) -configuration Debug test; status=$$?; Scripts/unregister-builds.sh; exit $$status

# Builds Release into ~/Applications and relaunches it.
install: $(PROJECT)
	Scripts/install.sh

clean:
	rm -rf .build Build
