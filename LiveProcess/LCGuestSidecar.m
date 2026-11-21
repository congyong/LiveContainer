//
//  LCGuestSidecar.m
//  LiveProcess
//
//  在 guest app 自己的进程里起一个 loopback HTTP 服务，把「界面」暴露给 LiveContainer 主进程代理：
//    GET  /guest/info                 bundleId / pid / 屏幕尺寸
//    GET  /guest/ui/tree              可访问性树（label/identifier/frame/activatable）
//    POST /guest/ui/activate          {index} | {label} | {identifier} | {x,y}
//    POST /guest/ui/taps              {steps:[{label|identifier|index|x,y,delayMs}], detectChange}
//    POST /guest/ui/text              {text}
//    GET  /guest/screenshot?maxWidth=&quality=
//
//  只 bind 127.0.0.1，并且要求 Authorization: Bearer <token>，token 由主进程写到
//  app group 的 LiveContainer/RemoteControl/guest-sidecar-token，两边共用。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <signal.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <Vision/Vision.h>

static const int kLCGuestSidecarPort = 8850;

// 扩展里 UIKit 没把 accessibilityIdentifier 放进 NSObject 的可见接口，这里补个声明
@interface NSObject (LCGuestA11y)
- (NSString *)accessibilityIdentifier;
@end

// ── 小工具 ──────────────────────────────────────────────────────────────────

static NSData *LCJSON(id object, int status, NSMutableDictionary *extraHeaders) {
    NSError *err = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:0 error:&err];
    if (!body) body = [@"{\"ok\":false,\"error\":\"encode\"}" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *resp = [NSMutableData data];
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: application/json; charset=utf-8\r\n"
         "Content-Length: %lu\r\nConnection: close\r\nServer: LC-GuestSidecar/1\r\n",
        status, status == 200 ? @"OK" : @"Error", (unsigned long)body.length];
    [resp appendData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    [extraHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [resp appendData:[[NSString stringWithFormat:@"%@: %@\r\n", k, v] dataUsingEncoding:NSUTF8StringEncoding]];
    }];
    [resp appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:body];
    return resp;
}

static NSData *LCBinary(NSData *body, NSString *contentType, int status) {
    NSMutableData *resp = [NSMutableData data];
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        status, status == 200 ? @"OK" : @"Error", contentType, (unsigned long)body.length];
    [resp appendData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:body];
    return resp;
}

// App Extension 里 UIApplication.sharedApplication 被标成 unavailable，动态取实例
static UIApplication *LCApp(void) {
    static UIApplication *app = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SEL sel = NSSelectorFromString(@"sharedApplication");
        Class cls = [UIApplication class];
        if ([cls respondsToSelector:sel]) {
            app = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
        }
    });
    return app;
}

static NSURL *LCGroupURL(void) {
    NSArray<NSString *> *ids = @[@"group.com.kdt.livecontainer",
                                 @"group.com.SideStore.SideStore",
                                 @"group.com.rileytestut.AltStore"];
    for (NSString *gid in ids) {
        NSURL *u = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:gid];
        if (u) return u;
    }
    return nil;
}

static NSString *LCSidecarTokenPath(void) {
    NSURL *group = LCGroupURL();
    if (!group) return nil;
    return [[[group.path stringByAppendingPathComponent:@"LiveContainer"]
             stringByAppendingPathComponent:@"RemoteControl"]
            stringByAppendingPathComponent:@"guest-sidecar-token"];
}

