TARGET := iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XPlus
XPlus_FILES = Tweak.x
XPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
XPlus_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
