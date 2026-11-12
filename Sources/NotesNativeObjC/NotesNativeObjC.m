#import "NotesNativeObjC.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

static NSString *const NCErrorDomain = @"NotesCLI.NotesNative";
static NSError *NCError(NSString *message) {
    return [NSError errorWithDomain:NCErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL NCCatch(NSString *action, NSError **error, NS_NOESCAPE void (^block)(void)) {
    @try { block(); return YES; }
    @catch (NSException *exception) {
        if (error) *error = NCError([NSString stringWithFormat:@"%@ failed: %@: %@", action, exception.name, exception.reason ?: @""]);
        return NO;
    }
}
static BOOL NCRequireObject(id target, NSArray<NSString *> *selectors, NSString *action, NSError **error) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in selectors) {
        if (!target || ![target respondsToSelector:NSSelectorFromString(name)]) {
            [missing addObject:[NSString stringWithFormat:@"-[%@ %@]", target ? NSStringFromClass([target class]) : @"nil", name]];
        }
    }
    if (missing.count && error) {
        *error = NCError([NSString stringWithFormat:@"required selectors missing for %@: %@", action, [missing componentsJoinedByString:@", "]]);
    }
    return missing.count == 0;
}
static BOOL NCRequireClass(Class cls, NSArray<NSString *> *selectors, NSString *action, NSError **error) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in selectors) {
        if (!cls || ![cls respondsToSelector:NSSelectorFromString(name)]) {
            [missing addObject:[NSString stringWithFormat:@"+[%@ %@]", cls ? NSStringFromClass(cls) : @"nil", name]];
        }
    }
    if (missing.count && error) {
        *error = NCError([NSString stringWithFormat:@"required selectors missing for %@: %@", action, [missing componentsJoinedByString:@", "]]);
    }
    return missing.count == 0;
}
static BOOL NCRequireInstanceClass(Class cls, NSArray<NSString *> *selectors, NSString *action, NSError **error) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in selectors) {
        if (!cls || ![cls instancesRespondToSelector:NSSelectorFromString(name)]) {
            [missing addObject:[NSString stringWithFormat:@"-[%@ %@]", cls ? NSStringFromClass(cls) : @"nil", name]];
        }
    }
    if (missing.count && error) {
        *error = NCError([NSString stringWithFormat:@"required selectors missing for %@: %@", action, [missing componentsJoinedByString:@", "]]);
    }
    return missing.count == 0;
}

@protocol NCNoteContextClass
+ (void)startSharedContextWithOptions:(NSUInteger)options;
+ (id)sharedContext;
@end
@protocol NCNoteContext
- (NSPersistentContainer *)persistentContainer;
@end
@protocol NCNote
- (id)document;
- (id)mergeableString;
- (void)beginEditing;
- (void)endEditing;
- (void)saveNoteData;
- (void)edited:(NSUInteger)mask range:(NSRange)range changeInLength:(NSInteger)delta;
- (id)addAttachmentWithFileURL:(NSURL *)url;
- (id)addURLAttachmentWithURL:(NSURL *)url;
- (id)addTableAttachmentWithText:(NSAttributedString *)text;
- (void)setShouldAddMediaAsynchronously:(BOOL)value;
- (void)setIsPinned:(BOOL)value;
@end
@protocol NCNoteClass
+ (id)newEmptyNoteInFolder:(id)folder;
@end
@protocol NCMergeable
- (NSAttributedString *)attributedString;
- (void)insertAttributedString:(NSAttributedString *)text atIndex:(NSUInteger)index;
- (void)deleteCharactersInRange:(NSRange)range;
- (void)setAttributes:(NSDictionary *)attributes range:(NSRange)range;
- (void)insertString:(NSString *)text atIndex:(NSUInteger)index;
- (void)beginEditing;
- (void)endEditing;
@end
@protocol NCParagraph
- (void)setStyle:(NSUInteger)value;
- (void)setIndent:(NSUInteger)value;
- (void)setBlockQuoteLevel:(NSUInteger)value;
- (id)todo;
@end
@protocol NCTodo
- (id)initWithIdentifier:(NSUUID *)identifier done:(BOOL)done;
- (id)todoWithDone:(BOOL)done;
@end
@protocol NCInlineClass
+ (id)newHashtagAttachmentWithIdentifier:(NSString *)identifier hashtagText:(NSString *)text
              creatingHashtagIfNecessary:(BOOL)create note:(id)note parentAttachment:(id)parent;
+ (id)newLinkAttachmentWithIdentifier:(NSString *)identifier toNote:(id)target fromNote:(id)source parentAttachment:(id)parent;
+ (id)newDividerLineAttachmentWithIdentifier:(NSString *)identifier note:(id)note parentAttachment:(id)parent;
+ (id)newCalculateGraphExpressionAttachmentWithIdentifier:(NSString *)identifier altText:(NSString *)text note:(id)note parentAttachment:(id)parent rightToLeft:(BOOL)rightToLeft;
+ (id)newMentionAttachmentWithIdentifier:(NSString *)identifier mentionText:(NSString *)text userRecordName:(NSString *)userRecordName note:(id)note parentAttachment:(id)parent;
+ (void)renameHashtagsWithStandardizedContent:(NSString *)content newDisplayText:(NSString *)name context:(NSManagedObjectContext *)context;
+ (void)reviveOrTouchHashtag:(id)attachment;
@end
@protocol NCSynced
- (void)markForDeletion;
- (void)unmarkForDeletion;
- (void)updateChangeCountWithReason:(NSString *)reason;
- (id)attachmentModel;
@end
@protocol NCTableModel
- (id)table;
- (void)setMergeableDataDirty:(BOOL)value;
- (void)writeMergeableData;
@end
@protocol NCTable
- (NSUInteger)rowCount;
- (NSUInteger)columnCount;
- (id)stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row;
- (id)identifierForColumnAtIndex:(NSUInteger)index;
- (id)identifierForRowAtIndex:(NSUInteger)index;
- (id)mergeableStringForColumnID:(id)column rowID:(id)row;
- (void)setAttributedString:(NSAttributedString *)text columnIndex:(NSUInteger)column rowIndex:(NSUInteger)row;
- (void)insertRowAtIndex:(NSUInteger)index;
- (void)removeRowAtIndex:(NSUInteger)index;
- (void)insertColumnAtIndex:(NSUInteger)index;
- (void)removeColumnAtIndex:(NSUInteger)index;
@end

static BOOL NCLoad(NSError **error) {
    setenv("com.apple.CoreData.SQLDebug", "0", 1);
    setenv("com.apple.CoreData.Logging.stderr", "0", 1);
    static BOOL loaded = NO;
    if (loaded) return YES;
    dlerror();
    if (!dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW | RTLD_LOCAL)) {
        const char *detail = dlerror();
        if (error) *error = NCError([NSString stringWithFormat:@"cannot load NotesShared: %s", detail ?: "unknown error"]);
        return NO;
    }
    loaded = YES;
    return YES;
}

