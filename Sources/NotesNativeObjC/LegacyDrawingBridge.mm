#import "NotesNativeObjC.h"

#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <cmath>
#include <vector>

namespace {

struct NCLegacyPoint {
    CGPoint point;
    double radius;
    double opacity;
    double azimuth;
    double edgeWidth;
    double aspectRatio;
    double timestamp;
};

NSError *NCLegacyError(NSString *message) {
    return [NSError errorWithDomain:@"NotesCLI.Native" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

BOOL NCFail(NSError **error, NSString *message) {
    if (error) *error = NCLegacyError(message);
    return NO;
}

BOOL NCLoadLegacyDrawingFrameworks(NSError **error) {
    if (!dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_LAZY)) {
        return NCFail(error, @"NotesShared is unavailable for legacy drawing restoration");
    }
    dlopen("/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", RTLD_LAZY);
    return YES;
}

id NCObject(id object, const char *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

BOOL NCRequire(id object, NSArray<NSString *> *selectors, NSError **error) {
    if (!object) return NCFail(error, @"A legacy drawing runtime object is unavailable");
    for (NSString *name in selectors) {
        if (![object respondsToSelector:NSSelectorFromString(name)]) {
            return NCFail(error, [NSString stringWithFormat:@"Legacy drawing selector %@ is unavailable", name]);
        }
    }
    return YES;
}

std::vector<NCLegacyPoint> *NCPoints(id data, NSError **error) {
    Ivar ivar = class_getInstanceVariable([data class], "_points");
    if (!ivar) {
        NCFail(error, @"The legacy drawing stroke point vector is unavailable");
        return nullptr;
    }
    ptrdiff_t offset = ivar_getOffset(ivar);
    return reinterpret_cast<std::vector<NCLegacyPoint> *>((char *)(__bridge void *)data + offset);
}

NSArray<NSNumber *> *NCColorComponents(CGColorRef color) {
    NSColor *value = color ? [NSColor colorWithCGColor:color] : NSColor.blackColor;
    value = [value colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.blackColor;
    return @[@(value.redComponent), @(value.greenComponent), @(value.blueComponent), @(value.alphaComponent)];
}

CGColorRef NCColor(NSArray *components, NSError **error) {
    if (![components isKindOfClass:NSArray.class] || components.count != 4) {
        NCFail(error, @"A legacy drawing stroke has an invalid colour");
        return nil;
    }
    double values[4];
    for (NSUInteger index = 0; index < 4; index++) {
        values[index] = [components[index] doubleValue];
        if (!std::isfinite(values[index]) || values[index] < 0 || values[index] > 1) {
            NCFail(error, @"Legacy drawing colour components must be between zero and one");
            return nil;
        }
    }
    return [NSColor colorWithSRGBRed:values[0] green:values[1] blue:values[2] alpha:values[3]].CGColor;
}

} // namespace

@implementation NCNotesRuntime (LegacyDrawing)

+ (NSData *)legacyDrawingStrokesForAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCLoadLegacyDrawingFrameworks(error)) return nil;
    @try {
        if (!NCRequire(attachment, @[@"attachmentModel"], error)) return nil;
        id model = NCObject(attachment, "attachmentModel");
        if (![NSStringFromClass([model class]) isEqualToString:@"ICAttachmentDrawingModel"] ||
            !NCRequire(model, @[@"drawing"], error)) {
            if (error && !*error) *error = NCLegacyError(@"The attachment is not a legacy Notes sketch");
            return nil;
        }
        id drawing = NCObject(model, "drawing");
        if (!NCRequire(drawing, @[@"visibleCommands", @"bounds"], error)) return nil;
        id commands = NCObject(drawing, "visibleCommands");
        NSUInteger commandCount = [commands respondsToSelector:NSSelectorFromString(@"count")] ? [commands count] : 0;
        if (![commands conformsToProtocol:@protocol(NSFastEnumeration)] || commandCount == 0 || commandCount > 100000) {
            NSData *mergeable = [attachment respondsToSelector:NSSelectorFromString(@"mergeableData")]
                ? NCObject(attachment, "mergeableData") : nil;
            NCFail(error, [NSString stringWithFormat:
                @"The legacy Notes sketch has no safe stroke command set (model=%@ commands=%lu mergeable=%lu)",
                NSStringFromClass([model class]), (unsigned long)commandCount, (unsigned long)mergeable.length]);
            return nil;
        }
        NSMutableArray *records = [NSMutableArray arrayWithCapacity:commandCount];
        NSUInteger totalPoints = 0;
        for (id command in commands) {
            id strokeData = [command valueForKey:@"_data"];
            if (!NCRequire(strokeData, @[@"color"], error)) return nil;
            std::vector<NCLegacyPoint> *points = NCPoints(strokeData, error);
            if (!points || points->size() < 2 || points->size() > 100000 || totalPoints + points->size() > 1000000) {
                NCFail(error, @"The legacy Notes sketch has an unsupported stroke point set");
                return nil;
            }
            totalPoints += points->size();
            NSMutableArray *encodedPoints = [NSMutableArray arrayWithCapacity:points->size()];
            for (const NCLegacyPoint &point : *points) {
                double values[] = { point.point.x, point.point.y, point.radius, point.opacity, point.azimuth,
                                    point.edgeWidth, point.aspectRatio, point.timestamp };
                for (double value : values) {
                    if (!std::isfinite(value)) {
                        NCFail(error, @"The legacy Notes sketch contains a non-finite stroke value");
                        return nil;
                    }
                }
                [encodedPoints addObject:@{
                    @"x": @(point.point.x), @"y": @(point.point.y), @"radius": @(point.radius),
                    @"opacity": @(point.opacity), @"azimuth": @(point.azimuth),
                    @"edgeWidth": @(point.edgeWidth), @"aspectRatio": @(point.aspectRatio),
                    @"timestamp": @(point.timestamp),
                }];
            }
            CGColorRef color = ((CGColorRef (*)(id, SEL))objc_msgSend)(strokeData, sel_registerName("color"));
            [records addObject:@{
                @"color": NCColorComponents(color), @"points": encodedPoints,
                @"commandClass": NSStringFromClass([command class]),
                @"dataClass": NSStringFromClass([strokeData class]),
            }];
        }
        NSError *serializationError = nil;
        NSData *result = [NSJSONSerialization dataWithJSONObject:records options:0 error:&serializationError];
        if (!result.length && error) *error = serializationError ?: NCLegacyError(@"The legacy drawing snapshot is empty");
        return result.length ? result : nil;
    } @catch (NSException *exception) {
        if (error) *error = NCLegacyError([NSString stringWithFormat:@"Legacy drawing capture failed: %@", exception.reason ?: exception.name]);
        return nil;
    }
}

+ (NSString *)addLegacyDrawingWithStrokesData:(NSData *)data toNote:(NSManagedObject *)note
                                          type:(NSString **)type error:(NSError **)error {
    if (!NCLoadLegacyDrawingFrameworks(error)) return nil;
    @try {
        NSError *serializationError = nil;
        NSArray *records = [NSJSONSerialization JSONObjectWithData:data options:0 error:&serializationError];
        if (![records isKindOfClass:NSArray.class] || records.count == 0 || records.count > 100000) {
            if (error) *error = serializationError ?: NCLegacyError(@"The legacy drawing snapshot is invalid");
            return nil;
        }
        Class drawingClass = NSClassFromString(@"ICDrawing");
        if (!drawingClass || ![drawingClass instancesRespondToSelector:NSSelectorFromString(@"initWithReplicaID:")] ||
            !NCRequire(note, @[@"addAttachmentWithUTI:"], error)) return nil;
        id attachment = ((id (*)(id, SEL, id))objc_msgSend)(note, NSSelectorFromString(@"addAttachmentWithUTI:"), @"com.apple.notes.sketch");
        if (!NCRequire(attachment, @[@"attachmentModel", @"identifier", @"typeUTI"], error)) return nil;
        id model = NCObject(attachment, "attachmentModel");
        if (![NSStringFromClass([model class]) isEqualToString:@"ICAttachmentDrawingModel"] ||
            !NCRequire(model, @[@"saveDrawing:withImage:forImageDrawing:", @"writeMergeableData"], error)) {
            NCFail(error, @"Notes did not create a legacy drawing attachment model");
            return nil;
        }
        id drawing = ((id (*)(id, SEL, id))objc_msgSend)([drawingClass alloc], NSSelectorFromString(@"initWithReplicaID:"), NSUUID.UUID);
        if (!NCRequire(drawing, @[@"insertNewTestCommand", @"invalidateBounds", @"visibleCommands"], error)) return nil;
        NSUInteger totalPoints = 0;
        for (NSDictionary *record in records) {
            NSArray *pointsJSON = record[@"points"];
            if (![record isKindOfClass:NSDictionary.class] || ![pointsJSON isKindOfClass:NSArray.class] ||
                pointsJSON.count < 2 || pointsJSON.count > 100000 || totalPoints + pointsJSON.count > 1000000) {
                NCFail(error, @"The legacy drawing snapshot has an unsupported stroke point set");
                return nil;
            }
            CGColorRef color = NCColor(record[@"color"], error);
            if (!color) return nil;
            id command = NCObject(drawing, "insertNewTestCommand");
            id strokeData = [command valueForKey:@"_data"];
            std::vector<NCLegacyPoint> *points = NCPoints(strokeData, error);
            if (!points || ![strokeData respondsToSelector:NSSelectorFromString(@"setColor:")] ||
                ![strokeData respondsToSelector:NSSelectorFromString(@"invalidateBounds")]) return nil;
            for (NSDictionary *encoded in pointsJSON) {
                NCLegacyPoint point = {
                    CGPointMake([encoded[@"x"] doubleValue], [encoded[@"y"] doubleValue]),
                    [encoded[@"radius"] doubleValue], [encoded[@"opacity"] doubleValue],
                    [encoded[@"azimuth"] doubleValue], [encoded[@"edgeWidth"] doubleValue],
                    [encoded[@"aspectRatio"] doubleValue], [encoded[@"timestamp"] doubleValue],
                };
                double values[] = { point.point.x, point.point.y, point.radius, point.opacity, point.azimuth,
                                    point.edgeWidth, point.aspectRatio, point.timestamp };
                for (double value : values) {
                    if (!std::isfinite(value)) {
                        NCFail(error, @"The legacy drawing snapshot contains a non-finite stroke value");
                        return nil;
                    }
                }
                if (point.radius <= 0 || point.opacity < 0 || point.opacity > 1 || point.edgeWidth < 0 || point.aspectRatio <= 0) {
                    NCFail(error, @"The legacy drawing snapshot contains an unsafe stroke value");
                    return nil;
                }
                points->push_back(point);
            }
            totalPoints += pointsJSON.count;
            ((void (*)(id, SEL, CGColorRef))objc_msgSend)(strokeData, NSSelectorFromString(@"setColor:"), color);
            ((void (*)(id, SEL))objc_msgSend)(strokeData, NSSelectorFromString(@"invalidateBounds"));
        }
        ((void (*)(id, SEL))objc_msgSend)(drawing, NSSelectorFromString(@"invalidateBounds"));
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(model,
            NSSelectorFromString(@"saveDrawing:withImage:forImageDrawing:"), drawing, nil, nil);
        ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"writeMergeableData"));
        if ([model respondsToSelector:NSSelectorFromString(@"generatePreviewsInOperation:")]) {
            ((BOOL (*)(id, SEL, id))objc_msgSend)(model, NSSelectorFromString(@"generatePreviewsInOperation:"), nil);
        }
        NSString *identifier = NCObject(attachment, "identifier");
        NSString *createdType = NCObject(attachment, "typeUTI");
        if (!identifier.length || ![createdType isEqualToString:@"com.apple.notes.sketch"]) {
            NCFail(error, @"Notes created an invalid legacy drawing attachment");
            return nil;
        }
        if (type) *type = createdType;
        return identifier;
    } @catch (NSException *exception) {
        if (error) *error = NCLegacyError([NSString stringWithFormat:@"Legacy drawing creation failed: %@", exception.reason ?: exception.name]);
        return nil;
    }
}

@end
