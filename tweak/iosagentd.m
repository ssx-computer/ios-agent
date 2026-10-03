/*
 * iosagentd — 纯 iOS 本地 Agent 核心（Obj-C + libcurl，无外部运行时）
 * 由 Theos 与 Tweak 一同编译、打进同一个 .deb；SpringBoard 注入端自动拉起
 * （RootHide / Dopamine 通用；停止：touch /private/tmp/iosagentd.stop）。
 *
 * 用法：
 *   iosagentd "打开设置，把蓝牙关掉"     单目标执行
 *   iosagentd --repl                     交互式（终端 App 里跑）
 *   iosagentd --daemon                   守护模式：监视 /private/tmp/iosagent_goals.jsonl
 *   iosagentd --setup                    生成配置模板 /var/mobile/Library/iosagent.json
 *   iosagentd --status                   打印状态
 *
 * 工具（外部模型 function calling）：
 *   tap / swipe / type / ui_tree / open_app / recent_notifs / finish
 *     —— 屏幕通道：经 127.0.0.1 TCP 调 Tweak（端口见 /private/tmp/iosagent_port_*）
 *   shell —— 本地 zsh（/var/jb/usr/bin/zsh → /usr/bin/zsh → /bin/zsh → /bin/sh），
 *            网页访问（需 apt install curl）、文件创建/修改、apt 包管理…
 *   terminal_send —— 在屏幕终端 App 里发一条命令
 */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <dlfcn.h>

/* jbroot 自定位（纯 C，无 roothide.h 依赖，三种环境通用）：
   Tool(可执行)：dladdr 自己 → <jbroot>/usr/bin/iosagentd → 提取 jbroot。
   rootful 时为空串；rootless=/var/jb；roothide=随机 jbroot。 */
static NSString *g_jbRoot = nil;

static NSString *detectJbRoot(void) {
    if (g_jbRoot) return g_jbRoot;
    NSFileManager *fm = [NSFileManager defaultManager];
    Dl_info info;
    if (dladdr((const void *)&detectJbRoot, &info) && info.dli_fname) {
        NSString *selfPath = [NSString stringWithUTF8String:info.dli_fname];
        NSRange ub = [selfPath rangeOfString:@"/usr/bin/"];
        NSRange le = [selfPath rangeOfString:@"/usr/libexec/"];
        NSRange ms = [selfPath rangeOfString:@"/Library/MobileSubstrate/"];
        NSString *root = nil;
        if (ub.location != NSNotFound)      root = [selfPath substringToIndex:ub.location];
        else if (le.location != NSNotFound) root = [selfPath substringToIndex:le.location];
        else if (ms.location != NSNotFound) root = [selfPath substringToIndex:ms.location];
        if (root.length > 1) { g_jbRoot = root; return root; }
    }
    if ([fm fileExistsAtPath:@"/var/jb"]) { g_jbRoot = @"/var/jb"; return g_jbRoot; }
    g_jbRoot = @"";
    return g_jbRoot;
}

static NSString *jbPath(const char *rel) {
    NSString *root = detectJbRoot();
    NSString *relS = [NSString stringWithUTF8String:rel];
    if (root.length == 0) return relS;
    return [root stringByAppendingString:relS];
}

#define GOAL_FILE  @"/private/tmp/iosagent_goals.jsonl"
#define RESULT_FILE @"/private/tmp/iosagent_results.jsonl"
#define STOP_FILE  @"/private/tmp/iosagentd.stop"
#define OFFSET_FILE @"/private/tmp/iosagentd.offset"

/* 配置文件候选路径（按序找第一个可用的；IAGENT_CFG 环境变量优先） */
static NSString *g_cfgPath = nil;   /* 实际使用/生成的配置路径 */
static NSString *g_setupErr = nil;  /* --setup 失败时的最后一个错误 */

static NSArray *configCandidates(void) {
    NSMutableArray *a = [NSMutableArray array];
    const char *e = getenv("IAGENT_CFG");
    if (e && *e) [a addObject:[NSString stringWithUTF8String:e]];
    [a addObject:@"/var/mobile/Library/iosagent.json"];
    [a addObject:jbPath("/etc/iosagent.json")];
    [a addObject:@"/private/tmp/iosagent.json"]; /* 沙盒/权限受限时的兑底（重启丢失） */
    return a;
}

static char *g_apiBase = 0, *g_apiKey = 0, *g_model = 0;
static int   g_maxSteps = 40;
static int   g_webPort = 0;      /* 配置里的期望端口，0=默认 80 */
static int   g_webPortLive = 0;  /* 实际监听端口 */
static NSString *g_termBundleId = nil;

static void dlog(const char *fmt, ...) {
    va_list v; va_start(v, fmt);
    fprintf(stderr, "[iosagentd] ");
    vfprintf(stderr, fmt, v);
    fputc('\n', stderr);
    va_end(v);
}

/* ---------------- 配置 ---------------- */
static NSDictionary *readConfigDict(void) {
    for (NSString *p in configCandidates()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
        NSData *d = [NSData dataWithContentsOfFile:p];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        if ([j isKindOfClass:[NSDictionary class]]) { g_cfgPath = p; return j; }
    }
    return nil;
}

static void loadConfig(void) {
    g_apiBase = strdup("https://example-llm/v1");
    g_apiKey = strdup("");
    g_model = strdup("gpt-4o");
    NSDictionary *j = readConfigDict();
    if (j) {
            if ([j[@"apiBase"] isKindOfClass:[NSString class]]) { free(g_apiBase); g_apiBase = strdup([j[@"apiBase"] UTF8String]); }
            if ([j[@"apiKey"] isKindOfClass:[NSString class]]) { free(g_apiKey); g_apiKey = strdup([j[@"apiKey"] UTF8String]); }
            if ([j[@"model"] isKindOfClass:[NSString class]]) { free(g_model); g_model = strdup([j[@"model"] UTF8String]); }
            if ([j[@"maxSteps"] isKindOfClass:[NSNumber class]]) g_maxSteps = [j[@"maxSteps"] intValue];
            if ([j[@"terminalBundleId"] isKindOfClass:[NSString class]]) g_termBundleId = j[@"terminalBundleId"];
            if ([j[@"webPort"] isKindOfClass:[NSNumber class]]) {
                int p = [j[@"webPort"] intValue];
                if (p > 0 && p < 65536) g_webPort = p;
            }
    }
    const char *e;
    if ((e = getenv("IAGENT_API_BASE"))) { free(g_apiBase); g_apiBase = strdup(e); }
    if ((e = getenv("IAGENT_API_KEY")))  { free(g_apiKey);  g_apiKey  = strdup(e); }
    if ((e = getenv("IAGENT_MODEL")))    { free(g_model);   g_model   = strdup(e); }
}