static NSString *LCReadSidecarToken(void) {
    NSString *path = LCSidecarTokenPath();
    if (!path) return @"";
    NSString *t = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

// ── 视图遍历（与主进程同一套顺序，index 才能对上） ───────────────────────────

static BOOL LCHasLabel(NSObject *o) {
    if (o.accessibilityLabel.length) return YES;
    if ([o respondsToSelector:@selector(accessibilityIdentifier)] && [[o accessibilityIdentifier] length]) return YES;
    if ([o.accessibilityValue isKindOfClass:NSString.class] && [o.accessibilityValue length]) return YES;
    if ([o isKindOfClass:UIControl.class]) return YES;
    return (o.accessibilityTraits & (UIAccessibilityTraitButton | UIAccessibilityTraitLink)) != 0;
}

static void LCWalk(id obj, NSMutableArray *out, NSMutableSet *visited, NSUInteger depth) {
    if (out.count >= 800 || depth > 32) return;
    if (![obj isKindOfClass:NSObject.class]) return;
    NSObject *o = (NSObject *)obj;
    NSValue *key = [NSValue valueWithNonretainedObject:o];
    if ([visited containsObject:key]) return;
    [visited addObject:key];

    if (LCHasLabel(o)) [out addObject:o];

    if ([o isKindOfClass:UIView.class]) {
        UIView *v = (UIView *)o;
        if (v.hidden || v.alpha < 0.01) return;
        for (UIView *sub in v.subviews) LCWalk(sub, out, visited, depth + 1);
    }
    if ([[o accessibilityElements] isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)[o accessibilityElements]) LCWalk(child, out, visited, depth + 1);
    }
}

static NSArray<NSObject *> *LCCollect(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    for (UIScene *scene in LCApp().connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            LCWalk(w, out, visited, 0);
        }
    }
    return out;
}

// 通用做法：老 App 很少写 accessibilityLabel，但界面上的文字一定在某个
// UILabel / UIButton title / UISegmentedControl 分段 / UITextField 里。
// 这里把元素子树里的文字抓出来（限深 3 层），这样"菜单→文件管理"这种
// 没有 a11y 标签的界面也能按文字定位。对 SwiftUI 无效（那边有 a11y label），
// 对 WKWebView/Flutter 也无效（文字不是 UIKit 控件，得 OCR）。
static void LCCollectTexts(UIView *v, NSMutableArray<NSString *> *out, NSInteger depth) {
    // 老 App 的菜单项往往是 MenuBtn → 容器 → UIStackView → UILabel，层数比想象深，
    // 所以放到 6 层、最多 12 条文字。
    if (!v || depth > 6 || out.count >= 12) return;
    NSString *t = nil;
    // CATextLayer：有些自定义按钮（如这个 App 的 MenuBtn）文字是画在图层的
    for (CALayer *l in v.layer.sublayers) {
        if ([l isKindOfClass:NSClassFromString(@"CATextLayer")]) {
            id str = [(id)l valueForKey:@"string"];
            if ([str isKindOfClass:NSString.class] && [str length]) {
                if (![out containsObject:str]) [out addObject:str];
            } else if ([str isKindOfClass:NSAttributedString.class]) {
                NSString *plain = [(NSAttributedString *)str string];
                if (plain.length && ![out containsObject:plain]) [out addObject:plain];
            }
        }
    }
    if ([v isKindOfClass:UILabel.class]) {
        UILabel *lb = (UILabel *)v;
        t = lb.text.length ? lb.text : lb.attributedText.string;
    } else if ([v isKindOfClass:UIButton.class]) {
        UIButton *b = (UIButton *)v;
        for (NSNumber *st in @[@(UIControlStateNormal), @(UIControlStateSelected), @(UIControlStateHighlighted)]) {
            UIControlState state = (UIControlState)st.unsignedIntegerValue;
            NSString *title = [b titleForState:state];
            if (!title.length) title = [b attributedTitleForState:state].string;
            if (title.length && ![out containsObject:title]) [out addObject:title];
        }
    } else if ([v isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *seg = (UISegmentedControl *)v;
        for (NSUInteger i = 0; i < seg.numberOfSegments; i++) {
            NSString *title = [seg titleForSegmentAtIndex:i];
            if (title.length && ![out containsObject:title]) [out addObject:title];
        }
    } else if ([v isKindOfClass:UITextField.class]) {
        UITextField *f = (UITextField *)v;
        for (NSString *cand in @[f.text ?: @"", f.placeholder ?: @""]) {
            if (cand.length && ![out containsObject:cand]) [out addObject:cand];
        }
    } else if ([v isKindOfClass:UITextView.class]) {
        t = ((UITextView *)v).text;
    } else if ([v isKindOfClass:UISearchBar.class]) {
        t = ((UISearchBar *)v).placeholder;
    }
    if (t.length && ![out containsObject:t]) [out addObject:t];
    for (UIView *sub in v.subviews) LCCollectTexts(sub, out, depth + 1);
}

// 元素自身+子树的文字，拼成一个可读字符串
static NSArray<NSString *> *LCTextsOf(NSObject *o) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if ([o isKindOfClass:UIView.class]) LCCollectTexts((UIView *)o, out, 0);
    if (out.count == 0) {
        NSString *l = o.accessibilityLabel;
        if (l.length) [out addObject:l];
    }
    return out;
}

