# 打包 scheme：rootless（Dopamine / palera1n rootless）为默认；
# RootHide 用 THEOS_PACKAGE_SCHEME=roothide 构建（配合 roothide/theos）。
# 代码内所有 jb 文件路径走 jbPath()（roothide.h 的 jbroot() / /var/jb 探测），
# 一份源码同时出 rootless / roothide / rootful 包。
THEOS_PACKAGE_SCHEME ?= rootless

TARGET := iphone:clang:14.5:14.5
ARCHS := arm64
GO_EASY_ON_ME = 1

# Tweak（手脚）
TWEAK_NAME = iosagent
iosagent_FILES = Tweak.xm
iosagent_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

# 本机 agent 核心（tool 可执行文件，与 Tweak 同一个 .deb）
TOOL_NAME = iosagentd
iosagentd_FILES = iosagentd.m
iosagentd_CFLAGS = -fobjc-arc

# theos 无 XXX_ENTITLEMENTS 变量，entitlements 通过 ldid 的 -S<file> 嵌入
# （platform-application/no-sandbox 等：rootless/roothide 上沙盒豁免必需）
TARGET_CODESIGN_FLAGS = -Siosagentd.entitlements

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/tweak.mk
include $(THEOS)/makefiles/tool.mk
