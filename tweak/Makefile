# RootHide（rootless）: 用装在 /var/jb 下的 Theos 构建 → make THEOS=/var/jb/theos package
# Dopamine（rootful）:  标准 Theos → make package
TARGET := iphone:clang:18.0:18.0
ARCHS := arm64

# Tweak（手脚）
IOSAGENT_FILES := Tweak.xm
IOSAGENT_CFLAGS := -fobjc-arc -Wno-deprecated-declarations

# 本机 agent 核心（可执行文件，与 Tweak 打进同一个 .deb）
iosagentd_FILES := iosagentd.m
iosagentd_INSTALL_PATH := /usr/bin
iosagentd_CFLAGS := -fobjc-arc
iosagentd_LDFLAGS += -lcurl
LIBRARY_PATH += /usr

include $(THEOS)/makefiles/