static BOOL writeConfigTo(NSString *path) {
    NSDictionary *j = @{ @"apiBase": @"https://your-llm-endpoint/v1",
                         @"apiKey": @"sk-填入外部模型的key",
                         @"model": @"gpt-4o",
                         @"maxSteps": @40,
                         @"terminalBundleId": @"换成你终端 App 的 bundleId" };
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:NULL];
    if (!d) { g_setupErr = @"JSON 序列化失败"; return NO; }
    NSError *err = nil;
    if ([d writeToFile:path options:NSDataWritingAtomic error:&err]) { g_cfgPath = path; return YES; }
    g_setupErr = err.localizedDescription ?: @"写入失败（未知原因）";
    return NO;
}

static BOOL writeConfig(void) {
    g_setupErr = nil;
    for (NSString *p in configCandidates()) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:NULL];
        if (writeConfigTo(p)) return YES;
    }
    return NO;
}

/* ---------------- LLM（NSURLSession，OpenAI 兼容 chat/completions + tools） ---------------- */
static NSString *llmCall(NSArray *messages, NSArray *tools, NSString **errMsg) {
    NSDictionary *body = @{ @"model": [NSString stringWithUTF8String:g_model],
                            @"messages": messages,
                            @"tools": tools,
                            @"tool_choice": @"auto",
                            @"temperature": @0.2 };
    NSData *js = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    NSString *urlStr = [NSString stringWithFormat:@"%@/chat/completions",
                        [NSString stringWithUTF8String:g_apiBase]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", [NSString stringWithUTF8String:g_apiKey]]
        forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = js;
    req.timeoutInterval = 180;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *respData = nil;
    __block NSError *respErr = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:
                             [NSURLSessionConfiguration defaultSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            respData = data;
            respErr = error;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_SEC)));
    if (!respData) {
        *errMsg = respErr.localizedDescription ?: @"LLM 请求超时或失败";
        return nil;
    }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:respData options:0 error:NULL];
    if (![j isKindOfClass:[NSDictionary class]]) { *errMsg = @"LLM 返回非 JSON"; return nil; }
    NSArray *choices = j[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || !choices.count) {
        *errMsg = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding] ?: @"LLM 返回异常";
        return nil;
    }
    return choices[0][@"message"];
}

/* ---------------- 屏幕通道（TCP → Tweak） ---------------- */
static NSDictionary *tcpRpc(int port, NSDictionary *cmd, int timeoutSec) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return @{@"ok": @NO, @"err": @"socket"};
    /* 非阻塞 connect + select，实现超时 */
    int flags = fcntl(s, F_GETFL, 0);
    fcntl(s, F_SETFL, flags | O_NONBLOCK);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    inet_aton("127.0.0.1", &a.sin_addr);
    int rc = connect(s, (struct sockaddr *)&a, sizeof a);
    if (rc < 0 && errno == EINPROGRESS) {
        fd_set wfds; FD_ZERO(&wfds); FD_SET(s, &wfds);
        struct timeval tv = { timeoutSec, 0 };
        rc = select(s + 1, 0, &wfds, 0, &tv);
        if (rc > 0) {
            int soerr = 0; socklen_t sl = sizeof soerr;
            getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &sl);
            if (soerr) { rc = -1; } else rc = 0;
        }
    }
    if (rc != 0) { close(s); return @{@"ok": @NO, @"err": @"connect"}; }
    fcntl(s, F_SETFL, flags);

    NSData *js = [NSJSONSerialization dataWithJSONObject:cmd options:0 error:NULL];
    if (!js) { close(s); return @{@"ok": @NO, @"err": @"json"}; }
    size_t off = 0;
    while (off < js.length) {
        ssize_t w = write(s, js.bytes + off, js.length - off);
        if (w <= 0) { close(s); return @{@"ok": @NO, @"err": @"write"}; }
        off += w;
    }
    char nl = '\n';
    (void)write(s, &nl, 1);
    NSMutableData *buf = [NSMutableData data];
    int waited = 0;
    while (waited < timeoutSec * 10) {
        const unsigned char *b = (const unsigned char *)buf.bytes;
        size_t len = buf.length;
        for (size_t i = 0; i < len; i++)
            if (b[i] == '\n') {
                NSData *line = [buf subdataWithRange:NSMakeRange(0, i + 1)];
                return [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            }
        fd_set rfds; FD_ZERO(&rfds); FD_SET(s, &rfds);
        struct timeval tv = { 1, 0 };
        int r = select(s + 1, &rfds, 0, 0, &tv);
        if (r > 0 && FD_ISSET(s, &rfds)) {
            unsigned char tmp[4096];
            ssize_t n = read(s, tmp, sizeof tmp);
            if (n <= 0) break;
            [buf appendBytes:tmp length:(NSUInteger)n];
        } else {
            waited++;
        }
    }
    close(s);
    return @{@"ok": @NO, @"err": @"timeout"};
}

static NSDictionary *portMap(void) {
    NSMutableDictionary *res = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:@"/private/tmp"];
    for (NSString *name in e) {
        if (![name hasPrefix:@"iosagent_port_"]) continue;
        NSString *content = [NSString stringWithContentsOfFile:
            [NSString stringWithFormat:@"/private/tmp/%@", name]
            encoding:NSUTF8StringEncoding error:NULL];
        long port = content ? strtoul([content UTF8String], 0, 10) : 0;
        if (port <= 0) continue;
        res[[name substringFromIndex:@"iosagent_port_".length]] = @(port);
    }
    return res;
}

/* 截图元信息缓存（shot() 写，runGoal 读） */
static NSDictionary *s_global_shotMeta = nil;

