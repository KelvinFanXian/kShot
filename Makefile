.PHONY: build test app run clean

build:
	swift build

test:
	mkdir -p .build/module-cache
	SWIFTPM_MODULECACHE_OVERRIDE="$(CURDIR)/.build/module-cache" CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/module-cache" swift test --disable-sandbox

app:
	./scripts/build-app.sh

run: app
	open .build/app/KShot.app

clean:
	swift package clean
