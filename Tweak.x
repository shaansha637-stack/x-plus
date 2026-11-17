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
    if
