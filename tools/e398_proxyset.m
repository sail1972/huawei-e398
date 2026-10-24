/*
 * e398_proxyset — 把 SOCKS 代理写进 configd 的动态存储（App 读系统代理的那份数据）
 *
 * 为什么不用 scutil 的 DSL：
 *   1. scutil 的 d.add 没法表达「嵌套字典」，写不出 __SCOPED__（按接口的代理表）。
 *      ppp0 没有服务对象，configd 算出来的 __SCOPED__ 里就没有 ppp0，
 *      App 在做「按接口查代理」时拿到的是空 —— 这正是 ppp0 下代理失效的原因。
 *   2. 这里直接构造 CFDictionary，global 与 __SCOPED__（覆盖所有活动接口）
 *      一次写全；读回校验也在同一进程里做。
 *
 * 用法：
 *   e398_proxyset set 127.0.0.1 1080     写入 SOCKS+HTTP+HTTPS（需要 root）
 *   e398_proxyset set 127.0.0.1 1080 socks   只写 SOCKS
 *   e398_proxyset off                    清空（需要 root）
 *   e398_proxyset check 127.0.0.1 1080   只读校验：当前有效代理是否就是它（免 root）
 *       exit 0 = 一致；1 = 不一致（打印实际值）；2 = 出错
 */

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <ifaddrs.h>
#include <net/if.h>

static NSString *const kKey = @"State:/Network/Global/Proxies";

static SCDynamicStoreRef openStore(void)
{
    return SCDynamicStoreCreate(kCFAllocatorDefault, CFSTR("e398-proxyset"), NULL, NULL);
}

static NSArray<NSString *> *exceptions(void)
{
    return @[ @"*.local", @"169.254/16",
              @"10.0.0.0/8", @"172.16.0.0/12", @"192.168.0.0/16" ];
}

/* all = YES 时连 HTTP/HTTPS 一起写：1080 是 xray 的 mixed 入站，
 * 既能当 SOCKS 也能当 HTTP 代理。有些程序（Chromium 系列就是）只认 HTTP 代理，
 * 系统里只开 SOCKS 它们会当没有代理。 */
static NSDictionary *proxyDict(NSString *host, int port, BOOL all)
{
    NSMutableDictionary *d = [@{ @"SOCKSEnable"    : @1,
                                 @"SOCKSProxy"     : host,
                                 @"SOCKSPort"      : @(port),
                                 @"FTPPassive"     : @1,
                                 @"ExceptionsList" : exceptions() } mutableCopy];
    if (all) {
        d[@"HTTPEnable"]  = @1; d[@"HTTPProxy"]  = host; d[@"HTTPPort"]  = @(port);
        d[@"HTTPSEnable"] = @1; d[@"HTTPSProxy"] = host; d[@"HTTPSPort"] = @(port);
    }
    return d;
}

/* 当前所有 UP 的接口名（跳过 lo0） */
static NSArray<NSString *> *activeIfaces(void)
{
    NSMutableArray *out = [NSMutableArray array];
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return out;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_name) continue;
        if ((p->ifa_flags & IFF_UP) == 0) continue;
        NSString *n = @(p->ifa_name);
        if ([n isEqualToString:@"lo0"]) continue;
        if (![out containsObject:n]) [out addObject:n];
    }
    freeifaddrs(ifa);
    return out;
}

static int doSet(NSString *host, int port, BOOL all)
{
    SCDynamicStoreRef store = openStore();
    if (!store) { fprintf(stderr, "SCDynamicStoreCreate 失败\n"); return 2; }

    NSDictionary *base = proxyDict(host, port, all);
    NSMutableDictionary *scoped = [NSMutableDictionary dictionary];
    for (NSString *n in activeIfaces()) scoped[n] = base;

    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:base];
    d[@"__SCOPED__"] = scoped;

    Boolean ok = SCDynamicStoreSetValue(store, (__bridge CFStringRef)kKey,
                                        (__bridge CFPropertyListRef)d);
    if (!ok) {
        fprintf(stderr, "SCDynamicStoreSetValue 失败（是否 root？）\n");
        CFRelease(store);
        return 3;
    }
    CFRelease(store);

    printf("已写入 %s %s:%d，__SCOPED__ 覆盖 %lu 个接口：%s\n",
           all ? "SOCKS+HTTP+HTTPS" : "SOCKS", host.UTF8String, port,
           (unsigned long)scoped.count,
           [[[scoped allKeys] sortedArrayUsingSelector:@selector(compare:)]
               componentsJoinedByString:@" "].UTF8String);
    return 0;
}

static int doOff(void)
{
    SCDynamicStoreRef store = openStore();
    if (!store) return 2;
    Boolean ok = SCDynamicStoreSetValue(store, (__bridge CFStringRef)kKey,
                                        (__bridge CFPropertyListRef)@{} );
    CFRelease(store);
    if (!ok) { fprintf(stderr, "清空失败（是否 root？）\n"); return 3; }
    printf("已清空 State:/Network/Global/Proxies\n");
    return 0;
}

static NSDictionary *readCurrent(void)
{
    SCDynamicStoreRef store = openStore();
    if (!store) return nil;
    NSDictionary *d = CFBridgingRelease(SCDynamicStoreCopyValue(store,
                                        (__bridge CFStringRef)kKey));
    CFRelease(store);
    return d;
}

static int doCheck(NSString *host, int port)
{
    NSDictionary *d = readCurrent();
    if (!d) { printf("空（没有任何代理）\n"); return 1; }

    NSNumber *en = d[@"SOCKSEnable"];
    NSString *h  = d[@"SOCKSProxy"];
    NSNumber *p  = d[@"SOCKSPort"];

    if (en.intValue == 1 && [h isEqualToString:host] && p.intValue == port) {
        /* ppp0 在用时，它的 scoped 条目必须存在，否则按接口查代理会拿到空 */
        BOOL pppUp = [activeIfaces() containsObject:@"ppp0"];
        NSDictionary *mine = ((NSDictionary *)d[@"__SCOPED__"])[@"ppp0"];
        printf("一致：SOCKS %s:%d 已启用；__SCOPED__ 里%s ppp0%s\n",
               h.UTF8String, p.intValue, mine ? "有" : "没有",
               pppUp ? "（ppp0 在用）" : "（ppp0 未使用，无所谓）");
        return (!pppUp || mine) ? 0 : 4;   /* 4 = 全局对但 scoped 缺，需要重写 */
    }
    printf("不一致：SOCKSEnable=%d SOCKSProxy=%s SOCKSPort=%d\n",
           en.intValue, h ? h.UTF8String : "(nil)", p ? p.intValue : -1);
    return 1;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *cmd = (argc > 1) ? @(argv[1]) : @"check";

        if ([cmd isEqualToString:@"off"]) return doOff();

        if ([cmd isEqualToString:@"set"] || [cmd isEqualToString:@"check"]) {
            if (argc < 4) {
                fprintf(stderr, "用法：%s set|check <host> <port>\n", argv[0]);
                return 2;
            }
            NSString *host = @(argv[2]);
            int port = atoi(argv[3]);
            if (port <= 0 || port > 65535) { fprintf(stderr, "端口非法\n"); return 2; }
            BOOL all = YES;
            if (argc > 4 && strcmp(argv[4], "socks") == 0) all = NO;
            return [cmd isEqualToString:@"set"] ? doSet(host, port, all) : doCheck(host, port);
        }

        fprintf(stderr, "用法：%s set|off|check [host port]\n", argv[0]);
        return 2;
    }
}
