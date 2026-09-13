.PHONY: build release dmg test run

build:
	bash scripts/build.sh

release:
	CONFIGURATION=Release bash scripts/build.sh

dmg: release
	bash scripts/package-dmg.sh

test:
	bash scripts/test.sh

run: build
	open "$(HOME)/Library/Developer/Xcode/DerivedData/Yapper/Build/Products/Debug/Yapper-Dev.app"