static NSDictionary *LCDescribe(NSObject *o) {
    CGRect frame = CGRectZero;
    if ([o isKindOfClass:UIView.class]) {
        UIView *v = (UIView *)o;
        frame = [v convertRect:v.bounds toView:nil];
    } else {
        frame = [o accessibilityFrame];
    }
    BOOL activatable = [o isKindOfClass:UIControl.class]
        || (o.accessibilityTraits & (UIAccessibilityTraitButton | UIAccessibilityTraitLink | UIAccessibilityTraitTabBar)) != 0;
    NSArray<NSString *> *texts = LCTextsOf(o);
    return @{
        @"label": o.accessibilityLabel ?: @"",
        @"text": [texts componentsJoinedByString: @" | "],
        @"texts": texts,
        @"identifier": ([o respondsToSelector:@selector(accessibilityIdentifier)] ? [o accessibilityIdentifier] : nil) ?: @"",
        @"value": ([o.accessibilityValue isKindOfClass:NSString.class] ? (NSString *)o.accessibilityValue : @""),
        @"class": NSStringFromClass(o.class),
        @"frame": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                    @"w": @(frame.size.width), @"h": @(frame.size.height)},
        @"control": @([o isKindOfClass:UIControl.class]),
        @"activatable": @(activatable)
    };
}

// ── 动作 ────────────────────────────────────────────────────────────────────

static UIWindow *LCKeyWindow(void) {
    for (UIScene *scene in LCApp().connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return LCApp().windows.firstObject;
}

static NSDictionary *LCTap(CGFloat x, CGFloat y);
static NSDictionary *LCActivateHit(UIView *hit);

static NSDictionary *LCActivateObject(NSObject *o) {
    if ([o isKindOfClass:UIControl.class]) {
        [(UIControl *)o sendActionsForControlEvents:UIControlEventTouchUpInside];
        return @{@"ok": @YES, @"detail": [NSString stringWithFormat:@"sendActions on %@", NSStringFromClass(o.class)]};
    }
    if ([o accessibilityActivate]) {
        return @{@"ok": @YES, @"detail": [NSString stringWithFormat:@"accessibilityActivate on %@", NSStringFromClass(o.class)]};
    }
    if ([o isKindOfClass:UIView.class]) {
        UIView *v = (UIView *)o;
        CGPoint c = CGPointMake(v.bounds.size.width / 2, v.bounds.size.height / 2);
        UIView *hit = [v hitTest:c withEvent:nil];
        NSDictionary *r = hit && hit != v ? LCActivateHit(hit) : nil;
        if (r) return r;
    } else {
        CGRect f = [o accessibilityFrame];
        if (f.size.width > 1 && f.size.height > 1) {
            NSDictionary *r = LCTap(f.origin.x + f.size.width / 2, f.origin.y + f.size.height / 2);
            if ([r[@"ok"] boolValue]) return r;
            return @{@"ok": @NO, @"detail": [NSString stringWithFormat:@"a11y 节点无法激活，坐标点击也失败: %@", r[@"detail"]]};
        }
    }
    return @{@"ok": @NO, @"detail": [NSString stringWithFormat:@"%@ 不可激活", NSStringFromClass(o.class)]};
}

static NSDictionary *LCActivateHit(UIView *hit) {
    UIView *cur = hit;
    while (cur) {
        if ([cur isKindOfClass:UIControl.class]) {
            [(UIControl *)cur sendActionsForControlEvents:UIControlEventTouchUpInside];
            return @{@"ok": @YES, @"detail": [NSString stringWithFormat:@"sendActions on %@", NSStringFromClass(cur.class)]};
        }
        if ([cur accessibilityActivate]) {
            return @{@"ok": @YES, @"detail": [NSString stringWithFormat:@"accessibilityActivate on %@", NSStringFromClass(cur.class)]};
        }
        cur = cur.superview;
    }
    return nil;
}

static NSDictionary *LCTap(CGFloat x, CGFloat y) {
    CGPoint p = CGPointMake(x, y);
    for (UIScene *scene in LCApp().connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!CGRectContainsPoint(w.bounds, p)) continue;
            UIView *hit = [w hitTest:p withEvent:nil];
            if (!hit) continue;
            NSDictionary *r = LCActivateHit(hit);
            if (r) return r;
            return @{@"ok": @NO, @"detail": [NSString stringWithFormat:@"命中 %@ 但没有可触发控件", NSStringFromClass(hit.class)]};
        }
    }
    return @{@"ok": @NO, @"detail": @"坐标不在任何窗口内"};
}

