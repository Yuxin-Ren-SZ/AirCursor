.PHONY: build app run install test icon release clean

build:
	swift build

test:
	swift test

icon:
	swift scripts/make-icon.swift "$(CURDIR)"

app:
	scripts/build-app.sh

# Fast single-arch build, then launch.
run:
	ARCHS=arm64 scripts/build-app.sh
	open build/AirCursor.app

# Installing to /Applications keeps the Accessibility grant stable and enables Launch at Login.
install: app
	rm -rf /Applications/AirCursor.app
	cp -R build/AirCursor.app /Applications/
	open /Applications/AirCursor.app

release:
	scripts/release.sh

clean:
	rm -rf .build build
