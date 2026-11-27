#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#import "BunTasks.h"

// Defined in Touch.xm (same event format the socket server uses).
void performTouchFromRawData(UInt8 *eventData);
#define TOUCH_UP 0
#define TOUCH_DOWN 1

// Everything is driven by files under this folder, so the PC only needs SSH.
//   tat-airdrop        exists -> do not accept AirDrop
//   xoa-anh/NAME.xoa   one line "original filename|size in bytes" -> delete that video
//   mo-man             exists -> wake and unlock (no passcode), then the file is removed
//   nhat-ky-tu-dong.txt  what was seen and done, for diagnosis
static NSString *const kRoot = @"/var/mobile/Library/ZXTouch";

static NSTimer *bunTimer = nil;
static NSDate *lastTap = nil;
static NSDate *deletePending = nil;
static NSString *lastDump = nil;

static NSString *inRoot(NSString *name) {
    return [kRoot stringByAppendingPathComponent:name];
}

static void note(NSString *line) {
    NSString *path = inRoot(@"nhat-ky-tu-dong.txt");
    NSFileManager *files = [NSFileManager defaultManager];
    if ([[files attributesOfItemAtPath:path error:nil] fileSize] > 200000) [files removeItemAtPath:path error:nil];
    if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[[NSString stringWithFormat:@"%@ %@\n", [NSDate date], line] dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

#pragma mark - reading what is on screen

static NSArray<UIWindow *> *allWindows(void) {
    SEL every = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
    if ([UIWindow respondsToSelector:every]) {
        NSArray *(*call)(id, SEL, BOOL, BOOL) = (NSArray *(*)(id, SEL, BOOL, BOOL))[UIWindow methodForSelector:every];
        return call([UIWindow class], every, YES, YES);
    }
    return [UIApplication sharedApplication].windows;
}

static void collect(UIView *view, NSMutableArray *texts, NSMutableArray *views, int depth) {
    if (depth > 40 || view.hidden || view.alpha < 0.05) return;
    NSString *text = nil;
    if ([view isKindOfClass:[UILabel class]]) text = ((UILabel *)view).text;
    else if ([view isKindOfClass:[UIButton class]]) text = ((UIButton *)view).currentTitle;
    if (!text.length) text = view.accessibilityLabel;
    if (text.length && text.length < 300) {
        [texts addObject:text];
        [views addObject:view];
    }
    for (UIView *child in view.subviews) collect(child, texts, views, depth + 1);
}

static UIView *buttonNamed(NSArray *texts, NSArray *views, NSArray *names) {
    for (NSUInteger i = 0; i < texts.count; i++) {
        NSString *clean = [[texts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            precomposedStringWithCanonicalMapping].lowercaseString;
        for (NSString *name in names) {
            if ([clean isEqualToString:name.precomposedStringWithCanonicalMapping.lowercaseString]) return views[i];
        }
    }
    return nil;
}

static void tapPixels(int x, int y) {
    UInt8 data[32];
    snprintf((char *)data, sizeof(data), "1%d%02d%05d%05d", TOUCH_DOWN, 7, x * 10, y * 10);
    performTouchFromRawData(data);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UInt8 up[32];
        snprintf((char *)up, sizeof(up), "1%d%02d%05d%05d", TOUCH_UP, 7, x * 10, y * 10);
        performTouchFromRawData(up);
    });
}

static void tapView(UIView *view) {
    if (!view.window) return;
    CGPoint middle = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    CGPoint inWindow = [view convertPoint:middle toView:nil];
    CGPoint onScreen = [view.window convertPoint:inWindow toCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
    CGFloat scale = [UIScreen mainScreen].scale;
    tapPixels((int)(onScreen.x * scale), (int)(onScreen.y * scale));
    lastTap = [NSDate date];
}

static void lookAtScreen(void) {
    BOOL acceptOn = ![[NSFileManager defaultManager] fileExistsAtPath:inRoot(@"tat-airdrop")];
    BOOL deleting = deletePending && -[deletePending timeIntervalSinceNow] < 30;
    if (!acceptOn && !deleting) return;
    if (lastTap && -[lastTap timeIntervalSinceNow] < 4) return;

    for (UIWindow *window in allWindows()) {
        if (window.hidden || window.alpha < 0.05) continue;
        NSMutableArray *texts = [NSMutableArray array];
        NSMutableArray *views = [NSMutableArray array];
        collect(window, texts, views, 0);
        if (!texts.count) continue;
        NSString *all = [texts componentsJoinedByString:@" | "];

        if (acceptOn && [all rangeOfString:@"AirDrop" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            if (![all isEqualToString:lastDump]) {
                lastDump = all;
                note([NSString stringWithFormat:@"thay AirDrop (%@): %@", NSStringFromClass([window class]), all]);
            }
            UIView *accept = buttonNamed(texts, views, @[@"Chấp nhận", @"Accept"]);
            if (accept) {
                note(@"bam Chap nhan");
                tapView(accept);
                return;
            }
        }
        if (deleting) {
            // The system confirmation always offers a cancel button next to the delete button.
            UIView *remove = buttonNamed(texts, views, @[@"Xóa", @"Delete"]);
            UIView *keep = buttonNamed(texts, views, @[@"Không cho phép", @"Hủy", @"Don’t Allow", @"Cancel"]);
            if (remove && keep) {
                note([NSString stringWithFormat:@"xac nhan xoa: %@", all]);
                deletePending = nil;
                tapView(remove);
                return;
            }
        }
    }
}

#pragma mark - delete a raw video that the PC already has

static PHAsset *videoMatching(NSString *name, long long size) {
    PHFetchResult<PHAsset *> *videos = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeVideo options:nil];
    for (NSInteger i = videos.count - 1; i >= 0; i--) {
        PHAsset *asset = videos[i];
        for (PHAssetResource *resource in [PHAssetResource assetResourcesForAsset:asset]) {
            long long bytes = 0;
            @try { bytes = [[resource valueForKey:@"fileSize"] longLongValue]; }
            @catch (NSException *exception) { continue; }
            // Both must match: the size alone or the name alone is not proof.
            if (bytes == size && [resource.originalFilename caseInsensitiveCompare:name] == NSOrderedSame) return asset;
        }
    }
    return nil;
}

static void deleteNext(void) {
    static BOOL busy = NO;
    if (busy) return;
    NSString *folder = inRoot(@"xoa-anh");
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *item in [files contentsOfDirectoryAtPath:folder error:nil]) {
        if (![item.pathExtension isEqualToString:@"xoa"]) continue;
        NSString *path = [folder stringByAppendingPathComponent:item];
        NSString *line = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        PHAsset *asset = parts.count == 2 ? videoMatching(parts[0], [parts[1] longLongValue]) : nil;
        NSString *base = [path stringByDeletingPathExtension];
        [files removeItemAtPath:path error:nil];
        if (!asset) {
            [@"khong tim thay video khop ten va dung luong" writeToFile:[base stringByAppendingPathExtension:@"loi"]
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        busy = YES;
        deletePending = [NSDate date];
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest deleteAssets:@[asset]];
        } completionHandler:^(BOOL success, NSError *error) {
            NSString *result = success ? @"xong" : (error.localizedDescription ?: @"loi");
            [result writeToFile:[base stringByAppendingPathExtension:success ? @"done" : @"loi"]
                     atomically:YES encoding:NSUTF8StringEncoding error:nil];
            note([NSString stringWithFormat:@"xoa %@: %@", line, result]);
            busy = NO;
        }];
        return;
    }
}

