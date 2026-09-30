DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Documents/DevPlugins

generate: ; xcodegen generate
build: generate ; xcodebuild -scheme TemplatePlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/TemplatePlugin.bundle"
	cp -R build/Build/Products/Debug/TemplatePlugin.bundle "$(DEV_PLUGINS)/TemplatePlugin.bundle"
release: ; ./scripts/release.sh $(V)
