DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# Debug hosts only scan this (PluginTrust.scansDevPluginsDirectory is #if DEBUG).
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins

.PHONY: generate build sideload test release
generate: ; xcodegen generate
build: lint generate ; xcodebuild -scheme WhisperPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/WhisperPlugin.bundle"
	cp -R build/Build/Products/Debug/WhisperPlugin.bundle "$(DEV_PLUGINS)/WhisperPlugin.bundle"
test: lint generate ; xcodebuild -scheme WhisperPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
release: ; ./scripts/release.sh $(V)

include scripts/guardrails.mk
