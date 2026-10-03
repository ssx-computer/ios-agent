# iOSAgent — 纯 iOS 本地 AI Agent，单 .deb 越狱插件（RootHide / Dopamine）

一个 `.deb` 装完，手机上多两个东西：

1. **Tweak**（注入所有 App + SpringBoard）：unix/loopback socket 服务，
   合成触摸 / 输入 / 截图 / 视图树 / 启动 App / 通知捕获；SpringBoard 端
   自动拉起并守护 agent 进程（掉线 30s 内自动复活，用户可停）。
2. **`iosagentd`**（`/usr/bin/iosagentd`，Obj-C + 系统 libcurl，**零外部运行时**）：
   Agent 核心，纯本地运行，模型走**外部 LLM API**（OpenAI 兼容，支持
   视觉 + function calling）。工具两条腿：
   - `shell`：直接调 **本地 zsh**（`/var/jb/usr/bin/zsh` → `/usr/bin/zsh`
     → `/bin/zsh` → `/bin/sh`）—— 访问网页（`apt install curl` 后可
     `curl` 任意网址）、创建/修改文件、apt 包管理、看日志……
   - 屏幕通道：`tap/swipe/type/ui_tree/open_app` 经 127.0.0.1 loopback
     TCP 调 Tweak；`terminal_send` 在屏幕终端 App 里发命令；
     `recent_notifs` 读通知；`finish` 收束。

**无需电脑**：手机上开一个终端 App（nsshell / iSSH / iSH / 越狱 Terminal）
跑 `iosagentd --repl`，或往目标文件里写一行目标，agent 全自动执行。

## 目录

```
ios-agent/
├── tweak/               # 全部源文件（Tweak + agentd 同一工程、同一个 .deb）
│   ├── Tweak.xm         #   手脚：socket 服务 + 触摸注入 + SB 端 agentd 守护
│   ├── iosagentd.m      #   大脑：LLM 循环(libcurl) + zsh shell + 屏幕通道
│   ├── Makefile
│   └── control
├── host/                # 可选：宿主机版（外部电脑跑，ssh 控制手机，见文末）
├── agent/               # 可选：on-device Node 版（被 iosagentd 取代，留作参考）
└── launch/              # 可选：launchd 常驻（默认不需要，SB 端自动守护）
```

## 一、RootHide / Dopamine 适配

| | Dopamine（rootful，iOS 14–16） | RootHide（rootless，iOS 15.5–18） |
|---|---|---|
| 构建 | 标准 Theos，`make package` | 装在 `/var/jb` 下的 Theos：`make THEOS=/var/jb/theos package`（路径自动加 `/var/jb` 前缀） |
| Makefile `TARGET` | 按设备系统，如 `iphone:clang:17.5:15.5` | 按设备系统，如 `iphone:clang:18.2:18.0` |
| 二进制落点 | `/usr/bin/iosagentd` | `/var/jb/usr/bin/iosagentd` |
| zsh | `/usr/bin/zsh` | `/var/jb/usr/bin/zsh`（都装 `zsh` 包；找不到自动退回 `/bin/sh`） |
| shell 权限 | `sudo` 可提权 | 无 root，`mobile` 用户（agent 循环里已提示模型） |
| 停止 agent | `touch /private/tmp/iosagentd.stop` | 同左（两种越狱一致） |

Tweak 的 agentd 查找逻辑自动兼容两种落点（`/usr/bin` → `/var/jb/usr/bin`
→ `/private/var/jb/usr/bin` 依次探测），守护循环 30s 一跳。

## 二、编译 & 安装（一步出一个 .deb）

```sh
cd tweak
make package            # RootHide: make THEOS=/var/jb/theos package
# 产出 com.ssx.iosagent_0.1.0_iphoneos-arm64.deb（含 dylib + /usr/bin/iosagentd）
```

把 .deb 拖进 Sileo/Zebra 安装（或 `apt install ./*.deb`），**重启设备**。
验证（`log stream` / Console，过滤 `iosagent`）：

```
iosagent: tcp listening 127.0.0.1:22xxx (pid …)      ← 每个进程一行
iosagent: spawned iosagentd pid …                    ← SB 自动拉起大脑
```

## 三、配置外部模型

任意终端 App（或 ssh）里：

```sh
iosagentd --setup        # 生成 /var/mobile/Library/iosagent.json 模板
# 编辑该文件（vi/nano），填入：
#   apiBase: 你的 OpenAI 兼容端点（GPT-4o / Claude 网关 / 自建 vLLM）
#   apiKey, model, maxSteps, terminalBundleId（终端 App 的 bundleId，
#            可从 ls /private/tmp/iosagent_port_* 的文件名看到）
iosagentd --status       # 检查配置、zsh 路径、Tweak 端口注册表
```

也可用环境变量覆盖：`IAGENT_API_BASE / IAGENT_API_KEY / IAGENT_MODEL`。

## 四、使用（无电脑）

```sh
# 交互式（推荐）：
iosagentd --repl
goal> apt 安装 posinst，然后上滑回桌面，打开 Safari

# 或丢目标进队列（agentd 守护进程 2s 内自动捡拾，结果写
# /private/tmp/iosagent_results.jsonl）：
echo "给最新收到的通知回个消息：好的" >> /private/tmp/iosagent_goals.jsonl

# 常用 shell 类目标示例：
iosagentd "用 curl 抓 https://example.com 存到 /var/mobile/tmp/idx.html，提取标题"
iosagentd "创建 /var/mobile/notes/今天.md，写入三条待办"
```

停止/重启 agent：`touch /private/tmp/iosagentd.stop`（停）；
`rm /private/tmp/iosagentd.stop && kill $(cat /private/tmp/iosagentd.pid)`（SB 会在 30s 内自动重新拉起）。
日志：`/private/tmp/iosagentd.log`。

## 五、触摸点不生效时的排坑

1. `log stream | grep iosagent` 看有无 `sel missing`；
2. 确认目标 App 已注入（`ls /private/tmp/iosagent_port_*` 有它的端口文件）；
3. `type` 有效而 `tap` 无效 → `Tweak.xm` 顶部四个 `kSel*` 私有符号按你的
   iOS 版本用 `classes -json`（class-dump）核对；
4. 最后兜底：`IOHIDEvent` 事件通道重写 `firePhase`。

已知边界：锁屏 PIN / Secure Input 无法注入（系统保护）；截图不含状态栏。

## 六、安全

- Tweak 只监听 unix socket（0600）与 127.0.0.1 loopback TCP，**不出网卡**；
- 唯一出网是 LLM API；`shell` 工具权限 = 手机当前用户权限（rootless 即
  mobile），破坏性命令由系统提示词约束，但 **API key 泄漏 = 手机可被远程
  操作**，key 请只给可信端点；
- 想收敛面：终端里 `touch /private/tmp/iosagentd.stop` 随时停。

## 七、可选扩展

- **`host/`（宿主机版）**：不想在手机跑循环时，`host/agent.js`（Node +
  ssh2）在电脑上跑大脑，经 ssh 隧道打同一套 Tweak 端口 + 直接 ssh shell，
  工具集相同。
- **`agent/`（on-device Node 版）**：`iosagentd` 的 JS 等价物，留作参考/
  对照调试。
- **Pi Agent 本体**：把 `iosagentd.m` 里 9 个工具包成 pi-mono extension
  自定义工具（复制 `host/agent.js` 的通道逻辑即可），Pi 跑在 Mac 上、
  手伸到 iPhone。
