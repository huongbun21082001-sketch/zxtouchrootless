#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "StatusPill.h"

// The PC writes one line "kind|text" (UTF-8) to this file; kind is dang, xong or loi.
static NSString *const kStatusPath = @"/var/mobile/Library/ZXTouch/trang-thai.txt";
static const NSTimeInterval kVisibleSeconds = 15.0;
#define PILL_W 300.0f
#define PILL_H 40.0f

@interface BunStatusPill : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) CAGradientLayer *border;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSDate *seen;
@property (nonatomic, assign) NSUInteger generation;
@end

@implementation BunStatusPill

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    [self build];
    // Ignore a status left over from before this launch.
    _seen = [self modified] ?: [NSDate distantPast];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(check) userInfo:nil repeats:YES];
    return self;
}

- (NSDate *)modified {
    return [[NSFileManager defaultManager] attributesOfItemAtPath:kStatusPath error:nil][NSFileModificationDate];
}

- (void)build {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGRect frame = CGRectMake((screen.size.width - PILL_W) / 2, 46, PILL_W, PILL_H);
    UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
    if (scene) {
        _window = [[UIWindow alloc] initWithWindowScene:scene];
        _window.frame = frame;
    } else {
        _window = [[UIWindow alloc] initWithFrame:frame];
    }
    _window.windowLevel = UIWindowLevelAlert + 3;
    _window.userInteractionEnabled = NO;   // touches go straight through
    _window.backgroundColor = [UIColor clearColor];
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor clearColor];
    _window.rootViewController = controller;
    // Ask the render server to leave this window out of screen captures.
    [_window.layer setValue:@((1 << 1) | (1 << 4)) forKey:@"disableUpdateMask"];

    CGRect bounds = CGRectMake(0, 0, PILL_W, PILL_H);
    UIVisualEffectView *glass = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    glass.frame = bounds;
    glass.layer.cornerRadius = PILL_H / 2;
    glass.clipsToBounds = YES;
    [controller.view addSubview:glass];

    // A conic gradient that spins, visible only through a ring-shaped mask.
    CALayer *ring = [CALayer layer];
    ring.frame = bounds;
    _border = [CAGradientLayer layer];
    _border.type = kCAGradientLayerConic;
    _border.frame = CGRectMake((PILL_W - 360) / 2, (PILL_H - 360) / 2, 360, 360);
    _border.startPoint = CGPointMake(0.5, 0.5);
    _border.endPoint = CGPointMake(1.0, 0.5);
    [ring addSublayer:_border];
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, 1.5, 1.5) cornerRadius:PILL_H / 2].CGPath;
    mask.fillColor = [UIColor clearColor].CGColor;
    mask.strokeColor = [UIColor blackColor].CGColor;
    mask.lineWidth = 2.5;
    ring.mask = mask;
    [controller.view.layer addSublayer:ring];

    _label = [[UILabel alloc] initWithFrame:CGRectInset(bounds, 16, 4)];
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.adjustsFontSizeToFitWidth = YES;
    _label.minimumScaleFactor = 0.7;
    [controller.view addSubview:_label];
    _window.hidden = YES;
}

- (void)animate:(NSString *)kind {
    NSArray *colors;
    if ([kind isEqualToString:@"xong"]) {
        colors = @[UIColor.systemGreenColor, UIColor.systemTealColor, UIColor.systemGreenColor];
    } else if ([kind isEqualToString:@"loi"]) {
        colors = @[UIColor.systemRedColor, UIColor.systemOrangeColor, UIColor.systemRedColor];
    } else {
        colors = @[UIColor.systemPinkColor, UIColor.systemOrangeColor, UIColor.systemYellowColor,
                   UIColor.systemGreenColor, UIColor.systemTealColor, UIColor.systemPurpleColor, UIColor.systemPinkColor];
    }
    NSMutableArray *values = [NSMutableArray array];
    for (UIColor *color in colors) [values addObject:(id)color.CGColor];
    _border.colors = values;

    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0;
    spin.toValue = @(2 * M_PI);
    spin.duration = 2.2;
    spin.repeatCount = HUGE_VALF;
    [_border removeAllAnimations];
    [_border addAnimation:spin forKey:@"spin"];

    CABasicAnimation *blink = [CABasicAnimation animationWithKeyPath:@"opacity"];
    blink.fromValue = @1.0;
    blink.toValue = @0.45;
    blink.duration = 0.6;
    blink.autoreverses = YES;
    blink.repeatCount = HUGE_VALF;
    [_border addAnimation:blink forKey:@"blink"];
}

- (void)check {
    NSDate *changed = [self modified];
    if (!changed || [changed isEqualToDate:_seen]) return;
    _seen = changed;
    NSString *line = [NSString stringWithContentsOfFile:kStatusPath encoding:NSUTF8StringEncoding error:nil];
    NSRange split = [line rangeOfString:@"|"];
    if (split.location == NSNotFound) return;
    NSString *text = [[line substringFromIndex:split.location + 1]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger mine = ++_generation;
    if (text.length == 0) {   // empty text hides the pill at once
        [self hide];
        return;
    }
    _label.text = text;
    [self animate:[line substringToIndex:split.location]];
    _window.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVisibleSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (mine == self.generation) [self hide];
    });
}

- (void)hide {
    _window.hidden = YES;
    [_border removeAllAnimations];   // no battery spent while hidden
}

@end

static BunStatusPill *bunPill = nil;

void bunStatusPillStart(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!bunPill) bunPill = [[BunStatusPill alloc] init];
    });
}
