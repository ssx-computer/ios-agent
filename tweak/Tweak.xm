/*
 * IOSAgent — 越狱 iOS 上的 AI Agent 手脚
 * 每个被注入的进程（所有 App + SpringBoard）在 /private/tmp/iosagent_<bundleid>.sock
 * 上开一个 unix socket，接受一行一条的 JSON 命令：
 *   {"c":"ping"}                     -> {ok,bundle,sb,active}
 *   {"c":"shot","p":{"jpeg":1}}      -> {ok,path,scale,w,h}
 *   {"c":"tap","p":{"x":10,"y":20}}  （单位：points，左上角原点）
 *   {"c":"swipe","p":{"x1","y1","x2","y2","ms":300}}
 *   {"c":"type","p":{"text":"..."}}
 *   {"c":"ui"}                       -> {ok,nodes:[[cls,[x,y,w,h],text?,ai?,en?],...]}
 *   {"c":"open","p":{"bundleId":...}}（仅 SpringBoard 进程）
 * 通知捕获：hook UNUserNotificationCenter，追加写 /private/tmp/iosagent_notif.jsonl
 * 另起一个 127.0.0.1 TCP 监听（端口 = 22100 + fnv1a(bundleid)%999），
 * 并把端口写到 /private/tmp/iosagent_port_<bundleid>，供外部宿主机 agent
 * 经 ssh -L 转发后直连（手机无需安装 Node）。
 *
 * 注意：合成触摸用到的 UITouch/UIEvent 私有符号在 iOS 版本间可能改名，
 * 全部集中在 kSel* 常量里，用 class-dump / `classes -json` 核对后只需改这里。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <stdio.h>
#import <unistd.h>
#import <sys/un.h>
#import <string.h>
#import <netinet/in.h>
#import <netdb.h>
#import <errno.h>
#import <spawn.h>
#import <fcntl.h>

static char gSock[160] = {0};
static BOOL gSB = NO;

static void iagentLog(const char *fmt, ...) {
    char buf[1024];
    va_list v; va_start(v, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, v);
    va_end(v);
    (void)write(2, buf, n > 0 ? (size_t)n : 0);
}

/* ------------------------------------------------------------------ */
static BOOL isSpringBoard(void) {
    return [[[NSProcessInfo processInfo] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

static UIWindow *keyWin(void) {
    @try {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        if (!w) w = [UIApplication sharedApplication].windows.firstObject;
        return w;
    } @catch (id e) { return nil; }
}

/* 稳定的 FNV-1a，用于给每个 bundleid 分配固定的 loopback 端口 */
static unsigned fnv1a(const char *s) {
    unsigned h = 2166136261u;
    while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; }
    return h;
}

static int gPort = 0;
static void makePort(void) {
    NSString *bid = [[NSProcessInfo processInfo] bundleIdentifier] ?: @"unknown";
    bid = [bid stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    if ([bid length] > 40) bid = [bid substringToIndex:40];
    gPort = 22100 + (int)(fnv1a([bid UTF8String]) % 999);
    /* 注册文件：外部 agent 经 ssh `cat` 即可拿到 端口↔App 映射 */
    NSString *f = [NSString stringWithFormat:@"/private/tmp/iosagent_port_%s", [bid UTF8String]];
    [[NSString stringWithFormat:@"%d\n", gPort] writeToFile:f atomically:YES
        encoding:NSUTF8StringEncoding error:nil];
}

static void makeSockPath(void) {
    NSString *bid = [[NSProcessInfo processInfo] bundleIdentifier] ?: @"unknown";
    bid = [bid stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    if ([bid length] > 40) bid = [bid substringToIndex:40];
    snprintf(gSock, sizeof gSock, "/private/tmp/iosagent_%s.sock", [bid UTF8String]);
    unlink(gSock);
}

/* ------------------------------------------------------------------ */
#pragma mark - 触摸注入（私有需要 class-dump 核对的符号都在这几行）

static const char *kSelTouchInit =
    "initWithWindow:timestamp:touchType:windowLocation:previousLocation:isFirstTouch:";
static const char *kSelEventInit =
    "initWithType:subType:timestamp:window:sender:";
static const char *kSelEventPhase =
    "eventWithPhase:locationInWindow:timestampInEvent:";
static const char *kSelEventTouches = "eventWithTouches:";
static const char *kSelTouchSetPhase = "setPhase:";

static id makeTouch(UIWindow *win, CGPoint p, UITouchType type, UITouchPhase phase) {
    @try {
        Class TC = NSClassFromString(@"UITouch");
        SEL sel = NSSelectorFromString(kSelTouchInit);
        if (!TC || ![TC respondsToSelector:sel]) { iagentLog("iosagent: UITouch init sel missing\n"); return nil; }
        NSMethodSignature *sig = [TC methodSignatureForSelector:sel];
        NSInvocation *iv = [NSInvocation invocationWithMethodSignature:sig];
        [iv setTarget:TC];
        [iv setSelector:sel];
        [iv setArgument:&win atIndex:2];
        double ts = [NSProcessInfo processInfo].systemUptime;
        [iv setArgument:&ts atIndex:5];
        unsigned int tt = (unsigned int)type;
        [iv setArgument:&tt atIndex:6];
        [iv setArgument:&p atIndex:7];
        [iv setArgument:&p atIndex:8];
        BOOL first = YES;
        [iv setArgument:&first atIndex:9];
        [iv invoke];
        id touch = [iv returnValue];
        if (touch && phase != UITouchPhaseBegan) {
            SEL sp = NSSelectorFromString(kSelTouchSetPhase);
            if ([touch respondsToSelector:sp])
                [touch setValue:@((unsigned int)phase) forKey:@"phase"];
        }
        return touch;
    } @catch (id e) { iagentLog("iosagent: makeTouch err %s\n", [e.reason UTF8String] ?: "?"); return nil; }
}

static UIEvent *makeBaseEvent(UIWindow *win) {
    @try {
        Class EC = NSClassFromString(@"UIEvent");
        SEL sel = NSSelectorFromString(kSelEventInit);
        if (!EC || ![EC respondsToSelector:sel]) { iagentLog("iosagent: UIEvent init sel missing\n"); return nil; }
        NSMethodSignature *sig = [EC methodSignatureForSelector:sel];
        NSInvocation *iv = [NSInvocation invocationWithMethodSignature:sig];
        [iv setTarget:EC];
        [iv setSelector:sel];
        unsigned int et = UIEventTypeTouches, sub = UIEventSubtypeTouches;
        double ts = [NSProcessInfo processInfo].systemUptime;
        [iv setArgument:&et atIndex:2];
        [iv setArgument:&sub atIndex:3];
        [iv setArgument:&ts atIndex:4];
        [iv setArgument:&win atIndex:5];
        id nilObj = nil;
        [iv setArgument:&nilObj atIndex:6];
        [iv invoke];
        return [iv returnValue];
    } @catch (id e) { iagentLog("iosagent: makeBaseEvent err %s\n", [e.reason UTF8String] ?: "?"); return nil; }
}

static void firePhase(UIWindow *win, UITouchPhase phase, CGPoint p, UITouchType type) {
    @try {
        id touch = makeTouch(win, p, type, phase);
        UIEvent *ev = makeBaseEvent(win);
        if (!touch || !ev) return;
        UIEvent *phaseEv = ev;
        SEL s1 = NSSelectorFromString(kSelEventPhase);
        if ([ev respondsToSelector:s1]) {
            @try {
                NSInvocation *iv = [NSInvocation invocationWithMethodSignature:[ev methodSignatureForSelector:s1]];
                [iv setTarget:ev];
                [iv setSelector:s1];
                unsigned int ph = (unsigned int)phase;
                [iv setArgument:&ph atIndex:2];
                [iv setArgument:&p atIndex:3];
                double ts = [NSProcessInfo processInfo].systemUptime;
                [iv setArgument:&ts atIndex:4];
                [iv invoke];
                phaseEv = [iv returnValue];
            } @catch (id e) {}
        } else {
            SEL s2 = NSSelectorFromString(kSelEventTouches);
            if ([ev respondsToSelector:s2]) {
                @try {
                    NSSet *set = [NSSet setWithObject:touch];
                    NSInvocation *iv = [NSInvocation invocationWithMethodSignature:[ev methodSignatureForSelector:s2]];
                    [iv setTarget:ev];
                    [iv setSelector:s2];
                    [iv setArgument:&set atIndex:2];
                    [iv invoke];
                    phaseEv = [iv returnValue];
                } @catch (id e) {}
            }
        }
        if (phaseEv) [[UIApplication sharedApplication] sendEvent:phaseEv];
    } @catch (id e) { iagentLog("iosagent: firePhase err %s\n", [e.reason UTF8String] ?: "?"); }
}

static NSDictionary *doTap(NSDictionary *p) {
    double x = [p[@"x"] doubleValue], y = [p[@"y"] doubleValue];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL ok = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = keyWin();
        if (!w) { dispatch_semaphore_signal(sem); return; }
        CGPoint pt = CGPointMake(x, y);
        firePhase(w, UITouchPhaseBegan, pt, UITouchTypeDirect);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                   firePhase(w, UITouchPhaseEnded, pt, UITouchTypeDirect);
                   ok = YES;
                   dispatch_semaphore_signal(sem);
               });
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    return @{@"ok": @YES, @"tapped": @(ok)};
}

static NSDictionary *doSwipe(NSDictionary *p) {
    double x1 = [p[@"x1"] doubleValue], y1 = [p[@"y1"] doubleValue;
    double x2 = [p[@"x2"] doubleValue], y2 = [p[@"y2"] doubleValue];
    double ms = [p[@"ms"] doubleValue]; if (ms <= 0 || ms > 3000) ms = 300;
    int steps = 8;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = keyWin();
        if (w) {
            firePhase(w, UITouchPhaseBegan, CGPointMake(x1, y1), UITouchTypeDirect);
            for (int i = 1; i <= steps; i++) {
                double k = (double)i / (double)steps;
                CGPoint pt = CGPointMake(x1 + (x2 - x1) * k, y1 + (y2 - y1) * k);
                firePhase(w, UITouchPhaseMoved, pt, UITouchTypeDirect);
            }
            firePhase(w, UITouchPhaseEnded, CGPointMake(x2, y2), UITouchTypeDirect);
        }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
    return @{@"ok": @YES};
}

static NSDictionary *doType(NSDictionary *p) {
    NSString *text = p[@"text"] ?: @"";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *res = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = keyWin();
            id fr = [w firstResponder];
            BOOL ok = NO;
            if ([fr conformsToProtocol:@protocol(UIKeyInput)]) {
                UIKeyInput *ki = (UIKeyInput)fr;
                if ([ki hasMarkedText]) [ki commitCompositionText];
                [ki insertText:text];
                ok = YES;
            }
            res = @{@"ok": @YES, @"typed": @(ok)};
        } @catch (id e) {
            res = @{@"ok": @NO, @"err": e.reason ?: @""};
        }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    return res ?: @{@"ok": @NO, @"err": @"no responder"};
}

static NSDictionary *doShot(NSDictionary *p) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *res = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = keyWin();
            if (!w) { res = @{@"ok": @NO, @"err": @"no window"}; dispatch_semaphore_signal(sem); return; }
            UIView *snap = [w snapshotViewAfterScreenUpdates:YES];
            UIImage *img = snap.image;
            if (!img) { res = @{@"ok": @NO, @"err": @"snapshot nil"}; dispatch_semaphore_signal(sem); return; }
            NSData *data = [p[@"jpeg"] boolValue] ? UIImageJPEGRepresentation(img, 0.8)
                                                  : UIImagePNGRepresentation(img);
            NSString *out = [NSString stringWithFormat:@"/private/tmp/iosagent_shot_%d.png", getpid()];
            [data writeToFile:out atomically:YES];
            res = @{@"ok": @YES, @"path": out,
                    @"scale": @([UIScreen mainScreen].scale),
                    @"w": @([UIScreen mainScreen].bounds.size.width),
                    @"h": @([UIScreen mainScreen].bounds.size.height)};
        } @catch (id e) {
            res = @{@"ok": @NO, @"err": e.reason ?: @""};
        }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
    return res ?: @{@"ok": @NO, @"err": @"shot timeout"};
}