static int findPort(BOOL wantSB, BOOL *gotActive) {
    NSDictionary *map = portMap();
    int fallback = -1;
    for (NSString *bid in map) {
        int port = [map[bid] intValue];
        NSDictionary *r = tcpRpc(port, @{@"c": @"ping"}, 2);
        if (![r[@"ok"] boolValue]) continue;
        BOOL sb = [r[@"sb"] boolValue];
        if (wantSB) { if (sb) return port; continue; }
        if ([r[@"active"] boolValue]) { if (gotActive) *gotActive = YES; return port; }
        if (fallback < 0) fallback = port;
    }
    if (!wantSB && fallback >= 0) { if (gotActive) *gotActive = NO; return fallback; }
    return -1;
}

static NSString *shot(void) {
    int port = findPort(NO, 0);
    if (port < 0) return nil;
    NSDictionary *r = tcpRpc(port, @{@"c": @"shot", @"p": @{@"jpeg": @1}}, 15);
    if (![r[@"ok"] boolValue]) return nil;
    NSData *img = [NSData dataWithContentsOfFile:r[@"path"]];
    if (!img) return nil;
    [[NSFileManager defaultManager] removeItemAtPath:r[@"path"] error:NULL];
    NSString *dataUrl = [@"data:image/jpeg;base64," stringByAppendingString:[img base64EncodedStringWithOptions:0]];
    s_global_shotMeta = r;
    return dataUrl;
}

/* ---------------- shell 工具（本地 zsh） ---------------- */
static NSString *findShell(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *zsh = jbPath("/usr/bin/zsh");
    if ([fm fileExistsAtPath:zsh]) return zsh;
    for (NSString *p in @[@"/bin/zsh", @"/bin/sh", @"/bin/bash"])
        if ([fm fileExistsAtPath:p]) return p;
    return @"/bin/sh";
}

static NSDictionary *toolShell(NSDictionary *args) {
    NSString *cmd = args[@"command"] ?: @"";
    char *argv[4] = { (char *)[findShell() UTF8String], "-c", (char *)[cmd UTF8String], 0 };
    char *envp[4] = { "HOME=/var/mobile",
                      "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/usr/sbin",
                      0 };
    posix_spawnattr_t at; posix_spawnattr_init(&at);
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    int outfd[2];
    if (pipe(outfd) != 0) {
        posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at);
        return @{@"ok": @NO, @"err": @"pipe"};
    }
    posix_spawn_file_actions_adddup2(&fa, outfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, outfd[1], STDERR_FILENO);
    pid_t pid = -1;
    int rc = posix_spawnp(&pid, argv[0], &fa, &at, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    if (rc != 0) { close(outfd[0]); close(outfd[1]); return @{@"ok": @NO, @"err": @(rc)}; }
    close(outfd[0]);
    int timeoutSec = [args[@"timeoutSec"] intValue];
    if (timeoutSec <= 0 || timeoutSec > 120) timeoutSec = 30;
    NSMutableData *out = [NSMutableData data];
    unsigned char buf[4096];
    int status = 0, waited = 0;
    while (1) {
        int wstat = 0;
        if (waitpid(pid, &wstat, WNOHANG) == pid) { status = wstat; }
        fd_set rfds; FD_ZERO(&rfds); FD_SET(outfd[1], &rfds);
        struct timeval tv = { 0, 200 * 1000 };
        int r = select(outfd[1] + 1, &rfds, 0, 0, &tv);
        if (r > 0 && FD_ISSET(outfd[1], &rfds)) {
            ssize_t n = read(outfd[1], buf, sizeof buf);
            if (n > 0) [out appendBytes:buf length:(NSUInteger)n];
            else if (status != 0) break;
        } else if (status != 0) {
            /* 子进程已退出，读尽剩余 */
            while (1) {
                ssize_t n = read(outfd[1], buf, sizeof buf);
                if (n <= 0) break;
                [out appendBytes:buf length:(NSUInteger)n];
            }
            break;
        }
        if (++waited > timeoutSec * 5) { kill(pid, SIGKILL); waitpid(pid, &status, 0); break; }
    }
    close(outfd[1]);
    NSString *o = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
    return @{@"ok": @(WIFEXITED(status) && WEXITSTATUS(status) == 0),
             @"code": @(WIFEXITED(status) ? WEXITSTATUS(status) : -1),
             @"output": o.length > 8000 ? [o substringToIndex:8000] : o};
}

/* ---------------- 工具定义与执行 ---------------- */
static NSArray *toolDefs(void) {
    return @[
      @{ @"type": @"function", @"function": @{
          @"name": @"tap",
          @"description": [NSString stringWithFormat:@"在 iPhone 屏幕指定点单击。坐标单位是 points（非像素），左上角为原点，范围见最近屏幕的 w/h。"],
          @"parameters": @{ @"type": @"object",
                            @"properties": @{ @"x": @{@"type": @"number"}, @"y": @{@"type": @"number"} },
                            @"required": @[@"x", @"y"] } } },
      @{ @"type": @"function", @"function": @{
          @"name": @"swipe",
          @"description": @"从 (x1,y1) 滑到 (x2,y2)，用于滚动/翻页/上滑回桌面。",
          @"parameters": @{ @"type": @"object",
                            @"properties": @{ @"x1": @{@"type": @"number"}, @"y1": @{@"type": @"number"},
                                              @"x2": @{@"type": @"number"}, @"y2": @{@"type": @"number"},
                                              @"ms": @{@"type": @"number"} },
                            @"required": @[@"x1", @"y1", @"x2", @"y2"] } } },
      @{ @"type": @"function", @"function": @{
          @"name": @"type",
          @"description": @"向当前聚焦的输入框键入文字（需先点击聚焦）。",
          @"parameters": @{ @"type": @"object",
                            @"properties": @{ @"text": @{@"type": @"string"} },
                            @"required": @[@"text"] } } },
      @{ @"type": @"function", @"function": @{
          @"name": @"ui_tree",
          @"description": @"获取当前窗口视图树 JSON：[类名,[x,y,w,h],文字?,accessibilityId?,enabled?]，用于精确定位控件。",
          @"parameters": @{ @"type": @"object", @"properties": [NSDictionary dictionary] } } },
      @{ @"type": @"function", @"function": @{
          @"name": @"open_app",
          @"description": @"按 bundleId 打开 App。例：com.apple.Preferences 设置。",
          @"parameters": @{ @"type": @"object",
                            @"properties": @{ @"bundleId": @{@"type": @"string"} },
                            @"required": @[@"bundleId"] } } },
      @{ @"type": @"function", @"function": @{
          @"name": @"shell",
          @"description": [NSString stringWithFormat:@"在本地越狱终端（zsh）执行命令：访问网页（可用 curl，未装可先 apt install curl）、创建/修改文件、apt 包管理、查看日志。rootful 可 sudo，rootless 为 mobile 用户。"],
          @"parameters": @{ @"type": @"object",
                            @"properties": @{ @"command": @{@"type": @"string"},
                                              @"timeoutSec": @{@"type": @"number"} },
                            @"required": @[@"command"] } } },
      @{ @"type": @"function", @"function": @{
          @"name": @"terminal_send",
          @"description": [NSString stringWithFormat:@"在屏幕上的终端 App（%@）里输入并回车一条命令。", g_termBundleId ?: @"<未配置>"],
          @"parameters": @{ @"type": @"object",
                            @"properties": @{ @"line": @{@"type": @"string"} },
                            @"required": @[@"line"] } } },
      @{ @"type": @"function", @"function": @{
          @"name": @"recent_notifs",
          @"description": @"读取手机上最近出现过的通知列表。",
          @"parameters": @{ @"type": @"object", @"properties": [NSDictionary dictionary] } } },
      @{ @"type": @"function", @"function": @{
          @"name": @"finish",
          @"description": @"任务完成（或确定无法完成）时调用，给出最终结论。",
          @"parameters": @{ @"type": @"object",
                            @"properties": @{ @"answer": @{@"type": @"string"} },
                            @"required": @[@"answer"] } } },
    ];
}