static NSDictionary *LCActivateSpec(NSDictionary *spec) {
    if (spec[@"x"] && spec[@"y"]) {
        return LCTap([spec[@"x"] doubleValue], [spec[@"y"] doubleValue]);
    }
    NSArray<NSObject *> *all = LCCollect();
    if (spec[@"index"]) {
        NSInteger idx = [spec[@"index"] integerValue];
        if (idx >= 0 && idx < (NSInteger)all.count) {
            return LCActivateObject(all[(NSUInteger)idx]);
        }
        return @{@"ok": @NO, @"detail": [NSString stringWithFormat:@"index %ld 越界（当前 %lu 个元素，先 GET /api/v1/guest/ui/tree 刷新）", (long)idx, (unsigned long)all.count]};
    }
    NSString *label = [spec[@"label"] isKindOfClass:NSString.class] ? spec[@"label"] : nil;
    NSString *ident = [spec[@"identifier"] isKindOfClass:NSString.class] ? spec[@"identifier"] : nil;
    NSString *txt   = [spec[@"text"] isKindOfClass:NSString.class] ? spec[@"text"] : nil;
    if (!label.length && !ident.length && !txt.length) {
        return @{@"ok": @NO, @"detail": @"需要 index / text / label / identifier / x+y"};
    }
    // 按界面上的文字找（老 App 没有 a11y label，但 UILabel/UIButton title 里有字）
    if (txt.length && !label.length && !ident.length) {
        // 先精确，再包含
        for (int pass = 0; pass < 2; pass++) {
            for (NSObject *o in all) {
                NSArray<NSString *> *ts = LCTextsOf(o);
                BOOL hit = NO;
                for (NSString *t in ts) {
                    if (pass == 0 ? [t isEqualToString:txt] : [t containsString:txt]) { hit = YES; break; }
                }
                if (!hit) continue;
                NSDictionary *r = LCActivateObject(o);
                if ([r[@"ok"] boolValue]) return r;
            }
        }
        NSMutableArray<NSString *> *seen = [NSMutableArray array];
        for (NSObject *o in all) {
            NSArray<NSString *> *ts = LCTextsOf(o);
            if (ts.count) [seen addObject:[ts componentsJoinedByString:@"/"]];
            if (seen.count >= 12) break;
        }
        // 视图树里没有（自绘/WebView）→ OCR 看图找文字，按框中心点一下
        for (NSDictionary *it in LCRecognizeText()) {
            NSString *t2 = it[@"text"];
            if (![t2 containsString:txt]) continue;
            CGFloat cx = [it[@"x"] doubleValue] + [it[@"w"] doubleValue] / 2.0;
            CGFloat cy = [it[@"y"] doubleValue] + [it[@"h"] doubleValue] / 2.0;
            NSDictionary *r = LCTap(cx, cy);
            NSMutableDictionary *m = [r mutableCopy];
            m[@"detail"] = [NSString stringWithFormat:@"OCR 命中「%@」→ (%.0f,%.0f): %@",
                            t2, cx, cy, r[@"detail"] ?: @""];
            m[@"via"] = @"ocr";
            return m;
        }
        return @{@"ok": @NO, @"detail": [NSString stringWithFormat:@"没找到文字「%@」（视图树和 OCR 都没有）；视图树里能看到的文字: %@",
                                        txt, [seen componentsJoinedByString:@", "]]};
    }
    for (NSObject *o in all) {
        BOOL match = NO;
        if (ident.length && [o respondsToSelector:@selector(accessibilityIdentifier)]) match = [[o accessibilityIdentifier] isEqualToString:ident];
        if (!match && label.length) {
            NSString *l = o.accessibilityLabel ?: @"";
            match = [l.lowercaseString isEqualToString:label.lowercaseString] || [l containsString:label];
        }
        if (!match) continue;
        NSDictionary *r = LCActivateObject(o);
        if ([r[@"ok"] boolValue]) return r;
    }
    return @{@"ok": @NO, @"detail": [NSString stringWithFormat:@"没找到可激活的 %@", label ?: ident]};
}

