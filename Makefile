PREFIX ?= /usr/local
VERSION ?= 0.1.0
ARCH_FLAGS ?=
BUILD_DIR := build
APP := $(BUILD_DIR)/OpenClean.app
BIN = $(shell swift build -c release $(ARCH_FLAGS) --show-bin-path)

.PHONY: build test app install uninstall dist lint icon

build:
	swift build -c release $(ARCH_FLAGS)

test:
	swift test

lint:
	swift format lint --strict --recursive Package.swift Packages Apps
	swift run openclean rules lint Rules/*.yaml

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources/Rules"
	cp "$(BIN)/OpenCleanApp" "$(APP)/Contents/MacOS/OpenClean"
	cp Apps/OpenClean/Info.plist "$(APP)/Contents/Info.plist"
	cp Rules/*.yaml "$(APP)/Contents/Resources/Rules/"
	cp Apps/OpenClean/Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP)"

install: app
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/share/openclean/rules"
	cp "$(BIN)/openclean" "$(PREFIX)/bin/openclean"
	cp Rules/*.yaml "$(PREFIX)/share/openclean/rules/"
	rm -rf /Applications/OpenClean.app
	cp -R "$(APP)" /Applications/OpenClean.app

uninstall:
	rm -rf /Applications/OpenClean.app "$(PREFIX)/bin/openclean" "$(PREFIX)/share/openclean"

dist: app
	rm -rf "$(BUILD_DIR)/dist"
	mkdir -p "$(BUILD_DIR)/dist/openclean-cli/bin" "$(BUILD_DIR)/dist/openclean-cli/share/openclean/rules"
	cp "$(BIN)/openclean" "$(BUILD_DIR)/dist/openclean-cli/bin/"
	cp Rules/*.yaml "$(BUILD_DIR)/dist/openclean-cli/share/openclean/rules/"
	ditto -c -k --keepParent "$(APP)" "$(BUILD_DIR)/OpenClean-$(VERSION).zip"
	ditto -c -k --keepParent "$(BUILD_DIR)/dist/openclean-cli" "$(BUILD_DIR)/openclean-cli-$(VERSION).zip"

# Regenerate the app icon after changing the logo (see .claude/skills/openclean-design).
icon:
	swift scripts/make-app-icon.swift Apps/OpenClean/Resources/AppIcon.icns