static NSDictionary *runTool(NSString *name, NSDictionary *args, NSString **err) {
    @autoreleasepool {
        if ([name isEqualToString:@"tap"] || [name isEqualToString:@"swipe"] ||
            [name isEqualToString:@"type"] || [name isEqualToString:@"ui_tree"]) {
            int port = findPort(NO, 0);
            if (port < 0) { *err = @"未找到前台 App 的 Tweak 端口"; return nil; }
            NSString *c = [name isEqualToString:@"ui_tree"] ? @"ui" : name;
            NSDictionary *r = tcpRpc(port, @{@"c": c, @"p": args ?: [NSDictionary dictionary]}, [name isEqualToString:@"ui_tree"] ? 15 : 10);
            if (![r[@"ok"] boolValue]) { *err = [r[@"err"] description] ?: @"tweak error"; return nil; }
            if ([name isEqualToString:@"ui_tree"]) {
                NSArray *nodes = [r[@"nodes"] isKindOfClass:[NSArray class]] ? r[@"nodes"] : [NSArray array];
                return @{@"nodes": [nodes subarrayWithRange:NSMakeRange(0, MIN(nodes.count, 400))]};
            }
            return r;
        }
        if ([name isEqualToString:@"open_app"]) {
            int port = findPort(YES, 0);
            if (port < 0) { *err = @"未找到 SpringBoard 的 Tweak 端口"; return nil; }
            NSDictionary *r = tcpRpc(port, @{@"c": @"open", @"p": @{@"bundleId": args[@"bundleId"] ?: @""}}, 15);
            if (![r[@"ok"] boolValue]) { *err = r[@"err"] ?: @"open fail"; return nil; }
            return r;
        }
        if ([name isEqualToString:@"shell"]) return toolShell(args);
        if ([name isEqualToString:@"terminal_send"]) {
            if (![g_termBundleId isKindOfClass:[NSString class]] || !g_termBundleId.length) {
                *err = @"terminalBundleId 未配置（编辑 /var/mobile/Library/iosagent.json）"; return nil;
            }
            int sb = findPort(YES, 0);
            if (sb >= 0) {
                (void)tcpRpc(sb, @{@"c": @"open", @"p": @{@"bundleId": g_termBundleId}}, 15);
                usleep(1800 * 1000);
            }
            int port = findPort(NO, 0);
            if (port < 0) { *err = @"未找到终端 App 的 Tweak 端口"; return nil; }
            NSDictionary *r = tcpRpc(port, @{@"c": @"type", @"p": @{@"text": [args[@"line"] ?: @"" stringByAppendingString:@"\n"]}}, 10);
            if (![r[@"ok"] boolValue]) { *err = @"type fail"; return nil; }
            return @{@"sent": args[@"line"]};
        }
        if ([name isEqualToString:@"recent_notifs"]) {
            NSString *txt = [NSString stringWithContentsOfFile:@"/private/tmp/iosagent_notif.jsonl"
                                                      encoding:NSUTF8StringEncoding error:NULL];
            NSArray *lines = txt.length ? [txt componentsSeparatedByString:@"\n"] : [NSArray array];
            NSRange cut = NSMakeRange(MAX(0L, (long)lines.count - 20), lines.count - MAX(0L, (long)lines.count - 20));
            return @{@"notifications": [lines subarrayWithRange:cut]};
        }
        if ([name isEqualToString:@"finish"]) return @{@"done": @YES, @"answer": args[@"answer"] ?: @""};
        *err = [@"unknown tool " stringByAppendingString:name];
        return nil;
    }
}

/* ---------------- 主循环 ---------------- */
static NSString *const SYSTEM =
    @"你通过工具直接操作一台越狱 iPhone（纯本地运行）。两条通道：\n"
    @"A. 屏幕通道：tap/swipe/type/ui_tree/open_app —— 操作图形界面；每次动作后自动附最新屏幕。\n"
    @"B. 终端通道：shell（本地 zsh 执行命令）/ terminal_send（屏幕终端 App 发命令）—— 操作越狱系统、网页、文件。\n"
    @"优先用 shell 完成文件/包管理/服务类任务；需要 UI 交互才用屏幕通道。\n"
    @"屏幕坐标单位是 points 不是 pixels。\n"
    @"连续 3 次同类动作无效就换策略，仍失败则调用 finish 说明原因。\n"
    @"破坏性命令（rm -rf、卸载系统组件、重启）先谨慎执行；任务完成时调用 finish。";

