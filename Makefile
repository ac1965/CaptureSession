# CaptureSession
#   make build    .app をビルドして dist/ に置く（ad-hoc署名）
#   make run      ビルドして起動する
#   make test     コア部分のテスト
#   make install  /Applications に置く
#   make clean    生成物を消す

APP := dist/CaptureSession.app

.PHONY: help build run test install clean

help:
	@echo "make build | run | test | install | clean"

build:
	zsh scripts/build_app.sh

run: build
	open $(APP)

test:
	swift test

install: build
	rm -rf /Applications/CaptureSession.app
	ditto $(APP) /Applications/CaptureSession.app

clean:
	rm -rf dist build .build