static UIView *LCFindTextInputView(void) {
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIScene *scene in LCApp().connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) [stack addObject:w];
    }
    UIView *fallback = nil;
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        BOOL isInput = [v isKindOfClass:UITextField.class]
                    || [v isKindOfClass:UITextView.class]
                    || [v isKindOfClass:UISearchBar.class];
        if (isInput) {
            if (!fallback) fallback = v;
            if (!v.hidden && v.alpha > 0.01 && v.window) return v;
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return fallback;
}

static NSDictionary *LCTextInput(NSString *text) {
    UIView *fr = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIScene *scene in LCApp().connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) [stack addObject:w];
    }
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if (v.isFirstResponder) { fr = v; break; }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    if (!fr) {
        // 没有第一响应者：自己找界面上的输入控件（老 App 常常不自动聚焦）
        fr = LCFindTextInputView();
        if (fr) [fr becomeFirstResponder];
    }
    if (!fr) return @{@"ok": @NO, @"detail": @"界面上没有可聚焦的输入框"};
    if ([fr conformsToProtocol:@protocol(UIKeyInput)] || [fr isKindOfClass:UITextField.class] || [fr isKindOfClass:UITextView.class]) {
        [(id<UIKeyInput>)fr insertText:text];
        return @{@"ok": @YES, @"detail": [NSString stringWithFormat:@"insertText on %@", NSStringFromClass(fr.class)]};
    }
    // UISearchBar：找内部 textField
    if ([fr isKindOfClass:UISearchBar.class]) {
        UITextField *tf = [(UISearchBar *)fr valueForKey:@"searchField"];
        if ([tf isKindOfClass:UITextField.class]) {
            [tf insertText:text];
            return @{@"ok": @YES, @"detail": @"insertText on UISearchBar.searchField"};
        }
    }
    return @{@"ok": @NO, @"detail": [NSString stringWithFormat:@"%@ 不接受文本", NSStringFromClass(fr.class)]};
}

static UIImage *LCSnapshot(CGFloat maxWidth) {
    UIWindow *w = LCKeyWindow();
    if (!w || w.bounds.size.width < 1) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:w.bounds];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        BOOL drew = [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO];
        if (!drew) [w.layer renderInContext:ctx.CGContext];
    }];
    if (maxWidth > 0 && img.size.width > maxWidth) {
        CGFloat scale = maxWidth / img.size.width;
        CGSize size = CGSizeMake(maxWidth, img.size.height * scale);
        UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
        f.scale = 1;
        img = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:f] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [img drawInRect:CGRectMake(0, 0, size.width, size.height)];
        }];
    }
    return img;
}

