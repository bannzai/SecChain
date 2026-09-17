XCODEPROJ := SecChain.xcodeproj
CONFIGURATION := Debug
# Kept inside the repository so that build products have a deterministic path and the system
# DerivedData is left alone.
DERIVED_DATA := tmp/DerivedData
# Deferred expansion: the `macos` target overrides CONFIGURATION.
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/SecChain.app
INSTALL_APP := /Applications/SecChain.app
CLI_INSTALL_DIR := $(HOME)/.local/bin
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# keychain-access-groups needs a provisioning profile, so command-line builds are allowed to
# create one and to register this Mac. CI has no signing identity and overrides this with ad-hoc
# signing settings (see .github/workflows/ci.yml).
SIGNING_FLAGS ?= -allowProvisioningUpdates -allowProvisioningDeviceRegistration
IOS_SIMULATOR_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphonesimulator/SecChainiOS.app

.PHONY: build-macos build-ios test test-integration macos cli ios dmg clean

# Build the macOS app together with the embedded command-line tool.
build-macos:
	xcodebuild -project $(XCODEPROJ) -scheme SecChain -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) -destination 'generic/platform=macOS' $(SIGNING_FLAGS) build

# Build the iOS app. The generic simulator destination needs neither a registered device nor a
# booted simulator. The simulator build is still signed (locally, without a profile) so that the
# keychain-access-groups entitlement is embedded and the simulator's Keychain honors the shared
# access group. CI passes IOS_SIGNING_FLAGS='CODE_SIGNING_ALLOWED=NO'.
IOS_SIGNING_FLAGS ?=
build-ios:
	xcodebuild -project $(XCODEPROJ) -scheme SecChainiOS -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) -destination 'generic/platform=iOS Simulator' $(IOS_SIGNING_FLAGS) build

# Unit tests. They use an in-memory Keychain double, so they need no signing identity.
test:
	swift test --package-path SecChainCore

# Tests against the real data protection keychain, executed by the signed embedded tool.
test-integration: build-macos
	bash scripts/test/integration.sh "$(APP)/Contents/Helpers/secchain.app/Contents/MacOS/secchain"

# Install the Release build to /Applications.
macos: CONFIGURATION := Release
macos: build-macos
	rm -rf $(INSTALL_APP)
	ditto $(APP) $(INSTALL_APP)
	$(LSREGISTER) -f $(INSTALL_APP)

# Put `secchain` on the PATH as a symlink into the installed app. A `swift build` product is not
# used because only the embedded, team-signed tool can read the shared Keychain items. The symlink
# follows app updates, and re-running `ln -sf` converges to the same result (idempotent).
cli: macos
	mkdir -p $(CLI_INSTALL_DIR)
	ln -sf $(INSTALL_APP)/Contents/Helpers/secchain.app/Contents/MacOS/secchain $(CLI_INSTALL_DIR)/secchain

# Build, install, and launch the iOS app on the project's simulator (booted by sim-boot).
ios: build-ios
	@set -e; \
	simulator_udid="$(SIMULATOR_UDID)"; \
	[ -n "$$simulator_udid" ] || simulator_udid=$$(SCRIPT_QUIET=1 sim-boot | sed -n 's/^DEVICE_UDID=//p' | tail -n 1); \
	[ -n "$$simulator_udid" ] || { echo "Error: sim-boot could not resolve a simulator (check that sim-boot is on PATH, or pass SIMULATOR_UDID=<UDID>)" >&2; exit 1; }; \
	xcrun simctl install "$$simulator_udid" "$(IOS_SIMULATOR_APP)"; \
	xcrun simctl launch "$$simulator_udid" com.bannzai.SecChain

# Build the Developer ID signed, notarized, and stapled DMG at tmp/distribution/SecChain-<version>.dmg.
# Needs the App Store Connect API key in the environment (documents/macos-distribution.md).
dmg:
	bash scripts/macos/create_developer_id_profiles.sh
	bash scripts/macos/export_developer_id.sh
	bash scripts/macos/notarize_and_dmg.sh

clean:
	rm -rf $(DERIVED_DATA)
