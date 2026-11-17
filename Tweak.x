// XPlus - personal customization tweak for the X (Twitter) iOS app.
// Design rules:
//  * Never touches the Keychain, cookies or app data (so no logout issues).
//  * Only hooks selectors that exist in the current X build (verified by
//    checking they are hooked by a working tweak on the same X version).
//  * Settings: long-press the Home tab (shake is a temporary fallback).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Photos/Photos.h>

#pragma mark - Preferences

static NSString *const kPrefix = @"xplus_";

static NSArray<NSDictionary *> *XPItems(void) {
    return @[
        @{@"key": @"hidePromoted",  @"title": @"Hide Promoted Posts",
          @"sub": @"Stops ads / promoted content from loading.", @"def": @YES},
        @{@"key": @"hqImages",      @"title": @"Always Load High Quality Images",
          @"sub": @"Use the high quality image path.", @"def": @YES},
        @{@"key": @"hideSensitive", @"title": @"Hide Sensitive Content Alerts",
          @"sub": @"Turns off sensitive-content warning screens.", @"def": @YES},
        @{@"key": @"hideGrok",      @"title": @"Hide Ask Grok Button",
          @"sub": @"Hides the Ask Grok button on posts.", @"def": @YES},
        @{@"key": @"hidePill",      @"title": @"Hide Timeline Update Pill",
          @"sub": @"Hides the 'new posts' pill.", @"def": @NO},
        @{@"key": @"keepTabBar",    @"title": @"Keep Tab Bar Visible",
          @"sub": @"Tab bar does not collapse when scrolling.", @"def": @NO},
        @{@"key": @"skipLaunch",    @"title": @"Skip Launch Animation",
          @"sub": @"Speeds up the animated splash screen when X opens.", @"def": @YES},
        @{@"key": @"downloads",     @"title": @"Media Downloads",
          @"sub": @"Long-press a photo/video in a post to save it to Photos.", @"def": @YES},
        @{@"key": @"navCustom",     @"title": @"Native Tab Customization",
          @"sub": @"Unlocks X's own navigation bar customization screen.", @"def": @YES},
        @{@"key": @"inspector",     @"title": @"Inspector Mode (developer)",
          @"sub": @"Long-press with TWO fingers on any element to see its class names. Used to add new features.", @"def": @NO},
    ];
}

static BOOL XPGet(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:[kPrefix stringByAppendingString:key]];
    return v ? [v boolValue] : def;
}

static void XPSet(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:[kPrefix stringByAppendingString:key]];
}

#pragma mark - Helpers

static UIWindow *XPKeyWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

static UIViewController *XPTopViewController(void) {
    UIViewController *vc = XPKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}


#pragma mark - Generic helpers (alerts, safe runtime access)

static void XPAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = XPTopViewController();
        if (!top) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

static void XPToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = XPTopViewController();
        if (!top) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [top presentViewController:a animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [a dismissViewControllerAnimated:YES completion:nil]; });
        }];
    });
}