// ── OCR ─────────────────────────────────────────────────────────────────────
// 自绘文字（画笔/图层/WebView/Flutter）在视图树里根本读不到，只能看图识字。
// 用系统的 Vision 框架做中文+英文识别，返回归一化框换算成视图坐标。
// 这样"按文字点"对任何 App 都成立，而不只是 UIKit 原生控件。
static NSArray<NSDictionary *> *LCRecognizeText(void) {
    UIImage *img = LCSnapshot(0);
    CGImageRef cg = img.CGImage;
    if (!cg) return @[];
    CGSize pts = img.size;                 // 点尺寸 == 窗口 bounds
    __block NSArray<NSDictionary *> *items = @[];
    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:cg orientation:kCGImagePropertyOrientationUp options:@{}];
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = YES;
    NSError *err = nil;
    if (![handler performRequests:@[req] error:&err]) {
        fprintf(stderr, "[LCGuestSidecar] ocr failed: %s\n", err.localizedDescription.UTF8String);
        return @[];
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (VNRecognizedTextObservation *obs in req.results) {
        VNRecognizedText *best = [obs topCandidates:1].firstObject;
        if (!best.string.length) continue;
        CGRect bb = obs.boundingBox;       // 归一化，原点在左下
        CGFloat x = bb.origin.x * pts.width;
        CGFloat w = bb.size.width * pts.width;
        CGFloat h = bb.size.height * pts.height;
        CGFloat y = (1.0 - bb.origin.y - bb.size.height) * pts.height;
        [out addObject:@{@"text": best.string,
                         @"confidence": @(best.confidence),
                         @"x": @(x), @"y": @(y), @"w": @(w), @"h": @(h)}];
    }
    items = out;
    return items;
}

// 把画面缩到 48x96 的缩略图（走 UIGraphicsImageRenderer + RGBA 位图，
// 之前用 CGBitmapContextCreate(灰度) 在真机上拿到的全是 0，导致 diff 永远是 0）
static NSData *LCGrayThumb(void) {
    UIImage *img = LCSnapshot(220);
    if (!img) return nil;
    const CGFloat W = 48, H = 96;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(W, H) format:fmt];
    UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [img drawInRect:CGRectMake(0, 0, W, H)];
    }];
    CGImageRef cg = small.CGImage;
    if (!cg) return nil;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return nil;
    unsigned char *buf = calloc(w * h * 4, 1);
    if (!buf) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return nil; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    return [NSData dataWithBytesNoCopy:buf length:w * h * 4 freeWhenDone:YES];
}

// 两张灰度缩略图的差异比例（0~1）；比"哈希是否相等"更能反映细微变化
static double LCDiffRatio(NSData *a, NSData *b) {
    if (!a || !b || a.length != b.length || a.length == 0) return a == b ? 0.0 : 1.0;
    const unsigned char *pa = a.bytes, *pb = b.bytes;
    NSUInteger changed = 0, total = 0;
    for (NSUInteger i = 0; i + 3 < a.length; i += 4) {
        int la = (pa[i] * 30 + pa[i + 1] * 59 + pa[i + 2] * 11) / 100;
        int lb = (pb[i] * 30 + pb[i + 1] * 59 + pb[i + 2] * 11) / 100;
        if (abs(la - lb) > 8) changed++;
        total++;
    }
    return total ? (double)changed / (double)total : 0.0;
}

// ── 请求处理 ────────────────────────────────────────────────────────────────

