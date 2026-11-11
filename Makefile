# Root entry point for Photon (v1: iPad UI + design/UI specs; macOS GUI deferred).
#
# `make check` is the merge gate that runs inside the DSH sandbox. App builds need a normal
# terminal / CI, so they live in `make check-apps`; `make check-full` runs both.
#
# DSH sandbox notes:
# - SwiftPM wants to sandbox its own manifest compilation, which the harness already sandboxes;
#   every SwiftPM invocation uses --disable-sandbox (script mode, e.g. fixtures, takes no flag).
# - TMPDIR and the clang module cache must be inside the workspace.
# - apps/ios references local SwiftPM packages, so xcodebuild cannot resolve them inside the DSH
#   sandbox (nested sandbox-exec). Agents build it through Xcode MCP; `make ios-build` is for a
#   normal terminal / CI (ADR-0009).
#
# Parallel agents: override the build locations so concurrent work does not race:
#   make test SCRATCH=.build-mine TMP=$PWD/.tmp-mine MC=$PWD/.mc-mine
SHELL := /bin/bash

SCRATCH ?= .build
TMP ?= $(CURDIR)/.tmp
MC ?= $(CURDIR)/.mc
DD_IOS ?= .dd-ios
DD_DEVICE ?= .dd-ios-device
DEVICE_UDID ?= 00008112-001E055E3EF0C01E
FIXTURES ?= $(CURDIR)/work/fixtures

SWIFT ?= swift
SWIFT_FLAGS := --disable-sandbox
CONTRACT_SCRATCH := $(abspath $(SCRATCH))/contract
SERVER_SCRATCH := $(abspath $(SCRATCH))/server
CLIENT_SCRATCH := $(abspath $(SCRATCH))/client
APPCTL := $(SERVER_SCRATCH)/release/appctl
IOS_PROJECT := apps/ios/iOS.xcodeproj
IOS_SCHEME := PhotonClient
IOS_BUNDLE_ID := com.criphc.Photon.Client
XCODEBUILD := xcodebuild
NO_SWIFT_SANDBOX := OTHER_SWIFT_FLAGS='$$(inherited) -disable-sandbox'

export TMPDIR := $(abspath $(TMP))
export CLANG_MODULE_CACHE_PATH := $(abspath $(MC))

.PHONY: test contract-test server-test client-test integration appctl cli parity \
        ios-build ios-build-device ios-install ios-launch check check-apps check-full \
        macos-build ui-check docs-lint docs-index docs-fix docs-check fixtures clean

## test: the merge gate's unit/integration-lite suite (no real appctl process).
test: contract-test server-test client-test

contract-test:
	@mkdir -p "$(TMPDIR)" "$(CLANG_MODULE_CACHE_PATH)"
	cd contract && $(SWIFT) test $(SWIFT_FLAGS) --scratch-path "$(CONTRACT_SCRATCH)"

server-test:
	@mkdir -p "$(TMPDIR)" "$(CLANG_MODULE_CACHE_PATH)"
	cd server && $(SWIFT) test $(SWIFT_FLAGS) --scratch-path "$(SERVER_SCRATCH)" --skip IntegrationTests

client-test:
	@mkdir -p "$(TMPDIR)" "$(CLANG_MODULE_CACHE_PATH)"
	cd client && $(SWIFT) test $(SWIFT_FLAGS) --scratch-path "$(CLIENT_SCRATCH)"

## appctl: build the thin CLI (the only server entry point). Release: the debug CLI is ~5x
## slower on a full delivery (docs/reference/performance.md).
appctl:
	@mkdir -p "$(TMPDIR)" "$(CLANG_MODULE_CACHE_PATH)"
	cd server && $(SWIFT) build $(SWIFT_FLAGS) --scratch-path "$(SERVER_SCRATCH)" -c release --product appctl

## integration: spawn the real appctl serve/deliver (in-process Core Image writer; no oracle needed).
integration: appctl
	@test -x "$(APPCTL)" || (echo "error: appctl was not built at $(APPCTL)" >&2; exit 1)
	cd server && APPCTL_BIN="$(APPCTL)" \
		$(SWIFT) test $(SWIFT_FLAGS) --scratch-path "$(SERVER_SCRATCH)" --filter IntegrationTests

## cli: what `make cli` prints.
cli: appctl
	"$(APPCTL)" --help

## parity: the single-MSL shader gate in the client package (trial base included; must be 0 skips).
parity:
	@mkdir -p "$(TMPDIR)" "$(CLANG_MODULE_CACHE_PATH)"
	cd client && PHOTON_TRIAL_BASE_PARITY=1 \
		$(SWIFT) test $(SWIFT_FLAGS) --scratch-path "$(CLIENT_SCRATCH)" --filter ShaderParity

## ios-build: unsigned compile check for a normal terminal / CI (agents use Xcode MCP).
ios-build:
	$(XCODEBUILD) build -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) \
		-destination 'generic/platform=iOS' -configuration Debug \
		-derivedDataPath "$(abspath $(DD_IOS))" CODE_SIGNING_ALLOWED=NO $(NO_SWIFT_SANDBOX)

## ios-build-device: signed Debug build for the acceptance iPad (normal terminal / CI).
ios-build-device:
	$(XCODEBUILD) build -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) \
		-destination 'platform=iOS,id=$(DEVICE_UDID)' -configuration Debug \
		-derivedDataPath "$(abspath $(DD_DEVICE))" -allowProvisioningUpdates $(NO_SWIFT_SANDBOX)

ios-install: ios-build-device
	xcrun devicectl device install app --device $(DEVICE_UDID) \
		"$(abspath $(DD_DEVICE))/Build/Products/Debug-iphoneos/PhotonClient.app"

ios-launch:
	xcrun devicectl device process launch --device $(DEVICE_UDID) $(IOS_BUNDLE_ID)

## check: merge gate that runs inside the DSH sandbox (no app builds).
check: test integration parity docs-lint

## check-apps: app build gate, for a normal terminal / CI (xcodebuild cannot run in DSH).
check-apps: ios-build
	@: # macOS build joins here when the macOS GUI is no longer deferred

## check-full: everything a merge must pass.
check-full: check check-apps

## Placeholders: fail loudly instead of silently doing nothing.
macos-build:
	@echo "error: macOS GUI is deferred; there is no macOS app project" >&2; exit 1

ui-check:
	@echo "error: ui-check is not implemented; snapshot/UI-test baseline is postponed by decision (see docs/status.md)" >&2; exit 1

## docs-lint: docs structure, links, generated index (errors fail; warnings do not).
docs-lint:
	python3 tools/docs-lint.py --check

## docs-index: regenerate docs/README.md from front-matter and headings.
docs-index:
	python3 tools/docs-lint.py --write

## docs-fix: repair links broken by manual doc moves/renames, then regenerate the index.
docs-fix:
	python3 tools/docs-fix-links.py --write
	python3 tools/docs-lint.py --write

## docs-check: deprecated alias for docs-lint (kept for old scripts).
docs-check: docs-lint

## fixtures: synthetic base+HDR pair under work/fixtures/ (gitignored); non-zero exit fails.
fixtures:
	@mkdir -p "$(TMPDIR)" "$(CLANG_MODULE_CACHE_PATH)" "$(FIXTURES)"
	cd "$(FIXTURES)" && $(SWIFT) -module-cache-path "$(CLANG_MODULE_CACHE_PATH)" \
		"$(CURDIR)/tools/make-fixtures/make-pair.swift" "$(FIXTURES)"

clean:
	rm -rf "$(SCRATCH)" "$(TMP)" "$(MC)" "$(DD_IOS)" "$(DD_DEVICE)"
