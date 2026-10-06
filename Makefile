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
IOS_DEVICE_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/SecChainiOS.app
# The ios-ota-install-tailscale skill of castle, where its installer puts it.
OTA_SKILL_DIR ?= $(HOME)/.agents/skills/ios-ota-install-tailscale
OTA_EXPORT_OUTPUT := tmp/ios-ota.out

.PHONY: build-macos build-ios build-ios-device test check-localization test-hooks test-integration macos cli ios ios-device ios-ota screenshots dmg clean

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

# Build the iOS app for a physical iPhone or iPad, signed with the team's development profile.
# The generic destination lets the build run with no device connected. xcodebuild registers only a
# destination device, so `ios-device` passes id=<UDID> here to have an unregistered device
# registered and included in the profile.
IOS_DEVICE_DESTINATION ?= generic/platform=iOS
build-ios-device:
	xcodebuild -project $(XCODEPROJ) -scheme SecChainiOS -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) -destination '$(IOS_DEVICE_DESTINATION)' $(SIGNING_FLAGS) build

# Unit tests. They use an in-memory Keychain double, so they need no signing identity.
test:
	swift test --package-path SecChainCore

# Every text of the apps is in the String Catalog with a Japanese translation. What is checked is
# described in the script.
check-localization:
	bash scripts/test/localization.sh

# The Claude Code hooks of the agent skill: the guard, against the calls it has to stop and the ones
# it has to let through, and the Claude Mods plugin that masks values, through `claude plugin
# validate` and `claude plugin test`. It needs no build, but it needs `claude` on PATH.
test-hooks:
	bash scripts/test/hooks.sh

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

# Build, install, and launch the iOS app on the connected iPhone or iPad (resolved through
# devicectl and jq), or on the one passed as DEVICE_UDID=<UDID>. The device is resolved before the
# build because the build takes it as its destination.
ios-device:
	@set -e; \
	device_udid="$(DEVICE_UDID)"; \
	if [ -z "$$device_udid" ]; then \
		devices=$$(xcrun devicectl list devices --quiet --omit-deprecated-fields-in-json --json-output - \
			| jq -r '.result.devices[] | select(.properties.hardware.reality == "physical" and (.properties.hardware.deviceType == "iPhone" or .properties.hardware.deviceType == "iPad") and (.properties.connection.state == "connected" or .properties.connection.state == "available")) | "\(.properties.hardware.udid)\t\(.properties.state.name)"'); \
		case $$(printf '%s' "$$devices" | grep -c .) in \
		0) echo "Error: no iPhone or iPad is connected. Connect one over USB or Wi-Fi and trust this Mac, or pass DEVICE_UDID=<UDID>" >&2; exit 1 ;; \
		1) device_udid=$$(printf '%s\n' "$$devices" | cut -f 1) ;; \
		*) echo "Error: more than one iPhone or iPad is connected. Pass DEVICE_UDID=<UDID> with one of them:" >&2; printf '%s\n' "$$devices" >&2; exit 1 ;; \
		esac; \
	fi; \
	$(MAKE) build-ios-device IOS_DEVICE_DESTINATION="id=$$device_udid"; \
	xcrun devicectl device install app --device "$$device_udid" "$(IOS_DEVICE_APP)"; \
	xcrun devicectl device process launch --device "$$device_udid" com.bannzai.SecChain