// Calls a no-argument getter only if it exists and returns an object (or a scalar number).
static id XPSafeValue(id obj, NSString *name) {
    if (!obj || !name) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return nil;
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return nil;
    @try {
        if (enc[0] == '@') {
            id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            return send(obj, sel);
        }
        if (enc[0] && strchr("cCsSiIlLqQ", enc[0])) return [obj valueForKey:name];
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSURL *XPURLFrom(id v) {
    if ([v isKindOfClass:[NSURL class]]) return v;
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return [NSURL URLWithString:v];
    return nil;
}

#pragma mark - Media finder (walks X's own objects looking for media entities)

static BOOL XPAllowedClass(Class c) {
    NSString *n = NSStringFromClass(c);
    for (NSString *p in @[@"T1", @"TFN", @"TFS", @"THF", @"TTA", @"TUI", @"TweetMedia", @"_TtC"]) {
        if ([n hasPrefix:p]) return YES;
    }
    return NO;
}

static NSArray *XPFindMediaEntities(id root, NSMutableOrderedSet *seenClasses) {
    NSMutableArray *found = [NSMutableArray array];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:@[root, @0]];
    NSMutableSet *visited = [NSMutableSet set];
    NSArray *probe = @[@"status", @"statusViewModel", @"viewModel", @"mediaEntities", @"allMediaEntities",
                       @"inlineMediaInfos", @"media", @"mediaEntity", @"attachment", @"entities"];
    NSUInteger steps = 0;
    while (queue.count && steps++ < 500) {
        NSArray *item = queue.firstObject; [queue removeObjectAtIndex:0];
        id o = item[0]; int depth = [item[1] intValue];
        if (!o) continue;
        NSValue *key = [NSValue valueWithNonretainedObject:o];
        if ([visited containsObject:key]) continue;
        [visited addObject:key];

        if ([o isKindOfClass:[NSArray class]] || [o isKindOfClass:[NSSet class]] || [o isKindOfClass:[NSOrderedSet class]]) {
            if (depth > 6) continue;
            for (id e in o) [queue addObject:@[e, @(depth + 1)]];
            continue;
        }
        Class cls = object_getClass(o);
        NSString *cn = NSStringFromClass(cls);
        if (!XPAllowedClass(cls)) continue;
        [seenClasses addObject:cn];
        if ([cn isEqualToString:@"TFSTwitterEntityMedia"]) { [found addObject:o]; continue; }
        if (depth >= 6) continue;

        for (NSString *name in probe) {
            id v = XPSafeValue(o, name);
            if (v && ![v isKindOfClass:[NSNumber class]]) [queue addObject:@[v, @(depth + 1)]];
        }
        for (Class c = cls; c && XPAllowedClass(c); c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Ivar *ivars = class_copyIvarList(c, &n);
            for (unsigned int i = 0; i < n; i++) {
                const char *enc = ivar_getTypeEncoding(ivars[i]);
                if (!enc || enc[0] != '@') continue;
                id v = object_getIvar(o, ivars[i]);
                if (v) [queue addObject:@[v, @(depth + 1)]];
            }
            free(ivars);
        }
    }
    return found;
}

// Turns media entities into downloadable options: {title, url, video}
static NSArray<NSDictionary *> *XPMediaOptions(NSArray *entities) {
    NSMutableArray *opts = [NSMutableArray array];
    int photoIndex = 0;
    for (id e in entities) {
        id videoInfo = XPSafeValue(e, @"videoInfo");
        NSArray *variants = videoInfo ? XPSafeValue(videoInfo, @"variants") : nil;
        if ([variants isKindOfClass:[NSArray class]] && variants.count) {
            NSURL *best = nil; double bestRate = -1;
            for (id v in variants) {
                NSURL *u = XPURLFrom(XPSafeValue(v, @"url")) ?: XPURLFrom(XPSafeValue(v, @"URL"));
                if (!u) continue;
                NSString *ct = [XPSafeValue(v, @"contentType") description] ?: @"";
                BOOL isMP4 = [u.absoluteString containsString:@".mp4"] || [ct containsString:@"mp4"];
                if (!isMP4) continue;
                double rate = [[XPSafeValue(v, @"bitrate") description] doubleValue];
                if (rate > bestRate) { bestRate = rate; best = u; }
            }
            if (best) [opts addObject:@{@"title": @"Save Video", @"url": best, @"video": @YES}];
            continue;
        }
        for (NSString *k in @[@"mediaURL", @"mediaUrl", @"mediaURLHTTPS", @"imageURL", @"originalImageURL", @"url"]) {
            NSURL *u = XPURLFrom(XPSafeValue(e, k));
            if (!u) continue;
            NSString *s = u.absoluteString;
            if (![s containsString:@"twimg.com"] && ![s hasSuffix:@".jpg"] && ![s hasSuffix:@".png"]) continue;
            if ([s containsString:@"pbs.twimg.com/media"] && !u.query) {
                u = [NSURL URLWithString:[s stringByAppendingString:@"?name=orig"]] ?: u;
            }
            photoIndex++;
            [opts addObject:@{@"title": [NSString stringWithFormat:@"Save Photo %d", photoIndex], @"url": u, @"video": @NO}];
            break;
        }
    }
    return opts;
}

static void XPDownloadAndSave(NSURL *url, BOOL isVideo) {
    XPToast(@"Downloading...");
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url
        completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
            if (err || !loc) { XPAlert(@"Download failed", err.localizedDescription ?: @"No file received."); return; }
            NSString *ext = isVideo ? @"mp4" : (url.pathExtension.length ? url.pathExtension : @"jpg");
            NSURL *dst = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"xplus_%@.%@", NSUUID.UUID.UUIDString, ext]]];
            [[NSFileManager defaultManager] moveItemAtURL:loc toURL:dst error:nil];
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus st) {
                if (st != PHAuthorizationStatusAuthorized && st != PHAuthorizationStatusLimited) {
                    XPAlert(@"Photos access denied", @"Allow adding photos for X in iOS Settings.");
                    return;
                }
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    if (isVideo) [PHAssetCreationRequest creationRequestForAssetFromVideoAtFileURL:dst];
                    else         [PHAssetCreationRequest creationRequestForAssetFromImageAtFileURL:dst];
                } completionHandler:^(BOOL ok, NSError *e) {
                    [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];
                    if (ok) XPToast(isVideo ? @"Video saved" : @"Photo saved");
                    else XPAlert(@"Save failed", e.localizedDescription ?: @"Unknown error");
                }];
            }];
        }];
    [task resume];
}

