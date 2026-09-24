#import <UIKit/UIKit.h>
#import "GameLauncher.h"
#import "SDLCheck.h"
#import "ResourceCheck.h"

static void SaveReport(NSDictionary *values, NSString *filename, BOOL complete) {
    NSMutableDictionary *report = [values mutableCopy];
    const char *token = getenv("EMU_CHECK_TOKEN");
    report[@"token"] = token ? @(token) : @"";
    report[@"complete"] = @(complete);
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:filename];
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:path options:NSDataWritingAtomic error:nil];
}

@interface EmuController : UIViewController
@property(nonatomic, strong) UITextView *status;
@property(nonatomic) BOOL started;
- (void)start;
@end

@implementation EmuController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.status = [[UITextView alloc] init];
    self.status.editable = NO;
    self.status.font = [UIFont systemFontOfSize:19 weight:UIFontWeightRegular];
    self.status.text = @"Starting SnowRunner…";
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.status];
    UILayoutGuide *area = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.status.leadingAnchor constraintEqualToAnchor:area.leadingAnchor constant:24],
        [self.status.trailingAnchor constraintEqualToAnchor:area.trailingAnchor constant:-24],
        [self.status.topAnchor constraintEqualToAnchor:area.topAnchor constant:16],
        [self.status.bottomAnchor constraintEqualToAnchor:area.bottomAnchor constant:-16]
    ]];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self start]; }
- (void)start {
    if (self.started || self.view.window.windowScene.activationState != UISceneActivationStateForegroundActive) return;
    self.started = YES;
    NSString *mode = getenv("EMU_MODE") ? @(getenv("EMU_MODE")) : @"game";
    BOOL directoriesReady = EmuCreateResourceDirectories();
    if ([mode isEqualToString:@"maintenance"]) {
        NSDictionary *disk = [NSFileManager.defaultManager attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
        SaveReport(@{@"passed":@(directoriesReady && disk[NSFileSystemFreeSize] != nil),
                     @"availableBytes":disk[NSFileSystemFreeSize] ?: @0}, @"maintenance-ready.json", YES);
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        self.status.text = @"Ready to transfer game files.\n\nFollow the progress on your Mac. When copying finishes, run:\n\n./emu launch";
        return;
    }
    if ([mode isEqualToString:@"verify-resources"]) {
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        self.status.text = @"Checking game files…\n\nKeep this app open.";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSDictionary *result = EmuVerifyResources(^(NSUInteger count, NSUInteger total, NSString *file) {
                SaveReport(@{@"checkedFiles":@(count), @"totalFiles":@(total)}, @"resource-check.json", NO);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.status.text = [NSString stringWithFormat:@"Checking game files: %lu / %lu\n\n%@", (unsigned long)count, (unsigned long)total, file.lastPathComponent];
                });
            });
            SaveReport(result, @"resource-check.json", YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                UIApplication.sharedApplication.idleTimerDisabled = NO;
                self.status.text = [result[@"passed"] boolValue] ? @"All game files verified.\n\nRun ./emu launch on your Mac, then open the game." :
                    [NSString stringWithFormat:@"Some game files need copying.\n\nRun ./emu resources on your Mac.\n\n%@", result[@"errors"]];
            });
        });
        return;
    }
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        if ([mode isEqualToString:@"check"]) {
            self.status.text = @"Checking SDL, graphics and touch controls…";
            RunSDLCheck(self.view.window, ^(NSDictionary *result, NSString *message) {
                SaveReport(result, @"sdl-check.json", YES);
                self.status.text = message;
            });
            return;
        }
        NSArray *missing = EmuMissingResources();
        if (missing.count) {
            self.status.text = [NSString stringWithFormat:@"Game files are not ready (%lu files).\n\nOn your Mac, run:\n./emu resources\n\nIf the files were copied earlier, check them with:\n./emu resources --verify", (unsigned long)missing.count];
            return;
        }
        NSDictionary *result = LaunchGame();
        [self.view.window makeKeyAndVisible];
        SaveReport(result, @"launch-error.json", YES);
        self.status.text = [NSString stringWithFormat:@"SnowRunner stopped.\n\n%@\n\nRun ./emu logs on your Mac for details.", result[@"error"] ?: result];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)sceneDidBecomeActive:(UIScene *)scene { [(EmuController *)self.window.rootViewController start]; }
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [EmuController new];
    [self.window makeKeyAndVisible];
    UIWindowSceneGeometryPreferencesIOS *geometry = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
    [(UIWindowScene *)scene requestGeometryUpdateWithPreferences:geometry errorHandler:^(NSError *error) { NSLog(@"Orientation: %@", error); }];
}
@end
@interface AppDelegate : UIResponder <UIApplicationDelegate> @end
@implementation AppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = SceneDelegate.class;
    return configuration;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
