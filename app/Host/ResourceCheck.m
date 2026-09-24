#import "ResourceCheck.h"
#import <CommonCrypto/CommonDigest.h>

NSArray<NSDictionary *> *EmuResourceManifest(void) {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"resources" withExtension:@"json"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![manifest[@"files"] isKindOfClass:NSArray.class]) return nil;
    return [manifest[@"files"] arrayByAddingObjectsFromArray:manifest[@"generated_files"] ?: @[]];
}

NSString *EmuResourceRoot(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/SnowRunner/SnowRunner.app/Contents/Resources"];
}

static NSString *ReceiptPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/emu-resources.json"];
}

static NSString *ResourcePath(NSString *relative) {
    if (relative.isAbsolutePath || [relative.pathComponents containsObject:@".."] || [relative containsString:@"\\"])
        return nil;
    return [EmuResourceRoot() stringByAppendingPathComponent:relative];
}

BOOL EmuCreateResourceDirectories(void) {
    NSArray *manifest = EmuResourceManifest();
    if (!manifest.count) return NO;
    for (NSDictionary *item in manifest) {
        NSString *path = ResourcePath(item[@"path"]);
        if (!path || ![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    }
    return YES;
}

NSArray<NSString *> *EmuMissingResources(void) {
    NSData *data = [NSData dataWithContentsOfFile:ReceiptPath()];
    NSDictionary *receipt = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![receipt isKindOfClass:NSDictionary.class] || ![receipt[@"version"] isEqual:@1] ||
        ![receipt[@"files"] isKindOfClass:NSDictionary.class]) receipt = nil;
    NSMutableArray *missing = [NSMutableArray new];
    NSArray *manifest = EmuResourceManifest();
    if (!manifest.count) return @[@"Bundled resource manifest"];
    for (NSDictionary *item in manifest) {
        NSString *relative = item[@"path"], *path = ResourcePath(relative);
        NSDictionary *attributes = path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] : nil;
        NSDictionary *saved = receipt[@"files"][relative];
        if (![saved isKindOfClass:NSDictionary.class]) saved = nil;
        if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] != [item[@"bytes"] unsignedLongLongValue] ||
            ![saved[@"sha256"] isEqual:item[@"sha256"]] || ![saved[@"bytes"] isEqual:item[@"bytes"]]) [missing addObject:relative];
    }
    return missing;
}

static NSString *FileHash(NSString *path) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    if (!stream) return nil;
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    [stream close];
    if (count < 0) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString new];
    for (NSUInteger i = 0; i < sizeof(digest); ++i) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSDictionary *EmuVerifyResources(void (^progress)(NSUInteger, NSUInteger, NSString *)) {
    NSArray *manifest = EmuResourceManifest();
    NSMutableArray *errors = [NSMutableArray new];
    NSMutableDictionary *files = [NSMutableDictionary new];
    NSUInteger checked = 0;
    if (!manifest.count) [errors addObject:@"Bundled resource manifest is missing"];
    for (NSDictionary *item in manifest) {
        @autoreleasepool {
            NSString *relative = item[@"path"], *path = ResourcePath(relative);
            NSDictionary *attributes = path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] : nil;
            if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] != [item[@"bytes"] unsignedLongLongValue]) {
                [errors addObject:[@"Missing or wrong size: " stringByAppendingString:relative]];
            } else if (![FileHash(path) isEqual:item[@"sha256"]]) {
                [errors addObject:[@"Checksum mismatch: " stringByAppendingString:relative]];
            } else {
                files[relative] = @{@"bytes":item[@"bytes"], @"sha256":item[@"sha256"]};
            }
            ++checked;
            if (progress) progress(checked, manifest.count, relative);
        }
    }
    NSError *error = nil;
    NSData *receipts = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"files":files} options:0 error:&error];
    if (!receipts || ![receipts writeToFile:ReceiptPath() options:NSDataWritingAtomic error:&error])
        [errors addObject:error.localizedDescription ?: @"Cannot save resource receipts"];
    return @{@"passed":@(errors.count == 0), @"errors":errors, @"checkedFiles":@(checked), @"totalFiles":@(manifest.count)};
}