static NSString *nodeText(UIView *v) {
    @try {
        if ([v isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)v).text;
            if (t.length) return t.length > 60 ? [t substringToIndex:60] : t;
        }
        if ([v isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)v;
            if (tf.text.length) return tf.text;
            if (tf.placeholder.length) return [@"(" stringByAppendingString:tf.placeholder];
        }
        if ([v isKindOfClass:[UITextView class]]) {
            NSString *t = ((UITextView *)v).text;
            if (t.length) return t.length > 80 ? [t substringToIndex:80] : t;
        }
        if ([v isKindOfClass:[UIButton class]]) {
            NSString *t = [((UIButton *)v) titleForControlEvents:UIControlEventTouchUpInside];
            if (t.length) return t;
        }
        id al = [v accessibilityLabel];
        if ([al isKindOfClass:[NSString class]] && [(NSString *)al length])
            return [(NSString *)al length] > 60 ? [(NSString *)al substringToIndex:60] : (NSString *)al;
    } @catch (id e) {}
    return nil;
}

static void walkView(UIView *v, int depth, NSMutableArray *out) {
    if (depth > 12 || out.count >= 1500 || !v) return;
    @try {
        if (!v.hidden || depth == 0) {
            NSMutableDictionary *n = [NSMutableDictionary dictionary];
            n[@"0"] = NSStringFromClass([v class]) ?: @"";
            CGRect f = v.frame;
            n[@"1"] = @[@(roundf(f.origin.x)), @(roundf(f.origin.y)),
                       @(roundf(f.size.width)), @(roundf(f.size.height))];
            NSString *t = nodeText(v);
            if (t) n[@"2"] = t;
            if (v.accessibilityIdentifier.length) n[@"3"] = v.accessibilityIdentifier;
            if ([v respondsToSelector:@selector(isEnabled)]) n[@"4"] = @([v isEnabled]);
            [out addObject:n];
        }
        NSArray *subs = v.subviews;
        for (UIView *sub in subs) walkView(sub, depth + 1, out);
    } @catch (id e) {}
}

