PREFIX ?= /usr/local
# Marketing version stamped into the bundle; defaults to the one in Apps/OpenClean/Info.plist.
VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Apps/OpenClean/Info.plist)
# CFBundleVersion: the commit count, so it only ever grows along main.
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ARCH_FLAGS ?=
BUILD_DIR := build
APP := $(BUILD_DIR)/OpenClean.app
RELEASE_DIR := $(BUILD_DIR)/release
DMG = $(RELEASE_DIR)/OpenClean-$(VERSION).dmg
CLI_ZIP = $(RELEASE_DIR)/openclean-cli-$(VERSION).zip
BIN = $(shell swift build -c release $(ARCH_FLAGS) --show-bin-path)
# Code signing. "-" (the default) = ad-hoc, for local builds, forks and PRs. Release CI passes a
# "Developer ID Application: … (TEAMID)" identity from a temporary keychain; then the app and the CLI are
# signed with the hardened runtime and a secure timestamp (both required for notarization) and the DMG is
# signed too. No entitlements file: nothing OpenClean does needs a hardened-runtime exception (see
# CONTRIBUTING.md "Releases").
SIGN_IDENTITY ?= -
ifeq ($(SIGN_IDENTITY),-)
CODESIGN = codesign --force --sign -
else
CODESIGN = codesign --force --options runtime --timestamp --sign "$(SIGN_IDENTITY)"
endif

.PHONY: build test app install uninstall dist lint icon dmg cli-zip release-assets

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
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(APP)/Contents/Info.plist"
	@# The bundle has no nested code (no frameworks, helpers or plug-ins), so signing the bundle signs its
	@# main executable too. If nested code is ever added, sign it first, inside-out.
	$(CODESIGN) "$(APP)"
	codesign --verify --strict --verbose=2 "$(APP)"

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

# Drag-to-Applications disk image: the app plus an /Applications symlink. hdiutil occasionally fails
# with "Resource busy" on CI runners, so it is retried.
dmg: app
	rm -rf "$(BUILD_DIR)/dmg-root" "$(DMG)"
	mkdir -p "$(BUILD_DIR)/dmg-root" "$(RELEASE_DIR)"
	ditto "$(APP)" "$(BUILD_DIR)/dmg-root/OpenClean.app"
	ln -s /Applications "$(BUILD_DIR)/dmg-root/Applications"
	for attempt in 1 2 3; do \
		hdiutil create -volname "OpenClean $(VERSION)" -srcfolder "$(BUILD_DIR)/dmg-root" \
			-fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$(DMG)" && break; \
		if [ $$attempt = 3 ]; then exit 1; fi; echo "hdiutil failed, retrying"; sleep 5; \
	done
	rm -rf "$(BUILD_DIR)/dmg-root"
	if [ "$(SIGN_IDENTITY)" != "-" ]; then codesign --timestamp --sign "$(SIGN_IDENTITY)" "$(DMG)"; fi

# CLI archive: openclean-cli/bin/openclean finds its rules in ../share/openclean/rules.
cli-zip: build
	rm -rf "$(BUILD_DIR)/cli-root" "$(CLI_ZIP)"
	mkdir -p "$(BUILD_DIR)/cli-root/openclean-cli/bin" "$(BUILD_DIR)/cli-root/openclean-cli/share/openclean/rules" "$(RELEASE_DIR)"
	cp "$(BIN)/openclean" "$(BUILD_DIR)/cli-root/openclean-cli/bin/"
	@# Ad-hoc builds keep the linker's signature; Developer ID builds are re-signed for notarization.
	if [ "$(SIGN_IDENTITY)" != "-" ]; then \
		$(CODESIGN) --identifier com.openclean.cli "$(BUILD_DIR)/cli-root/openclean-cli/bin/openclean"; \
	fi
	cp Rules/*.yaml "$(BUILD_DIR)/cli-root/openclean-cli/share/openclean/rules/"
	ditto -c -k --norsrc --noextattr --noacl --keepParent "$(BUILD_DIR)/cli-root/openclean-cli" "$(CLI_ZIP)"
	rm -rf "$(BUILD_DIR)/cli-root"

# Everything a GitHub release uploads, in build/release/ (cleared first so no stale assets ship).
release-assets:
	rm -rf "$(RELEASE_DIR)"
	sed -i '' 's/^public let openCleanVersion = .*/public let openCleanVersion = "$(VERSION)"/' Apps/openclean-cli/Sources/OpenCleanCLI/Version.swift
	$(MAKE) dmg cli-zip VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" ARCH_FLAGS="$(ARCH_FLAGS)"
	cd "$(RELEASE_DIR)" && shasum -a 256 "OpenClean-$(VERSION).dmg" "openclean-cli-$(VERSION).zip" > SHA256SUMS.txt
	cat "$(RELEASE_DIR)/SHA256SUMS.txt"

# Regenerate the app icon after changing the logo (see .claude/skills/openclean-design).
icon:
	swift scripts/make-app-icon.swift Apps/OpenClean/Resources/AppIcon.icns
