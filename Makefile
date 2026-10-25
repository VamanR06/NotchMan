.PHONY: build app run release clean

build:
	swift build

app:
	scripts/bundle.sh debug

release:
	scripts/bundle.sh release

# Quits the running NotchMan and opens the new build; works from a shell inside NotchMan too.
run: app
	scripts/relaunch.sh

clean:
	rm -rf .build build
