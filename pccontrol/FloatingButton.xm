#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <ifaddrs.h>
#include <arpa/inet.h>

#import "FloatingButton.h"
#import "Popup.h"
#import "Record.h"
#import "Play.h"
#include "Common.h"

#define BUN_SIZE 54.0f
#define CARD_W 250.0f
#define CARD_H 246.0f

static NSString *const kPositionPath = @"/var/mobile/Library/ZXTouch/config/tweak/floating.plist";
static NSString *const kEnabledKey = @"floating_button";

extern PopupWindow *popupWindow;

static UIColor *bunPink(void) {
    return [UIColor colorWithRed:1.0 green:0.353 blue:0.431 alpha:1.0];
}

static BOOL bunEnabled(void) {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:getCommonConfigFilePath()];
    return config[kEnabledKey] ? [config[kEnabledKey] boolValue] : YES;
}

static void bunSetEnabled(BOOL enabled) {
    NSString *path = getCommonConfigFilePath();
    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    config[kEnabledKey] = @(enabled);
    [config writeToFile:path atomically:YES];
}

static NSString *bunWiFiAddress(void) {
    NSString *address = nil;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    for (struct ifaddrs *item = list; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(item->ifa_name, "en0") != 0) continue;
        char text[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *socketAddress = (struct sockaddr_in *)item->ifa_addr;
        if (inet_ntop(AF_INET, &socketAddress->sin_addr, text, sizeof(text)))
            address = [NSString stringWithUTF8String:text];
    }
    freeifaddrs(list);
    return address;
}

@interface BunFloating : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *bubble;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *info;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) CGPoint origin;
- (void)reload;
@end

@implementation BunFloating

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kPositionPath];
    CGRect screen = [UIScreen mainScreen].bounds;
    _origin = saved ? CGPointMake([saved[@"x"] floatValue], [saved[@"y"] floatValue])
                    : CGPointMake(screen.size.width - BUN_SIZE - 8, screen.size.height * 0.4f);
    [self buildWindow];
    return self;
}

- (UIButton *)buttonWithTitle:(NSString *)title frame:(CGRect)frame action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:bunPink() forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor secondarySystemBackgroundColor];
    button.layer.cornerRadius = 9;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildWindow {
    CGRect frame = CGRectMake(_origin.x, _origin.y, BUN_SIZE, BUN_SIZE);
    UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
    if (scene) {
        _window = [[UIWindow alloc] initWithWindowScene:scene];
        _window.frame = frame;
    } else {
        _window = [[UIWindow alloc] initWithFrame:frame];
    }
    _window.windowLevel = UIWindowLevelAlert + 2;
    _window.autoresizingMask = UIViewAutoresizingNone;
    _window.backgroundColor = [UIColor clearColor];
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor clearColor];
    _window.rootViewController = controller;

    // Ask the render server to leave this window out of screen captures, so it
    // does not disturb image matching. Harmless if the system ignores it.
    [_window.layer setValue:@((1 << 1) | (1 << 4)) forKey:@"disableUpdateMask"];

    // Collapsed state: a round gradient button.
    _bubble = [[UIView alloc] initWithFrame:CGRectMake(0, 0, BUN_SIZE, BUN_SIZE)];
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = _bubble.bounds;
    gradient.cornerRadius = BUN_SIZE / 2;
    gradient.colors = @[(id)[UIColor colorWithRed:1.0 green:0.6 blue:0.27 alpha:1.0].CGColor,
                        (id)[UIColor colorWithRed:1.0 green:0.24 blue:0.5 alpha:1.0].CGColor];
    gradient.startPoint = CGPointMake(0, 0);
    gradient.endPoint = CGPointMake(1, 1);
    [_bubble.layer addSublayer:gradient];
    UILabel *name = [[UILabel alloc] initWithFrame:_bubble.bounds];
    name.text = @"bun";
    name.textColor = [UIColor whiteColor];
    name.font = [UIFont systemFontOfSize:17 weight:UIFontWeightHeavy];
    name.textAlignment = NSTextAlignmentCenter;
    [_bubble addSubview:name];
    _bubble.alpha = 0.85f;
    [_bubble addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(expand)]];
    [_bubble addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [controller.view addSubview:_bubble];

    // Expanded state: device information and shortcuts.
    _card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CARD_W, CARD_H)];
    _card.backgroundColor = [UIColor systemBackgroundColor];
    _card.layer.cornerRadius = 16;
    _card.layer.borderWidth = 1;
    _card.layer.borderColor = bunPink().CGColor;
    _card.clipsToBounds = YES;
    _card.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, CARD_W - 60, 30)];
    title.text = @"bunAuto";
    title.textColor = bunPink();
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [_card addSubview:title];
    [_card addSubview:[self buttonWithTitle:@"✕" frame:CGRectMake(CARD_W - 42, 8, 32, 30) action:@selector(collapse)]];

    _info = [[UILabel alloc] initWithFrame:CGRectMake(14, 44, CARD_W - 28, 92)];
    _info.numberOfLines = 0;
    _info.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _info.textColor = [UIColor labelColor];
    [_card addSubview:_info];

    CGFloat half = (CARD_W - 36) / 2;
    [_card addSubview:[self buttonWithTitle:@"Chép IP" frame:CGRectMake(12, 142, half, 42) action:@selector(copyAddress)]];
    [_card addSubview:[self buttonWithTitle:@"● Ghi" frame:CGRectMake(24 + half, 142, half, 42) action:@selector(record)]];
    [_card addSubview:[self buttonWithTitle:@"Kịch bản" frame:CGRectMake(12, 192, half, 42) action:@selector(openScripts)]];
    [_card addSubview:[self buttonWithTitle:@"Ẩn nút" frame:CGRectMake(24 + half, 192, half, 42) action:@selector(turnOff)]];
    [controller.view addSubview:_card];

    _window.hidden = YES;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self reload];
}