#pragma mark - wake the screen

static id shared(NSString *name) {
    Class cls = NSClassFromString(name);
    SEL getter = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:getter]) return nil;
    id (*call)(id, SEL) = (id (*)(id, SEL))[cls methodForSelector:getter];
    return call(cls, getter);
}

static void wakeIfAsked(void) {
    NSString *path = inRoot(@"mo-man");
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    id light = shared(@"SBBacklightController");
    SEL on = NSSelectorFromString(@"turnOnScreenFullyWithBacklightSource:");
    if ([light respondsToSelector:on]) {
        void (*call)(id, SEL, long long) = (void (*)(id, SEL, long long))[light methodForSelector:on];
        call(light, on, 1);
    } else {
        note(@"khong co ham bat man hinh");
    }

    id lock = shared(@"SBLockScreenManager");
    SEL unlock = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
    if ([lock respondsToSelector:unlock]) {
        BOOL (*call)(id, SEL, int, id) = (BOOL (*)(id, SEL, int, id))[lock methodForSelector:unlock];
        BOOL done = call(lock, unlock, 17, nil);
        note(done ? @"mo khoa: duoc" : @"mo khoa: khong duoc");
    } else {
        note(@"khong co ham mo khoa");
    }
}

#pragma mark - timer

void bunTasksStart(void) {
    NSString *folder = inRoot(@"xoa-anh");
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (bunTimer) return;
        note(@"bat dau");
        bunTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            @autoreleasepool {
                @try {
                    wakeIfAsked();
                    lookAtScreen();
                    deleteNext();
                } @catch (NSException *exception) {
                    note([NSString stringWithFormat:@"loi: %@", exception.reason]);
                }
            }
        }];
    });
}
