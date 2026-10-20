.PHONY: build app run release clean

build:
	swift build

app:
	scripts/bundle.sh debug

release:
	scripts/bundle.sh release

run: app
	-pkill -x NotchMan
	open build/NotchMan.app

clean:
	rm -rf .build build