static NSString *runGoal(NSString *goal) {
    NSArray *tools = toolDefs();
    @autoreleasepool {
        NSMutableArray *messages = [NSMutableArray arrayWithObject:
            @{ @"role": @"system", @"content": SYSTEM }];
        NSString *s0 = shot();
        if (!s0) { dlog("首屏截图失败，继续（shell 工具仍可用）"); }
        NSDictionary *meta = s_global_shotMeta ?: [NSDictionary dictionary];
        NSMutableArray *first = [NSMutableArray arrayWithObject:
            @{ @"type": @"text",
               @"text": [NSString stringWithFormat:@"任务：%@ (屏幕 w=%@ h=%@ points; 已注入进程: %@)",
                         goal, meta[@"w"] ?: @"?", meta[@"h"] ?: @"?", [portMap() description]] }];
        if (s0) [first addObject:@{ @"type": @"image_url", @"image_url": @{ @"url": s0 } }];
        [messages addObject:@{ @"role": @"user", @"content": first }];

        for (int step = 1; step <= g_maxSteps; step++) {
            fprintf(stderr, "\n[step %d] LLM...\n", step);
            NSString *err = nil;
            NSDictionary *m = llmCall(messages, tools, &err);
            if (!m) { dlog("LLM 失败: %@", err); return [NSString stringWithFormat:@"LLM 调用失败: %@", err]; }
            NSArray *calls = [m[@"tool_calls"] isKindOfClass:[NSArray class]] ? m[@"tool_calls"] : [NSArray array];
            NSString *content = [m[@"content"] isKindOfClass:[NSString class]] ? m[@"content"] : @"";
            if (content.length && !calls.count) {
                printf("\n=== 结论 ===\n%s\n", [content UTF8String]);
                return content;
            }
            [messages addObject:@{ @"role": @"assistant", @"content": content,
                                   @"tool_calls": calls ?: [NSArray array] }];
            NSMutableArray *results = [NSMutableArray array];
            NSString *finalAnswer = nil;
            for (NSDictionary *tc in calls) {
                NSDictionary *fn = tc[@"function"];
                NSString *name = fn[@"name"];
                NSDictionary *args = [NSDictionary dictionary];
                if ([fn[@"arguments"] isKindOfClass:[NSString class]])
                    args = [NSJSONSerialization JSONObjectWithData:
                            [fn[@"arguments"] dataUsingEncoding:NSUTF8StringEncoding]
                            options:0 error:NULL];
                NSData *argsJ = [NSJSONSerialization dataWithJSONObject:args options:0 error:NULL];
                NSString *argsS = argsJ ? [[NSString alloc] initWithData:argsJ encoding:NSUTF8StringEncoding] : @"{}";
                fprintf(stderr, "[tool] %s %s\n", [name UTF8String], [argsS UTF8String]);
                NSString *terr = nil;
                NSDictionary *out = runTool(name, args, &terr) ?: @{@"ok": @NO, @"error": terr ?: @"?"};
                if ([name isEqualToString:@"finish"] && [out[@"done"] boolValue]) finalAnswer = out[@"answer"];
                NSData *od = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
                NSString *os = [[NSString alloc] initWithData:od encoding:NSUTF8StringEncoding];
                if (os.length > 12000) os = [os substringToIndex:12000];
                [results addObject:@{ @"role": @"tool", @"tool_call_id": tc[@"id"] ?: @"", @"content": os }];
            }
            [messages addObjectsFromArray:results];
            if (finalAnswer) { printf("\n=== 结论 ===\n%s\n", [finalAnswer UTF8String]); return finalAnswer; }
            NSString *s = shot();
            if (s) {
                [messages addObject:@{ @"role": @"user",
                                       @"content": @[
                                        @{ @"type": @"text",
                                           @"text": [NSString stringWithFormat:@"这是执行动作后的当前屏幕 (w=%@ h=%@ points)。",
                                                   s_global_shotMeta[@"w"] ?: @"?", s_global_shotMeta[@"h"] ?: @"?"] },
                                        @{ @"type": @"image_url", @"image_url": @{ @"url": s } } ] }];
            } else {
                [messages addObject:@{ @"role": @"user", @"content":
                                       [NSString stringWithFormat:@"注意：截图失败（Tweak 未就绪或无前台 App？）。shell 工具仍可用。"] }];
            }
        }
        return @"(达到最大步数，停止)";
    }
}

/* ---------------- Web UI（127.0.0.1，默认 80，非 root 自动降 8080） ---------------- */
static NSString *j2s(NSDictionary *o) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:0 error:NULL];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

static NSString *tailLines(NSString *path, int n) {
    NSString *t = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!t.length) return @"";
    NSArray *L = [t componentsSeparatedByString:@"\n"];
    NSUInteger start = L.count > (NSUInteger)n ? L.count - (NSUInteger)n : 0;
    return [[L subarrayWithRange:NSMakeRange(start, L.count - start)] componentsJoinedByString:@"\n"];
}

static NSString *maskKey(NSString *k) {
    if (!k.length) return @"";
    if (k.length <= 6) return @"(已设置)";
    return [NSString stringWithFormat:@"%@...%@", [k substringToIndex:3], [k substringFromIndex:k.length - 2]];
}

static NSDictionary *statusDict(void) {
    NSString *key = [NSString stringWithUTF8String:g_apiKey];
    return @{
      @"pid": @(getpid()),
      @"webPort": @(g_webPortLive),
      @"shell": findShell(),
      @"apiBase": [NSString stringWithUTF8String:g_apiBase],
      @"model": [NSString stringWithUTF8String:g_model],
      @"maxSteps": @(g_maxSteps),
      @"keySet": @(*g_apiKey != 0 && ![key containsString:@"填入"]),
      @"apiKeyMasked": maskKey(key),
      @"terminalBundleId": [g_termBundleId isKindOfClass:[NSString class]] ? g_termBundleId : @"",
      @"stopRequested": @(access([STOP_FILE UTF8String], F_OK) == 0),
      @"tweaks": portMap(),
    };
}