@interface XPMediaLongPress : NSObject
+ (instancetype)shared;
- (void)handle:(UILongPressGestureRecognizer *)g;
@end

@implementation XPMediaLongPress
+ (instancetype)shared {
    static XPMediaLongPress *i; static dispatch_once_t once;
    dispatch_once(&once, ^{ i = [XPMediaLongPress new]; });
    return i;
}
- (void)handle:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || !XPGet(@"downloads", YES)) return;
    UIView *root = g.view;
    UIView *v = g.view;
    for (int i = 0; i < 10 && v; i++, v = v.superview) {
        NSString *n = NSStringFromClass([v class]);
        if ([n isEqualToString:@"T1StandardStatusView"] || [n isEqualToString:@"T1StatusCell"]) { root = v; break; }
    }
    NSMutableOrderedSet *seen = [NSMutableOrderedSet orderedSet];
    NSArray *entities = XPFindMediaEntities(root, seen);
    NSArray<NSDictionary *> *opts = XPMediaOptions(entities);
    if (!opts.count) {
        NSArray *names = [seen.array subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)30, seen.count))];
        XPAlert(@"No downloadable media found",
                [NSString stringWithFormat:@"Entities: %lu\nIf this keeps happening, send a screenshot of this message.\n\nClasses seen:\n%@",
                 (unsigned long)entities.count, [names componentsJoinedByString:@"\n"]]);
        return;
    }
    [[UIImpactFeedbackGenerator new] impactOccurred];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"XPlus Download" message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *o in opts) {
        [sheet addAction:[UIAlertAction actionWithTitle:o[@"title"] style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) { XPDownloadAndSave(o[@"url"], [o[@"video"] boolValue]); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = g.view;
    sheet.popoverPresentationController.sourceRect = g.view.bounds;
    [XPTopViewController() presentViewController:sheet animated:YES completion:nil];
}
@end

#pragma mark - Native tab customization screen

// Finds X's current account object by asking view controllers for `account` / `currentAccount`.
static id XPFindAccountInVC(UIViewController *vc, int depth, NSMutableSet *seen) {
    if (!vc || depth > 10) return nil;
    NSValue *k = [NSValue valueWithNonretainedObject:vc];
    if ([seen containsObject:k]) return nil;
    [seen addObject:k];
    for (NSString *key in @[@"account", @"currentAccount"]) {
        id a = XPSafeValue(vc, key);
        if (a && [NSStringFromClass([a class]) containsString:@"Account"]) return a;
    }
    NSMutableArray *kids = [NSMutableArray arrayWithArray:vc.childViewControllers];
    if (vc.presentedViewController) [kids addObject:vc.presentedViewController];
    for (UIViewController *c in kids) {
        id a = XPFindAccountInVC(c, depth + 1, seen);
        if (a) return a;
    }
    return nil;
}

static id XPFindCurrentAccount(void) {
    id a = XPFindAccountInVC(XPKeyWindow().rootViewController, 0, [NSMutableSet set]);
    if (a) return a;
    id delegate = UIApplication.sharedApplication.delegate;
    for (NSString *key in @[@"currentAccount", @"account"]) {
        a = XPSafeValue(delegate, key);
        if (a && [NSStringFromClass([a class]) containsString:@"Account"]) return a;
    }
    return nil;
}

static id XPMakeScribeContext(void) {
    Class cls = NSClassFromString(@"TFSTwitterScribeContext");
    if (!cls) return nil;
    @try {
        SEL s = NSSelectorFromString(@"scribeContextWithPage:");
        Method m = class_getClassMethod(cls, s);
        if (m && method_getNumberOfArguments(m) == 3 && method_getTypeEncoding(m)[0] == '@') {
            id (*send)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id c = send(cls, s, @"home");
            if (c) return c;
        }
        return [[cls alloc] init];
    } @catch (__unused NSException *e) {}
    return nil;
}

static void XPOpenTabCustomization(UINavigationController *nav) {
    Class cls = NSClassFromString(@"T1TabCustomizationViewController");
    if (!cls) { XPAlert(@"Tab customization", @"T1TabCustomizationViewController was not found in this X version."); return; }
    SEL initSel = NSSelectorFromString(@"initWithAccount:scribeContext:");
    if (![cls instancesRespondToSelector:initSel]) { XPAlert(@"Tab customization", @"initWithAccount:scribeContext: is not available in this X version."); return; }

    id account = XPFindCurrentAccount();
    if (!account) { XPAlert(@"Tab customization", @"Could not find the current account object. Close this screen, open the Home timeline, and try again."); return; }
    id ctx = XPMakeScribeContext();

    UIViewController *vc = nil;
    @try {
        id (*initWith)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        vc = initWith([cls alloc], initSel, account, ctx);
    } @catch (NSException *e) {
        XPAlert(@"Tab customization failed", e.reason ?: @"Exception while creating the screen.");
        return;
    }
    if (![vc isKindOfClass:[UIViewController class]]) { XPAlert(@"Tab customization", @"The screen could not be created."); return; }

    if (nav) [nav pushViewController:vc animated:YES];
    else [XPTopViewController() presentViewController:[[UINavigationController alloc] initWithRootViewController:vc] animated:YES completion:nil];
}

#pragma mark - Settings screen (modern design)

#define XP_ACCENT [UIColor colorWithRed:0.114 green:0.608 blue:0.941 alpha:1.0]
#define XP_BG     [UIColor colorWithRed:0.0   green:0.0   blue:0.0   alpha:1.0]
#define XP_CARD   [UIColor colorWithRed:0.086 green:0.094 blue:0.110 alpha:1.0]
#define XP_TEXT   [UIColor colorWithRed:0.906 green:0.914 blue:0.918 alpha:1.0]
#define XP_MUTED  [UIColor colorWithRed:0.443 green:0.463 blue:0.486 alpha:1.0]
#define XP_LINE   [UIColor colorWithRed:0.184 green:0.200 blue:0.212 alpha:1.0]

static UIImage *XPIconTile(NSString *symbol, UIColor *color) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(30, 30)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 30, 30) cornerRadius:8] fill];
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [[UIImage systemImageNamed:symbol withConfiguration:cfg]
                        imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (sym) {
            CGSize sz = sym.size;
            [sym drawInRect:CGRectMake((30 - sz.width) / 2, (30 - sz.height) / 2, sz.width, sz.height)];
        }
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static NSArray<NSDictionary *> *XPLayout(void) {
    return @[
        @{@"title": @"CONTENT",    @"keys": @[@"hidePromoted", @"hideSensitive", @"hideGrok", @"hidePill"]},
        @{@"title": @"MEDIA",      @"keys": @[@"hqImages", @"downloads"]},
        @{@"title": @"INTERFACE",  @"keys": @[@"keepTabBar", @"skipLaunch"]},
        @{@"title": @"NAVIGATION", @"keys": @[@"navCustom"], @"action": @YES},
        @{@"title": @"DEVELOPER",  @"keys": @[@"inspector"]},
    ];
}

static NSDictionary *XPItemForKey(NSString *key) {
    for (NSDictionary *d in XPItems()) if ([d[@"key"] isEqualToString:key]) return d;
    return nil;
}

static UIImage *XPIconForKey(NSString *key) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"hidePromoted":  @[@"megaphone.fill", [UIColor colorWithRed:1.0 green:0.58 blue:0.0 alpha:1]],
            @"hideSensitive": @[@"eye.slash.fill", [UIColor colorWithRed:0.69 green:0.32 blue:0.87 alpha:1]],
            @"hideGrok":      @[@"sparkles", [UIColor colorWithRed:0.35 green:0.34 blue:0.84 alpha:1]],
            @"hidePill":      @[@"arrow.up.circle.fill", [UIColor colorWithRed:0.19 green:0.69 blue:0.78 alpha:1]],
            @"hqImages":      @[@"photo.fill", [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1]],
            @"downloads":     @[@"arrow.down.circle.fill", [UIColor colorWithRed:0.114 green:0.608 blue:0.941 alpha:1]],
            @"keepTabBar":    @[@"square.grid.2x2.fill", [UIColor colorWithRed:0.35 green:0.78 blue:0.98 alpha:1]],
            @"skipLaunch":    @[@"bolt.fill", [UIColor colorWithRed:1.0 green:0.80 blue:0.0 alpha:1]],
            @"navCustom":     @[@"slider.horizontal.3", [UIColor colorWithRed:1.0 green:0.18 blue:0.33 alpha:1]],
            @"inspector":     @[@"hammer.fill", [UIColor colorWithRed:0.56 green:0.56 blue:0.58 alpha:1]],
            @"_action":       @[@"arrow.up.forward.app.fill", [UIColor colorWithRed:0.114 green:0.608 blue:0.941 alpha:1]],
        };
    });
    NSArray *p = map[key];
    return p ? XPIconTile(p[0], p[1]) : nil;
}

