.PHONY: build app run release zip clean

build:
	swift build

app:
	scripts/bundle.sh debug

release:
	scripts/bundle.sh release

# Quits the running NotchMan and opens the new build; works from a shell inside NotchMan too.
run: app
	scripts/relaunch.sh

# Universal, ad-hoc-signed build/NotchMan-v<version>.zip to attach to a GitHub release.
zip:
	scripts/package.sh

clean:
	rm -rf .build build