static NSDictionary *doUi(void) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSMutableArray *nodes = [NSMutableArray array];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { walkView(keyWin(), 0, nodes); } @catch (id e) {}
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)));
    return @{@"ok": @YES, @"nodes": nodes};
}

static NSDictionary *doOpen(NSDictionary *p) {
    NSString *bid = p[@"bundleId"];
    if (!gSB) return @{@"ok": @NO, @"err": @"open_app only works inside SpringBoard process"};
    @try {
        NSWorkspace *ws = [NSWorkspace sharedWorkspace];
        SEL sel = NSSelectorFromString(@"openApplicationWithIdentifier:andUIDelegate:");
        if ([ws respondsToSelector:sel]) {
            NSInvocation *iv = [NSInvocation invocationWithMethodSignature:[ws methodSignatureForSelector:sel]];
            [iv setTarget:ws];
            [iv setSelector:sel];
            [iv setArgument:&bid atIndex:2];
            id nilObj = nil;
            [iv setArgument:&nilObj atIndex:3];
            [iv invoke];
            return @{@"ok": @YES, @"via": @"NSWorkspace"};
        }
        NSString *safe = [bid stringByReplacingOccurrencesOfString:@"'" withString:@""];
        NSString *cmd = [NSString stringWithFormat:
                         @"(mclabsbsctl launch '%s' || iobctl launch '%s') >/dev/null 2>&1 &",
                         [safe UTF8String], [safe UTF8String]];
        int r = system([cmd UTF8String]);
        return @{@"ok": @(r == 0), @"via": @"bsctl"};
    } @catch (id e) {
        return @{@"ok": @NO, @"err": e.reason ?: @""};
    }
}

