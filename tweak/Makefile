# RootHide（rootless）: 用装在 /var/jb 下的 Theos 构建 → make THEOS=/var/jb/theos package
# Dopamine（rootful）:  标准 Theos → make package
# SDK 14.5（theos/sdks 自带）：对 iOS 15–18 向前兼容；私有 API 全部动态查找
TARGET := iphone:clang:14.5:14.5
ARCHS := arm64
GO_EASY_ON_ME = 1

# Tweak（手脚）
TWEAK_NAME = iosagent
iosagent_FILES = Tweak.xm
iosagent_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

# 本机 agent 核心（tool 可执行文件，默认安装到 /usr/bin，与 Tweak 同一个 .deb）
TOOL_NAME = iosagentd
iosagentd_FILES = iosagentd.m
iosagentd_CFLAGS = -fobjc-arc
iosagentd_LDFLAGS = -lcurl

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/tweak.mk
include $(THEOS)/makefiles/tool.mk