@interface XPSettingsViewController : UITableViewController
@end

@implementation XPSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.title = @"Settings";
    self.view.backgroundColor = XP_BG;
    self.tableView.backgroundColor = XP_BG;
    self.tableView.separatorColor = XP_LINE;
    self.tableView.showsVerticalScrollIndicator = NO;

    UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
    [ap configureWithTransparentBackground];
    ap.titleTextAttributes = @{NSForegroundColorAttributeName: XP_TEXT};
    self.navigationItem.standardAppearance = ap;
    self.navigationItem.scrollEdgeAppearance = ap;

    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
                                                              style:UIBarButtonItemStylePlain
                                                             target:self action:@selector(close)];
    close.tintColor = XP_MUTED;
    self.navigationItem.rightBarButtonItem = close;

    [self buildHeader];
}

- (void)buildHeader {
    CGFloat w = self.view.bounds.size.width;
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 158)];
    h.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake((w - 64) / 2, 12, 64, 64)];
    badge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = badge.bounds;
    g.cornerRadius = 18;
    g.colors = @[(id)XP_ACCENT.CGColor,
                 (id)[UIColor colorWithRed:0.50 green:0.30 blue:0.95 alpha:1.0].CGColor];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint = CGPointMake(1, 1);
    [badge.layer addSublayer:g];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightBold];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles" withConfiguration:cfg]];
    iv.tintColor = UIColor.whiteColor;
    iv.contentMode = UIViewContentModeCenter;
    iv.frame = badge.bounds;
    [badge addSubview:iv];
    [h addSubview:badge];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 88, w, 30)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = @"XPlus";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = XP_TEXT;
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightHeavy];
    [h addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 120, w, 20)];
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    sub.text = @"Custom features for X  \u00B7  v1.0";
    sub.textAlignment = NSTextAlignmentCenter;
    sub.textColor = XP_MUTED;
    sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [h addSubview:sub];

    self.tableView.tableHeaderView = h;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return XPLayout().count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    NSDictionary *sec = XPLayout()[s];
    return [sec[@"keys"] count] + ([sec[@"action"] boolValue] ? 1 : 0);
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return XPLayout()[s][@"title"];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == (NSInteger)XPLayout().count - 1) return @"Long-press the Home tab to open this screen. Some options need an app restart to fully take effect.";
    return nil;
}

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    UITableViewHeaderFooterView *hv = (UITableViewHeaderFooterView *)view;
    hv.textLabel.textColor = XP_MUTED;
    hv.textLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
}