/* ------------------------------------------------------------------ */
#pragma mark - 通知捕获

static void appendNotif(NSString *bid, NSString *title, NSString *body) {
    @try {
        NSDictionary *rec = @{ @"ts": @((long long)[[NSDate date] timeIntervalSince1970]),
                               @"app": bid ?: @"", @"title": title ?: @"", @"body": body ?: @"" };
        NSData *line = [NSJSONSerialization dataWithJSONObject:rec options:0 error:nil];
        FILE *f = fopen("/private/tmp/iosagent_notif.jsonl", "a");
        if (!f) return;
        fwrite(line, 1, line.length, f);
        fputc('\n', f);
        fclose(f);
    } @catch (id e) {}
}

%hook(conditional=1) UNUserNotificationCenter
- (void)willPresentNotification:(UNNotification *)n
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))h {
    @try {
        UNNotificationContent *c = n.request.content;
        appendNotif([NSProcessInfo processInfo].bundleIdentifier,
                    c.title ?: @"", c.body ?: c.subtitle ?: @"");
    } @catch (id e) {}
    if (h) h(UNNotificationPresentationOptionBanner);
}

- (void)didReceiveNotificationResponse:(UNNotificationResponse *)r {
    @try {
        UNNotificationContent *c = r.notification.request.content;
        appendNotif([NSProcessInfo processInfo].bundleIdentifier,
                    c.title ?: @"", c.body ?: @"");
    } @catch (id e) {}
}
%end

