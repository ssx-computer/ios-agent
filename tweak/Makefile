# RootHide（rootless）: 用装在 /var/jb 下的 Theos 构建 → make THEOS=/var/jb/theos package
# Dopamine（rootful）:  标准 Theos → make package
# SDK 14.5（theos/sdks 自带）：对 iOS 15–18 向前兼容；私有 API 全部动态查找
TARGET := iphone:clang:14.5:14.5
ARCHS := arm64

# Tweak（手脚）
IOSAGENT_FILES := Tweak.xm
IOSAGENT_CFLAGS := -fobjc-arc -Wno-deprecated-declarations

# 本机 agent 核心（可执行文件，与 Tweak 打进同一个 .deb）
iosagentd_FILES := iosagentd.m
iosagentd_INSTALL_PATH := /usr/bin
iosagentd_CFLAGS := -fobjc-arc
iosagentd_LDFLAGS += -lcurl

include $(THEOS)/makefiles/common.mk