static NSDictionary<NSString *, NSArray<NSString *> *> *NCClassSelectors(void) {
    return @{
        @"ICNoteContext": @[@"startSharedContextWithOptions:", @"sharedContext"],
        @"ICInlineAttachment": @[@"newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:",
                                  @"newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:",
                                  @"newDividerLineAttachmentWithIdentifier:note:parentAttachment:",
                                  @"newCalculateGraphExpressionAttachmentWithIdentifier:altText:note:parentAttachment:rightToLeft:",
                                  @"newMentionAttachmentWithIdentifier:mentionText:userRecordName:note:parentAttachment:", @"reviveOrTouchHashtag:"],
        @"ICHashtag": @[@"renameHashtagsWithStandardizedContent:newDisplayText:context:"],
    };
}
static NSDictionary<NSString *, NSArray<NSString *> *> *NCInstanceSelectors(void) {
    return @{
        @"ICNoteContext": @[@"persistentContainer"],
        @"ICNote": @[@"document", @"mergeableString", @"beginEditing", @"endEditing", @"saveNoteData",
                     @"edited:range:changeInLength:", @"addAttachmentWithFileURL:", @"addTableAttachmentWithText:", @"setIsPinned:",
                     @"setShouldAddMediaAsynchronously:", @"updateChangeCountWithReason:"],
        @"ICInlineAttachment": @[@"markForDeletion"],
        @"ICTTParagraphStyle": @[@"setStyle:", @"setIndent:", @"setBlockQuoteLevel:", @"todo"],
        @"ICTTFont": @[@"initWithName:size:hints:", @"fontName", @"pointSize", @"fontHints"],
        @"ICOutlineState": @[@"initWithCollapsedUUIDs:", @"data", @"collapsedUUIDStrings"],
        @"ICTTTodo": @[@"initWithIdentifier:done:", @"todoWithDone:"],
        @"ICAttachment": @[@"markForDeletion", @"attachmentModel", @"updateChangeCountWithReason:", @"setPreferredViewSize:"],
        @"ICFolder": @[@"updateChangeCountWithReason:"],
        @"ICAttachmentTableModel": @[@"table", @"setMergeableDataDirty:", @"writeMergeableData"],
        @"ICTable": @[@"rowCount", @"columnCount", @"stringForColumnIndex:rowIndex:", @"identifierForColumnAtIndex:",
                      @"identifierForRowAtIndex:", @"mergeableStringForColumnID:rowID:", @"setAttributedString:columnIndex:rowIndex:",
                      @"insertRowAtIndex:", @"removeRowAtIndex:", @"insertColumnAtIndex:", @"removeColumnAtIndex:"],
    };
}

static NSString *NCPlain(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSAttributedString.class]) return [value string];
    return @"";
}

static void NCInstallTableStyleMethod(void) {
    SEL selector = NSSelectorFromString(@"ic_convertParagraphStyleToBodyInRange:");
    Class stringClass = NSMutableAttributedString.class;
    if ([stringClass instancesRespondToSelector:selector]) return;
    IMP implementation = imp_implementationWithBlock(^(NSMutableAttributedString *string, NSRange range) {
        @try {
            Class styleClass = NSClassFromString(@"ICTTParagraphStyle");
            if (!styleClass) return;
            NSMutableArray *updates = [NSMutableArray array];
            [string enumerateAttribute:@"TTStyle" inRange:range options:0 usingBlock:^(id value, NSRange run, BOOL *stop) {
                id<NCParagraph> style = value ? [value mutableCopy] : [[styleClass alloc] init];
                if (![(id)style respondsToSelector:@selector(setStyle:)]) return;
                [style setStyle:3];
                [updates addObject:@[[NSValue valueWithRange:run], style]];
            }];
            for (NSArray *update in updates) [string addAttribute:@"TTStyle" value:update[1] range:[update[0] rangeValue]];
        } @catch (__unused NSException *exception) {}
    });
    class_addMethod(stringClass, selector, implementation, "v@:{_NSRange=QQ}");
}

@implementation NCNotesRuntime
+ (NSDictionary<NSString *,id> *)doctor {
    NSError *loadError = nil;
    BOOL framework = NCLoad(&loadError);
    NSMutableDictionary *classes = [NSMutableDictionary dictionary];
    NSMutableArray *missing = [NSMutableArray array];
    if (framework) {
        dlopen("/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", RTLD_NOW | RTLD_LOCAL);
        NSMutableDictionary *classChecks = [NCClassSelectors() mutableCopy];
        classChecks[@"ICNote"] = @[@"duplicateNote:intoFolder:isPasswordProtected:removeOriginalNote:"];
        NSMutableSet *names = [NSMutableSet setWithArray:NCClassSelectors().allKeys];
        [names addObject:@"ICNote"];
        [names addObjectsFromArray:NCInstanceSelectors().allKeys];
        for (NSString *name in names) {
            Class cls = NSClassFromString(name);
            NSMutableDictionary *selectors = [NSMutableDictionary dictionary];
            for (NSString *sel in classChecks[name] ?: @[]) {
                BOOL ok = cls && [cls respondsToSelector:NSSelectorFromString(sel)]; selectors[[@"+" stringByAppendingString:sel]] = @(ok);
                if (!ok) [missing addObject:[NSString stringWithFormat:@"+[%@ %@]", name, sel]];
            }
            for (NSString *sel in NCInstanceSelectors()[name] ?: @[]) {
                BOOL ok = cls && [cls instancesRespondToSelector:NSSelectorFromString(sel)]; selectors[[@"-" stringByAppendingString:sel]] = @(ok);
                if (!ok) [missing addObject:[NSString stringWithFormat:@"-[%@ %@]", name, sel]];
            }
            classes[name] = @{ @"resolved": @(cls != Nil), @"selectors": selectors };
        }
    }
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    return @{ @"frameworkLoaded": @(framework), @"frameworkPath": @"/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared",
              @"macOS": [NSString stringWithFormat:@"%ld.%ld.%ld", v.majorVersion, v.minorVersion, v.patchVersion],
              @"classes": classes, @"missing": [missing sortedArrayUsingSelector:@selector(compare:)],
              @"error": loadError.localizedDescription ?: NSNull.null };
}

