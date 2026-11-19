.PHONY: gen run test analyze format apk check core-test

gen:
	flutter pub get
	dart run build_runner build

run:
	flutter run

test:
	flutter test
	cd packages/tg_proxy_core && dart test

analyze:
	flutter analyze

format:
	dart format lib test packages

apk:
	flutter build apk --debug

core-test:
	cd packages/tg_proxy_core && dart test

check:
	dart format --output=none --set-exit-if-changed lib test packages
	flutter analyze
	flutter test
	cd packages/tg_proxy_core && dart test
