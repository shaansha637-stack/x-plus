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

static void XPOpenTabCustomization(void) {
    Class cls = NSClassFromString(@"T1TabCustomizationViewController");
    UIViewController *top = XPTopViewController();
    if (!cls || !top) { XPAlert(@"Tab customization", @"T1TabCustomizationViewController was not found in this X version."); return; }
    UIViewController *vc = nil;
    @try { vc = [[cls alloc] init]; } @catch (__unused NSException *e) {}
    if (![vc isKindOfClass:[UIViewController class]]) {
        NSMutableArray *inits = [NSMutableArray array];
        unsigned int n = 0; Method *ms = class_copyMethodList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *s = NSStringFromSelector(method_getName(ms[i]));
            if ([s hasPrefix:@"init"]) [inits addObject:s];
        }
        free(ms);
        XPAlert(@"Could not create the screen", [NSString stringWithFormat:@"Init methods:\n%@", [inits componentsJoinedByString:@"\n"]]);
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [top presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Settings screen

@interface XPSettingsViewController : UITableViewController
@end

@implementation XPSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"XPlus";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(close)];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? (NSInteger)XPItems().count : 1;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        [self dismissViewControllerAnimated:YES completion:^{ XPOpenTabCustomization(); }];
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) return nil;
    return @"Changes apply immediately. Some options need an app restart to fully take effect. Long-press the Home tab to open this screen.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        c.textLabel.text = @"Open Native Tab Customization";
        c.detailTextLabel.text = @"Experimental: opens X's own navigation bar editor.";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *item = XPItems()[ip.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"sub"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [UISwitch new];
    sw.on = XPGet(item[@"key"], [item[@"def"] boolValue]);
    sw.tag = ip.row;
    [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)toggled:(UISwitch *)sw {
    XPSet(XPItems()[sw.tag][@"key"], sw.isOn);
}

@end

static void XPPresentSettings(void) {
    UIViewController *top = XPTopViewController();
    if (!top) return;
    if ([top isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:[XPSettingsViewController class]]) return;
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:[XPSettingsViewController new]];
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