static NSData *LCHandleRequest(NSString *method, NSString *path, NSDictionary *headers, NSData *body) {
    // 鉴权
    NSString *expected = LCReadSidecarToken();
    NSString *auth = headers[@"authorization"];
    if (expected.length) {
        NSString *want = [@"Bearer " stringByAppendingString:expected];
        if (![auth isEqualToString:want]) {
            return LCJSON(@{@"ok": @NO, @"error": @"unauthorized"}, 401, nil);
        }
    }

    NSString *purePath = [path componentsSeparatedByString:@"?"].firstObject;
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        for (NSString *pair in [[path substringFromIndex:q.location + 1] componentsSeparatedByString:@"&"]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count == 2) query[kv[0]] = kv[1];
        }
    }

    // 全部 UI 操作都回主线程做
    __block NSData *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([purePath isEqualToString:@"/guest/info"]) {
            UIWindow *w = LCKeyWindow();
            // view* 是 guest 自己的坐标系（老 App 会按自己的逻辑分辨率铺满，可能不等于屏幕点），
            // 传 x/y 点击时必须用 view* 这套值，tree 里的 frame 也是它。
            UIView *root = w.rootViewController.view ?: w;
            result = LCJSON(@{@"ok": @YES, @"pid": @(getpid()),
                              @"bundleId": NSBundle.mainBundle.bundleIdentifier ?: @"",
                              @"width": @(w.bounds.size.width), @"height": @(w.bounds.size.height),
                              @"viewWidth": @(root.bounds.size.width),
                              @"viewHeight": @(root.bounds.size.height)}, 200, nil);
        } else if ([purePath isEqualToString:@"/guest/ocr"]) {
            NSArray<NSDictionary *> *items = LCRecognizeText();
            NSString *want = query[@"text"];
            if (want.length) {
                NSMutableArray *hit = [NSMutableArray array];
                for (NSDictionary *it in items) {
                    if ([it[@"text"] containsString:want]) [hit addObject:it];
                }
                result = LCJSON(@{@"ok": @YES, @"count": @(hit.count), @"items": hit}, 200, nil);
            } else {
                result = LCJSON(@{@"ok": @YES, @"count": @(items.count), @"items": items}, 200, nil);
            }
        } else if ([purePath isEqualToString:@"/guest/ui/tree"]) {
            NSMutableArray *items = [NSMutableArray array];
            NSArray<NSObject *> *all = LCCollect();
            [all enumerateObjectsUsingBlock:^(NSObject *o, NSUInteger i, BOOL *stop) {
                NSMutableDictionary *d = [LCDescribe(o) mutableCopy];
                d[@"index"] = @(i);
                [items addObject:d];
            }];
            result = LCJSON(@{@"ok": @YES, @"count": @(items.count), @"elements": items}, 200, nil);
        } else if ([purePath isEqualToString:@"/guest/ui/activate"] || [purePath isEqualToString:@"/guest/ui/tap"]) {
            NSDictionary *spec = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : @{};
            if (![spec isKindOfClass:NSDictionary.class]) spec = @{};
            NSDictionary *r = [purePath hasSuffix:@"/tap"] ? LCTap([spec[@"x"] doubleValue], [spec[@"y"] doubleValue])
                                                          : LCActivateSpec(spec);
            NSMutableDictionary *out = [r mutableCopy]; out[@"ok"] = r[@"ok"] ?: @NO;
            result = LCJSON(out, 200, nil);
        } else if ([purePath isEqualToString:@"/guest/ui/taps"]) {
            NSDictionary *spec = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : @{};
            NSArray *steps = [spec isKindOfClass:NSDictionary.class] ? spec[@"steps"] : nil;
            BOOL detect = spec[@"detectChange"] ? [spec[@"detectChange"] boolValue] : YES;
            NSMutableArray *out = [NSMutableArray array];
            for (NSDictionary *step in steps ?: @[]) {
                NSData *before = detect ? LCGrayThumb() : nil;
                NSDictionary *r = [step isKindOfClass:NSDictionary.class] ? LCActivateSpec(step)
                                                                          : @{@"ok": @NO, @"detail": @"step 不是对象"};
                NSInteger delay = step[@"delayMs"] ? [step[@"delayMs"] integerValue] : 400;
                if (delay > 0) [NSThread sleepForTimeInterval:delay / 1000.0];
                NSMutableDictionary *item = [@{@"ok": r[@"ok"] ?: @NO, @"detail": r[@"detail"] ?: @""} mutableCopy];
                if (detect) {
                    double ratio = LCDiffRatio(before, LCGrayThumb());
                    item[@"changed"] = @(ratio > 0.002);   // 0.2% 像素变化就算变了
                    item[@"diff"] = @(round(ratio * 10000) / 10000.0);
                }
                [out addObject:item];
            }
            result = LCJSON(@{@"ok": @YES, @"count": @(out.count), @"steps": out}, 200, nil);
        } else if ([purePath isEqualToString:@"/guest/ui/text"]) {
            NSDictionary *spec = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : @{};
            NSString *text = [spec isKindOfClass:NSDictionary.class] ? spec[@"text"] : nil;
            result = LCJSON(LCTextInput(text ?: @""), 200, nil);
        } else if ([purePath isEqualToString:@"/guest/screenshot"]) {
            CGFloat maxWidth = query[@"maxWidth"] ? [query[@"maxWidth"] doubleValue] : 600;
            CGFloat quality = query[@"quality"] ? [query[@"quality"] doubleValue] / 100.0 : 0.7;
            UIImage *img = LCSnapshot(maxWidth);
            NSData *d = UIImageJPEGRepresentation(img, quality);
            result = d ? LCBinary(d, @"image/jpeg", 200) : LCJSON(@{@"ok": @NO, @"error": @"capture failed"}, 500, nil);
        } else {
            result = LCJSON(@{@"ok": @NO, @"error": @"no route"}, 404, nil);
        }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20ull * NSEC_PER_SEC));
    return result ?: LCJSON(@{@"ok": @NO, @"error": @"timeout"}, 500, nil);
}