+ (NSManagedObjectContext *)sharedContext:(NSError **)error {
    static NSManagedObjectContext *context = nil;
    if (context) return context;
    if (!NCLoad(error)) return nil;
    Class cls = NSClassFromString(@"ICNoteContext");
    if (!NCRequireClass(cls, @[@"startSharedContextWithOptions:", @"sharedContext"], @"opening Notes context", error)) return nil;
    __block id shared = nil;
    if (!NCCatch(@"opening Notes context", error, ^{
        id<NCNoteContextClass> typed = (id<NCNoteContextClass>)cls;
        [typed startSharedContextWithOptions:0];
        shared = [typed sharedContext];
    })) return nil;
    if (!NCRequireObject(shared, @[@"persistentContainer"], @"opening Notes persistent container", error)) return nil;
    __block NSManagedObjectContext *found = nil;
    if (!NCCatch(@"opening Notes persistent container", error, ^{ found = [[(id<NCNoteContext>)shared persistentContainer] viewContext]; })) return nil;
    if (!found && error) *error = NCError(@"Notes shared context returned no view context");
    context = found;
    return context;
}

+ (id)valueForKey:(NSString *)key ofObject:(id)object { @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; } }
+ (BOOL)setValue:(id)value forKey:(NSString *)key ofObject:(id)object error:(NSError **)error {
    return NCCatch(@"setting private property", error, ^{ [object setValue:value forKey:key]; });
}

+ (NSAttributedString *)bodyOfNote:(NSManagedObject *)note error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    if (!NCRequireObject(note, @[@"mergeableString"], @"reading note body", error)) return nil;
    __block id mergeable = nil; __block NSAttributedString *body = nil;
    if (!NCCatch(@"reading note body", error, ^{ mergeable = [(id<NCNote>)note mergeableString]; })) return nil;
    if (!NCRequireObject(mergeable, @[@"attributedString"], @"reading note body", error)) return nil;
    if (!NCCatch(@"reading note body", error, ^{ body = [[(id<NCMergeable>)mergeable attributedString] copy]; })) return nil;
    return body ?: [[NSAttributedString alloc] init];
}
+ (NSManagedObject *)newNoteInFolder:(NSManagedObject *)folder error:(NSError **)error {
    Class cls = NSClassFromString(@"ICNote");
    if (!NCRequireClass(cls, @[@"newEmptyNoteInFolder:"], @"creating note", error)) return nil;
    __block NSManagedObject *note = nil;
    if (!NCCatch(@"creating note", error, ^{ note = (NSManagedObject *)[(id<NCNoteClass>)cls newEmptyNoteInFolder:folder]; })) return nil;
    if (!note && error) *error = NCError(@"NotesShared created no note");
    return note;
}

+ (id)paragraphStyle:(NSInteger)style indent:(NSInteger)indent quote:(NSInteger)quote checked:(NSInteger)checked basedOn:(id)existing error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    Class cls = NSClassFromString(@"ICTTParagraphStyle"), todoClass = NSClassFromString(@"ICTTTodo");
    if (!cls || !todoClass) { if (error) *error = NCError(@"required class missing: ICTTParagraphStyle or ICTTTodo"); return nil; }
    if (!NCRequireObject(existing ?: [cls alloc], @[@"setStyle:", @"setIndent:", @"setBlockQuoteLevel:", @"todo"], @"creating paragraph style", error)) return nil;
    if (checked >= 0 && !NCRequireObject([todoClass alloc], @[@"initWithIdentifier:done:"], @"creating checklist state", error)) return nil;
    if (checked >= 0 && existing) {
        __block id prior = nil;
        if (!NCCatch(@"reading checklist state", error, ^{ prior = [(id<NCParagraph>)existing todo]; })) return nil;
        if (prior && !NCRequireObject(prior, @[@"todoWithDone:"], @"updating checklist state", error)) return nil;
    }
    __block id result = nil;
    if (!NCCatch(@"creating paragraph style", error, ^{
        id<NCParagraph> made = existing ? [existing mutableCopy] : [[cls alloc] init];
        [made setStyle:(NSUInteger)style]; [made setIndent:(NSUInteger)MAX(0, indent)]; [made setBlockQuoteLevel:(NSUInteger)MAX(0, quote)];
        id todo = nil;
        if (checked >= 0) { id prior = [made todo]; todo = prior ? [(id<NCTodo>)prior todoWithDone:checked == 1] : [(id<NCTodo>)[todoClass alloc] initWithIdentifier:NSUUID.UUID done:checked == 1]; }
        [(NSObject *)made setValue:todo forKey:@"todo"];
        result = made;
    })) return nil;
    return result;
}

+ (id)fontWithName:(NSString *)name size:(NSNumber *)size hints:(NSInteger)hints basedOn:(id)existing error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    Class cls = NSClassFromString(@"ICTTFont");
    if (!NCRequireInstanceClass(cls, @[@"initWithName:size:hints:"], @"creating font", error)) return nil;
    if (existing && !NCRequireObject(existing, @[@"fontName", @"pointSize"], @"reading font", error)) return nil;
    __block id result = nil;
    if (!NCCatch(@"creating font", error, ^{
        NSString *resolvedName = name ?: (existing ? [existing valueForKey:@"fontName"] : nil);
        double resolvedSize = size ? size.doubleValue : (existing ? [[existing valueForKey:@"pointSize"] doubleValue] : NSFont.systemFontSize);
        if (!resolvedName.length) resolvedName = [NSFont systemFontOfSize:resolvedSize].fontName;
        SEL selector = NSSelectorFromString(@"initWithName:size:hints:");
        result = ((id (*)(id, SEL, id, double, unsigned int))objc_msgSend)([cls alloc], selector, resolvedName, resolvedSize, (unsigned int)MAX(0, hints));
    })) return nil;
    return result;
}

+ (NSData *)outlineStateDataWithCollapsedUUIDStrings:(NSArray<NSString *> *)identifiers error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    Class cls = NSClassFromString(@"ICOutlineState");
    if (!NCRequireInstanceClass(cls, @[@"initWithCollapsedUUIDs:", @"data"], @"creating outline state", error)) return nil;
    NSMutableSet<NSUUID *> *uuids = [NSMutableSet set];
    for (NSString *identifier in identifiers) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
        if (!uuid) { if (error) *error = NCError([NSString stringWithFormat:@"invalid paragraph UUID: %@", identifier]); return nil; }
        [uuids addObject:uuid];
    }
    __block NSData *data = nil;
    if (!NCCatch(@"creating outline state", error, ^{
        id state = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithCollapsedUUIDs:"), uuids);
        data = ((id (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"data"));
    })) return nil;
    return data;
}

+ (id)attachmentMarkerWithID:(NSString *)identifier type:(NSString *)type error:(NSError **)error {
    Class cls = NSClassFromString(@"ICTTAttachment");
    if (!cls) { if (error) *error = NCError(@"required class missing: ICTTAttachment"); return nil; }
    __block id marker = nil;
    if (!NCCatch(@"creating attachment marker", error, ^{ marker = [[cls alloc] init]; [marker setValue:identifier forKey:@"attachmentIdentifier"]; [marker setValue:type forKey:@"attachmentUTI"]; })) return nil;
    return marker;
}
+ (NSString *)markerID:(id)marker { id v = [self valueForKey:@"attachmentIdentifier" ofObject:marker]; return [v isKindOfClass:NSString.class] ? v : nil; }
+ (NSString *)markerType:(id)marker { id v = [self valueForKey:@"attachmentUTI" ofObject:marker]; return [v isKindOfClass:NSString.class] ? v : nil; }

