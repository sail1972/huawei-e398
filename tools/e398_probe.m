/*
 * e398_probe — 用系统代理（CFNetwork 默认配置）发一个 HTTPS 请求，打印出口 IP。
 *
 * 为什么需要它：
 *   curl 只认自己的 -x 和环境变量，完全无视 macOS「系统代理」。
 *   要判断「系统代理到底有没有被 App 用上」，必须走 CFNetwork/NSURLSession 的默认配置
 *   —— 那正是 Chrome / Safari / 大多数客户端读系统代理的路径。
 *
 * 用法：
 *   ./e398_probe                     取 https://ifconfig.me/ip
 *   ./e398_probe https://ip.sb       换目标
 *
 * 判读：
 *   返回代理服务器的出口 IP（例如 154.40.47.204） → 系统代理生效
 *   返回本机宽带/4G 的真实出口 IP（例如 112.96.x.x）→ 系统代理没被用上，走了直连
 */

#import <Foundation/Foundation.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *u = (argc > 1) ? [NSString stringWithUTF8String:argv[1]]
                                 : @"https://ifconfig.me/ip";
        NSURL *url = [NSURL URLWithString:u];
        if (!url) { fprintf(stderr, "URL 非法: %s\n", argv[1] ? argv[1] : ""); return 2; }

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.timeoutInterval = 15;
        req.cachePolicy = NSURLRequestReloadIgnoringCacheData;

        __block NSString *body = nil;
        __block NSString *err  = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        /* 故意不设 connectionProxyDictionary —— 让 CFNetwork 自己读系统代理 */
        NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg];
        NSURLSessionDataTask *t =
            [s dataTaskWithRequest:req
                 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                    if (e) err = [e localizedDescription];
                    else if (d) body = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                    dispatch_semaphore_signal(sem);
                 }];
        [t resume];
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC))) {
            fprintf(stderr, "超时\n");
            [s invalidateAndCancel];
            return 3;
        }
        [s finishTasksAndInvalidate];

        if (err) { fprintf(stderr, "失败: %s\n", err.UTF8String); return 1; }
        /* ifconfig.me/ip 只返回 IP，去掉首尾空白 */
        printf("%s\n", [[body stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] UTF8String]);
        return 0;
    }
}
