// XPlus - personal customization tweak for the X (Twitter) iOS app.
// Design rules:
//  * Never touches the Keychain, cookies or app data (so no logout issues).
//  * Only hooks selectors that exist in the current X build (verified by
//    checking they are hooked by a working tweak on the same X version).
//  * Settings: long-press the Home tab (shake is a temporary fallback).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return XPItems().count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"Changes apply immediately. Some options need an app restart to fully take effect. Long-press the Home tab to open this screen.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
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

#pragma mark - Constructor

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) { [[XPInspector shared] install]; }];
}
