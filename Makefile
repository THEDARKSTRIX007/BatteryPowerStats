APP_NAME = BatterySOT
BUNDLE_NAME = $(APP_NAME).app
CONTENTS = $(BUNDLE_NAME)/Contents
MACOS = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
BUILD_BIN = .build/release/$(APP_NAME)

.PHONY: all build bundle run clean install

all: bundle

build:
	swift build -c release

debug:
	swift build

bundle: build
	@echo "Creating .app bundle..."
	@rm -rf $(BUNDLE_NAME)
	@mkdir -p $(MACOS)
	@mkdir -p $(RESOURCES)
	@cp $(BUILD_BIN) $(MACOS)/$(APP_NAME)
	@cp Support/Info.plist $(CONTENTS)/Info.plist
	@echo "APPL????" > $(CONTENTS)/PkgInfo
	@codesign --force --deep --sign - $(BUNDLE_NAME)
	@echo "✅ Build complete: $(BUNDLE_NAME)"
	@echo ""
	@echo "To run: open $(BUNDLE_NAME)"
	@echo "To install: cp -r $(BUNDLE_NAME) /Applications/"

run: bundle
	open $(BUNDLE_NAME)

install: bundle
	@echo "Installing to /Applications..."
	@cp -r $(BUNDLE_NAME) /Applications/
	@echo "✅ Installed to /Applications/$(BUNDLE_NAME)"
	@echo ""
	@echo "You can now find BatterySOT in your menu bar."
	@echo "To enable Launch at Login, right-click the menu bar icon → Settings."

clean:
	swift package clean
	rm -rf $(BUNDLE_NAME)

test:
	swift run BatterySOTTests