+ (NSString *)makeTag:(NSString *)name inNote:(NSManagedObject *)note error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    if (!NCRequireClass(cls, @[@"newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:", @"reviveOrTouchHashtag:"], @"creating tag", error)) return nil;
    __block NSString *identifier = nil;
    if (!NCCatch(@"creating tag", error, ^{ id item = [(id<NCInlineClass>)cls newHashtagAttachmentWithIdentifier:NSUUID.UUID.UUIDString hashtagText:name creatingHashtagIfNecessary:YES note:note parentAttachment:nil]; identifier = [item valueForKey:@"identifier"]; })) return nil;
    return identifier;
}

+ (NSString *)makeNoteLinkTo:(NSManagedObject *)target from:(NSManagedObject *)source text:(NSString *)text error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    if (!NCRequireClass(cls, @[@"newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:"], @"creating note link", error)) return nil;
    __block NSString *identifier = nil;
    if (!NCCatch(@"creating note link", error, ^{ id item = [(id<NCInlineClass>)cls newLinkAttachmentWithIdentifier:NSUUID.UUID.UUIDString toNote:target fromNote:source parentAttachment:nil]; if (text.length) [item setValue:text forKey:@"altText"]; identifier = [item valueForKey:@"identifier"]; })) return nil;
    return identifier;
}

static NSString *NCInlineIdentifier(id item, NSString **type, NSString *action, NSError **error) {
    if (!NCRequireObject(item, @[@"identifier", @"typeUTI"], action, error)) return nil;
    NSString *identifier = [item valueForKey:@"identifier"], *kind = [item valueForKey:@"typeUTI"];
    if (!identifier.length || !kind.length) { if (error) *error = NCError([NSString stringWithFormat:@"%@ created no typed attachment", action]); return nil; }
    if (type) *type = kind;
    return identifier;
}

+ (NSString *)makeDividerInNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    NSString *selector = @"newDividerLineAttachmentWithIdentifier:note:parentAttachment:";
    if (!NCRequireClass(cls, @[selector], @"creating divider", error)) return nil;
    __block id item = nil;
    if (!NCCatch(@"creating divider", error, ^{ item = [(id<NCInlineClass>)cls newDividerLineAttachmentWithIdentifier:NSUUID.UUID.UUIDString note:note parentAttachment:nil]; })) return nil;
    return NCInlineIdentifier(item, type, @"creating divider", error);
}

+ (NSString *)makeMathExpression:(NSString *)expression inNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    NSString *selector = @"newCalculateGraphExpressionAttachmentWithIdentifier:altText:note:parentAttachment:rightToLeft:";
    if (!NCRequireClass(cls, @[selector], @"creating math expression", error)) return nil;
    __block id item = nil;
    if (!NCCatch(@"creating math expression", error, ^{ item = [(id<NCInlineClass>)cls newCalculateGraphExpressionAttachmentWithIdentifier:NSUUID.UUID.UUIDString altText:expression note:note parentAttachment:nil rightToLeft:NO]; })) return nil;
    return NCInlineIdentifier(item, type, @"creating math expression", error);
}

+ (NSString *)makeMention:(NSString *)text userRecordName:(NSString *)userRecordName inNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    NSString *selector = @"newMentionAttachmentWithIdentifier:mentionText:userRecordName:note:parentAttachment:";
    if (!NCRequireClass(cls, @[selector], @"creating mention", error)) return nil;
    __block id item = nil;
    if (!NCCatch(@"creating mention", error, ^{ item = [(id<NCInlineClass>)cls newMentionAttachmentWithIdentifier:NSUUID.UUID.UUIDString mentionText:text userRecordName:userRecordName note:note parentAttachment:nil]; })) return nil;
    return NCInlineIdentifier(item, type, @"creating mention", error);
}