- (void)tableView:(UITableView *)tv willDisplayFooterView:(UIView *)view forSection:(NSInteger)s {
    UITableViewHeaderFooterView *fv = (UITableViewHeaderFooterView *)view;
    fv.textLabel.textColor = XP_MUTED;
    fv.textLabel.font = [UIFont systemFontOfSize:12];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *sec = XPLayout()[ip.section];
    NSArray *keys = sec[@"keys"];

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = XP_CARD;
    cell.textLabel.textColor = XP_TEXT;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    cell.detailTextLabel.textColor = XP_MUTED;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5];
    cell.detailTextLabel.numberOfLines = 0;
    cell.separatorInset = UIEdgeInsetsMake(0, 62, 0, 0);
    UIView *sel = [UIView new];
    sel.backgroundColor = XP_LINE;
    cell.selectedBackgroundView = sel;

    if (ip.row >= (NSInteger)keys.count) {
        cell.imageView.image = XPIconForKey(@"_action");
        cell.textLabel.text = @"Open Tab Customization";
        cell.textLabel.textColor = XP_ACCENT;
        cell.detailTextLabel.text = @"Opens X's native navigation bar editor.";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.tintColor = XP_MUTED;
        return cell;
    }

    NSDictionary *item = XPItemForKey(keys[ip.row]);
    cell.imageView.image = XPIconForKey(item[@"key"]);
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"sub"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *sw = [UISwitch new];
    sw.onTintColor = XP_ACCENT;
    sw.on = XPGet(item[@"key"], [item[@"def"] boolValue]);
    sw.accessibilityIdentifier = item[@"key"];
    [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *sec = XPLayout()[ip.section];
    if (ip.row >= (NSInteger)[sec[@"keys"] count]) XPOpenTabCustomization(self.navigationController);
}