static NSString *htmlPage(void) {
    return @"<!DOCTYPE html>\n<html lang=\"zh\">\n<head>\n<meta charset=\"utf-8\">\n"
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n<title>iOSAgent</title>\n"
      "<style>body{font-family:-apple-system,sans-serif;background:#101014;color:#eee;padding:16px;max-width:720px;margin:auto}\n"
      "h1{font-size:20px}h2{font-size:15px;color:#7fb3ff;margin:18px 0 6px}label{display:block;margin:8px 0 4px;color:#99a}\n"
      "input,textarea{width:100%;box-sizing:border-box;background:#1c1c24;color:#eee;border:1px solid #333;border-radius:8px;padding:8px}\n"
      "button{background:#3b82f6;color:#fff;border:0;border-radius:8px;padding:9px 16px;margin:8px 8px 0 0}\n"
      "pre{background:#000;padding:10px;border-radius:8px;overflow:auto;font-size:12px;white-space:pre-wrap;max-height:260px}\n"
      "#status{font-size:13px;color:#9ab}.warn{color:#f66}\n</style>\n</head>\n<body>\n"
      "<h1>iOSAgent · 本地面板</h1>\n<div id=\"status\">加载中…</div>\n"
      "<h2>下发目标</h2>\n"
      "<textarea id=\"goal\" rows=\"2\" placeholder=\"例如：apt 安装 posinst，然后上滑回桌面并打开 Safari\"></textarea>\n"
      "<button onclick=\"sendGoal()\">运行目标</button>\n"
      "<h2>外部模型配置</h2>\n"
      "<label>apiBase</label><input id=\"apiBase\" placeholder=\"https://.../v1\">\n"
      "<label>apiKey</label><input id=\"apiKey\" type=\"password\" placeholder=\"sk-...\">\n"
      "<label>model</label><input id=\"model\">\n"
      "<label>maxSteps</label><input id=\"maxSteps\" type=\"number\">\n"
      "<label>terminalBundleId</label><input id=\"termBundle\">\n"
      "<button onclick=\"saveConfig()\">保存并即时生效</button>\n"
      "<h2>结果（最近 20 条）</h2><pre id=\"results\">-</pre>\n"
      "<h2>agentd 日志</h2><pre id=\"log\">-</pre>\n"
      "<script>\n"
      "function j(u,o){return fetch(u,o).then(function(r){return r.json()}).catch(function(){return {error:'bad response'}})}\n"
      "function sendGoal(){var g=document.getElementById('goal').value.trim();if(!g)return;\n"
      " j('/api/goal',{method:'POST',headers:{'Content-Type':'text/plain'},body:g})\n"
      " .then(function(r){alert(r.ok?'目标已下发（守护进程 2 秒内自动执行）':'失败: '+JSON.stringify(r));if(r.ok)document.getElementById('goal').value=''});}\n"
      "function saveConfig(){var b={apiBase:document.getElementById('apiBase').value,apiKey:document.getElementById('apiKey').value,\n"
      " model:document.getElementById('model').value,maxSteps:parseInt(document.getElementById('maxSteps').value,10)||40,\n"
      " terminalBundleId:document.getElementById('termBundle').value};\n"
      " j('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)})\n"
      " .then(function(r){alert(r.ok?'配置已保存并即时生效':'失败: '+JSON.stringify(r))})}\n"
      "function tick(){j('/api/status').then(function(s){if(s.error){document.getElementById('status').textContent='连接失败';return}\n"
      " var st='pid '+s.pid+' · web :'+s.webPort+' · shell '+s.shell+' · model '+s.model+' · key '+(s.keySet?'已配置':'<b class=\"warn\">未配置</b>');\n"
      " st+='<br>已注入进程: '+JSON.stringify(s.tweaks);if(s.stopRequested)st+='<br><b class=\"warn\">stop 文件存在，agentd 即将退出</b>';\n"
      " document.getElementById('status').innerHTML=st;var a=document.getElementById('apiBase');\n"
      " if(!a.value){a.value=s.apiBase||'';document.getElementById('model').value=s.model||'';\n"
      " document.getElementById('maxSteps').value=s.maxSteps||40;document.getElementById('termBundle').value=s.terminalBundleId||''}});}\n"
      "j('/api/results').then(function(r){var lines=(r.results||[]).map(function(x){return '· '+x.goal+'\\n  → '+String(x.answer||'').slice(0,200)});\n"
      " document.getElementById('results').textContent=lines.join('\\n')||'(暂无结果)'})\n"
      "j('/api/log').then(function(l){document.getElementById('log').textContent=l.log||'(暂无日志)'})\n"
      "setInterval(function(){tick()},3000);tick();\n"
      "</script>\n</body>\n</html>\n";
}

static void httpReply(int c, int code, const char *reason, const char *ctype, NSString *body) {
    NSData *bd = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSString *h = [NSString stringWithFormat:
        @"HTTP/1.1 %d %s\r\nContent-Type: %s; charset=utf-8\r\nContent-Length: %lu\r\n"
        @"Connection: close\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\n\r\n",
        code, reason, ctype, (unsigned long)bd.length];
    NSData *hd = [h dataUsingEncoding:NSASCIIStringEncoding];
    size_t total = hd.length + bd.length;
    unsigned char *buf = malloc(total);
    if (!buf) { close(c); return; }
    memcpy(buf, hd.bytes, hd.length);
    memcpy(buf + hd.length, bd.bytes, bd.length);
    size_t off = 0;
    while (off < total) {
        ssize_t w = write(c, buf + off, total - off);
        if (w <= 0) break;
        off += w;
    }
    free(buf);
    close(c);
}

static NSArray *resultEntries(void) {
    NSArray *lines = [tailLines(RESULT_FILE, 20) componentsSeparatedByString:@"\n"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in lines) {
        if (!l.length) continue;
        NSData *d = [l dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([o isKindOfClass:[NSDictionary class]]) [out addObject:o];
    }
    return out;
}

static NSArray *goalEntries(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in [tailLines(GOAL_FILE, 20) componentsSeparatedByString:@"\n"]) {
        if (l.length) [out addObject:l];
    }
    return out;
}

