DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# Debug hosts only scan this (PluginTrust.scansDevPluginsDirectory is #if DEBUG).
DEV_PLUGINS ?= $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins

.PHONY: generate build sideload test release
generate: ; xcodegen generate
build: lint generate ; xcodebuild -scheme WhisperPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	@case "$(DEV_PLUGINS)" in "$(HOME)/Library/Application Support/"*) \
		[ "$(CONFIRM_DAILY)" = 1 ] || { echo "refusing: DEV_PLUGINS is the daily app's folder (set DEV_PLUGINS=<fixture>/DevPlugins or CONFIRM_DAILY=1)"; exit 1; };; esac
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/WhisperPlugin.bundle"
	cp -R build/Build/Products/Debug/WhisperPlugin.bundle "$(DEV_PLUGINS)/WhisperPlugin.bundle"
test: lint generate ; xcodebuild -scheme WhisperPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
release: ; ./scripts/release.sh $(V)

include scripts/guardrails.mk
