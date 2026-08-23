APP_BUILD_DIR := .derived
APP_PATH := $(APP_BUILD_DIR)/Build/Products/Debug/NativQL.app

.PHONY: generate build run test clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project NativQL.xcodeproj -scheme NativQL \
		-configuration Debug build CODE_SIGNING_ALLOWED=NO \
		-derivedDataPath $(APP_BUILD_DIR)

run: build
	open $(APP_PATH)

test:
	cd Packages/NativQLKit && swift test

clean:
	rm -rf $(APP_BUILD_DIR)