- (CGPoint)clamp:(CGPoint)point size:(CGSize)size {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat x = MAX(4, MIN(point.x, screen.size.width - size.width - 4));
    CGFloat y = MAX(30, MIN(point.y, screen.size.height - size.height - 30));
    return CGPointMake(x, y);
}

- (void)layout {
    if (_expanded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        _window.frame = CGRectMake((screen.size.width - CARD_W) / 2, (screen.size.height - CARD_H) / 2, CARD_W, CARD_H);
    } else {
        _origin = [self clamp:_origin size:CGSizeMake(BUN_SIZE, BUN_SIZE)];
        _window.frame = CGRectMake(_origin.x, _origin.y, BUN_SIZE, BUN_SIZE);
    }
    _bubble.hidden = _expanded;
    _card.hidden = !_expanded;
}

- (void)reload {
    [self layout];
    [self tick];
}

// Stay out of the way while recording or replaying, so the button is never
// recorded and never swallows a scripted touch.
- (void)tick {
    BOOL hidden = !bunEnabled() || isRecordingStart() || isScriptPlaying();
    if (hidden && _expanded) {
        _expanded = NO;
        [self layout];
    }
    _window.hidden = hidden;
    if (!hidden && _expanded) [self refreshInfo];
}

- (void)refreshInfo {
    UIDevice *device = [UIDevice currentDevice];
    device.batteryMonitoringEnabled = YES;
    float level = device.batteryLevel;
    NSString *battery = level < 0 ? @"?" : [NSString stringWithFormat:@"%d%%", (int)roundf(level * 100)];
    NSString *address = bunWiFiAddress() ?: @"chưa có Wi-Fi";
    _info.text = [NSString stringWithFormat:@"IP    %@\nCổng  6000\nPin   %@\niOS   %@\nMáy   %@",
                  address, battery, device.systemVersion, device.name];
}

- (void)expand {
    _expanded = YES;
    [self refreshInfo];
    [self layout];
}

- (void)collapse {
    _expanded = NO;
    [self layout];
}

- (void)drag:(UIPanGestureRecognizer *)gesture {
    CGPoint move = [gesture translationInView:nil];
    [gesture setTranslation:CGPointZero inView:nil];
    _origin = [self clamp:CGPointMake(_origin.x + move.x, _origin.y + move.y) size:CGSizeMake(BUN_SIZE, BUN_SIZE)];
    _window.frame = CGRectMake(_origin.x, _origin.y, BUN_SIZE, BUN_SIZE);
    if (gesture.state != UIGestureRecognizerStateEnded) return;

    CGRect screen = [UIScreen mainScreen].bounds;
    _origin.x = (_origin.x + BUN_SIZE / 2 < screen.size.width / 2) ? 4 : screen.size.width - BUN_SIZE - 4;
    [UIView animateWithDuration:0.2 animations:^{ [self layout]; }];
    [@{@"x": @(_origin.x), @"y": @(_origin.y)} writeToFile:kPositionPath atomically:YES];
}

- (void)copyAddress {
    NSString *address = bunWiFiAddress();
    if (!address) return;
    [UIPasteboard generalPasteboard].string = address;
    _info.text = [NSString stringWithFormat:@"Đã chép:\n%@", address];
}

- (void)record {
    [self collapse];
    [popupWindow recordingStart];
}

- (void)openScripts {
    [self collapse];
    [popupWindow show];
}

- (void)turnOff {
    bunSetEnabled(NO);
    [self collapse];
    [self tick];
}

@end

static BunFloating *bunFloating = nil;

void bunFloatingStart(void) {
    // Give SpringBoard a moment to create its window scene.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!bunFloating) bunFloating = [[BunFloating alloc] init];
    });
}

void bunFloatingReload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [bunFloating reload];
    });
}