- (void)toggled:(UISwitch *)sw {
    XPSet(sw.accessibilityIdentifier, sw.isOn);
    [[UISelectionFeedbackGenerator new] selectionChanged];
}

@end

static void XPPresentSettings(void) {
    UIViewController *top = XPTopViewController();
    if (!top) return;
    if ([top isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:[XPSettingsViewController class]]) return;
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:[XPSettingsViewController new]];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [top presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Inspector (finds class names for new features)

@interface XPInspector : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)install;
@end

@implementation XPInspector {
    BOOL _installed;
}

+ (instancetype)shared {
    static XPInspector *i; static dispatch_once_t once;
    dispatch_once(&once, ^{ i = [XPInspector new]; });
    return i;
}

- (void)install {
    if (_installed) return;
    UIWindow *w = XPKeyWindow();
    if (!w) return;
    UILongPressGestureRecognizer *g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handle:)];
    g.numberOfTouchesRequired = 2;
    g.minimumPressDuration = 0.8;
    g.cancelsTouchesInView = NO;
    g.delegate = self;
    [w addGestureRecognizer:g];
    _installed = YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (void)handle:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || !XPGet(@"inspector", NO)) return;
    UIView *hit = [g.view hitTest:[g locationInView:g.view] withEvent:nil];
    NSMutableArray *lines = [NSMutableArray array];
    UIResponder *r = hit;
    int n = 0;
    while (r && n < 24) {
        [lines addObject:NSStringFromClass([r class])];
        r = r.nextResponder; n++;
    }
    NSString *text = [lines componentsJoinedByString:@"\n"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"XPlus Inspector"
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { UIPasteboard.generalPasteboard.string = text; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [XPTopViewController() presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - Long-press on Home tab opens settings

static const void *kXPLongPressKey = &kXPLongPressKey;

// The Home tab is found by its accessibility label ("Home"). If the tab has
// no label at all, we fall back to "first tab in its container".
static BOOL XPIsHomeTab(UIView *v) {
    NSString *label = [NSString stringWithFormat:@"%@ %@",
                       v.accessibilityLabel ?: @"", v.accessibilityIdentifier ?: @""].lowercaseString;
    NSString *trimmed = [label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length > 0) return [trimmed containsString:@"home"];
    for (UIView *sib in v.superview.subviews) {
        if ([sib isKindOfClass:[v class]]) return sib == v;
    }
    return NO;
}

@interface XPTabLongPress : NSObject
+ (instancetype)shared;
- (void)handle:(UILongPressGestureRecognizer *)g;
@end

@implementation XPTabLongPress
+ (instancetype)shared {
    static XPTabLongPress *i; static dispatch_once_t once;
    dispatch_once(&once, ^{ i = [XPTabLongPress new]; });
    return i;
}
- (void)handle:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!XPIsHomeTab(g.view)) return;
    [[UIImpactFeedbackGenerator new] impactOccurred];
    XPPresentSettings();
}
@end

#pragma mark - Hooks: temporary fallback - shake opens settings
// Delete this whole %hook UIWindow block once Home long-press works for you.

%hook UIWindow
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    %orig;
    if (motion == UIEventSubtypeMotionShake) XPPresentSettings();
}
%end