static void webHandle(int c) {
    NSMutableData *req = [NSMutableData data];
    int bodyRemain = -1;
    NSUInteger hdrLen = 0;
    int done = 0;
    for (int i = 0; i < 600 && !done; i++) {
        fd_set rfds; FD_ZERO(&rfds); FD_SET(c, &rfds);
        struct timeval tv = { 1, 0 };
        int r = select(c + 1, &rfds, 0, 0, &tv);
        if (r <= 0) continue;
        char buf[8192];
        ssize_t n = read(c, buf, sizeof buf);
        if (n <= 0) break;
        [req appendBytes:buf length:(NSUInteger)n];
        if (req.length > (1024 * 64)) break;
        if (bodyRemain < 0) {
            const unsigned char *b = (const unsigned char *)req.bytes;
            for (NSUInteger k = 4; k + 3 < req.length; k++) {
                if (!memcmp(b + k, "\r\n\r\n", 4)) {
                    hdrLen = k + 4;
                    NSString *hdr = [[NSString alloc] initWithBytes:req.bytes length:k encoding:NSASCIIStringEncoding];
                    NSRange cl = [hdr rangeOfString:@"Content-Length:" options:NSCaseInsensitiveSearch];
                    if (cl.location != NSNotFound) {
                        NSArray *clParts = [[hdr substringFromIndex:NSMaxRange(cl)] componentsSeparatedByString:@"\r"];
                        NSString *cl0 = [(NSString *)[clParts firstObject] copy];
                        bodyRemain = (int)strtol(cl0.UTF8String ?: "0", 0, 10);
                        if (bodyRemain < 0) bodyRemain = 0;
                    } else bodyRemain = 0;
                    break;
                }
            }
        } else if (req.length >= hdrLen + (NSUInteger)bodyRemain) {
            done = 1;
        }
    }
    if (!done || !hdrLen) { close(c); return; }
    NSString *hdr = [[NSString alloc] initWithBytes:req.bytes length:hdrLen encoding:NSASCIIStringEncoding];
    NSString *firstLine = [[hdr componentsSeparatedByString:@"\r\n"] firstObject] ?: @"";
    NSArray *parts = [firstLine componentsSeparatedByString:@" "];
    if (parts.count < 2) { close(c); return; }
    NSString *method = [(NSString *)parts[0] uppercaseString];
    NSString *path = [(NSString *)parts[1] copy];
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) path = [path substringToIndex:q.location];
    path = [(NSString *)path lowercaseString];
    NSData *body = req.length > hdrLen
        ? [req subdataWithRange:NSMakeRange(hdrLen, req.length - hdrLen)] : [NSData data];

    if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"])) {
        httpReply(c, 200, "OK", "text/html", htmlPage());
        return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/status"]) {
        httpReply(c, 200, "OK", "application/json", j2s(statusDict()));
        return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/results"]) {
        httpReply(c, 200, "OK", "application/json", j2s(@{@"results": resultEntries()}));
        return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/goals"]) {
        httpReply(c, 200, "OK", "application/json", j2s(@{@"goals": goalEntries()}));
        return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/log"]) {
        httpReply(c, 200, "OK", "application/json", j2s(@{@"log": tailLines(@"/private/tmp/iosagentd.log", 60)}));
        return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/config"]) {
        httpReply(c, 200, "OK", "application/json", j2s(statusDict()));
        return;
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/goal"]) {
        NSString *g = nil;
        NSDictionary *jb = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        if ([jb isKindOfClass:[NSDictionary class]] && [jb[@"goal"] isKindOfClass:[NSString class]]) g = jb[@"goal"];
        else if (body.length) g = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        g = [g stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!g.length) { httpReply(c, 400, "Bad Request", "application/json", @"{\"ok\":false}\n"); return; }
        if (g.length > 500) g = [g substringToIndex:500];
        NSString *line = [g stringByAppendingString:@"\n"];
        FILE *gf = fopen([GOAL_FILE UTF8String], "a");
        if (gf) {
            fwrite([line dataUsingEncoding:NSUTF8StringEncoding].bytes, 1, [line dataUsingEncoding:NSUTF8StringEncoding].length, gf);
            fclose(gf);
        } else {
            [line writeToFile:GOAL_FILE atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        httpReply(c, 200, "OK", "application/json", j2s(@{@"ok": @YES, @"queued": g}));
        return;
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/config"]) {
        NSDictionary *jb = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        if (![jb isKindOfClass:[NSDictionary class]]) { httpReply(c, 400, "Bad Request", "application/json", @"{\"ok\":false}\n"); return; }
        NSMutableDictionary *cur = [NSMutableDictionary dictionary];
        NSData *cd = g_cfgPath ? [NSData dataWithContentsOfFile:g_cfgPath] : nil;
        if (cd) {
            NSDictionary *c = [NSJSONSerialization JSONObjectWithData:cd options:0 error:NULL];
            if ([c isKindOfClass:[NSDictionary class]]) [cur addEntriesFromDictionary:c];
        }
        for (NSString *k in @[@"apiBase", @"apiKey", @"model", @"maxSteps", @"terminalBundleId", @"webPort"]) {
            if ([jb[k] isKindOfClass:[NSString class]] || [jb[k] isKindOfClass:[NSNumber class]])
                cur[k] = jb[k];
        }
        NSData *out = [NSJSONSerialization dataWithJSONObject:cur options:NSJSONWritingPrettyPrinted error:NULL];
        if (![out writeToFile:(g_cfgPath ?: @"/var/mobile/Library/iosagent.json") options:NSDataWritingAtomic error:NULL]) { httpReply(c, 500, "Error", "application/json", @"{\"ok\":false}\n"); return; }
        loadConfig(); /* 即时生效 */
        httpReply(c, 200, "OK", "application/json", j2s(@{@"ok": @YES}));
        return;
    }
    httpReply(c, 404, "Not Found", "application/json", @"{\"error\":\"not found\"}\n");
}

static void webStart(void) {
    int want = g_webPort > 0 ? g_webPort : 80;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return;
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    inet_aton("127.0.0.1", &a.sin_addr);
    a.sin_port = htons((unsigned short)want);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) {
        if (errno == EACCES || errno == EPERM) {
            a.sin_port = htons(8080); /* 非 root 绑 80 被拒（iOS 限制）→ 降级 */
            if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) {
                dlog("web: bind fail: %s", strerror(errno));
                close(s);
                return;
            }
            g_webPortLive = 8080;
        } else {
            dlog("web: bind :%d fail: %s（可能已有实例在运行）", want, strerror(errno));
            close(s);
            return;
        }
    } else {
        g_webPortLive = want;
    }
    if (listen(s, 16) < 0) { close(s); return; }
    [[NSString stringWithFormat:@"%d\n", g_webPortLive] writeToFile:@"/private/tmp/iosagentd.port" atomically:YES];
    dlog("web: http://127.0.0.1:%d （手机 Safari 打开即可）", g_webPortLive);
    dispatch_async(dispatch_queue_create("iosagentd.web", DISPATCH_QUEUE_SERIAL), ^{
        while (1) {
            int c = accept(s, NULL, NULL);
            if (c < 0) { if (errno == EINTR) continue; break; }
            webHandle(c);
        }
    });
}

