.PHONY: build test run demo probe app install xcode-project xcode-build xcode-test
build:
	swift build
test:
	swift test
run:
	swift run CodexMaestro
demo:
	swift run CodexMaestro --demo
probe:
	swift run MaestroProbe
app:
	./scripts/package-app.sh
install:
	./scripts/install-app.sh
xcode-project:
	xcodegen generate --spec project.yml
xcode-build:
	xcodebuild -project CodexMaestro.xcodeproj -scheme CodexMaestro -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/XcodeDerivedData build
xcode-test:
	xcodebuild -project CodexMaestro.xcodeproj -scheme CodexMaestro -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/XcodeDerivedData test
