.PHONY: build test package example
build:
	swift build
test:
	swift test
package:
	./tools/package-app.sh
example:
	./tools/build-example.sh --update-fixtures