+ (NSString *)addFile:(NSURL *)file toNote:(NSManagedObject *)note title:(NSString *)title type:(NSString **)type error:(NSError **)error {
    if (!NCRequireObject(note, @[@"setShouldAddMediaAsynchronously:", @"addAttachmentWithFileURL:"], @"adding file", error)) return nil;
    __block NSString *identifier = nil, *kind = nil;
    if (!NCCatch(@"adding file", error, ^{ [(id<NCNote>)note setShouldAddMediaAsynchronously:NO]; id item = [(id<NCNote>)note addAttachmentWithFileURL:file]; if (title.length) [item setValue:title forKey:@"userTitle"]; identifier = [item valueForKey:@"identifier"]; kind = [item valueForKey:@"typeUTI"]; })) return nil;
    if (type) *type = kind;
    return identifier;
}
+ (NSArray<NSString *> *)transformAudioAttachment:(NSManagedObject *)attachment duration:(double)duration error:(NSError **)error {
    if (!NCRequireObject(attachment, @[@"attachmentModel", @"setDuration:", @"updateChangeCountWithReason:", @"subAttachments"], @"creating audio recording", error)) return nil;
    __block id model = nil;
    if (!NCCatch(@"opening audio attachment", error, ^{ model = [(id<NCSynced>)attachment attachmentModel]; })) return nil;
    if (!NCRequireObject(model, @[@"setRecordedInNotes:", @"transformNewlyAddedMediaAttachment", @"writeMergeableData"], @"creating audio recording", error)) return nil;
    __block NSArray<NSString *> *identifiers = nil;
    if (!NCCatch(@"creating audio recording", error, ^{
        ((void (*)(id, SEL, BOOL))objc_msgSend)(model, NSSelectorFromString(@"setRecordedInNotes:"), YES);
        ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"transformNewlyAddedMediaAttachment"));
        [attachment setValue:@(duration) forKey:@"duration"];
        NSArray *children = [[[attachment valueForKey:@"subAttachments"] allObjects] sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
            return [[left valueForKey:@"identifier"] compare:[right valueForKey:@"identifier"]];
        }];
        NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:children.count];
        for (id child in children) {
            if (!NCRequireObject(child, @[@"identifier", @"setDuration:"], @"setting audio fragment duration", error)) return;
            [child setValue:@(duration) forKey:@"duration"];
            NSString *identifier = [child valueForKey:@"identifier"];
            if (identifier.length) [values addObject:identifier];
        }
        ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"writeMergeableData"));
        [(id<NCSynced>)attachment updateChangeCountWithReason:@"Added audio recording"];
        identifiers = values;
    })) return nil;
    if (!identifiers) { if (error && !*error) *error = NCError(@"Notes created no audio fragment"); return nil; }
    return identifiers;
}
+ (NSNumber *)appendTranscriptSegments:(NSArray<NSDictionary<NSString *,id> *> *)segments toAudioAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCRequireObject(attachment, @[@"attachmentModel", @"updateChangeCountWithReason:"], @"writing audio transcript", error)) return nil;
    __block id model = nil;
    if (!NCCatch(@"opening audio transcript", error, ^{ model = [(id<NCSynced>)attachment attachmentModel]; })) return nil;
    if (!NCRequireObject(model, @[@"audioDocument", @"writeMergeableData"], @"writing audio transcript", error)) return nil;
    Class segmentClass = NSClassFromString(@"NotesShared.ICTTTranscriptSegment");
    if (!segmentClass || !NCRequireInstanceClass(segmentClass, @[@"initWithDocument:identity:", @"setText:", @"setTimestamp:", @"setDuration:", @"setSpeaker:"], @"writing audio transcript", error)) return nil;
    __block NSNumber *count = nil;
    if (!NCCatch(@"writing audio transcript", error, ^{
        id audioDocument = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"audioDocument"));
        if (!NCRequireObject(audioDocument, @[@"document", @"orderedFragmentUUIDs"], @"opening audio document", error)) return;
        id document = [audioDocument valueForKey:@"document"];
        if (!NCRequireObject(document, @[@"objects"], @"opening audio document objects", error)) return;
        NSArray *fragmentUUIDs = [audioDocument valueForKey:@"orderedFragmentUUIDs"];
        id fragmentUUID = fragmentUUIDs.firstObject;
        id fragment = fragmentUUID ? [[document valueForKey:@"objects"] objectForKey:fragmentUUID] : nil;
        if (!fragment || !NCRequireObject(fragment, @[@"transcript", @"setTranscriptVersion:"], @"opening audio fragment transcript", error)) return;
        id transcript = [fragment valueForKey:@"transcript"];
        if (!NCRequireObject(transcript, @[@"addObject:", @"count"], @"writing audio transcript segments", error)) return;
        if ([[transcript valueForKey:@"count"] unsignedIntegerValue] != 0) {
            if (error) *error = NCError(@"The recording already has a transcript");
            return;
        }
        for (NSDictionary<NSString *, id> *row in segments) {
            id segment = ((id (*)(id, SEL, id, id))objc_msgSend)([segmentClass alloc], NSSelectorFromString(@"initWithDocument:identity:"), document, NSUUID.UUID);
            if (!segment) { if (error) *error = NCError(@"Notes could not create a transcript segment"); return; }
            [segment setValue:row[@"text"] ?: @"" forKey:@"text"];
            [segment setValue:row[@"start"] ?: @0 forKey:@"timestamp"];
            [segment setValue:row[@"duration"] ?: @0 forKey:@"duration"];
            [segment setValue:row[@"speaker"] forKey:@"speaker"];
            ((void (*)(id, SEL, id))objc_msgSend)(transcript, NSSelectorFromString(@"addObject:"), segment);
        }
        [fragment setValue:@1 forKey:@"transcriptVersion"];
        ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"writeMergeableData"));
        [(id<NCSynced>)attachment updateChangeCountWithReason:@"Added audio transcript"];
        count = @([[transcript valueForKey:@"count"] unsignedIntegerValue]);
    })) return nil;
    if (!count && error && !*error) *error = NCError(@"Notes could not write the audio transcript");
    return count;
}
+ (NSString *)addURL:(NSURL *)url toNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    if (!NCRequireObject(note, @[@"addURLAttachmentWithURL:"], @"adding URL preview", error)) return nil;
    __block NSString *identifier = nil, *kind = nil;
    if (!NCCatch(@"adding URL preview", error, ^{ id item = [(id<NCNote>)note addURLAttachmentWithURL:url]; identifier = [item valueForKey:@"identifier"]; kind = [item valueForKey:@"typeUTI"]; })) return nil;
    if (type) *type = kind;
    return identifier;
}

+ (BOOL)setPreferredImageSize:(NSString *)size attachment:(NSManagedObject *)attachment error:(NSError **)error {
    SEL sel = NSSelectorFromString(@"setPreferredViewSize:");
    if (!NCRequireObject(attachment, @[@"setPreferredViewSize:"], @"setting image view size", error)) return NO;
    return NCCatch(@"setting image view size", error, ^{ ((void (*)(id, SEL, short))objc_msgSend)(attachment, sel, [size isEqualToString:@"small"] ? 1 : 0); });
}

