
# NotificationGrouper - iOS 17 通知归纳插件
# Makefile for Theos (rootless)

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:17.0
PACKAGE_VERSION = 1.0.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotificationGrouper
NotificationGrouper_FILES = Tweak.x
NotificationGrouper_CFLAGS = -fobjc-arc -Wno-error
NotificationGrouper_LDFLAGS = -framework Foundation -framework UIKit -lsubstrate

# Rootless package (Dopamine/Palera1n)
THEOS_PACKAGE_SCHEME = rootless
THEOS_PACKAGE_DIR = debs
THEOS_LDID_FLAGS = -S

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	@echo "Respringing device..."
	@killall -9 SpringBoard 2>/dev/null || true

before-package::
	@echo "Building package version $(PACKAGE_VERSION)..."
	@echo "Target: iOS 17.0+ (rootless)"