#pragma mark - Hooks: X features (selectors verified in the current X build)

@interface TFNTwitterAPICommandContext : NSObject @end
%hook TFNTwitterAPICommandContext
- (BOOL)allowPromotedContent {
    return XPGet(@"hidePromoted", YES) ? NO : %orig;
}
%end

@interface TFNTwitterAccount : NSObject @end
%hook TFNTwitterAccount
- (BOOL)isVideoDynamicAdEnabled {
    return XPGet(@"hidePromoted", YES) ? NO : %orig;
}
- (BOOL)isSensitiveTweetWarningsConsumeEnabled {
    return XPGet(@"hideSensitive", YES) ? NO : %orig;
}
%end

@interface T1ImageDisplayView : UIView @end
%hook T1ImageDisplayView
- (BOOL)_tfn_shouldUseHighQualityImage {
    return XPGet(@"hqImages", YES) ? YES : %orig;
}
%end

@interface T1TabBarViewController : UIViewController @end
%hook T1TabBarViewController
- (void)setTabBarCollapseRatio:(double)ratio {
    %orig(XPGet(@"keepTabBar", NO) ? 0.0 : ratio);
}
%end

@interface T1StandardStatusAskGrokButtonView : UIView @end
%hook T1StandardStatusAskGrokButtonView
- (void)didMoveToWindow {
    %orig;
    if (XPGet(@"hideGrok", YES)) self.hidden = YES;
}
%end

@interface TUIUpdateIndicator : NSObject @end
%hook TUIUpdateIndicator
- (void)_recreatePillControlForContentNotification:(void *)notification hideOnScroll:(BOOL)hide {
    if (XPGet(@"hidePill", NO)) return;
    %orig;
}
%end

@interface T1TabView : UIView @end
%hook T1TabView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    if (objc_getAssociatedObject(self, kXPLongPressKey)) return;
    UILongPressGestureRecognizer *g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[XPTabLongPress shared]
                                                      action:@selector(handle:)];
    g.minimumPressDuration = 0.6;
    g.cancelsTouchesInView = NO;
    [self addGestureRecognizer:g];
    objc_setAssociatedObject(self, kXPLongPressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end

@interface T1AnimatedLaunchScreenView : UIView @end
%hook T1AnimatedLaunchScreenView
- (void)animateRevealWithCompletion:(void *)completion {
    if (XPGet(@"skipLaunch", YES)) self.layer.speed = 100.0f;
    %orig(completion);
}
%end

@interface T1TabCustomizationConfig : NSObject @end
%hook T1TabCustomizationConfig
- (BOOL)isTabCustomizationEnabled {
    return XPGet(@"navCustom", YES) ? YES : %orig;
}
%end

static const void *kXPMediaKey = &kXPMediaKey;

@interface T1StatusPhotoVideoForwardView : UIView @end
%hook T1StatusPhotoVideoForwardView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    if (objc_getAssociatedObject(self, kXPMediaKey)) return;
    UILongPressGestureRecognizer *g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[XPMediaLongPress shared] action:@selector(handle:)];
    g.minimumPressDuration = 0.6;
    g.cancelsTouchesInView = NO;
    [self addGestureRecognizer:g];
    objc_setAssociatedObject(self, kXPMediaKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end

#pragma mark - Constructor

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) { [[XPInspector shared] install]; }];
}