+ (BOOL)renameTag:(NSManagedObject *)tag to:(NSString *)name error:(NSError **)error {
    Class cls = NSClassFromString(@"ICHashtag");
    if (!NCRequireClass(cls, @[@"renameHashtagsWithStandardizedContent:newDisplayText:context:"], @"renaming tag", error)) return NO;
    return NCCatch(@"renaming tag", error, ^{ [(id<NCInlineClass>)cls renameHashtagsWithStandardizedContent:[tag valueForKey:@"standardizedContent"] newDisplayText:name context:tag.managedObjectContext]; });
}
+ (BOOL)reviveTagAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    if (!NCRequireClass(cls, @[@"reviveOrTouchHashtag:"], @"reviving tag", error)) return NO;
    return NCCatch(@"reviving tag", error, ^{ [(id<NCInlineClass>)cls reviveOrTouchHashtag:attachment]; });
}
+ (BOOL)markForDeletion:(NSManagedObject *)object error:(NSError **)error {
    if (!NCRequireObject(object, @[@"markForDeletion"], @"marking object deleted", error)) return NO;
    return NCCatch(@"marking object deleted", error, ^{ [(id<NCSynced>)object markForDeletion]; });
}
+ (BOOL)unmarkForDeletion:(NSManagedObject *)object error:(NSError **)error {
    if (!NCRequireObject(object, @[@"unmarkForDeletion", @"updateChangeCountWithReason:"], @"restoring object", error)) return NO;
    return NCCatch(@"restoring object", error, ^{ [(id<NCSynced>)object unmarkForDeletion]; [(id<NCSynced>)object updateChangeCountWithReason:@"Restored"]; });
}
+ (BOOL)setPinned:(BOOL)pinned note:(NSManagedObject *)note error:(NSError **)error {
    if (!NCRequireObject(note, @[@"setIsPinned:", @"updateChangeCountWithReason:"], @"changing pin", error)) return NO;
    return NCCatch(@"changing pin", error, ^{ [(id<NCNote>)note setIsPinned:pinned]; [(id<NCSynced>)note updateChangeCountWithReason:pinned ? @"Pinned note" : @"Unpinned note"]; });
}
+ (BOOL)moveFolder:(NSManagedObject *)folder parent:(NSManagedObject *)parent error:(NSError **)error {
    if (!NCRequireObject(folder, @[@"updateChangeCountWithReason:"], @"moving folder", error)) return NO;
    return NCCatch(@"moving folder", error, ^{ [folder setValue:parent forKey:@"parent"]; [folder setValue:NSDate.date forKey:@"parentModificationDate"]; [(id<NCSynced>)folder updateChangeCountWithReason:@"Moved folder"]; });
}
+ (NSString *)createSmartFolder:(NSString *)name tags:(NSArray<NSManagedObject *> *)tags matchAll:(BOOL)matchAll account:(NSManagedObject *)account error:(NSError **)error {
    Class selection = NSClassFromString(@"ICTagSelection"), query = NSClassFromString(@"ICQueryObjC"), folders = NSClassFromString(@"ICFolder");
    SEL make = NSSelectorFromString(@"initWithManagedObjectContext:includedObjectIDs:excludedObjectIDs:tagOperator:");
    SEL ask = NSSelectorFromString(@"objc_queryForNotesMatchingTagSelection:");
    SEL smart = NSSelectorFromString(@"objc_smartFolderWithQuery:account:");
    if (!selection || !query || !folders || ![selection instancesRespondToSelector:make] || ![query respondsToSelector:ask] || ![folders respondsToSelector:smart]) {
        if (error) *error = NCError(@"NotesShared cannot create smart folders in this version of macOS");
        return nil;
    }
    __block NSString *identifier = nil;
    if (!NCCatch(@"creating smart folder", error, ^{
        NSSet *ids = [NSSet setWithArray:[tags valueForKey:@"objectID"]];
        id chosen = ((id (*)(id, SEL, id, id, id, NSInteger))objc_msgSend)([selection alloc], make, account.managedObjectContext, ids, [NSSet set], matchAll ? 1 : 0);
        id rule = ((id (*)(id, SEL, id))objc_msgSend)(query, ask, chosen);
        NSManagedObject *folder = ((id (*)(id, SEL, id, id))objc_msgSend)(folders, smart, rule, account);
        [folder setValue:name forKey:@"title"];
        identifier = [folder valueForKey:@"identifier"];
    })) return nil;
    if (!identifier && error) *error = NCError(@"NotesShared created no smart folder");
    return identifier;
}
+ (BOOL)renameFolder:(NSManagedObject *)folder name:(NSString *)name error:(NSError **)error {
    if (!NCRequireObject(folder, @[@"updateChangeCountWithReason:"], @"renaming folder", error)) return NO;
    return NCCatch(@"renaming folder", error, ^{ [folder setValue:name forKey:@"title"]; [folder setValue:NSDate.date forKey:@"dateForLastTitleModification"]; [(id<NCSynced>)folder updateChangeCountWithReason:@"Renamed folder"]; });
}
+ (NSManagedObject *)duplicateNote:(NSManagedObject *)note folder:(NSManagedObject *)folder error:(NSError **)error {
    dlerror();
    if (!dlopen("/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", RTLD_NOW | RTLD_LOCAL)) { if (error) *error = NCError(@"cannot load NotesUI for duplicate"); return nil; }
    Class cls = NSClassFromString(@"ICNote"); SEL sel = NSSelectorFromString(@"duplicateNote:intoFolder:isPasswordProtected:removeOriginalNote:");
    if (!NCRequireClass(cls, @[@"duplicateNote:intoFolder:isPasswordProtected:removeOriginalNote:"], @"duplicating note", error)) return nil;
    __block NSManagedObject *copy = nil;
    if (!NCCatch(@"duplicating note", error, ^{ copy = ((id (*)(id, SEL, id, id, BOOL, BOOL))objc_msgSend)(cls, sel, note, folder, NO, NO); })) return nil;
    return copy;
}
+ (BOOL)saveContext:(NSManagedObjectContext *)context error:(NSError **)error {
    __block BOOL ok = NO;
    if (!NCCatch(@"saving Notes context", error, ^{ ok = [context save:error]; })) return NO;
    return ok;
}
+ (NSNumber *)checkedIntegerSelector:(NSString *)selector ofObject:(id)object error:(NSError **)error {
    if (!NCRequireObject(object, @[selector], @"reading private integer property", error)) return nil;
    __block NSInteger value = 0;
    SEL sel = NSSelectorFromString(selector);
    if (!NCCatch(@"reading private integer property", error, ^{ value = ((NSInteger (*)(id, SEL))objc_msgSend)(object, sel); })) return nil;
    return @(value);
}
+ (BOOL)requireInstanceSelectors:(NSArray<NSString *> *)selectors className:(NSString *)className error:(NSError **)error {
    return NCRequireInstanceClass(NSClassFromString(className), selectors, className, error);
}
+ (BOOL)requireSelectors:(NSArray<NSString *> *)selectors ofObject:(id)object error:(NSError **)error {
    return NCRequireObject(object, selectors, NSStringFromClass([object class]), error);
}
+ (BOOL)updateChangeCountOfObject:(id)object reason:(NSString *)reason error:(NSError **)error {
    if (!NCRequireObject(object, @[@"updateChangeCountWithReason:"], @"updating change count", error)) return NO;
    return NCCatch(@"updating change count", error, ^{ [(id<NCSynced>)object updateChangeCountWithReason:reason]; });
}
+ (BOOL)checklistAutoSortEnabled {
    id value = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("ICChecklistAutoSortEnabledDefaultsKey"), CFSTR("com.apple.Notes"));
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}
+ (BOOL)setChecklistAutoSortEnabled:(BOOL)enabled error:(NSError **)error {
    CFPreferencesSetAppValue(CFSTR("ICChecklistAutoSortEnabledDefaultsKey"), enabled ? kCFBooleanTrue : kCFBooleanFalse, CFSTR("com.apple.Notes"));
    if (!CFPreferencesAppSynchronize(CFSTR("com.apple.Notes"))) { if (error) *error = NCError(@"could not save the Notes checklist auto-sort preference"); return NO; }
    if ([self checklistAutoSortEnabled] != enabled) { if (error) *error = NCError(@"Notes checklist auto-sort preference did not match after save"); return NO; }
    return YES;
}
+ (id)folderSortTypeWithOrder:(NSInteger)order direction:(NSInteger)direction error:(NSError **)error {
    Class cls = NSClassFromString(@"ICFolderCustomNoteSortType");
    NSString *selector = @"folderNoteSortTypeWithOrder:direction:";
    if (!NCRequireClass(cls, @[selector], @"creating folder sort setting", error)) return nil;
    __block id value = nil;
    if (!NCCatch(@"creating folder sort setting", error, ^{
        value = ((id (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(cls, NSSelectorFromString(selector), order, direction);
    })) return nil;
    return value;
}
+ (NSString *)defaultAccountIdentifier:(NSError **)error {
    Class cls = NSClassFromString(@"ICDefaultAccountUtilities");
    if (!NCRequireClass(cls, @[@"defaultAccount"], @"reading default account", error)) return nil;
    __block id account = nil;
    if (!NCCatch(@"reading default account", error, ^{ account = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"defaultAccount")); })) return nil;
    if (!NCRequireObject(account, @[@"identifier"], @"reading default account identifier", error)) return nil;
    return [account valueForKey:@"identifier"];
}
+ (BOOL)setDefaultAccountIdentifier:(NSString *)identifier error:(NSError **)error {
    Class cls = NSClassFromString(@"ICDefaultAccountUtilities");
    NSString *selector = @"setDefaultAccountIdentifier:";
    if (!NCRequireClass(cls, @[selector], @"setting default account", error)) return NO;
    return NCCatch(@"setting default account", error, ^{
        ((void (*)(id, SEL, id))objc_msgSend)(cls, NSSelectorFromString(selector), identifier);
    });
}
@end

@implementation NCBodyEditor { NSManagedObject *_note; id<NCMergeable> _mergeable; }
- (instancetype)initWithNote:(NSManagedObject *)note error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (!NCRequireObject(note, @[@"document"], @"opening note body", error)) return nil;
    __block id document = nil, value = nil; __block NSAttributedString *body = nil;
    if (!NCCatch(@"opening note body", error, ^{ document = [(id<NCNote>)note document]; })) return nil;
    if (!NCRequireObject(document, @[@"mergeableString"], @"opening note body", error)) return nil;
    if (!NCCatch(@"opening note body", error, ^{ value = [(id<NCNote>)document mergeableString]; })) return nil;
    if (!NCRequireObject(value, @[@"attributedString"], @"opening note body", error)) return nil;
    if (!NCCatch(@"opening note body", error, ^{ body = [[(id<NCMergeable>)value attributedString] copy]; })) return nil;
    if (!value || !body) { if (error) *error = NCError(@"note has no editable body"); return nil; }
    _note = note; _mergeable = value; _original = body; return self;
}
- (BOOL)begin:(NSError **)error { if (!NCRequireObject(_note, @[@"beginEditing"], @"beginning body edit", error)) return NO; return NCCatch(@"beginning body edit", error, ^{ [(id<NCNote>)self->_note beginEditing]; }); }
- (BOOL)prepareWithOperations:(NSArray<NSString *> *)operations error:(NSError **)error {
    NSMutableArray<NSString *> *noteSelectors = [NSMutableArray arrayWithArray:@[@"beginEditing", @"endEditing", @"saveNoteData"]];
    NSMutableArray<NSString *> *mergeableSelectors = [NSMutableArray array];
    if ([operations containsObject:@"insert"]) { [mergeableSelectors addObject:@"insertAttributedString:atIndex:"]; [noteSelectors addObject:@"edited:range:changeInLength:"]; }
    if ([operations containsObject:@"delete"]) { [mergeableSelectors addObject:@"deleteCharactersInRange:"]; [noteSelectors addObject:@"edited:range:changeInLength:"]; }
    if ([operations containsObject:@"attributes"]) { [mergeableSelectors addObject:@"setAttributes:range:"]; [noteSelectors addObject:@"edited:range:changeInLength:"]; }
    if (!NCRequireObject(_note, noteSelectors, @"preparing body edit", error)) return NO;
    if (mergeableSelectors.count && !NCRequireObject(_mergeable, mergeableSelectors, @"preparing body edit", error)) return NO;
    return YES;
}
- (BOOL)beginWithOperations:(NSArray<NSString *> *)operations error:(NSError **)error {
    if (![self prepareWithOperations:operations error:error]) return NO;
    return NCCatch(@"beginning body edit", error, ^{ [(id<NCNote>)self->_note beginEditing]; });
}
- (BOOL)insert:(NSAttributedString *)text at:(NSUInteger)index error:(NSError **)error {
    if (!text.length) return YES;
    if (!NCRequireObject(_mergeable, @[@"insertAttributedString:atIndex:"], @"inserting body text", error) || !NCRequireObject(_note, @[@"edited:range:changeInLength:"], @"inserting body text", error)) return NO;
    return NCCatch(@"inserting body text", error, ^{ [self->_mergeable insertAttributedString:text atIndex:index]; [(id<NCNote>)self->_note edited:3 range:NSMakeRange(index, text.length) changeInLength:(NSInteger)text.length]; });
}
- (BOOL)deleteRange:(NSRange)range error:(NSError **)error {
    if (!range.length) return YES;
    if (!NCRequireObject(_mergeable, @[@"deleteCharactersInRange:"], @"deleting body text", error) || !NCRequireObject(_note, @[@"edited:range:changeInLength:"], @"deleting body text", error)) return NO;
    return NCCatch(@"deleting body text", error, ^{ [self->_mergeable deleteCharactersInRange:range]; [(id<NCNote>)self->_note edited:3 range:NSMakeRange(range.location, 0) changeInLength:-(NSInteger)range.length]; });
}
- (BOOL)setAttributes:(NSDictionary *)attributes range:(NSRange)range error:(NSError **)error {
    if (!range.length) return YES;
    if (!NCRequireObject(_mergeable, @[@"setAttributes:range:"], @"formatting body text", error) || !NCRequireObject(_note, @[@"edited:range:changeInLength:"], @"formatting body text", error)) return NO;
    return NCCatch(@"formatting body text", error, ^{ [self->_mergeable setAttributes:attributes range:range]; [(id<NCNote>)self->_note edited:1 range:range changeInLength:0]; });
}
- (NSString *)addTable:(NSString *)text error:(NSError **)error {
    NCInstallTableStyleMethod(); __block NSString *identifier = nil;
    if (!NCRequireObject(_note, @[@"addTableAttachmentWithText:"], @"adding table", error)) return nil;
    Class styleClass = NSClassFromString(@"ICTTParagraphStyle");
    if (!styleClass || !NCRequireObject([styleClass alloc], @[@"setStyle:"], @"adding table", error)) return nil;
    if (!NCCatch(@"adding table", error, ^{ id table = [(id<NCNote>)self->_note addTableAttachmentWithText:[[NSAttributedString alloc] initWithString:text]]; identifier = [table valueForKey:@"identifier"]; })) return nil;
    return identifier;
}
- (BOOL)finish:(NSError **)error {
    if (!NCRequireObject(_note, @[@"endEditing", @"saveNoteData"], @"finishing body edit", error)) return NO;
    return NCCatch(@"finishing body edit", error, ^{ [self->_note setValue:NSDate.date forKey:@"modificationDate"]; [(id<NCNote>)self->_note endEditing]; [(id<NCNote>)self->_note saveNoteData]; });
}
@end