static void appendResult(NSString *goal, NSString *answer) {
    NSDictionary *rec = @{ @"ts": @((long)[[NSDate date] timeIntervalSince1970]),
                           @"goal": goal, @"answer": answer };
    NSData *d = [NSJSONSerialization dataWithJSONObject:rec options:0 error:NULL];
    if (!d) return;
    NSData *nl = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    FILE *f = fopen([RESULT_FILE UTF8String], "a");
    if (!f) return;
    fwrite(d.bytes, 1, d.length, f);
    fwrite(nl.bytes, 1, nl.length, f);
    fclose(f);
}

/* ---------------- 各运行模式 ---------------- */
static void daemonMode(void) {
    dlog("daemon 模式：监视 %s（停止: touch %s）", [GOAL_FILE UTF8String], [STOP_FILE UTF8String]);
    long offset = 0;
    @autoreleasepool {
        NSString *txt = [NSString stringWithContentsOfFile:OFFSET_FILE encoding:NSUTF8StringEncoding error:NULL];
        offset = txt ? (long)strtoul([txt UTF8String], 0, 10) : 0;
    }
    while (1) {
        if (access([STOP_FILE UTF8String], F_OK) == 0) { dlog("检测到 stop 文件，退出"); exit(0); }
        @autoreleasepool {
            NSData *all = [NSData dataWithContentsOfFile:GOAL_FILE];
            if (all && all.length > offset) {
                NSString *full = [[NSString alloc] initWithData:all encoding:NSUTF8StringEncoding];
                NSString *newPart = [full substringFromIndex:offset];
                for (NSString *line0 in [newPart componentsSeparatedByString:@"\n"]) {
                    NSString *line = [line0 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!line.length) continue;
                    fprintf(stderr, "\n[goal] %s\n", [line UTF8String]);
                    NSString *answer = runGoal(line);
                    appendResult(line, answer);
                }
                offset = all.length;
                NSData *od2 = [[NSString stringWithFormat:@"%ld", (long)offset]
                               dataUsingEncoding:NSUTF8StringEncoding];
                [od2 writeToFile:OFFSET_FILE atomically:YES];
            }
        }
        sleep(2);
    }
}

static void replMode(void) {
    printf("iosagentd REPL（Ctrl-D 退出）。每行一个目标。\n");
    char buf[4096];
    while (printf("goal> "), fflush(stdout), fgets(buf, sizeof buf, stdin)) {
        char *nl = strchr(buf, '\n');
        if (nl) *nl = 0;
        if (buf[0] == 0) continue;
        runGoal([NSString stringWithUTF8String:buf]);
    }
}

static void status(void) {
    printf("iosagentd 状态：\n");
    printf("  配置: %s\n", g_cfgPath ? [g_cfgPath UTF8String] : "(未找到，先运行 iosagentd --setup)");
    NSFileManager *fm = [NSFileManager defaultManager];
    printf("  目标文件: %s (%s)\n", [GOAL_FILE UTF8String], [fm fileExistsAtPath:GOAL_FILE] ? "存在" : "不存在");
    printf("  结果文件: %s\n", [RESULT_FILE UTF8String]);
    printf("  shell: %s\n", [findShell() UTF8String]);
    printf("  web: 127.0.0.1:%d（实际端口也写在 /private/tmp/iosagentd.port）\n", g_webPortLive);
    printf("  apiBase: %s\n  model: %s\n  terminal: %s\n",
           g_apiBase, g_model, g_termBundleId.UTF8String ?: "(未配置)");
    printf("  Tweak 端口注册: %s\n", [portMap() description].UTF8String);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--setup")) {
            if (writeConfig()) {
                printf("已生成配置模板: %s\n填入 apiBase/apiKey/model 后保存；或用 Web 面板（127.0.0.1:80/8080）在线改。\n",
                       [g_cfgPath UTF8String]);
            } else {
                fprintf(stderr, "生成失败: %s\n", g_setupErr ? [g_setupErr UTF8String] : "未知");
                fprintf(stderr, "若为 Operation not permitted = 当前进程沙盒限制，两个替代方案：\n");
                fprintf(stderr, "  1) 在 Web 面板（127.0.0.1:80/8080）里直接填配置（保存即时生效，无需文件权限）\n");
                fprintf(stderr, "  2) 用环境变量（优先级最高）：\n");
                fprintf(stderr, "     export IAGENT_API_BASE=https://.../v1 IAGENT_API_KEY=sk-... IAGENT_MODEL=gpt-4o\n");
            }
            return 0;
        }
        loadConfig();
        if (!g_apiKey || !*g_apiKey || strstr(g_apiKey, "填入")) {
            fprintf(stderr, "请先配置：iosagentd --setup 然后编辑 /var/mobile/Library/iosagent.json\n");
            return 1;
        }
        if (argc > 1 && !strcmp(argv[1], "--status")) { status(); return 0; }
        webStart(); /* 已有实例占用端口时静默跳过，不致命 */
        if (argc > 1 && !strcmp(argv[1], "--daemon")) { daemonMode(); return 0; }
        if (argc > 1 && !strcmp(argv[1], "--repl"))  { replMode(); return 0; }
        if (argc > 2) {
            NSMutableString *goal = [NSMutableString string];
            for (int i = 2; i < argc; i++) { if (i > 2) [goal appendString:@" "]; [goal appendString:[NSString stringWithUTF8String:argv[i]]]; }
            runGoal(goal);
            return 0;
        }
        printf("用法: iosagentd \"目标\" | iosagentd --repl | iosagentd --daemon | iosagentd --setup | iosagentd --status\n");
        return 0;
    }
}
