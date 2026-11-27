#import <Foundation/Foundation.h>
#import <Photos/Photos.h>

#import "PhotoImport.h"

// The PC copies a video here (as *.part, then renames it to *.mp4). It is added to
// the photo library and then renamed to *.done, or *.error with the reason in *.txt.
static NSString *const kImportFolder = @"/var/mobile/Library/ZXTouch/nhap-anh";

static dispatch_source_t importTimer = nil;
static BOOL importing = NO;

static void finishImport(NSString *path, BOOL success, NSError *error) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *target = [path stringByAppendingPathExtension:success ? @"done" : @"error"];
    [files removeItemAtPath:target error:nil];
    [files moveItemAtPath:path toPath:target error:nil];
    if (!success) {
        NSString *reason = error.localizedDescription ?: @"unknown error";
        [reason writeToFile:[path stringByAppendingPathExtension:@"txt"] atomically:YES
                   encoding:NSUTF8StringEncoding error:nil];
    }
    importing = NO;
}

// Edited videos also go into their own album, so the right one is easy to find
// when posting: the newest item of that album is the last edit.
static NSString *const kAlbumName = @"bunAuto";

static PHAssetCollection *bunAlbum(void) {
    PHFetchOptions *options = [[PHFetchOptions alloc] init];
    options.predicate = [NSPredicate predicateWithFormat:@"title = %@", kAlbumName];
    return [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                    subtype:PHAssetCollectionSubtypeAlbumRegular
                                                    options:options].firstObject;
}

static void importNextVideo(void) {
    if (importing) return;
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kImportFolder error:nil];
    for (NSString *name in names) {
        if (![[name.pathExtension lowercaseString] isEqualToString:@"mp4"]) continue;
        NSString *path = [kImportFolder stringByAppendingPathComponent:name];
        importing = YES;
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetChangeRequest *created =
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];
            PHAssetCollection *album = bunAlbum();
            PHAssetCollectionChangeRequest *request = album
                ? [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album]
                : [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:kAlbumName];
            if (created.placeholderForCreatedAsset) [request addAssets:@[created.placeholderForCreatedAsset]];
        } completionHandler:^(BOOL success, NSError *error) {
            finishImport(path, success, error);
        }];
        return;
    }
}

void bunPhotoImportStart(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:kImportFolder withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    if (importTimer) return;
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    importTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(importTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(importTimer, ^{
        importNextVideo();
    });
    dispatch_resume(importTimer);
}