@implementation NCTableEditor { NSManagedObject *_attachment; id<NCTableModel> _model; id<NCTable> _table; }
- (BOOL)prepareToSave:(NSError **)error {
    return NCRequireObject(_model, @[@"setMergeableDataDirty:", @"writeMergeableData"], @"saving table", error) &&
           NCRequireObject(_attachment, @[@"updateChangeCountWithReason:"], @"saving table", error);
}
- (instancetype)initWithAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!(self = [super init])) return nil;
    __block id model = nil, table = nil;
    if (!NCRequireObject(attachment, @[@"attachmentModel"], @"opening table", error)) return nil;
    if (!NCCatch(@"opening table", error, ^{ model = [(id<NCSynced>)attachment attachmentModel]; })) return nil;
    if (!NCRequireObject(model, @[@"table"], @"opening table", error)) return nil;
    if (!NCCatch(@"opening table", error, ^{ table = [(id<NCTableModel>)model table]; })) return nil;
    if (!model || !table) { if (error) *error = NCError(@"table attachment has no editable table"); return nil; }
    _attachment = attachment; _model = model; _table = table; return self;
}
- (NSNumber *)rowCount:(NSError **)error {
    if (!NCRequireObject(_table, @[@"rowCount"], @"reading table row count", error)) return nil;
    __block NSInteger count = 0;
    if (!NCCatch(@"reading table row count", error, ^{ count = (NSInteger)[self->_table rowCount]; })) return nil;
    return @(count);
}
- (NSNumber *)columnCount:(NSError **)error {
    if (!NCRequireObject(_table, @[@"columnCount"], @"reading table column count", error)) return nil;
    __block NSInteger count = 0;
    if (!NCCatch(@"reading table column count", error, ^{ count = (NSInteger)[self->_table columnCount]; })) return nil;
    return @(count);
}
- (NSString *)textAtColumn:(NSInteger)column row:(NSInteger)row error:(NSError **)error {
    if (!NCRequireObject(_table, @[@"stringForColumnIndex:rowIndex:"], @"reading table cell", error)) return nil;
    __block NSString *text = @"";
    if (!NCCatch(@"reading table cell", error, ^{ text = NCPlain([self->_table stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row]); })) return nil;
    return text;
}
- (NSAttributedString *)attributedTextAtColumn:(NSInteger)column row:(NSInteger)row error:(NSError **)error {
    if (!NCRequireObject(_table, @[@"stringForColumnIndex:rowIndex:"], @"reading rich table cell", error)) return nil;
    __block NSAttributedString *text = nil;
    if (!NCCatch(@"reading rich table cell", error, ^{
        id value = [self->_table stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row];
        text = [value isKindOfClass:NSAttributedString.class] ? value : [[NSAttributedString alloc] initWithString:NCPlain(value)];
    })) return nil;
    return text;
}
- (BOOL)insertRow:(NSInteger)index error:(NSError **)error { if (![self prepareToSave:error] || !NCRequireObject(_table, @[@"insertRowAtIndex:"], @"inserting table row", error)) return NO; return NCCatch(@"inserting table row", error, ^{ [self->_table insertRowAtIndex:(NSUInteger)index]; }); }
- (BOOL)removeRow:(NSInteger)index error:(NSError **)error { if (![self prepareToSave:error] || !NCRequireObject(_table, @[@"removeRowAtIndex:"], @"removing table row", error)) return NO; return NCCatch(@"removing table row", error, ^{ [self->_table removeRowAtIndex:(NSUInteger)index]; }); }
- (BOOL)insertColumn:(NSInteger)index error:(NSError **)error { if (![self prepareToSave:error] || !NCRequireObject(_table, @[@"insertColumnAtIndex:"], @"inserting table column", error)) return NO; return NCCatch(@"inserting table column", error, ^{ [self->_table insertColumnAtIndex:(NSUInteger)index]; }); }
- (BOOL)removeColumn:(NSInteger)index error:(NSError **)error { if (![self prepareToSave:error] || !NCRequireObject(_table, @[@"removeColumnAtIndex:"], @"removing table column", error)) return NO; return NCCatch(@"removing table column", error, ^{ [self->_table removeColumnAtIndex:(NSUInteger)index]; }); }
- (BOOL)setCellColumn:(NSInteger)column row:(NSInteger)row text:(NSString *)text style:(id)style error:(NSError **)error {
    if (![self prepareToSave:error]) return NO;
    NSArray *readSelectors = @[@"identifierForColumnAtIndex:", @"identifierForRowAtIndex:", @"mergeableStringForColumnID:rowID:", @"stringForColumnIndex:rowIndex:"];
    if (!NCRequireObject(_table, readSelectors, @"editing table cell", error)) return NO;
    __block id columnID = nil, rowID = nil, cell = nil; __block NSString *old = @"";
    if (!NCCatch(@"reading table cell", error, ^{
        columnID = [self->_table identifierForColumnAtIndex:(NSUInteger)column]; rowID = [self->_table identifierForRowAtIndex:(NSUInteger)row];
        cell = columnID && rowID ? [self->_table mergeableStringForColumnID:columnID rowID:rowID] : nil;
        old = NCPlain([self->_table stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row]);
    })) return NO;
    if (!cell || old.length == 0) {
        if (!NCRequireObject(_table, @[@"setAttributedString:columnIndex:rowIndex:"], @"editing table cell", error)) return NO;
    } else if (!NCRequireObject(cell, @[@"beginEditing", @"deleteCharactersInRange:", @"insertString:atIndex:", @"endEditing"], @"editing table cell", error)) return NO;
    return NCCatch(@"editing table cell", error, ^{
        if (!cell || old.length == 0) { [self->_table setAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{@"TTStyle": style}] columnIndex:(NSUInteger)column rowIndex:(NSUInteger)row]; return; }
        [(id<NCMergeable>)cell beginEditing]; @try { if (old.length) [(id<NCMergeable>)cell deleteCharactersInRange:NSMakeRange(0, old.length)]; if (text.length) [(id<NCMergeable>)cell insertString:text atIndex:0]; } @finally { [(id<NCMergeable>)cell endEditing]; }
    });
}
- (BOOL)setAttributedCellColumn:(NSInteger)column row:(NSInteger)row text:(NSAttributedString *)text error:(NSError **)error {
    if (![self prepareToSave:error] || !NCRequireObject(_table, @[@"setAttributedString:columnIndex:rowIndex:"], @"formatting table cell", error)) return NO;
    return NCCatch(@"formatting table cell", error, ^{
        [self->_table setAttributedString:text columnIndex:(NSUInteger)column rowIndex:(NSUInteger)row];
    });
}
- (BOOL)save:(NSError **)error { if (![self prepareToSave:error]) return NO; return NCCatch(@"saving table", error, ^{ [self->_model setMergeableDataDirty:YES]; [self->_model writeMergeableData]; [(id<NCSynced>)self->_attachment updateChangeCountWithReason:@"Edited table"]; }); }
@end