// ── socket 服务 ─────────────────────────────────────────────────────────────

static void LCServeConnection(int fd) {  // 需要 #include <sys/time.h>
    NSMutableData *buf = [NSMutableData data];
    uint8_t chunk[8192];
    NSData *headerEnd = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger headerLen = 0;
    long contentLength = 0;

    while (true) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buf appendBytes:chunk length:(NSUInteger)n];

        if (headerLen == 0) {
            NSRange r = [buf rangeOfData:headerEnd options:0 range:NSMakeRange(0, buf.length)];
            if (r.location == NSNotFound) {
                if (buf.length > 128 * 1024) break;
                continue;
            }
            headerLen = r.location + r.length;
            NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, r.location)]
                                                   encoding:NSUTF8StringEncoding];
            for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
                NSRange colon = [line rangeOfString:@":"];
                if (colon.location != NSNotFound) {
                    NSString *name = [[line substringToIndex:colon.location] lowercaseString];
                    NSString *value = [[line substringFromIndex:colon.location + 1]
                                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if ([name isEqualToString:@"content-length"]) contentLength = value.longLongValue;
                }
            }
        }
        if (buf.length >= headerLen + (NSUInteger)contentLength) break;
        if (buf.length > 64 * 1024 * 1024) break;
    }

    if (buf.length < headerLen) { close(fd); return; }

    NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, headerLen - 4)]
                                           encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
    NSString *method = requestLine.count > 0 ? requestLine[0] : @"GET";
    NSString *path = requestLine.count > 1 ? requestLine[1] : @"/";

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSRange colon = [lines[i] rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[lines[i] substringToIndex:colon.location] lowercaseString];
        NSString *value = [[lines[i] substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        headers[name] = value;
    }

    NSData *body = buf.length > headerLen ? [buf subdataWithRange:NSMakeRange(headerLen, buf.length - headerLen)] : [NSData data];
    fprintf(stderr, "[LCGuestSidecar] %s %s\n", method.UTF8String, path.UTF8String);
    NSData *resp = LCHandleRequest(method, path, headers, body);

    const uint8_t *bytes = resp.bytes;
    NSUInteger remaining = resp.length;
    while (remaining > 0) {
        ssize_t sent = send(fd, bytes, remaining, 0);
        if (sent <= 0) break;
        bytes += sent;
        remaining -= (NSUInteger)sent;
    }
    close(fd);
}

void LCGuestSidecarStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        signal(SIGPIPE, SIG_IGN);
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return;
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kLCGuestSidecarPort);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            fprintf(stderr, "[LCGuestSidecar] bind failed: %s\n", strerror(errno));
            close(fd);
            return;
        }
        if (listen(fd, 16) != 0) {
            fprintf(stderr, "[LCGuestSidecar] listen failed: %s\n", strerror(errno));
            close(fd);
            return;
        }

        // accept 循环必须和"处理连接"分开两个队列：如果都用同一个串行队列，
        // accept 循环永不返回，处理块永远排不上（真机表现就是请求挂到超时）。
        dispatch_queue_t acceptQ = dispatch_queue_create("lc.guest.sidecar.accept", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_t workQ = dispatch_queue_create("lc.guest.sidecar.work", DISPATCH_QUEUE_CONCURRENT);
        dispatch_async(acceptQ, ^{
            fprintf(stderr, "[LCGuestSidecar] listening on 127.0.0.1:%d\n", kLCGuestSidecarPort);
            while (true) {
                int client = accept(fd, NULL, NULL);
                if (client < 0) continue;
                struct timeval tv = { 10, 0 };
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
                dispatch_async(workQ, ^{ LCServeConnection(client); });
            }
        });
    });
}
