PROJECT := Sunoh.xcodeproj
SCHEME := Sunoh
BUNDLE_ID := com.samuel.sunoh
DERIVED := $(CURDIR)/.build
APP := $(DERIVED)/Build/Products/Debug-iphonesimulator/Sunoh.app
SEED ?= $(CURDIR)/.local/seed.jsonl
PHONE_UDID ?= $(shell xcrun simctl list devices available -j | python3 scripts/simulator.py)

.PHONY: check-phone check-seed build run test gps seed token
check-phone:
	@test -n "$(PHONE_UDID)" || (echo "Boot an iPhone simulator first."; exit 1)

build: check-phone
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination "id=$(PHONE_UDID)" -derivedDataPath "$(DERIVED)" build

run: build
	xcrun simctl terminate "$(PHONE_UDID)" $(BUNDLE_ID) 2>/dev/null || true
	xcrun simctl install "$(PHONE_UDID)" "$(APP)"
	xcrun simctl launch "$(PHONE_UDID)" $(BUNDLE_ID)
	python3 scripts/simulator.py --open

test: check-phone
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination "id=$(PHONE_UDID)" -derivedDataPath "$(DERIVED)" -parallel-testing-enabled NO test

gps: check-phone
	python3 scripts/gps.py DebugRoute.gpx | xcrun simctl location "$(PHONE_UDID)" start --speed=5 -

# Prompt for map service credentials and save the private app build configuration.
token:
	@python3 scripts/credentials.py

check-seed:
	@test -f "$(SEED)" && test -r "$(SEED)" && test -s "$(SEED)" || (echo 'Seed file is missing, empty or unreadable: $(SEED)'; echo 'Use make seed SEED=/path/to/seed.jsonl'; exit 1)

seed: check-seed
	$(MAKE) build
	xcrun simctl terminate "$(PHONE_UDID)" $(BUNDLE_ID) 2>/dev/null || true
	xcrun simctl install "$(PHONE_UDID)" "$(APP)"
	python3 scripts/seed.py "$(PHONE_UDID)" "$(BUNDLE_ID)" "$(SEED)"
	python3 scripts/simulator.py --open
