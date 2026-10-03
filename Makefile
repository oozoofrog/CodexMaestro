.PHONY: build test run demo probe app
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