/* ------------------------------------------------------------------ */
#pragma mark - 命令分发 + socket server

static NSDictionary *handleCommand(NSDictionary *cmd) {
    if (![cmd isKindOfClass:[NSDictionary class]]) return nil;
    NSString *c = cmd[@"c"];
    NSDictionary *p = [cmd[@"p"] isKindOfClass:[NSDictionary class]] ? cmd[@"p"] : @{};
    @try {
        if ([c isEqualToString:@"ping"])
            return @{@"ok": @YES,
                     @"bundle": [NSProcessInfo processInfo].bundleIdentifier ?: @"",
                     @"sb": @(gSB),
                     @"active": @([UIApplication sharedApplication].applicationState == UIApplicationStateActive)};
        if ([c isEqualToString:@"shot"])  return doShot(p);
        if ([c isEqualToString:@"tap"])   return doTap(p);
        if ([c isEqualToString:@"swipe"]) return doSwipe(p);
        if ([c isEqualToString:@"type"])  return doType(p);
        if ([c isEqualToString:@"ui"])    return doUi();
        if ([c isEqualToString:@"open"])  return doOpen(p);
        return @{@"ok": @NO, @"err": @"unknown command"};
    } @catch (id e) {
        return @{@"ok": @NO, @"err": e.reason ?: @"exception"};
    }
}

static void serveConn(int fd) {
    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    while (1) {
        int n = read(fd, tmp, sizeof tmp);
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        while (1) {
            const unsigned char *bytes = buf.bytes;
            size_t len = buf.length;
            int idx = -1;
            for (size_t i = 0; i < len; i++)
                if (bytes[i] == '\n') { idx = (int)i; break; }
            if (idx < 0) break;
            NSData *lineData = [buf subdataWithRange:NSMakeRange(0, (NSUInteger)idx + 1)];
            [buf deleteBytesInRange:NSMakeRange(0, (NSUInteger)idx + 1)];
            NSDictionary *cmd = [NSJSONSerialization JSONObjectWithData:lineData
                                                               options:0 error:NULL];
            NSDictionary *res = handleCommand(cmd) ?: @{@"ok": @NO, @"err": @"bad json"};
            NSData *out = [NSJSONSerialization dataWithJSONObject:res options:0 error:NULL];
            if (!out) continue;
            ssize_t off = 0;
            while (off < (ssize_t)out.length) {
                ssize_t w = write(fd, (const char *)out.bytes + off, out.length - off);
                if (w <= 0) return;
                off += w;
            }
            const char nl = '\n';
            (void)write(fd, &nl, 1);
        }
    }
    close(fd);
}

/* ------------------------------------------------------------------ */
#pragma mark - SpringBoard 端：自动拉起并守护 iosagentd