# Archive the iOS app and publish it for over-the-air installation on an iPhone in the same tailnet,
# through the ios-ota-install-tailscale skill of castle. Starting the server (`ota-serve.sh up`) is
# the skill's own step, so this target only checks that it is serving. OTA_SLACK_CHANNEL=<channel>
# also posts the install page to Slack.
ios-ota:
	@set -eo pipefail; \
	[ -d "$(OTA_SKILL_DIR)" ] || { echo "Error: the ios-ota-install-tailscale skill of castle is required, and it was not found at $(OTA_SKILL_DIR) (pass OTA_SKILL_DIR=<path> if it is elsewhere)" >&2; exit 1; }; \
	serve_status=$$(bash "$(OTA_SKILL_DIR)/scripts/ota-serve.sh" status 2>&1) || { printf '%s\n' "$$serve_status" >&2; echo "Error: the OTA server is not ready. Set it up with the ios-ota-install-tailscale skill (ota-serve.sh up)" >&2; exit 1; }; \
	mkdir -p $(dir $(OTA_EXPORT_OUTPUT)); \
	bash "$(OTA_SKILL_DIR)/scripts/ota-export.sh" --project $(XCODEPROJ) --scheme SecChainiOS --slug secchain | tee $(OTA_EXPORT_OUTPUT); \
	page_url=$$(sed -n 's/^PAGE_URL=//p' $(OTA_EXPORT_OUTPUT)); \
	[ -n "$$page_url" ] || { echo "Error: ota-export.sh did not print PAGE_URL" >&2; exit 1; }; \
	[ -z "$(OTA_SLACK_CHANNEL)" ] || bash "$(OTA_SKILL_DIR)/scripts/ota-notify.sh" --url "$$page_url" --channel "$(OTA_SLACK_CHANNEL)"; \
	grep -E '^(PAGE_URL|INSTALL_URL)=' $(OTA_EXPORT_OUTPUT)

# The App Store screenshots of the iOS app, for every language and device class, into
# fastlane/screenshots (scripts/generate_screenshots/README.md). Runs simulators, so not in CI.
screenshots:
	bash scripts/generate_screenshots/generate_appstore_screenshots.sh

# Build the Developer ID signed, notarized, and stapled DMG at tmp/distribution/SecChain-<version>.dmg.
# Needs the App Store Connect API key in the environment (documents/macos-distribution.md).
dmg:
	bash scripts/macos/create_developer_id_profiles.sh
	bash scripts/macos/export_developer_id.sh
	bash scripts/macos/notarize_and_dmg.sh

clean:
	rm -rf $(DERIVED_DATA)

# Install the Debug build over the Release one at /Applications/SecChain.app. This is a temporary
# install for operations that only the Debug build has (developer menus and the like) against the
# data in everyday use; run `make macos` afterwards to go back to the Release build.
# It does not launch the app, so that it also works over ssh.
.PHONY: macos-debug

macos-debug:
	xcodebuild -project 'SecChain.xcodeproj' -scheme 'SecChain' \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath 'tmp/DerivedData' \
		-allowProvisioningUpdates -allowProvisioningDeviceRegistration \
		build
	rm -rf $(INSTALL_APP)
	ditto 'tmp/DerivedData/Build/Products/Debug/SecChain.app' $(INSTALL_APP)
	$(LSREGISTER) -f $(INSTALL_APP)
	@echo "To launch: open $(INSTALL_APP)"
	@echo "To go back to the Release build: make macos"

# A bare `make` runs the checks of CI (.github/workflows/ci.yml) with the signing of a developer's
# Mac: the builds need the team's signing identity (CI passes CODE_SIGNING_ALLOWED=NO through
# SIGNING_FLAGS and IOS_SIGNING_FLAGS instead), which registers this Mac with the team and updates
# its provisioning profiles, and test-hooks needs `claude` on PATH. No step prompts or needs a
# device.
.DEFAULT_GOAL := verify

.PHONY: verify
verify: test check-localization test-hooks build-macos build-ios

# Serializes every target of this Makefile under `make -j`, so that the prerequisites of verify run
# one after another: build-macos and build-ios share tmp/DerivedData, and two xcodebuild processes
# on it fight over the build database. Nothing is lost, because verify is the only target with
# more than one prerequisite, and xcodebuild and swift parallelize on their own. The global form is used because
# the make shipped with macOS (3.81) ignores prerequisites on this target.
.NOTPARALLEL:
