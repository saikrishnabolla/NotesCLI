#import "NotesNativeObjC.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

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
static BOOL NCRequire(id target, NSString *selector, BOOL classMethod, NSError **error) {
    SEL sel = NSSelectorFromString(selector);
    BOOL available = classMethod ? [target respondsToSelector:sel] : [(Class)target instancesRespondToSelector:sel];
    if (!available && error) *error = NCError([NSString stringWithFormat:@"required selector missing: %@ %@", target, selector]);
    return available;
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
- (id)addTableAttachmentWithText:(NSAttributedString *)text;
- (void)setShouldAddMediaAsynchronously:(BOOL)value;
- (void)setIsPinned:(BOOL)value;
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
                                  @"newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:"],
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
        Class styleClass = NSClassFromString(@"ICTTParagraphStyle");
        if (!styleClass) return;
        NSMutableArray *updates = [NSMutableArray array];
        [string enumerateAttribute:@"TTStyle" inRange:range options:0 usingBlock:^(id value, NSRange run, BOOL *stop) {
            id<NCParagraph> style = value ? [value mutableCopy] : [[styleClass alloc] init];
            [style setStyle:3];
            [updates addObject:@[[NSValue valueWithRange:run], style]];
        }];
        for (NSArray *update in updates) [string addAttribute:@"TTStyle" value:update[1] range:[update[0] rangeValue]];
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
    if (!cls || !NCRequire(cls, @"startSharedContextWithOptions:", YES, error) || !NCRequire(cls, @"sharedContext", YES, error)) return nil;
    __block id shared = nil;
    if (!NCCatch(@"opening Notes context", error, ^{
        id<NCNoteContextClass> typed = (id<NCNoteContextClass>)cls;
        [typed startSharedContextWithOptions:0];
        shared = [typed sharedContext];
    })) return nil;
    if (![shared respondsToSelector:@selector(persistentContainer)]) { if (error) *error = NCError(@"required selector missing: ICNoteContext persistentContainer"); return nil; }
    __block NSManagedObjectContext *found = nil;
    if (!NCCatch(@"opening Notes persistent container", error, ^{ found = [[(id<NCNoteContext>)shared persistentContainer] viewContext]; })) return nil;
    if (!found && error) *error = NCError(@"Notes shared context returned no view context");
    context = found;
    return context;
}

+ (id)valueForKey:(NSString *)key ofObject:(id)object { @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; } }

+ (NSAttributedString *)bodyOfNote:(NSManagedObject *)note error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    if (![note respondsToSelector:@selector(mergeableString)]) { if (error) *error = NCError(@"required selector missing: ICNote mergeableString"); return nil; }
    __block NSAttributedString *body = nil;
    if (!NCCatch(@"reading note body", error, ^{ body = [[[(id<NCNote>)note mergeableString] attributedString] copy]; })) return nil;
    return body ?: [[NSAttributedString alloc] init];
}

+ (id)paragraphStyle:(NSInteger)style indent:(NSInteger)indent quote:(NSInteger)quote checked:(NSInteger)checked basedOn:(id)existing error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    Class cls = NSClassFromString(@"ICTTParagraphStyle"), todoClass = NSClassFromString(@"ICTTTodo");
    if (!cls || !todoClass) { if (error) *error = NCError(@"required class missing: ICTTParagraphStyle or ICTTTodo"); return nil; }
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
    Class cls = NSClassFromString(@"ICInlineAttachment"); SEL sel = NSSelectorFromString(@"newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:");
    if (!cls || ![cls respondsToSelector:sel]) { if (error) *error = NCError(@"required selector missing: ICInlineAttachment tag creation"); return nil; }
    __block NSString *identifier = nil;
    if (!NCCatch(@"creating tag", error, ^{ id item = [(id<NCInlineClass>)cls newHashtagAttachmentWithIdentifier:NSUUID.UUID.UUIDString hashtagText:name creatingHashtagIfNecessary:YES note:note parentAttachment:nil]; identifier = [item valueForKey:@"identifier"]; })) return nil;
    return identifier;
}

+ (NSString *)makeNoteLinkTo:(NSManagedObject *)target from:(NSManagedObject *)source text:(NSString *)text error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment"); SEL sel = NSSelectorFromString(@"newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:");
    if (!cls || ![cls respondsToSelector:sel]) { if (error) *error = NCError(@"required selector missing: ICInlineAttachment note-link creation"); return nil; }
    __block NSString *identifier = nil;
    if (!NCCatch(@"creating note link", error, ^{ id item = [(id<NCInlineClass>)cls newLinkAttachmentWithIdentifier:NSUUID.UUID.UUIDString toNote:target fromNote:source parentAttachment:nil]; if (text.length) [item setValue:text forKey:@"altText"]; identifier = [item valueForKey:@"identifier"]; })) return nil;
    return identifier;
}

+ (NSString *)addFile:(NSURL *)file toNote:(NSManagedObject *)note title:(NSString *)title type:(NSString **)type error:(NSError **)error {
    if (![note respondsToSelector:@selector(addAttachmentWithFileURL:)]) { if (error) *error = NCError(@"required selector missing: ICNote addAttachmentWithFileURL:"); return nil; }
    __block NSString *identifier = nil, *kind = nil;
    if (!NCCatch(@"adding file", error, ^{ if ([note respondsToSelector:@selector(setShouldAddMediaAsynchronously:)]) [(id<NCNote>)note setShouldAddMediaAsynchronously:NO]; id item = [(id<NCNote>)note addAttachmentWithFileURL:file]; if (title.length) [item setValue:title forKey:@"userTitle"]; identifier = [item valueForKey:@"identifier"]; kind = [item valueForKey:@"typeUTI"]; })) return nil;
    if (type) *type = kind;
    return identifier;
}

+ (BOOL)setPreferredImageSize:(NSString *)size attachment:(NSManagedObject *)attachment error:(NSError **)error {
    SEL sel = NSSelectorFromString(@"setPreferredViewSize:");
    if (![attachment respondsToSelector:sel]) { if (error) *error = NCError(@"required selector missing: ICAttachment setPreferredViewSize:"); return NO; }
    return NCCatch(@"setting image view size", error, ^{ ((void (*)(id, SEL, short))objc_msgSend)(attachment, sel, [size isEqualToString:@"small"] ? 1 : 0); });
}

+ (BOOL)renameTag:(NSManagedObject *)tag to:(NSString *)name error:(NSError **)error {
    Class cls = NSClassFromString(@"ICHashtag"); SEL sel = NSSelectorFromString(@"renameHashtagsWithStandardizedContent:newDisplayText:context:");
    if (!cls || ![cls respondsToSelector:sel]) { if (error) *error = NCError(@"required selector missing: ICHashtag rename"); return NO; }
    return NCCatch(@"renaming tag", error, ^{ [(id<NCInlineClass>)cls renameHashtagsWithStandardizedContent:[tag valueForKey:@"standardizedContent"] newDisplayText:name context:tag.managedObjectContext]; });
}
+ (BOOL)reviveTagAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment"); SEL sel = NSSelectorFromString(@"reviveOrTouchHashtag:");
    if (!cls || ![cls respondsToSelector:sel]) return YES;
    return NCCatch(@"reviving tag", error, ^{ [(id<NCInlineClass>)cls reviveOrTouchHashtag:attachment]; });
}
+ (BOOL)markForDeletion:(NSManagedObject *)object error:(NSError **)error {
    if (![object respondsToSelector:@selector(markForDeletion)]) { if (error) *error = NCError(@"required selector missing: markForDeletion"); return NO; }
    return NCCatch(@"marking object deleted", error, ^{ [(id<NCSynced>)object markForDeletion]; });
}
+ (BOOL)unmarkForDeletion:(NSManagedObject *)object error:(NSError **)error {
    if (![object respondsToSelector:@selector(unmarkForDeletion)]) { if (error) *error = NCError(@"required selector missing: unmarkForDeletion"); return NO; }
    return NCCatch(@"restoring object", error, ^{ [(id<NCSynced>)object unmarkForDeletion]; [(id<NCSynced>)object updateChangeCountWithReason:@"Restored"]; });
}
+ (BOOL)setPinned:(BOOL)pinned note:(NSManagedObject *)note error:(NSError **)error {
    if (![note respondsToSelector:@selector(setIsPinned:)]) { if (error) *error = NCError(@"required selector missing: ICNote setIsPinned:"); return NO; }
    return NCCatch(@"changing pin", error, ^{ [(id<NCNote>)note setIsPinned:pinned]; [(id<NCSynced>)note updateChangeCountWithReason:pinned ? @"Pinned note" : @"Unpinned note"]; });
}
+ (BOOL)moveFolder:(NSManagedObject *)folder parent:(NSManagedObject *)parent error:(NSError **)error {
    return NCCatch(@"moving folder", error, ^{ [folder setValue:parent forKey:@"parent"]; [folder setValue:NSDate.date forKey:@"parentModificationDate"]; [(id<NCSynced>)folder updateChangeCountWithReason:@"Moved folder"]; });
}
+ (NSManagedObject *)duplicateNote:(NSManagedObject *)note folder:(NSManagedObject *)folder error:(NSError **)error {
    dlerror();
    if (!dlopen("/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", RTLD_NOW | RTLD_LOCAL)) { if (error) *error = NCError(@"cannot load NotesUI for duplicate"); return nil; }
    Class cls = NSClassFromString(@"ICNote"); SEL sel = NSSelectorFromString(@"duplicateNote:intoFolder:isPasswordProtected:removeOriginalNote:");
    if (!cls || ![cls respondsToSelector:sel]) { if (error) *error = NCError(@"required selector missing: ICNote duplicateNote"); return nil; }
    __block NSManagedObject *copy = nil;
    if (!NCCatch(@"duplicating note", error, ^{ copy = ((id (*)(id, SEL, id, id, BOOL, BOOL))objc_msgSend)(cls, sel, note, folder, NO, NO); })) return nil;
    return copy;
}
+ (BOOL)saveContext:(NSManagedObjectContext *)context error:(NSError **)error {
    __block BOOL ok = NO;
    if (!NCCatch(@"saving Notes context", error, ^{ ok = [context save:error]; })) return NO;
    return ok;
}
@end

@implementation NCBodyEditor { NSManagedObject *_note; id<NCMergeable> _mergeable; }
- (instancetype)initWithNote:(NSManagedObject *)note error:(NSError **)error {
    if (!(self = [super init])) return nil;
    __block id value = nil; __block NSAttributedString *body = nil;
    if (!NCCatch(@"opening note body", error, ^{ value = [[(id<NCNote>)note document] mergeableString]; body = [[(id<NCMergeable>)value attributedString] copy]; })) return nil;
    if (!value || !body) { if (error) *error = NCError(@"note has no editable body"); return nil; }
    _note = note; _mergeable = value; _original = body; return self;
}
- (BOOL)begin:(NSError **)error { return NCCatch(@"beginning body edit", error, ^{ [(id<NCNote>)self->_note beginEditing]; }); }
- (BOOL)insert:(NSAttributedString *)text at:(NSUInteger)index error:(NSError **)error {
    if (!text.length) return YES;
    return NCCatch(@"inserting body text", error, ^{ [self->_mergeable insertAttributedString:text atIndex:index]; [(id<NCNote>)self->_note edited:3 range:NSMakeRange(index, text.length) changeInLength:(NSInteger)text.length]; });
}
- (BOOL)deleteRange:(NSRange)range error:(NSError **)error {
    if (!range.length) return YES;
    return NCCatch(@"deleting body text", error, ^{ [self->_mergeable deleteCharactersInRange:range]; [(id<NCNote>)self->_note edited:3 range:NSMakeRange(range.location, 0) changeInLength:-(NSInteger)range.length]; });
}
- (BOOL)setAttributes:(NSDictionary *)attributes range:(NSRange)range error:(NSError **)error {
    if (!range.length) return YES;
    return NCCatch(@"formatting body text", error, ^{ [self->_mergeable setAttributes:attributes range:range]; [(id<NCNote>)self->_note edited:1 range:range changeInLength:0]; });
}
- (NSString *)addTable:(NSString *)text error:(NSError **)error {
    NCInstallTableStyleMethod(); __block NSString *identifier = nil;
    if (![(id) _note respondsToSelector:@selector(addTableAttachmentWithText:)]) { if (error) *error = NCError(@"required selector missing: ICNote addTableAttachmentWithText:"); return nil; }
    if (!NCCatch(@"adding table", error, ^{ id table = [(id<NCNote>)self->_note addTableAttachmentWithText:[[NSAttributedString alloc] initWithString:text]]; identifier = [table valueForKey:@"identifier"]; })) return nil;
    return identifier;
}
- (BOOL)finish:(NSError **)error {
    return NCCatch(@"finishing body edit", error, ^{ [self->_note setValue:NSDate.date forKey:@"modificationDate"]; [(id<NCNote>)self->_note endEditing]; [(id<NCNote>)self->_note saveNoteData]; });
}
@end

@implementation NCTableEditor { NSManagedObject *_attachment; id<NCTableModel> _model; id<NCTable> _table; }
- (instancetype)initWithAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!(self = [super init])) return nil;
    __block id model = nil, table = nil;
    if (!NCCatch(@"opening table", error, ^{ model = [(id<NCSynced>)attachment attachmentModel]; table = [(id<NCTableModel>)model table]; })) return nil;
    if (!model || !table) { if (error) *error = NCError(@"table attachment has no editable table"); return nil; }
    _attachment = attachment; _model = model; _table = table; return self;
}
- (NSInteger)rowCount { return (NSInteger)[_table rowCount]; }
- (NSInteger)columnCount { return (NSInteger)[_table columnCount]; }
- (NSString *)textAtColumn:(NSInteger)column row:(NSInteger)row { __block NSString *text = @""; NCCatch(@"reading table cell", NULL, ^{ text = NCPlain([self->_table stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row]); }); return text; }
- (BOOL)insertRow:(NSInteger)index error:(NSError **)error { return NCCatch(@"inserting table row", error, ^{ [self->_table insertRowAtIndex:(NSUInteger)index]; }); }
- (BOOL)removeRow:(NSInteger)index error:(NSError **)error { return NCCatch(@"removing table row", error, ^{ [self->_table removeRowAtIndex:(NSUInteger)index]; }); }
- (BOOL)insertColumn:(NSInteger)index error:(NSError **)error { return NCCatch(@"inserting table column", error, ^{ [self->_table insertColumnAtIndex:(NSUInteger)index]; }); }
- (BOOL)removeColumn:(NSInteger)index error:(NSError **)error { return NCCatch(@"removing table column", error, ^{ [self->_table removeColumnAtIndex:(NSUInteger)index]; }); }
- (BOOL)setCellColumn:(NSInteger)column row:(NSInteger)row text:(NSString *)text style:(id)style error:(NSError **)error {
    return NCCatch(@"editing table cell", error, ^{
        id columnID = [self->_table identifierForColumnAtIndex:(NSUInteger)column], rowID = [self->_table identifierForRowAtIndex:(NSUInteger)row];
        id<NCMergeable> cell = columnID && rowID ? [self->_table mergeableStringForColumnID:columnID rowID:rowID] : nil;
        NSString *old = NCPlain([self->_table stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row]);
        if (!cell || old.length == 0) { [self->_table setAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{@"TTStyle": style}] columnIndex:(NSUInteger)column rowIndex:(NSUInteger)row]; return; }
        [cell beginEditing]; @try { if (old.length) [cell deleteCharactersInRange:NSMakeRange(0, old.length)]; if (text.length) [cell insertString:text atIndex:0]; } @finally { [cell endEditing]; }
    });
}
- (BOOL)save:(NSError **)error { return NCCatch(@"saving table", error, ^{ [self->_model setMergeableDataDirty:YES]; [self->_model writeMergeableData]; [(id<NCSynced>)self->_attachment updateChangeCountWithReason:@"Edited table"]; }); }
@end