static void ensureAgentDaemon(void) {
    if (!gSB) return;
    if (access("/private/tmp/iosagentd.stop", F_OK) == 0) return; /* 用户要求停止 */
    int pid = -1;
    FILE *f = fopen("/private/tmp/iosagentd.pid", "r");
    if (f) { if (fscanf(f, "%d", &pid) != 1) pid = -1; fclose(f); }
    if (pid > 0 && kill(pid, 0) == 0) return; /* 已在跑 */
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bin = @"/usr/bin/iosagentd";
    if (![fm fileExistsAtPath:bin]) bin = @"/var/jb/usr/bin/iosagentd";
    if (![fm fileExistsAtPath:bin]) bin = @"/private/var/jb/usr/bin/iosagentd";
    if (![fm fileExistsAtPath:bin]) return;
    @try {
        char *argv[3] = { (char *)[bin UTF8String], "--daemon", 0 };
        char *envp[5] = { "HOME=/var/mobile", "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin",
                         "TERM=dumb", "LANG=C.UTF-8", 0 };
        posix_spawnattr_t at; posix_spawnattr_init(&at);
        posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
        FILE *logf = fopen("/private/tmp/iosagentd.log", "a");
        if (logf) {
            int fd = fileno(logf);
            posix_spawn_file_actions_adddup2(&fa, fd, 1);
            posix_spawn_file_actions_adddup2(&fa, fd, 2);
            fclose(logf);
        }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
        pid_t p = -1;
        int rc = posix_spawnp(&p, argv[0], &at, argv, envp);
        if (rc == 0) {
            FILE *of = fopen("/private/tmp/iosagentd.pid", "w");
            if (of) { fprintf(of, "%d\n", (int)p); fclose(of); }
            iagentLog("iosagent: spawned iosagentd pid %d (%s)\n", (int)p, [bin UTF8String]);
        } else {
            iagentLog("iosagent: spawn fail rc=%d: %s\n", rc, strerror(rc));
        }
        posix_spawn_file_actions_destroy(&fa);
        posix_spawnattr_destroy(&at);
    } @catch (id e) { iagentLog("iosagent: spawn err %s\n", [e.reason UTF8String] ?: "?"); }
}

static void serveForever(int s) {
    while (1) {
        int c = accept(s, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; break; }
        serveConn(c);
    }
}

%ctor {
    gSB = isSpringBoard();
    makeSockPath();
    makePort();
    dispatch_queue_t q = dispatch_queue_create("com.ssx.iosagent.server", DISPATCH_QUEUE_SERIAL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), q, ^{
        /* 1) unix socket（本机 daemon 用） */
        int s = -1;
        int s0 = socket(AF_UNIX, SOCK_STREAM, 0);
        if (s0 >= 0) {
            s = s0;
            struct sockaddr_un a;
            memset(&a, 0, sizeof a);
            a.sun_family = AF_UNIX;
            strncpy(a.sun_path, gSock, sizeof a.sun_path - 1);
            if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) {
                iagentLog("iosagent: unix bind fail %s: %s\n", gSock, strerror(errno));
                close(s);
                s = -1;
            } else {
                fchmod(s, 0600);
                if (listen(s, 4) < 0) {
                    iagentLog("iosagent: unix listen fail\n");
                    close(s);
                    s = -1;
                } else {
                    iagentLog("iosagent: unix listening %s (pid %d)\n", gSock, (int)getpid());
                }
            }
        }
        /* 2) 127.0.0.1 TCP（外部模型经 ssh 转发用；只绑 loopback，不出网卡） */
        dispatch_async(dispatch_queue_create("com.ssx.iosagent.tcp", DISPATCH_QUEUE_SERIAL), ^{
            int t = socket(AF_INET, SOCK_STREAM, 0);
            if (t < 0) return;
            int one = 1;
            setsockopt(t, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
            struct sockaddr_in a;
            memset(&a, 0, sizeof a);
            a.sin_family = AF_INET;
            a.sin_port = htons((unsigned short)gPort);
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (bind(t, (struct sockaddr *)&a, sizeof a) < 0) {
                iagentLog("iosagent: tcp bind fail %d: %s\n", gPort, strerror(errno));
                close(t);
                return;
            }
            if (listen(t, 4) < 0) { close(t); return; }
            iagentLog("iosagent: tcp listening 127.0.0.1:%d (pid %d)\n", gPort, (int)getpid());
            serveForever(t);
        });
        /* SpringBoard 端：守护 agent 进程（独立队列，避免被 accept 循环阻塞） */
        if (gSB) {
            dispatch_async(dispatch_queue_create("com.ssx.iosagent.mgr", DISPATCH_QUEUE_SERIAL), ^{
                usleep(20 * 1000 * 1000); /* 等系统稍稳定 */
                while (1) {
                    ensureAgentDaemon();
                    usleep(30 * 1000 * 1000);
                }
            });
        }
        if (s >= 0) serveForever(s); /* unix socket 服务（阻塞该串行队列） */
    });
}
