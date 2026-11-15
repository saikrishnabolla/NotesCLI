#import "NotesNativeObjC.h"
#import <dlfcn.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

static NSString *const NCErrorDomain = @"NotesCLI.NotesNative";
static NSError *NCError(NSString *message) {
    return [NSError errorWithDomain:NCErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSError *NCErrorWithCode(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:NCErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
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
- (BOOL)saveNoteData;
- (void)edited:(NSUInteger)mask range:(NSRange)range changeInLength:(NSInteger)delta;
- (id)addAttachmentWithFileURL:(NSURL *)url;
- (id)addURLAttachmentWithURL:(NSURL *)url;
- (id)addSynapseLinkAttachmentWithContentItem:(id)item;
- (id)addTableAttachmentWithText:(NSAttributedString *)text;
- (id)addAudioAttachmentWithIdentifier:(NSString *)identifier;
- (id)addAttachmentWithUTI:(NSString *)uti identifier:(NSString *)identifier urlString:(NSString *)urlString analytics:(BOOL)analytics regulatoryLogging:(BOOL)logging;
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
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)text;
- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)text;
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
- (void)setUuid:(NSUUID *)value;
- (void)setTodo:(id)value;
@end
@protocol NCTodo
- (id)initWithIdentifier:(NSUUID *)identifier done:(BOOL)done;
- (id)todoWithDone:(BOOL)done;
@end
@protocol NCInlineClass
+ (id)newHashtagAttachmentWithIdentifier:(NSString *)identifier hashtagText:(NSString *)text
              creatingHashtagIfNecessary:(BOOL)create note:(id)note parentAttachment:(id)parent;
+ (id)newLinkAttachmentWithIdentifier:(NSString *)identifier toNote:(id)target fromNote:(id)source parentAttachment:(id)parent;
+ (id)newParagraphLinkAttachmentWithIdentifier:(NSString *)identifier toNote:(id)target paragraphName:(NSString *)name
                                    paragraphID:(NSUUID *)paragraphID fromNote:(id)source parentAttachment:(id)parent;
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
- (void)reverseColumnDirection;
@end
@protocol NCScanEditor
- (id)initWithGalleryAttachment:(id)gallery;
- (void)applyFilter:(short)filter forAttachmentWithIdentifier:(NSString *)identifier;
- (void)setOrientation:(NSInteger)orientation forAttachmentAtIndex:(NSUInteger)index;
- (BOOL)moveObjectWithIdentifier:(NSString *)identifier toIndex:(NSUInteger)index;
- (void)setQuad:(id)quad forAttachmentWithIdentifier:(NSString *)identifier;
- (void)setMarkupData:(NSData *)data forAttachmentWithIdentifier:(NSString *)identifier;
- (id)subAttachmentWithIdentifier:(NSString *)identifier;
- (void)deletePagesAtIndexes:(NSIndexSet *)indexes;
- (void)undeleteSubAttachment:(id)attachment;
- (id)galleryModel;
- (void)saveAndUpdatePreview:(BOOL)update;
@end
@protocol NCGalleryModel
- (NSUInteger)indexOfSubAttachmentWithIdentifier:(NSString *)identifier;
- (void)insertSubAttachment:(id)attachment atIndex:(NSUInteger)index;
@end
@protocol NCImageQuad
- (void)setBottomLeft:(CGPoint)value;
- (void)setBottomRight:(CGPoint)value;
- (void)setTopLeft:(CGPoint)value;
- (void)setTopRight:(CGPoint)value;
- (BOOL)isValid;
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

static BOOL NCLoadFramework(NSString *path, NSString *name, NSError **error) {
    dlerror();
    if (dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL)) return YES;
    const char *detail = dlerror();
    if (error) *error = NCError([NSString stringWithFormat:@"cannot load %@: %s", name, detail ?: "unknown error"]);
    return NO;
}

@interface NCPreparedScan ()
@property(nonatomic, strong) id imageCache;
@property(nonatomic, copy) NSArray *documents;
@property(nonatomic, strong) NSURL *cacheDirectoryURL;
@property(nonatomic, readwrite) NSUInteger pageCount;
@end

@implementation NCPreparedScan
- (void)invalidate {
    id cache = self.imageCache;
    if (cache && [cache respondsToSelector:NSSelectorFromString(@"deleteAllImages")]) {
        @try { ((BOOL (*)(id, SEL))objc_msgSend)(cache, NSSelectorFromString(@"deleteAllImages")); }
        @catch (__unused NSException *exception) {}
    }
    NSURL *directory = self.cacheDirectoryURL;
    NSString *temporary = NSTemporaryDirectory().stringByStandardizingPath;
    NSString *path = directory.path.stringByStandardizingPath;
    if ([path hasPrefix:[temporary stringByAppendingString:@"/"]] && [directory.lastPathComponent hasPrefix:@"NotesCLI-DocCam-"]) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    }
    self.imageCache = nil;
    self.documents = @[];
    self.cacheDirectoryURL = nil;
    self.pageCount = 0;
}
- (void)dealloc { [self invalidate]; }
@end

static NSDictionary<NSString *, NSArray<NSString *> *> *NCClassSelectors(void) {
    return @{
        @"ICNoteContext": @[@"startSharedContextWithOptions:", @"sharedContext"],
        @"ICInlineAttachment": @[@"newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:",
                                  @"newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:",
                                  @"newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:fromNote:parentAttachment:",
                                  @"newDividerLineAttachmentWithIdentifier:note:parentAttachment:",
                                  @"newCalculateGraphExpressionAttachmentWithIdentifier:altText:note:parentAttachment:rightToLeft:",
                                  @"newMentionAttachmentWithIdentifier:mentionText:userRecordName:note:parentAttachment:", @"reviveOrTouchHashtag:"],
        @"ICMentionsController": @[@"allUserRecordName"],
        @"ICHashtagController": @[@"shouldAutoConvertToTag", @"setShouldAutoConvertToTag:"],
        @"Calculate": @[@"evaluate:options:error:"],
        @"ICHashtag": @[@"renameHashtagsWithStandardizedContent:newDisplayText:context:"],
        @"ICTextStyle": @[@"noteDefaultNamedStyle", @"setNoteDefaultNamedStyle:"],
        @"ICDefaultAccountUtilities": @[@"defaultAccount", @"setDefaultAccountIdentifier:"],
        @"ICDocCamImageQuad": @[@"quadFromCGRect:"],
        @"ICGalleryAttachmentUtilities": @[@"createAndAddSubAttachmentsToGalleryAttachment:fromDocuments:imageCache:context:"],
    };
}
static NSDictionary<NSString *, NSArray<NSString *> *> *NCInstanceSelectors(void) {
    return @{
        @"ICNoteContext": @[@"persistentContainer"],
        @"SYContentItem": @[@"initWithDisplayTitle:sourceIdentifier:sourceName:itemURL:", @"dataRepresentationWithError:",
                              @"initWithData:error:", @"displayTitle", @"sourceIdentifier", @"sourceLastKnownName", @"itemURL"],
        @"ICNote": @[@"document", @"mergeableString", @"beginEditing", @"endEditing", @"saveNoteData",
                     @"edited:range:changeInLength:", @"addAttachmentWithFileURL:", @"addTableAttachmentWithText:", @"setIsPinned:",
                     @"addSynapseLinkAttachmentWithContentItem:",
                     @"setShouldAddMediaAsynchronously:", @"updateChangeCountWithReason:", @"addGalleryAttachmentWithIdentifier:"],
        @"ICInlineAttachment": @[@"markForDeletion"],
        @"ICTTParagraphStyle": @[@"setStyle:", @"setIndent:", @"setBlockQuoteLevel:", @"setStartingItemNumber:", @"todo", @"setUuid:", @"setTodo:"],
        @"ICTTFont": @[@"initWithName:size:hints:", @"fontName", @"pointSize", @"fontHints"],
        @"ICOutlineState": @[@"initWithCollapsedUUIDs:", @"data", @"collapsedUUIDStrings"],
        @"ICTTTodo": @[@"initWithIdentifier:done:", @"todoWithDone:"],
        @"ICAttachment": @[@"markForDeletion", @"attachmentModel", @"updateChangeCountWithReason:", @"setPreferredViewSize:", @"addLocationIfNeeded",
                            @"hasSynapseLink", @"synapseData", @"setOcrSummary:", @"setImageClassificationSummary:"],
        @"ICAttachmentAudioModel": @[@"deleteSummaryAndReturnError:"],
        @"ICAttachmentGalleryModel": @[@"subAttachmentCount", @"subAttachmentIdentifierAtIndex:",
                                        @"indexOfSubAttachmentWithIdentifier:", @"insertSubAttachment:atIndex:"],
        @"ICDocCamScannedDocumentEditor": @[@"initWithGalleryAttachment:", @"applyFilter:forAttachmentWithIdentifier:",
                                               @"setOrientation:forAttachmentAtIndex:", @"moveObjectWithIdentifier:toIndex:",
                                               @"setQuad:forAttachmentWithIdentifier:", @"setMarkupData:forAttachmentWithIdentifier:", @"deletePagesAtIndexes:",
                                               @"undeleteSubAttachment:", @"galleryModel", @"saveAndUpdatePreview:"],
        @"ICFolder": @[@"updateChangeCountWithReason:", @"applyDateHeadersType:", @"isShowingDateHeaders"],
        @"ICDocCamImageCache": @[@"initWithDataCryptorDelegate:cachesDirectoryURL:", @"setImage:metaData:", @"getImageURL:", @"deleteAllImages"],
        @"ICDocCamDocumentInfo": @[@"init", @"setFullImageUUID:", @"setCroppedButNotFilteredImageUUID:",
                                    @"setCroppedAndFilteredImageUUID:", @"setImageQuad:", @"setMetaData:",
                                    @"setCurrentFilter:", @"setCurrentOrientation:"],
        @"CalculateResult": @[@"formattedExpression", @"formattedResult"],
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
        dlopen("/System/Library/PrivateFrameworks/DocumentCamera.framework/DocumentCamera", RTLD_NOW | RTLD_LOCAL);
        dlopen("/System/Library/PrivateFrameworks/NotesEditor.framework/NotesEditor", RTLD_NOW | RTLD_LOCAL);
        dlopen("/System/Library/PrivateFrameworks/Calculate.framework/Calculate", RTLD_NOW | RTLD_LOCAL);
        dlopen("/System/Library/PrivateFrameworks/Synapse.framework/Synapse", RTLD_NOW | RTLD_LOCAL);
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
    return [self paragraphStyle:style indent:indent quote:quote checked:checked startNumber:-1 basedOn:existing error:error];
}

+ (id)paragraphStyle:(NSInteger)style indent:(NSInteger)indent quote:(NSInteger)quote checked:(NSInteger)checked startNumber:(NSInteger)startNumber basedOn:(id)existing error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    Class cls = NSClassFromString(@"ICTTParagraphStyle"), todoClass = NSClassFromString(@"ICTTTodo");
    if (!cls || !todoClass) { if (error) *error = NCError(@"required class missing: ICTTParagraphStyle or ICTTTodo"); return nil; }
    if (!NCRequireObject(existing ?: [cls alloc], @[@"setStyle:", @"setIndent:", @"setBlockQuoteLevel:", @"todo"], @"creating paragraph style", error)) return nil;
    if (startNumber >= 0 && !NCRequireObject(existing ?: [cls alloc], @[@"setStartingItemNumber:"], @"setting numbered-list start", error)) return nil;
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
        if (startNumber >= 0) [(NSObject *)made setValue:@(startNumber) forKey:@"startingItemNumber"];
        id todo = nil;
        if (checked >= 0) { id prior = [made todo]; todo = prior ? [(id<NCTodo>)prior todoWithDone:checked == 1] : [(id<NCTodo>)[todoClass alloc] initWithIdentifier:NSUUID.UUID done:checked == 1]; }
        [(NSObject *)made setValue:todo forKey:@"todo"];
        result = made;
    })) return nil;
    return result;
}

+ (BOOL)applyParagraphID:(NSUUID *)paragraphID checklistID:(NSUUID *)checklistID checked:(NSInteger)checked toStyle:(id)style error:(NSError **)error {
    Class todoClass = NSClassFromString(@"ICTTTodo");
    if (!style || (paragraphID && !NCRequireObject(style, @[@"setUuid:"], @"restoring paragraph identity", error))) return NO;
    if (checklistID && (!todoClass || !NCRequireObject(style, @[@"setTodo:"], @"restoring checklist identity", error) ||
                        !NCRequireObject([todoClass alloc], @[@"initWithIdentifier:done:"], @"restoring checklist identity", error))) return NO;
    return NCCatch(@"restoring paragraph identity", error, ^{
        if (paragraphID) [(id<NCParagraph>)style setUuid:paragraphID];
        if (checklistID) {
            id todo = [(id<NCTodo>)[todoClass alloc] initWithIdentifier:checklistID done:checked == 1];
            [(id<NCParagraph>)style setTodo:todo];
        }
    });
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

static BOOL NCValidateInlineParent(NSManagedObject *note, NSManagedObject *parent, NSString *action, NSError **error) {
    if (!parent) return YES;
    if (!NCRequireObject(note, @[@"markedForDeletion", @"needsInitialFetchFromCloud"], action, error) ||
        !NCRequireObject(parent, @[@"typeUTI", @"note", @"markedForDeletion", @"needsInitialFetchFromCloud", @"inlineAttachments"], action, error)) return NO;
    __block BOOL valid = NO;
    if (!NCCatch(action, error, ^{
        valid = [[parent valueForKey:@"typeUTI"] isEqual:@"com.apple.notes.table"] &&
            [parent valueForKey:@"note"] == note &&
            ![[note valueForKey:@"markedForDeletion"] boolValue] &&
            ![[note valueForKey:@"needsInitialFetchFromCloud"] boolValue] &&
            ![[parent valueForKey:@"markedForDeletion"] boolValue] &&
            ![[parent valueForKey:@"needsInitialFetchFromCloud"] boolValue];
    })) return NO;
    if (!valid && error) *error = NCError([NSString stringWithFormat:@"%@ requires a live table belonging to the target note", action]);
    return valid;
}

static BOOL NCVerifyInlineParent(id item, NSManagedObject *note, NSManagedObject *parent, NSString *action, NSError **error) {
    if (!parent) return YES;
    if (!NCRequireObject(item, @[@"note", @"parentAttachment"], action, error)) return NO;
    __block BOOL valid = NO;
    if (!NCCatch(action, error, ^{
        id children = [parent valueForKey:@"inlineAttachments"];
        valid = [item valueForKey:@"note"] == note && [item valueForKey:@"parentAttachment"] == parent &&
            [children respondsToSelector:@selector(containsObject:)] && [children containsObject:item];
    })) return NO;
    if (!valid && error) *error = NCError([NSString stringWithFormat:@"%@ did not attach the new object to its table", action]);
    return valid;
}

+ (NSString *)makeTag:(NSString *)name inNote:(NSManagedObject *)note error:(NSError **)error {
    return [self makeTag:name inNote:note parent:nil error:error];
}

+ (NSString *)makeTag:(NSString *)name inNote:(NSManagedObject *)note parent:(NSManagedObject *)parent error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    if (!NCRequireClass(cls, @[@"newHashtagAttachmentWithIdentifier:hashtagText:creatingHashtagIfNecessary:note:parentAttachment:", @"reviveOrTouchHashtag:"], @"creating tag", error)) return nil;
    if (!NCValidateInlineParent(note, parent, @"creating tag", error)) return nil;
    __block NSString *identifier = nil; __block id item = nil;
    if (!NCCatch(@"creating tag", error, ^{ item = [(id<NCInlineClass>)cls newHashtagAttachmentWithIdentifier:NSUUID.UUID.UUIDString hashtagText:name creatingHashtagIfNecessary:YES note:note parentAttachment:parent]; identifier = [item valueForKey:@"identifier"]; })) return nil;
    if (!NCVerifyInlineParent(item, note, parent, @"creating tag", error)) return nil;
    return identifier;
}

+ (NSString *)makeNoteLinkTo:(NSManagedObject *)target from:(NSManagedObject *)source text:(NSString *)text error:(NSError **)error {
    return [self makeNoteLinkTo:target from:source text:text parent:nil error:error];
}

+ (NSString *)makeNoteLinkTo:(NSManagedObject *)target from:(NSManagedObject *)source text:(NSString *)text parent:(NSManagedObject *)parent error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    if (!NCRequireClass(cls, @[@"newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:"], @"creating note link", error)) return nil;
    if (!NCValidateInlineParent(source, parent, @"creating note link", error)) return nil;
    __block NSString *identifier = nil; __block id item = nil;
    if (!NCCatch(@"creating note link", error, ^{ item = [(id<NCInlineClass>)cls newLinkAttachmentWithIdentifier:NSUUID.UUID.UUIDString toNote:target fromNote:source parentAttachment:parent]; if (text.length) [item setValue:text forKey:@"altText"]; identifier = [item valueForKey:@"identifier"]; })) return nil;
    if (!NCVerifyInlineParent(item, source, parent, @"creating note link", error)) return nil;
    return identifier;
}

+ (NSString *)makeParagraphLinkTo:(NSManagedObject *)target paragraphName:(NSString *)paragraphName paragraphID:(NSUUID *)paragraphID from:(NSManagedObject *)source text:(NSString *)text parent:(NSManagedObject *)parent error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    NSString *selector = @"newParagraphLinkAttachmentWithIdentifier:toNote:paragraphName:paragraphID:fromNote:parentAttachment:";
    if (!paragraphID || !NCRequireClass(cls, @[selector], @"creating paragraph link", error)) return nil;
    if (!NCValidateInlineParent(source, parent, @"creating paragraph link", error)) return nil;
    __block NSString *identifier = nil; __block id item = nil;
    if (!NCCatch(@"creating paragraph link", error, ^{
        item = [(id<NCInlineClass>)cls newParagraphLinkAttachmentWithIdentifier:NSUUID.UUID.UUIDString toNote:target
                                                                  paragraphName:paragraphName paragraphID:paragraphID
                                                                        fromNote:source parentAttachment:parent];
        if (text.length) [item setValue:text forKey:@"altText"];
        identifier = [item valueForKey:@"identifier"];
    })) return nil;
    if (!NCVerifyInlineParent(item, source, parent, @"creating paragraph link", error)) return nil;
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
    return [self makeDividerInNote:note parent:nil type:type error:error];
}

+ (NSString *)makeDividerInNote:(NSManagedObject *)note parent:(NSManagedObject *)parent type:(NSString **)type error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    NSString *selector = @"newDividerLineAttachmentWithIdentifier:note:parentAttachment:";
    if (!NCRequireClass(cls, @[selector], @"creating divider", error)) return nil;
    if (!NCValidateInlineParent(note, parent, @"creating divider", error)) return nil;
    __block id item = nil;
    if (!NCCatch(@"creating divider", error, ^{ item = [(id<NCInlineClass>)cls newDividerLineAttachmentWithIdentifier:NSUUID.UUID.UUIDString note:note parentAttachment:parent]; })) return nil;
    if (!NCVerifyInlineParent(item, note, parent, @"creating divider", error)) return nil;
    return NCInlineIdentifier(item, type, @"creating divider", error);
}

+ (NSString *)makeMathExpression:(NSString *)expression inNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    return [self makeMathExpression:expression inNote:note parent:nil type:type error:error];
}

+ (NSString *)makeMathExpression:(NSString *)expression inNote:(NSManagedObject *)note parent:(NSManagedObject *)parent type:(NSString **)type error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    NSString *selector = @"newCalculateGraphExpressionAttachmentWithIdentifier:altText:note:parentAttachment:rightToLeft:";
    if (!NCRequireClass(cls, @[selector], @"creating math expression", error)) return nil;
    if (!NCValidateInlineParent(note, parent, @"creating math expression", error)) return nil;
    __block id item = nil;
    if (!NCCatch(@"creating math expression", error, ^{ item = [(id<NCInlineClass>)cls newCalculateGraphExpressionAttachmentWithIdentifier:NSUUID.UUID.UUIDString altText:expression note:note parentAttachment:parent rightToLeft:NO]; })) return nil;
    if (!NCVerifyInlineParent(item, note, parent, @"creating math expression", error)) return nil;
    return NCInlineIdentifier(item, type, @"creating math expression", error);
}

+ (NSString *)makeMention:(NSString *)text userRecordName:(NSString *)userRecordName inNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    return [self makeMention:text userRecordName:userRecordName inNote:note parent:nil type:type error:error];
}

+ (NSString *)makeMention:(NSString *)text userRecordName:(NSString *)userRecordName inNote:(NSManagedObject *)note parent:(NSManagedObject *)parent type:(NSString **)type error:(NSError **)error {
    Class cls = NSClassFromString(@"ICInlineAttachment");
    NSString *selector = @"newMentionAttachmentWithIdentifier:mentionText:userRecordName:note:parentAttachment:";
    if (!NCRequireClass(cls, @[selector], @"creating mention", error)) return nil;
    if (!NCValidateInlineParent(note, parent, @"creating mention", error)) return nil;
    __block id item = nil;
    if (!NCCatch(@"creating mention", error, ^{ item = [(id<NCInlineClass>)cls newMentionAttachmentWithIdentifier:NSUUID.UUID.UUIDString mentionText:text userRecordName:userRecordName note:note parentAttachment:parent]; })) return nil;
    if (!NCVerifyInlineParent(item, note, parent, @"creating mention", error)) return nil;
    return NCInlineIdentifier(item, type, @"creating mention", error);
}

+ (NSString *)allMentionUserRecordName:(NSError **)error {
    Class cls = NSClassFromString(@"ICMentionsController");
    if (!NCRequireClass(cls, @[@"allUserRecordName"], @"reading the all-mention identity", error)) return nil;
    __block NSString *identity = nil;
    if (!NCCatch(@"reading the all-mention identity", error, ^{
        identity = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"allUserRecordName"));
    })) return nil;
    if (!identity.length && error) *error = NCError(@"Notes returned an empty all-mention identity");
    return identity.length ? identity : nil;
}

+ (NSString *)addFile:(NSURL *)file toNote:(NSManagedObject *)note title:(NSString *)title type:(NSString **)type error:(NSError **)error {
    if (!NCRequireObject(note, @[@"setShouldAddMediaAsynchronously:", @"addAttachmentWithFileURL:"], @"adding file", error)) return nil;
    __block NSString *identifier = nil, *kind = nil;
    if (!NCCatch(@"adding file", error, ^{ [(id<NCNote>)note setShouldAddMediaAsynchronously:NO]; id item = [(id<NCNote>)note addAttachmentWithFileURL:file]; if (title.length) [item setValue:title forKey:@"userTitle"]; identifier = [item valueForKey:@"identifier"]; kind = [item valueForKey:@"typeUTI"]; })) return nil;
    if (type) *type = kind;
    return identifier;
}
+ (NSString *)addFile:(NSURL *)file toNote:(NSManagedObject *)note title:(NSString *)title
               typeUTI:(NSString *)typeUTI filename:(NSString *)filename
          resultingType:(NSString **)type error:(NSError **)error {
    if (!file.isFileURL || !typeUTI.length || !filename.length) {
        if (error) *error = NCError(@"explicit attachment metadata is incomplete");
        return nil;
    }
    NSArray *noteSelectors = @[@"setShouldAddMediaAsynchronously:",
                               @"addAttachmentWithUTI:identifier:urlString:analytics:regulatoryLogging:"];
    if (!NCRequireObject(note, noteSelectors, @"restoring file with explicit type", error)) return nil;
    __block NSString *identifier = nil, *kind = nil;
    if (!NCCatch(@"restoring file with explicit type", error, ^{
        [(id<NCNote>)note setShouldAddMediaAsynchronously:NO];
        NSString *newIdentifier = NSUUID.UUID.UUIDString;
        id item = ((id (*)(id, SEL, id, id, id, BOOL, BOOL))objc_msgSend)(
            note,
            NSSelectorFromString(@"addAttachmentWithUTI:identifier:urlString:analytics:regulatoryLogging:"),
            typeUTI, newIdentifier, nil, NO, NO
        );
        if (!NCRequireObject(item, @[@"addMediaWithURL:filename:updateFileBasedAttributes:",
                                     @"updateChangeCountWithReason:", @"identifier", @"typeUTI"],
                             @"restoring file with explicit type", error)) return;
        ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(
            item, NSSelectorFromString(@"addMediaWithURL:filename:updateFileBasedAttributes:"),
            file, filename, NO
        );
        NSDictionary<NSString *, id> *properties = [[item entity] propertiesByName];
        if (title.length && properties[@"userTitle"]) [item setValue:title forKey:@"userTitle"];
        [(id<NCSynced>)item updateChangeCountWithReason:@"Restored file attachment"];
        identifier = [item valueForKey:@"identifier"];
        kind = [item valueForKey:@"typeUTI"];
    })) return nil;
    if (!identifier.length && error && !*error) *error = NCError(@"Notes created no explicit file attachment");
    if (type) *type = kind;
    return identifier;
}
+ (NSURL *)mediaFileURLForAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!attachment) {
        if (error) *error = NCError(@"attachment is unavailable");
        return nil;
    }
    __block NSURL *result = nil;
    if (!NCCatch(@"reading attachment media URL", error, ^{
        NSArray<NSString *> *urlKeys = @[@"mediaURL", @"fileURL", @"fallbackImageURL", @"fallbackPDFURL"];
        for (NSString *key in urlKeys) {
            id candidate = [self valueForKey:key ofObject:attachment];
            if ([candidate isKindOfClass:NSURL.class] && [candidate isFileURL]) {
                result = candidate;
                return;
            }
        }
        for (NSString *relationship in @[@"media", @"mediaObject"]) {
            id media = [self valueForKey:relationship ofObject:attachment];
            NSArray *objects = nil;
            if ([media isKindOfClass:NSSet.class]) objects = [(NSSet *)media allObjects];
            else if ([media isKindOfClass:NSArray.class]) objects = media;
            else if (media) objects = @[media];
            for (id object in objects ?: @[]) {
                for (NSString *key in urlKeys) {
                    id candidate = [self valueForKey:key ofObject:object];
                    if ([candidate isKindOfClass:NSURL.class] && [candidate isFileURL]) {
                        result = candidate;
                        return;
                    }
                }
            }
        }
    })) return nil;
    if (!result && error && !*error) *error = NCError(@"Notes exposes no local media URL for the attachment");
    return result;
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
+ (NSDictionary<NSString *, id> *)createRecordingInNote:(NSManagedObject *)note
                                               fragments:(NSArray<NSDictionary<NSString *, id> *> *)fragments
                                                   title:(NSString *)title
                                                duration:(double)duration
                                                   error:(NSError **)error {
    NSArray *noteSelectors = @[@"addAudioAttachmentWithIdentifier:", @"addAttachmentWithUTI:identifier:urlString:analytics:regulatoryLogging:", @"setShouldAddMediaAsynchronously:"];
    if (!NCRequireObject(note, noteSelectors, @"creating multi-fragment recording", error)) return nil;
    Class fragmentClass = NSClassFromString(@"_TtCE11NotesSharedCSo18ICTTAudioRecording8Fragment");
    Class segmentClass = NSClassFromString(@"NotesShared.ICTTTranscriptSegment");
    if (!NCRequireInstanceClass(fragmentClass, @[@"initWithDocument:identity:", @"setCreatedDate:", @"setTranscriptVersion:", @"transcript"], @"creating recording fragment", error) ||
        !NCRequireInstanceClass(segmentClass, @[@"initWithDocument:identity:", @"setText:", @"setTimestamp:", @"setDuration:", @"setSpeaker:"], @"creating recording transcript", error)) return nil;
    __block NSDictionary<NSString *, id> *result = nil;
    if (!NCCatch(@"creating multi-fragment recording", error, ^{
        [(id<NCNote>)note setShouldAddMediaAsynchronously:NO];
        NSString *parentID = NSUUID.UUID.UUIDString;
        id parent = ((id (*)(id, SEL, id))objc_msgSend)(note, NSSelectorFromString(@"addAudioAttachmentWithIdentifier:"), parentID);
        if (!NCRequireObject(parent, @[@"attachmentModel", @"setDuration:", @"updateChangeCountWithReason:", @"identifier", @"typeUTI"], @"creating recording parent", error)) return;
        NSDictionary<NSString *, id> *properties = [[parent entity] propertiesByName];
        id savedTitle = title.length ? title : nil;
        for (NSString *key in @[@"title", @"fallbackTitle", @"altText", @"displayText"]) {
            if (properties[key]) [parent setValue:nil forKey:key];
        }
        if (properties[@"userTitle"]) [parent setValue:savedTitle forKey:@"userTitle"];
        [parent setValue:@(duration) forKey:@"duration"];
        id model = [(id<NCSynced>)parent attachmentModel];
        if (!NCRequireObject(model, @[@"audioDocument", @"setRecordedInNotes:", @"writeMergeableData"], @"opening recording model", error)) return;
        id audioDocument = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"audioDocument"));
        if (!NCRequireObject(audioDocument, @[@"document"], @"opening recording document", error)) return;
        id document = [audioDocument valueForKey:@"document"];
        if (!NCRequireObject(document, @[@"rootObject"], @"opening recording root", error)) return;
        id root = [document valueForKey:@"rootObject"];
        if (!NCRequireObject(root, @[@"fragments"], @"opening recording fragments", error)) return;
        id fragmentSet = [root valueForKey:@"fragments"];
        if (!NCRequireObject(fragmentSet, @[@"addObject:"], @"adding recording fragments", error)) return;
        NSMutableArray<NSString *> *childIDs = [NSMutableArray arrayWithCapacity:fragments.count];
        for (NSDictionary<NSString *, id> *row in fragments) {
            NSURL *url = row[@"url"];
            NSString *uti = row[@"typeUTI"], *filename = row[@"filename"];
            NSDate *createdDate = row[@"createdDate"];
            NSNumber *transcriptVersion = row[@"transcriptVersion"];
            if (![url isKindOfClass:NSURL.class] || !uti.length || ![createdDate isKindOfClass:NSDate.class] || ![transcriptVersion isKindOfClass:NSNumber.class]) {
                if (error) *error = NCError(@"recording fragment metadata is incomplete"); return;
            }
            NSString *childID = NSUUID.UUID.UUIDString;
            id child = ((id (*)(id, SEL, id, id, id, BOOL, BOOL))objc_msgSend)(note, NSSelectorFromString(@"addAttachmentWithUTI:identifier:urlString:analytics:regulatoryLogging:"), uti, childID, nil, NO, NO);
            if (!NCRequireObject(child, @[@"addMediaWithURL:filename:updateFileBasedAttributes:", @"setParentAttachment:", @"setDuration:", @"updateChangeCountWithReason:", @"identifier", @"typeUTI"], @"creating recording child", error)) return;
            ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(child, NSSelectorFromString(@"addMediaWithURL:filename:updateFileBasedAttributes:"), url, filename, NO);
            ((void (*)(id, SEL, id))objc_msgSend)(child, NSSelectorFromString(@"setParentAttachment:"), parent);
            [child setValue:row[@"duration"] ?: @0 forKey:@"duration"];
            NSUUID *identity = [[NSUUID alloc] initWithUUIDString:childID];
            id fragment = ((id (*)(id, SEL, id, id))objc_msgSend)([fragmentClass alloc], NSSelectorFromString(@"initWithDocument:identity:"), document, identity);
            if (!fragment) { if (error) *error = NCError(@"Notes could not create a recording fragment"); return; }
            [fragment setValue:createdDate forKey:@"createdDate"];
            [fragment setValue:transcriptVersion forKey:@"transcriptVersion"];
            id transcript = [fragment valueForKey:@"transcript"];
            if (!NCRequireObject(transcript, @[@"addObject:"], @"writing fragment transcript", error)) return;
            for (NSDictionary<NSString *, id> *segmentRow in row[@"segments"] ?: @[]) {
                id segment = ((id (*)(id, SEL, id, id))objc_msgSend)([segmentClass alloc], NSSelectorFromString(@"initWithDocument:identity:"), document, NSUUID.UUID);
                if (!segment) { if (error) *error = NCError(@"Notes could not create a transcript segment"); return; }
                [segment setValue:segmentRow[@"text"] ?: @"" forKey:@"text"];
                [segment setValue:segmentRow[@"start"] ?: @0 forKey:@"timestamp"];
                [segment setValue:segmentRow[@"duration"] ?: @0 forKey:@"duration"];
                [segment setValue:segmentRow[@"speaker"] forKey:@"speaker"];
                ((void (*)(id, SEL, id))objc_msgSend)(transcript, NSSelectorFromString(@"addObject:"), segment);
            }
            ((void (*)(id, SEL, id))objc_msgSend)(fragmentSet, NSSelectorFromString(@"addObject:"), fragment);
            [(id<NCSynced>)child updateChangeCountWithReason:@"Restored audio fragment"];
            [childIDs addObject:childID];
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(model, NSSelectorFromString(@"setRecordedInNotes:"), YES);
        ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"writeMergeableData"));
        [(id<NCSynced>)parent updateChangeCountWithReason:@"Restored audio recording"];
        result = @{@"parentID": parentID, @"childIDs": childIDs, @"typeUTI": [parent valueForKey:@"typeUTI"] ?: @""};
    })) return nil;
    if (!result && error && !*error) *error = NCError(@"Notes could not create the recording graph");
    return result;
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
        NSDictionary *objects = [document valueForKey:@"objects"];
        // Each row names its fragment by index in orderedFragmentUUIDs. Check every target before writing any.
        NSMutableDictionary<NSNumber *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
        for (NSDictionary<NSString *, id> *row in segments) {
            NSInteger index = [row[@"fragment"] integerValue];
            if (index < 0 || (NSUInteger)index >= fragmentUUIDs.count) {
                if (error) *error = NCError([NSString stringWithFormat:@"The transcript uses fragment %ld, but the recording has %lu fragments", (long)index, (unsigned long)fragmentUUIDs.count]);
                return;
            }
            NSMutableArray *group = groups[@(index)];
            if (!group) { group = [NSMutableArray array]; groups[@(index)] = group; }
            [group addObject:row];
        }
        NSArray<NSNumber *> *indices = [groups.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *targets = [NSMutableArray arrayWithCapacity:indices.count];
        for (NSNumber *index in indices) {
            id fragment = [objects objectForKey:fragmentUUIDs[index.unsignedIntegerValue]];
            if (!fragment || !NCRequireObject(fragment, @[@"transcript", @"setTranscriptVersion:"], @"opening audio fragment transcript", error)) return;
            id transcript = [fragment valueForKey:@"transcript"];
            if (!NCRequireObject(transcript, @[@"addObject:", @"count"], @"writing audio transcript segments", error)) return;
            if ([[transcript valueForKey:@"count"] unsignedIntegerValue] != 0) {
                if (error) *error = NCError(@"The recording already has a transcript");
                return;
            }
            [targets addObject:fragment];
        }
        NSUInteger total = 0;
        for (NSUInteger position = 0; position < indices.count; position++) {
            id fragment = targets[position];
            id transcript = [fragment valueForKey:@"transcript"];
            for (NSDictionary<NSString *, id> *row in groups[indices[position]]) {
                id segment = ((id (*)(id, SEL, id, id))objc_msgSend)([segmentClass alloc], NSSelectorFromString(@"initWithDocument:identity:"), document, NSUUID.UUID);
                if (!segment) { if (error) *error = NCError(@"Notes could not create a transcript segment"); return; }
                [segment setValue:row[@"text"] ?: @"" forKey:@"text"];
                [segment setValue:row[@"start"] ?: @0 forKey:@"timestamp"];
                [segment setValue:row[@"duration"] ?: @0 forKey:@"duration"];
                [segment setValue:row[@"speaker"] forKey:@"speaker"];
                ((void (*)(id, SEL, id))objc_msgSend)(transcript, NSSelectorFromString(@"addObject:"), segment);
            }
            [fragment setValue:@1 forKey:@"transcriptVersion"];
            total += [[transcript valueForKey:@"count"] unsignedIntegerValue];
        }
        ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"writeMergeableData"));
        [(id<NCSynced>)attachment updateChangeCountWithReason:@"Added audio transcript"];
        count = @(total);
    })) return nil;
    if (!count && error && !*error) *error = NCError(@"Notes could not write the audio transcript");
    return count;
}
+ (BOOL)applyRecordingMetadata:(NSDictionary<NSString *,id> *)metadata toAudioAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCRequireObject(attachment, @[@"attachmentModel", @"currentReplicaID", @"updateChangeCountWithReason:"], @"writing recording metadata", error)) return NO;
    __block id model = nil;
    if (!NCCatch(@"opening recording metadata", error, ^{ model = [(id<NCSynced>)attachment attachmentModel]; })) return NO;
    if (!NCRequireObject(model, @[@"audioDocument", @"writeMergeableData"], @"writing recording metadata", error)) return NO;
    Class textClass = NSClassFromString(@"NotesShared.ICTTMergeableAttributedString") ?: NSClassFromString(@"ICTTMergeableAttributedString");
    if ((metadata[@"summary"] || metadata[@"topLineSummary"]) &&
        !NCRequireInstanceClass(textClass, @[@"initWithReplicaID:", @"replaceCharactersInRange:withString:"], @"writing recording summary", error)) return NO;
    __block BOOL applied = NO;
    if (!NCCatch(@"writing recording metadata", error, ^{
        id audioDocument = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"audioDocument"));
        if (!NCRequireObject(audioDocument, @[@"document"], @"opening recording document", error)) return;
        id document = [audioDocument valueForKey:@"document"];
        if (!NCRequireObject(document, @[@"rootObject"], @"opening recording root", error)) return;
        id root = [document valueForKey:@"rootObject"];
        if (!root) { if (error) *error = NCError(@"recording document has no root object"); return; }
        id replicaID = [attachment valueForKey:@"currentReplicaID"];
        for (NSString *key in @[@"summary", @"topLineSummary"]) {
            NSString *value = metadata[key];
            if (![value isKindOfClass:NSString.class]) continue;
            id text = ((id (*)(id, SEL, id))objc_msgSend)([textClass alloc], NSSelectorFromString(@"initWithReplicaID:"), replicaID);
            if (!text) { if (error) *error = NCError([NSString stringWithFormat:@"Notes could not create %@ text", key]); return; }
            [root setValue:text forKey:key];
            ((void (*)(id, SEL, NSRange, id))objc_msgSend)(text, NSSelectorFromString(@"replaceCharactersInRange:withString:"), NSMakeRange(0, 0), value);
        }
        if (metadata[@"summaryVersion"]) [root setValue:metadata[@"summaryVersion"] forKey:@"summaryVersion"];
        NSDictionary<NSString *, NSString *> *objectSetters = @{
            @"externalModelAttributionProviderName": @"setExternalModelAttributionProviderName:",
            @"externalModelAttributionSymbolName": @"setExternalModelAttributionSymbolName:",
            @"localSpeakerHandle": @"setLocalSpeakerHandle:",
            @"remoteSpeakerHandle": @"setRemoteSpeakerHandle:",
            @"startTime": @"setCallRecordingStartTime:"
        };
        for (NSString *key in objectSetters) {
            id value = metadata[key];
            if (!value) continue;
            SEL selector = NSSelectorFromString(objectSetters[key]);
            if (![audioDocument respondsToSelector:selector]) { if (error) *error = NCError([NSString stringWithFormat:@"recording metadata setter missing: %@", objectSetters[key]]); return; }
            ((void (*)(id, SEL, id))objc_msgSend)(audioDocument, selector, value);
        }
        if (metadata[@"callType"]) {
            SEL selector = NSSelectorFromString(@"setCallType:");
            if (![audioDocument respondsToSelector:selector]) { if (error) *error = NCError(@"recording metadata setter missing: setCallType:"); return; }
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(audioDocument, selector, [metadata[@"callType"] integerValue]);
        }
        if (metadata[@"isCallRecording"]) {
            SEL selector = NSSelectorFromString(@"setIsCallRecording:");
            if (![audioDocument respondsToSelector:selector]) { if (error) *error = NCError(@"recording metadata setter missing: setIsCallRecording:"); return; }
            ((void (*)(id, SEL, BOOL))objc_msgSend)(audioDocument, selector, [metadata[@"isCallRecording"] boolValue]);
        }
        ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"writeMergeableData"));
        [(id<NCSynced>)attachment updateChangeCountWithReason:@"Restored recording metadata"];
        applied = YES;
    })) return NO;
    if (!applied && error && !*error) *error = NCError(@"Notes could not write recording metadata");
    return applied;
}
+ (BOOL)deleteRecordingSummaryForAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCRequireObject(attachment, @[@"attachmentModel"],
                         @"deleting recording summary", error)) return NO;
    __block id model = nil;
    if (!NCCatch(@"opening recording summary", error, ^{
        model = [(id<NCSynced>)attachment attachmentModel];
    })) return NO;
    Class audioModelClass = NSClassFromString(@"ICAttachmentAudioModel");
    if (!audioModelClass || ![model isKindOfClass:audioModelClass]) {
        if (error) *error = NCError(@"The attachment is not a native recording");
        return NO;
    }
    if (!NCRequireObject(model, @[@"audioDocument", @"deleteSummaryAndReturnError:"],
                         @"deleting recording summary", error)) return NO;
    __block id audioDocument = nil;
    if (!NCCatch(@"opening recording document", error, ^{
        audioDocument = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"audioDocument"));
    })) return NO;
    if (!audioDocument) {
        if (error) *error = NCError(@"The recording document is unavailable");
        return NO;
    }
    __block BOOL deleted = NO;
    __block NSError *deleteError = nil;
    if (!NCCatch(@"deleting recording summary", error, ^{
        deleted = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(
            model, NSSelectorFromString(@"deleteSummaryAndReturnError:"), &deleteError
        );
    })) return NO;
    if (!deleted) {
        if (error) *error = deleteError ?: NCError(@"Notes did not delete the recording summary");
        return NO;
    }
    if (deleteError) {
        if (error) *error = deleteError;
        return NO;
    }
    return YES;
}
+ (NSString *)addURL:(NSURL *)url toNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    if (!NCRequireObject(note, @[@"addURLAttachmentWithURL:"], @"adding URL preview", error)) return nil;
    __block NSString *identifier = nil, *kind = nil;
    if (!NCCatch(@"adding URL preview", error, ^{ id item = [(id<NCNote>)note addURLAttachmentWithURL:url]; identifier = [item valueForKey:@"identifier"]; kind = [item valueForKey:@"typeUTI"]; })) return nil;
    if (type) *type = kind;
    return identifier;
}

+ (NSString *)addSynapseLink:(NSURL *)url title:(NSString *)title toNote:(NSManagedObject *)note
                        type:(NSString **)type error:(NSError **)error {
    NSString *path = @"/System/Library/PrivateFrameworks/Synapse.framework/Synapse";
    if (!NCLoadFramework(path, @"Synapse", error)) return nil;
    void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_NOLOAD);
    CFStringRef const *sourceSymbol = handle ? (CFStringRef const *)dlsym(handle, "SYContentItemSourceIdentifierWeb") : NULL;
    NSString *sourceIdentifier = sourceSymbol ? (__bridge NSString *)*sourceSymbol : nil;
    NSString *sourceName = @"NotesCLI";
    if (!sourceIdentifier.length) { if (error) *error = NCError(@"Synapse web source identifier is unavailable"); return nil; }
    Class itemClass = NSClassFromString(@"SYContentItem");
    if (!NCRequireInstanceClass(itemClass, @[@"initWithDisplayTitle:sourceIdentifier:sourceName:itemURL:", @"dataRepresentationWithError:",
                                             @"initWithData:error:", @"itemIdentifier", @"displayTitle", @"sourceIdentifier",
                                             @"sourceLastKnownName", @"itemURL", @"isEqual:", @"representsSameContentAsItem:"],
                                @"creating shared link content", error) ||
        !NCRequireObject(note, @[@"addSynapseLinkAttachmentWithContentItem:"], @"adding shared link", error)) return nil;
    __block NSString *identifier = nil, *kind = nil;
    if (!NCCatch(@"adding shared link", error, ^{
        id item = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            [itemClass alloc], NSSelectorFromString(@"initWithDisplayTitle:sourceIdentifier:sourceName:itemURL:"),
            title, sourceIdentifier, sourceName, url);
        if (!item) { if (error) *error = NCError(@"Synapse did not create a content item"); return; }
        NSError *serializationError = nil;
        NSData *data = ((id (*)(id, SEL, id *))objc_msgSend)(item, NSSelectorFromString(@"dataRepresentationWithError:"), &serializationError);
        id decoded = data.length ? ((id (*)(id, SEL, id, id *))objc_msgSend)(
            [itemClass alloc], NSSelectorFromString(@"initWithData:error:"), data, &serializationError) : nil;
        BOOL fieldsMatch = decoded && [[decoded valueForKey:@"itemIdentifier"] isEqual:[item valueForKey:@"itemIdentifier"]] &&
            [[decoded valueForKey:@"displayTitle"] isEqual:title] && [[decoded valueForKey:@"sourceIdentifier"] isEqual:sourceIdentifier] &&
            [[decoded valueForKey:@"sourceLastKnownName"] isEqual:sourceName] && [[decoded valueForKey:@"itemURL"] isEqual:url];
        BOOL equal = decoded && ((BOOL (*)(id, SEL, id))objc_msgSend)(item, NSSelectorFromString(@"isEqual:"), decoded);
        BOOL sameContent = decoded && ((BOOL (*)(id, SEL, id))objc_msgSend)(item, NSSelectorFromString(@"representsSameContentAsItem:"), decoded);
        if (!fieldsMatch || !equal || !sameContent) {
            if (error) *error = serializationError ?: NCError(@"Synapse content did not survive serialization");
            return;
        }
        id attachment = [(id<NCNote>)note addSynapseLinkAttachmentWithContentItem:item];
        if (!NCRequireObject(attachment, @[@"identifier", @"typeUTI", @"hasSynapseLink", @"synapseData"], @"validating shared link", error)) return;
        if (![[attachment valueForKey:@"hasSynapseLink"] boolValue] || ![[attachment valueForKey:@"synapseData"] length]) {
            if (error) *error = NCError(@"Notes created an attachment without Synapse link data");
            return;
        }
        identifier = [attachment valueForKey:@"identifier"];
        kind = [attachment valueForKey:@"typeUTI"];
    })) return nil;
    if (!identifier.length) { if (error && !*error) *error = NCError(@"Notes did not create a shared-link attachment"); return nil; }
    if (type) *type = kind;
    return identifier;
}

+ (NSString *)synapseWebSourceIdentifier:(NSError **)error {
    NSString *path = @"/System/Library/PrivateFrameworks/Synapse.framework/Synapse";
    if (!NCLoadFramework(path, @"Synapse", error)) return nil;
    void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_NOLOAD);
    CFStringRef const *symbol = handle ? (CFStringRef const *)dlsym(handle, "SYContentItemSourceIdentifierWeb") : NULL;
    NSString *value = symbol ? (__bridge NSString *)*symbol : nil;
    if (!value.length && error) *error = NCError(@"Synapse web source identifier is unavailable");
    return value;
}

+ (NSDictionary<NSString *, id> *)synapseLinkInfoForAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCLoadFramework(@"/System/Library/PrivateFrameworks/Synapse.framework/Synapse", @"Synapse", error)) return nil;
    Class itemClass = NSClassFromString(@"SYContentItem");
    if (!NCRequireInstanceClass(itemClass, @[@"initWithData:error:", @"displayTitle", @"sourceIdentifier", @"sourceLastKnownName", @"itemURL"],
                                @"reading shared link", error) ||
        !NCRequireObject(attachment, @[@"synapseData", @"hasSynapseLink"], @"reading shared link", error)) return nil;
    __block NSDictionary<NSString *, id> *result = nil;
    if (!NCCatch(@"reading shared link", error, ^{
        NSData *data = [attachment valueForKey:@"synapseData"];
        BOOL hasLink = [[attachment valueForKey:@"hasSynapseLink"] boolValue];
        if (!hasLink || !data.length) { if (error) *error = NCError(@"The attachment has no Synapse link data"); return; }
        NSError *decodeError = nil;
        id item = ((id (*)(id, SEL, id, id *))objc_msgSend)(
            [itemClass alloc], NSSelectorFromString(@"initWithData:error:"), data, &decodeError);
        if (!item) { if (error) *error = decodeError ?: NCError(@"Synapse could not decode the shared link"); return; }
        NSURL *itemURL = [item valueForKey:@"itemURL"];
        result = @{
            @"url": itemURL.absoluteString ?: @"",
            @"title": [item valueForKey:@"displayTitle"] ?: @"",
            @"sourceIdentifier": [item valueForKey:@"sourceIdentifier"] ?: @"",
            @"sourceName": [item valueForKey:@"sourceLastKnownName"] ?: @"",
            @"dataBytes": @(data.length),
        };
    })) return nil;
    return result;
}

+ (NSString *)addSystemPaperDrawing:(id)drawing toNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    __block NSString *identifier = nil;
    BOOL ok = NCCatch(@"create system Paper attachment", error, ^{
        Class helperClass = NSClassFromString(@"ICPaperAttachmentCreationHelper");
        if (!NCRequireObject(drawing, @[@"dataRepresentation", @"strokes"], @"validate PencilKit drawing", error) ||
            !NCRequireClass(helperClass, @[@"createSystemPaperAttachmentWithPKDrawing:inNote:"], @"create system Paper attachment", error)) return;
        id attachment = ((id (*)(id, SEL, id, id))objc_msgSend)(helperClass,
            NSSelectorFromString(@"createSystemPaperAttachmentWithPKDrawing:inNote:"), drawing, note);
        if (!NCRequireObject(attachment, @[@"identifier", @"typeUTI"], @"read created Paper attachment", error)) return;
        identifier = ((id (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"identifier"));
        if (type) *type = ((id (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"typeUTI"));
        if (!identifier.length && error) *error = NCError(@"Paper attachment has no identifier");
    });
    return ok ? identifier : nil;
}

+ (NSArray *)systemPaperDrawingsForAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    __block NSArray *result = nil;
    BOOL ok = NCCatch(@"read system Paper drawings", error, ^{
        Class helperClass = NSClassFromString(@"ICSystemPaperDrawingsHelper");
        if (!NCRequireClass(helperClass, @[@"drawingsForAttachment:"], @"read system Paper drawings", error)) return;
        id drawings = ((id (*)(id, SEL, id))objc_msgSend)(helperClass, NSSelectorFromString(@"drawingsForAttachment:"), attachment);
        if (![drawings isKindOfClass:[NSArray class]]) {
            if (error) *error = NCError(@"Paper drawing helper returned no drawing array");
            return;
        }
        result = drawings;
    });
    return ok ? result : nil;
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
+ (BOOL)setSystemPaper:(BOOL)enabled note:(NSManagedObject *)note error:(NSError **)error {
    if (!NCRequireObject(note, @[@"markAsSystemPaperIfNeeded:", @"isSystemPaper", @"updateChangeCountWithReason:"],
                         @"changing Quick Note state", error)) return NO;
    return NCCatch(@"changing Quick Note state", error, ^{
        ((void (*)(id, SEL, BOOL))objc_msgSend)(note, NSSelectorFromString(@"markAsSystemPaperIfNeeded:"), enabled);
        [(id<NCSynced>)note updateChangeCountWithReason:@"Changed Quick Note state"];
    });
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
static NSURL *NCNotesGroupPreferencesURL(void) {
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Group Containers/group.com.apple.notes/Library/Preferences/group.com.apple.notes.plist"]];
}

static NSURL *NCNotesApplicationPreferencesURL(void) {
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Containers/com.apple.Notes/Data/Library/Preferences/com.apple.Notes.plist"]];
}

static NSDictionary<NSString *, id> *NCPreferencesAtURL(NSURL *url, NSString *name, NSError **error) {
    NSTask *task = [NSTask new];
    NSPipe *output = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/defaults"];
    task.arguments = @[@"export", url.URLByDeletingPathExtension.path, @"-"];
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    __block NSData *data = nil;
    @try {
        [task launch];
        data = [output.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (error) *error = NCError([NSString stringWithFormat:@"Could not read %@ preferences: %@", name,
                                     exception.reason ?: exception.name]);
        return nil;
    }
    if (task.terminationStatus != 0) {
        if (error) *error = NCError([NSString stringWithFormat:@"Could not read %@ preferences with defaults export", name]);
        return nil;
    }
    NSError *plistError = nil;
    id value = [NSPropertyListSerialization propertyListWithData:data ?: NSData.data options:NSPropertyListImmutable
                                                           format:NULL error:&plistError];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) *error = NCError([NSString stringWithFormat:@"Could not decode %@ preferences: %@", name,
                                     plistError.localizedDescription ?: @"the exported property list is invalid"]);
        return nil;
    }
    return value;
}

static NSDictionary<NSString *, id> *NCNotesGroupPreferences(NSError **error) {
    return NCPreferencesAtURL(NCNotesGroupPreferencesURL(), @"Notes group", error);
}

static NSDictionary<NSString *, id> *NCNotesApplicationPreferences(NSError **error) {
    return NCPreferencesAtURL(NCNotesApplicationPreferencesURL(), @"Notes application", error);
}

static id NCNotesGroupPreference(NSString *key, NSError **error) {
    return NCNotesGroupPreferences(error)[key];
}

static id NCNotesApplicationPreference(NSString *key, NSError **error) {
    return NCNotesApplicationPreferences(error)[key];
}

static BOOL NCSetPreferenceAtURL(NSURL *url, NSString *name, NSString *key, id value, NSError **error) {
    NSTask *task = [NSTask new];
    NSPipe *errors = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/defaults"];
    NSString *domain = url.URLByDeletingPathExtension.path;
    if ([value isKindOfClass:NSNumber.class]) {
        task.arguments = @[@"write", domain, key, @"-int", [value stringValue]];
    } else if ([value isKindOfClass:NSString.class]) {
        task.arguments = @[@"write", domain, key, @"-string", value];
    } else {
        if (error) *error = NCError([NSString stringWithFormat:@"Unsupported %@ preference type for %@", name, key]);
        return NO;
    }
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = errors;
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (error) *error = NCError([NSString stringWithFormat:@"Could not write the %@ preference %@: %@", name, key, exception.reason ?: exception.name]);
        return NO;
    }
    if (task.terminationStatus != 0) {
        NSData *data = [errors.fileHandleForReading readDataToEndOfFile];
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"defaults failed";
        if (error) *error = NCError([NSString stringWithFormat:@"Could not write the %@ preference %@: %@", name, key, message]);
        return NO;
    }
    NSError *readError = nil;
    id stored = [name isEqualToString:@"Notes group"] ? NCNotesGroupPreference(key, &readError) : NCNotesApplicationPreference(key, &readError);
    if (readError) {
        if (error) *error = readError;
        return NO;
    }
    if (![stored isEqual:value]) {
        if (error) *error = NCError([NSString stringWithFormat:@"%@ preference %@ did not match after save", name, key]);
        return NO;
    }
    return YES;
}

static NSURL *NCNotesShadowGroupPreferencesURL(void) {
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Preferences/group.com.apple.notes.plist"]];
}

static BOOL NCRemovePreferenceAtURL(NSURL *url, NSString *name, NSString *key, NSError **error) {
    NSError *readError = nil;
    NSDictionary *before = NCPreferencesAtURL(url, name, &readError);
    if (!before) { if (error) *error = readError; return NO; }
    if (before[key] == nil) return YES;
    NSTask *task = [NSTask new];
    NSPipe *errors = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/defaults"];
    task.arguments = @[@"delete", url.URLByDeletingPathExtension.path, key];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = errors;
    @try { [task launch]; [task waitUntilExit]; }
    @catch (NSException *exception) {
        if (error) *error = NCError([NSString stringWithFormat:@"Could not remove the %@ preference %@: %@", name, key, exception.reason ?: exception.name]);
        return NO;
    }
    if (task.terminationStatus != 0) {
        NSData *data = [errors.fileHandleForReading readDataToEndOfFile];
        NSString *message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"defaults failed";
        if (error) *error = NCError([NSString stringWithFormat:@"Could not remove the %@ preference %@: %@", name, key, message]);
        return NO;
    }
    NSDictionary *after = NCPreferencesAtURL(url, name, &readError);
    if (!after) { if (error) *error = readError; return NO; }
    if (after[key] != nil) {
        if (error) *error = NCError([NSString stringWithFormat:@"%@ preference %@ was still present after removal", name, key]);
        return NO;
    }
    return YES;
}

+ (NSDictionary<NSString *, id> *)notesPreferencesInApplicationDomain:(BOOL)application error:(NSError **)error {
    return application ? NCNotesApplicationPreferences(error) : NCNotesGroupPreferences(error);
}
+ (NSDictionary<NSString *, id> *)shadowNotesGroupPreferences:(NSError **)error {
    if (![NSFileManager.defaultManager fileExistsAtPath:NCNotesShadowGroupPreferencesURL().path]) return @{};
    return NCPreferencesAtURL(NCNotesShadowGroupPreferencesURL(), @"shadow Notes group", error);
}
+ (BOOL)setNotesPreference:(NSString *)key integerValue:(NSInteger)value inApplicationDomain:(BOOL)application error:(NSError **)error {
    return NCSetPreferenceAtURL(application ? NCNotesApplicationPreferencesURL() : NCNotesGroupPreferencesURL(),
                                application ? @"Notes application" : @"Notes group", key, @(value), error);
}
+ (BOOL)removeNotesPreference:(NSString *)key inApplicationDomain:(BOOL)application error:(NSError **)error {
    return NCRemovePreferenceAtURL(application ? NCNotesApplicationPreferencesURL() : NCNotesGroupPreferencesURL(),
                                   application ? @"Notes application" : @"Notes group", key, error);
}

static BOOL NCSetNotesGroupPreference(NSString *key, id value, NSError **error) {
    return NCSetPreferenceAtURL(NCNotesGroupPreferencesURL(), @"Notes group", key, value, error);
}

static BOOL NCSetNotesApplicationPreference(NSString *key, id value, NSError **error) {
    return NCSetPreferenceAtURL(NCNotesApplicationPreferencesURL(), @"Notes application", key, value, error);
}

+ (BOOL)checklistAutoSortEnabled {
    id value = NCNotesApplicationPreference(@"ICChecklistAutoSortEnabledDefaultsKey", nil);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}
+ (BOOL)setChecklistAutoSortEnabled:(BOOL)enabled error:(NSError **)error {
    return NCSetNotesApplicationPreference(@"ICChecklistAutoSortEnabledDefaultsKey", @(enabled), error);
}
+ (NSNumber *)shouldAutoConvertToTag:(NSError **)error {
    if (!NCLoad(error)) return nil;
    Class cls = NSClassFromString(@"ICHashtagController");
    if (!NCRequireClass(cls, @[@"shouldAutoConvertToTag"], @"reading automatic tag conversion", error)) return nil;
    NSError *readError = nil;
    id stored = NCNotesGroupPreference(@"EnableSmartTags", &readError);
    if (readError) { if (error) *error = readError; return nil; }
    return [stored respondsToSelector:@selector(boolValue)] ? @([stored boolValue]) : @YES;
}
+ (BOOL)setShouldAutoConvertToTag:(BOOL)enabled error:(NSError **)error {
    if (!NCLoad(error)) return NO;
    Class cls = NSClassFromString(@"ICHashtagController");
    if (!NCRequireClass(cls, @[@"shouldAutoConvertToTag", @"setShouldAutoConvertToTag:"],
                        @"setting automatic tag conversion", error)) return NO;
    if (!NCSetNotesGroupPreference(@"EnableSmartTags", @(enabled), error)) return NO;
    NSError *readError = nil;
    NSNumber *stored = [self shouldAutoConvertToTag:&readError];
    if (readError) { if (error) *error = readError; return NO; }
    if (!stored || stored.boolValue != enabled) {
        if (error) *error = NCError(@"Notes did not retain the automatic tag conversion setting");
        return NO;
    }
    return YES;
}

+ (NSDictionary<NSString *, NSString *> *)evaluateMathExpression:(NSString *)expression error:(NSError **)error {
    NSString *value = [expression stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([value hasSuffix:@"="]) {
        value = [[value substringToIndex:value.length - 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (value.length == 0) {
        if (error) *error = NCError(@"Math expression cannot be empty");
        return nil;
    }
    if (!NCLoadFramework(@"/System/Library/PrivateFrameworks/Calculate.framework/Calculate", @"Calculate", error)) return nil;
    Class calculate = NSClassFromString(@"Calculate");
    if (!NCRequireClass(calculate, @[@"evaluate:options:error:"], @"evaluating math", error)) return nil;
    __block id result = nil;
    __block NSError *evaluationError = nil;
    if (!NCCatch(@"evaluating math", error, ^{
        result = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(
            calculate, NSSelectorFromString(@"evaluate:options:error:"), value, nil, &evaluationError);
    })) return nil;
    if (!result) {
        if (error) *error = evaluationError ?: NCError(@"Notes could not evaluate the math expression");
        return nil;
    }
    if (!NCRequireObject(result, @[@"formattedExpression", @"formattedResult"], @"reading math result", error)) return nil;
    __block NSString *formattedExpression = nil;
    __block NSString *formattedResult = nil;
    if (!NCCatch(@"reading math result", error, ^{
        formattedExpression = NCPlain(((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"formattedExpression")));
        formattedResult = NCPlain(((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"formattedResult")));
    })) return nil;
    if (formattedExpression.length == 0 || formattedResult.length == 0) {
        if (error) *error = NCError(@"Notes returned an empty math result");
        return nil;
    }
    return @{ @"expression": value,
              @"formattedExpression": formattedExpression,
              @"result": formattedResult,
              @"renderedText": [NSString stringWithFormat:@"%@=%@", value, formattedResult] };
}

+ (NSString *)storedDefaultAccountIdentifier:(NSError **)error {
    NSError *readError = nil;
    NSDictionary *preferences = NCNotesGroupPreferences(&readError);
    if (!preferences) { if (error) *error = readError; return nil; }
    id stored = preferences[@"DefaultNotesAccount"];
    return [stored isKindOfClass:NSString.class] && [stored length] ? stored : @"";
}
+ (NSString *)frameworkDefaultAccountIdentifier:(NSError **)error {
    NSError *shadowError = nil;
    NSDictionary *shadow = [self shadowNotesGroupPreferences:&shadowError];
    if (!shadow) { if (error) *error = shadowError; return nil; }
    if (shadow[@"DefaultNotesAccount"] != nil) {
        if (error) *error = NCError(@"A shadow DefaultNotesAccount exists in ~/Library/Preferences/group.com.apple.notes.plist; refusing to report a default account Notes does not read");
        return nil;
    }
    Class cls = NSClassFromString(@"ICDefaultAccountUtilities");
    if (!NCRequireClass(cls, @[@"defaultAccount"], @"reading default account", error)) return nil;
    __block id account = nil;
    if (!NCCatch(@"reading default account", error, ^{
        account = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"defaultAccount"));
    })) return nil;
    if (account) {
        if (!NCRequireObject(account, @[@"identifier"], @"reading default account identifier", error)) return nil;
        NSString *identifier = [account valueForKey:@"identifier"];
        if (identifier.length) return identifier;
    }
    if (error) *error = NCError(@"Notes did not return a default account identifier");
    return nil;
}
+ (BOOL)setDefaultAccountIdentifier:(NSString *)identifier error:(NSError **)error {
    if (!identifier.length) { if (error) *error = NCError(@"The default account identifier is empty"); return NO; }
    return NCSetNotesGroupPreference(@"DefaultNotesAccount", identifier, error);
}
+ (nullable NSNumber *)noteDefaultNamedStyle:(NSError **)error {
    NSError *readError = nil;
    id stored = NCNotesGroupPreference(@"TTTextControllerNoteDefaultNamedStyleKey", &readError);
    if (readError) { if (error) *error = readError; return nil; }
    if ([stored isKindOfClass:NSNumber.class]) return stored;
    return @0;
}
+ (BOOL)setNoteDefaultNamedStyle:(NSUInteger)style error:(NSError **)error {
    if (style > UINT_MAX) { if (error) *error = NCError(@"The default paragraph style is out of range"); return NO; }
    return NCSetNotesGroupPreference(@"TTTextControllerNoteDefaultNamedStyleKey", @((unsigned int)style), error);
}
+ (NSNumber *)currentNoteListSortType:(NSError **)error {
    NSError *readError = nil;
    id stored = NCNotesGroupPreference(@"kICSettingsNoteListSortTypeKey", &readError);
    if (readError) { if (error) *error = readError; return nil; }
    return [stored isKindOfClass:NSNumber.class] ? stored : @0;
}
+ (BOOL)setCurrentNoteListSortType:(NSInteger)type error:(NSError **)error {
    if (type < 0 || type > 2) { if (error) *error = NCError(@"The global note sort type must be 0, 1, or 2"); return NO; }
    return NCSetNotesGroupPreference(@"kICSettingsNoteListSortTypeKey", @(type), error);
}
+ (NSNumber *)defaultDateHeadersType:(NSError **)error {
    NSError *readError = nil;
    id stored = NCNotesGroupPreference(@"kICSettingsNoteDateHeadersTypeKey", &readError);
    if (readError) { if (error) *error = readError; return nil; }
    return [stored isKindOfClass:NSNumber.class] ? stored : @2;
}
+ (BOOL)setDefaultDateHeadersType:(NSInteger)type error:(NSError **)error {
    if (type < 1 || type > 2) { if (error) *error = NCError(@"Global date grouping must be off (1) or on (2)"); return NO; }
    return NCSetNotesGroupPreference(@"kICSettingsNoteDateHeadersTypeKey", @(type), error);
}
+ (NSNumber *)globalZoomFactorIndex:(NSError **)error {
    NSError *readError = nil;
    id stored = NCNotesApplicationPreference(@"ICMGlobalZoomFactorIndexKey", &readError);
    if (readError) { if (error) *error = readError; return nil; }
    return [stored isKindOfClass:NSNumber.class] ? stored : @1;
}
+ (BOOL)setGlobalZoomFactorIndex:(NSInteger)index error:(NSError **)error {
    if (index < 0 || index > 4) { if (error) *error = NCError(@"The default note text size index must be between 0 and 4"); return NO; }
    return NCSetNotesApplicationPreference(@"ICMGlobalZoomFactorIndexKey", @(index), error);
}
+ (NSNumber *)shouldResumeLastQuickNote:(NSError **)error {
    NSError *readError = nil;
    id stored = NCNotesGroupPreference(@"ICShouldResumeLastQuickNoteDefaultsKey", &readError);
    if (readError) { if (error) *error = readError; return nil; }
    return [stored isKindOfClass:NSNumber.class] ? stored : @YES;
}
+ (BOOL)setShouldResumeLastQuickNote:(BOOL)enabled error:(NSError **)error {
    return NCSetNotesGroupPreference(@"ICShouldResumeLastQuickNoteDefaultsKey", @(enabled), error);
}
+ (BOOL)applyDateHeadersType:(NSInteger)type toFolder:(NSManagedObject *)folder error:(NSError **)error {
    if (!NCRequireObject(folder, @[@"applyDateHeadersType:", @"isShowingDateHeaders", @"updateChangeCountWithReason:"], @"changing folder date grouping", error)) return NO;
    return NCCatch(@"changing folder date grouping", error, ^{
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(folder, NSSelectorFromString(@"applyDateHeadersType:"), type);
        [(id<NCSynced>)folder updateChangeCountWithReason:@"Changed folder date grouping"];
    });
}
+ (nullable NSDictionary<NSString *, id> *)addLocationToMapAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCRequireObject(attachment, @[@"attachmentModel", @"addLocationIfNeeded"], @"adding map location metadata", error)) return nil;
    __block NSDictionary<NSString *, id> *result = nil;
    if (!NCCatch(@"adding map location metadata", error, ^{
        id model = [(id<NCSynced>)attachment attachmentModel];
        NSString *modelName = model ? NSStringFromClass([model class]) : @"";
        if (![modelName isEqualToString:@"ICAttachmentMapModel"]) {
            if (error) *error = NCError([NSString stringWithFormat:@"URL did not create a native Apple Maps attachment; model=%@", modelName]);
            return;
        }
        ((void (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"addLocationIfNeeded"));
        id location = [attachment valueForKey:@"location"];
        id latitude = location ? [location valueForKey:@"latitude"] : nil;
        id longitude = location ? [location valueForKey:@"longitude"] : nil;
        result = @{ @"model": modelName, @"hasLocation": @(location != nil),
                    @"latitude": latitude ?: [NSNull null], @"longitude": longitude ?: [NSNull null] };
    })) return nil;
    if (!result && error && !*error) *error = NCError(@"Notes did not create map metadata");
    return result;
}
+ (NCPreparedScan *)prepareScanImageURLs:(NSArray<NSURL *> *)urls error:(NSError **)error {
    if (urls.count == 0 || urls.count > 100) {
        if (error) *error = NCError(@"A scanned document requires between 1 and 100 image pages");
        return nil;
    }
    if (!NCLoadFramework(@"/System/Library/PrivateFrameworks/DocumentCamera.framework/DocumentCamera", @"DocumentCamera", error)) return nil;
    if (!NCLoadFramework(@"/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", @"NotesUI", error)) return nil;
    Class cacheClass = NSClassFromString(@"ICDocCamImageCache");
    Class infoClass = NSClassFromString(@"ICDocCamDocumentInfo");
    Class quadClass = NSClassFromString(@"ICDocCamImageQuad");
    if (!NCRequireInstanceClass(cacheClass, @[@"initWithDataCryptorDelegate:cachesDirectoryURL:", @"setImage:metaData:", @"getImageURL:", @"deleteAllImages"], @"preparing scanned document images", error) ||
        !NCRequireInstanceClass(infoClass, @[@"init", @"setFullImageUUID:", @"setCroppedButNotFilteredImageUUID:", @"setCroppedAndFilteredImageUUID:", @"setImageQuad:", @"setMetaData:", @"setCurrentFilter:", @"setCurrentOrientation:"], @"preparing scanned document pages", error) ||
        !NCRequireClass(quadClass, @[@"quadFromCGRect:"], @"preparing scanned document crop", error)) return nil;

    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"NotesCLI-DocCam-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO
                                                 attributes:@{NSFilePosixPermissions: @0700} error:error]) return nil;
    NCPreparedScan *prepared = [NCPreparedScan new];
    prepared.cacheDirectoryURL = directory;
    __block id cache = nil;
    __block NSMutableArray *documents = [NSMutableArray arrayWithCapacity:urls.count];
    __block unsigned long long aggregatePixels = 0;
    BOOL ok = NCCatch(@"preparing scanned document images", error, ^{
        cache = ((id (*)(id, SEL, id, id))objc_msgSend)([cacheClass alloc], NSSelectorFromString(@"initWithDataCryptorDelegate:cachesDirectoryURL:"), nil, directory);
        if (!cache) { if (error) *error = NCError(@"Document Camera could not create its image cache"); return; }
        for (NSURL *url in urls) { @autoreleasepool {
            if (!url.isFileURL || ![NSFileManager.defaultManager isReadableFileAtPath:url.path]) {
                if (error) *error = NCError(@"A scan page is not a readable local file"); return;
            }
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nil);
            NSString *sourceType = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
            size_t sourceCount = source ? CGImageSourceGetCount(source) : 0;
            if (!source || sourceCount == 0 || [sourceType.lowercaseString containsString:@"pdf"]) {
                if (source) CFRelease(source);
                if (error) *error = NCError([NSString stringWithFormat:@"A scan page must be an image, not a PDF or document: %@", url.lastPathComponent]);
                return;
            }
            CFRelease(source);
            NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
            CGRect proposed = CGRectZero;
            CGImageRef cgImage = [image CGImageForProposedRect:&proposed context:nil hints:nil];
            if (!image || !cgImage) { if (error) *error = NCError([NSString stringWithFormat:@"Unreadable scan image: %@", url.lastPathComponent]); return; }
            size_t width = CGImageGetWidth(cgImage), height = CGImageGetHeight(cgImage);
            unsigned long long pixels = (unsigned long long)width * (unsigned long long)height;
            if (width == 0 || height == 0 || pixels > 40000000ULL || aggregatePixels + pixels > 100000000ULL) {
                if (error) *error = NCError(@"Scan images exceed the 40-megapixel page or 100-megapixel document limit"); return;
            }
            aggregatePixels += pixels;
            NSString *uuid = ((id (*)(id, SEL, id, id))objc_msgSend)(cache, NSSelectorFromString(@"setImage:metaData:"), image, @{});
            NSURL *cachedURL = uuid ? ((id (*)(id, SEL, id))objc_msgSend)(cache, NSSelectorFromString(@"getImageURL:"), uuid) : nil;
            unsigned long long previousSize = 0;
            BOOL cachedImageReady = NO;
            for (NSUInteger attempt = 0; cachedURL && attempt < 20 && !cachedImageReady; attempt++) {
                NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:cachedURL.path error:nil];
                unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
                if (size > 0 && size == previousSize) {
                    CGImageSourceRef cachedSource = CGImageSourceCreateWithURL((__bridge CFURLRef)cachedURL, nil);
                    CGImageRef cachedImage = cachedSource ? CGImageSourceCreateImageAtIndex(cachedSource, 0, nil) : nil;
                    cachedImageReady = cachedImage != nil;
                    if (cachedImage) CGImageRelease(cachedImage);
                    if (cachedSource) CFRelease(cachedSource);
                }
                previousSize = size;
                if (cachedImageReady) break;
                [NSThread sleepForTimeInterval:0.05];
            }
            if (!uuid.length || !cachedURL || !cachedImageReady) {
                NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path error:nil] ?: @[];
                if (error) *error = NCError([NSString stringWithFormat:@"Document Camera did not retain a prepared scan page (id=%@, url=%@, cache=%@)",
                                             uuid ?: @"nil", cachedURL.path ?: @"nil", [entries componentsJoinedByString:@","]]);
                return;
            }
            id info = [infoClass new];
            ((void (*)(id, SEL, id))objc_msgSend)(info, NSSelectorFromString(@"setFullImageUUID:"), uuid);
            ((void (*)(id, SEL, id))objc_msgSend)(info, NSSelectorFromString(@"setCroppedButNotFilteredImageUUID:"), uuid);
            ((void (*)(id, SEL, id))objc_msgSend)(info, NSSelectorFromString(@"setCroppedAndFilteredImageUUID:"), uuid);
            id quad = ((id (*)(id, SEL, CGRect))objc_msgSend)(
                quadClass, NSSelectorFromString(@"quadFromCGRect:"), CGRectMake(0, 0, width, height));
            ((void (*)(id, SEL, id))objc_msgSend)(info, NSSelectorFromString(@"setImageQuad:"), quad);
            ((void (*)(id, SEL, id))objc_msgSend)(info, NSSelectorFromString(@"setMetaData:"), @{});
            ((void (*)(id, SEL, short))objc_msgSend)(info, NSSelectorFromString(@"setCurrentFilter:"), (short)0);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(info, NSSelectorFromString(@"setCurrentOrientation:"), (NSInteger)0);
            [documents addObject:info];
        }}
    });
    if (!ok || (error && *error) || documents.count != urls.count) { prepared.imageCache = cache; [prepared invalidate]; return nil; }
    prepared.imageCache = cache;
    prepared.documents = documents;
    prepared.pageCount = documents.count;
    return prepared;
}
+ (BOOL)validateScanPopulation:(NCPreparedScan *)preparation error:(NSError **)error {
    if (!preparation.imageCache || preparation.documents.count == 0 || preparation.documents.count != preparation.pageCount) {
        if (error) *error = NCError(@"The prepared scan is no longer available");
        return NO;
    }
    if (!NCLoadFramework(@"/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", @"NotesUI", error)) return NO;
    Class utilities = NSClassFromString(@"ICGalleryAttachmentUtilities");
    return NCRequireClass(utilities, @[@"createAndAddSubAttachmentsToGalleryAttachment:fromDocuments:imageCache:context:"],
                          @"creating scanned document pages", error);
}
+ (NSManagedObject *)newScanGalleryInNote:(NSManagedObject *)note identifier:(NSString *)identifier error:(NSError **)error {
    if (!NCRequireObject(note, @[@"addGalleryAttachmentWithIdentifier:"], @"creating scanned document gallery", error)) return nil;
    __block id gallery = nil;
    if (!NCCatch(@"creating scanned document gallery", error, ^{
        gallery = ((id (*)(id, SEL, id))objc_msgSend)(note, NSSelectorFromString(@"addGalleryAttachmentWithIdentifier:"), identifier);
    })) return nil;
    if (!NCRequireObject(gallery, @[@"identifier", @"typeUTI"], @"reading scanned document gallery", error)) return nil;
    return gallery;
}
+ (NSArray<NSString *> *)galleryPageIdentifiers:(NSManagedObject *)gallery error:(NSError **)error {
    if (!NCRequireObject(gallery, @[@"attachmentModel"], @"reading scanned document page order", error)) return nil;
    __block id model = nil;
    if (!NCCatch(@"reading scanned document page order", error, ^{
        model = ((id (*)(id, SEL))objc_msgSend)(gallery, NSSelectorFromString(@"attachmentModel"));
    })) return nil;
    if (!NCRequireObject(model, @[@"subAttachmentCount", @"subAttachmentIdentifierAtIndex:"],
                         @"reading scanned document page order", error)) return nil;
    __block NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    if (!NCCatch(@"reading scanned document page order", error, ^{
        NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"subAttachmentCount"));
        for (NSUInteger index = 0; index < count; index++) {
            id value = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(model,
                NSSelectorFromString(@"subAttachmentIdentifierAtIndex:"), index);
            if (![value isKindOfClass:NSString.class] || ![value length]) {
                if (error) *error = NCError(@"A scanned document page has no ordered identifier");
                return;
            }
            [identifiers addObject:value];
        }
    })) return nil;
    return (error && *error) ? nil : identifiers;
}

static Class NCScanEditorClass(NSError **error) {
    if (!NCLoadFramework(@"/System/Library/PrivateFrameworks/NotesEditor.framework/NotesEditor", @"NotesEditor", error)) return Nil;
    Class cls = NSClassFromString(@"ICDocCamScannedDocumentEditor");
    NSArray *selectors = @[@"initWithGalleryAttachment:", @"applyFilter:forAttachmentWithIdentifier:",
                           @"setOrientation:forAttachmentAtIndex:", @"moveObjectWithIdentifier:toIndex:",
                           @"setQuad:forAttachmentWithIdentifier:", @"setMarkupData:forAttachmentWithIdentifier:",
                           @"saveAndUpdatePreview:"];
    return NCRequireInstanceClass(cls, selectors, @"editing scanned document", error) ? cls : Nil;
}

static id<NCScanEditor> NCNewScanEditor(NSManagedObject *gallery, NSError **error) {
    Class cls = NCScanEditorClass(error);
    if (!cls) return nil;
    __block id<NCScanEditor> editor = nil;
    if (!NCCatch(@"opening scanned document editor", error, ^{
        editor = [(id<NCScanEditor>)[cls alloc] initWithGalleryAttachment:gallery];
    })) return nil;
    if (!editor && error) *error = NCError(@"Notes returned no scanned document editor");
    return editor;
}

+ (BOOL)validateScanEditing:(NSError **)error { return NCScanEditorClass(error) != Nil; }

+ (BOOL)applyScanFilter:(short)filter pageIdentifier:(NSString *)pageIdentifier
                gallery:(NSManagedObject *)gallery error:(NSError **)error {
    if (filter < 0 || filter > 4) { if (error) *error = NCError(@"Scan filter must be between 0 and 4"); return NO; }
    NSArray *order = [self galleryPageIdentifiers:gallery error:error];
    if (!order || ![order containsObject:pageIdentifier]) {
        if (error && !*error) *error = NCError(@"The scan page is not in this gallery");
        return NO;
    }
    id<NCScanEditor> editor = NCNewScanEditor(gallery, error);
    if (!editor) return NO;
    return NCCatch(@"applying scanned document filter", error, ^{
        [editor applyFilter:filter forAttachmentWithIdentifier:pageIdentifier];
        [editor saveAndUpdatePreview:YES];
    });
}

+ (BOOL)setScanMarkupData:(NSData *)data pageIdentifier:(NSString *)pageIdentifier
                   gallery:(NSManagedObject *)gallery error:(NSError **)error {
    if (!data.length) { if (error) *error = NCError(@"Scan markup data cannot be empty"); return NO; }
    NSArray *order = [self galleryPageIdentifiers:gallery error:error];
    if (!order || ![order containsObject:pageIdentifier]) {
        if (error && !*error) *error = NCError(@"The scan page is not in this gallery");
        return NO;
    }
    id<NCScanEditor> editor = NCNewScanEditor(gallery, error);
    if (!editor) return NO;
    if (!NCRequireObject(editor, @[@"setMarkupData:forAttachmentWithIdentifier:", @"subAttachmentWithIdentifier:"],
                         @"restoring scanned document markup", error)) return NO;
    return NCCatch(@"restoring scanned document markup", error, ^{
        [editor setMarkupData:data forAttachmentWithIdentifier:pageIdentifier];
        [editor saveAndUpdatePreview:YES];
        Class generator = NSClassFromString(@"ICDocCamPDFGenerator");
        SEL invalidate = NSSelectorFromString(@"deletePDFForAttachmentIfExists:");
        if (generator && [generator respondsToSelector:invalidate]) {
            ((void (*)(id, SEL, id))objc_msgSend)(generator, invalidate, gallery);
        }
    });
}

+ (NSData *)scanRectangleMarkupDataWithX:(double)x y:(double)y width:(double)width height:(double)height
                              strokeWidth:(double)strokeWidth error:(NSError **)error {
    double values[] = {x, y, width, height, strokeWidth};
    for (NSUInteger index = 0; index < 5; index++) {
        if (!isfinite(values[index]) || values[index] < 0) {
            if (error) *error = NCError(@"Scan markup rectangle values must be finite and nonnegative");
            return nil;
        }
    }
    if (width == 0 || height == 0 || strokeWidth == 0) {
        if (error) *error = NCError(@"Scan markup rectangles require positive width, height, and stroke width");
        return nil;
    }
    if (!NCLoadFramework(@"/System/Library/PrivateFrameworks/AnnotationKit.framework/AnnotationKit", @"AnnotationKit", error) ||
        !NCLoadFramework(@"/System/Library/PrivateFrameworks/MarkupUI.framework/MarkupUI", @"MarkupUI", error)) return nil;
    Class controllerClass = NSClassFromString(@"AKController");
    Class modelClass = NSClassFromString(@"AKModelController");
    Class pageClass = NSClassFromString(@"AKPageModelController");
    Class rectangleClass = NSClassFromString(@"AKRectAnnotation");
    Class writerClass = NSClassFromString(@"MUImageWriter");
    if (!NCRequireInstanceClass(controllerClass, @[@"initForTesting", @"modelController", @"setModelController:"], @"creating scan markup", error) ||
        !NCRequireInstanceClass(modelClass, @[@"pageModelControllers", @"insertObject:inPageModelControllersAtIndex:"], @"creating scan markup", error) ||
        !NCRequireInstanceClass(pageClass, @[@"annotations", @"insertObject:inAnnotationsAtIndex:"], @"creating scan markup", error) ||
        !NCRequireInstanceClass(rectangleClass, @[@"setRectangle:", @"setStrokeWidth:", @"setStrokeColor:", @"setFillColor:"], @"creating scan markup", error) ||
        !NCRequireInstanceClass(writerClass, @[@"encodedModelFromAnnotationsController:encrypt:"], @"encoding scan markup", error)) return nil;
    __block NSData *result = nil;
    if (!NCCatch(@"creating scan markup", error, ^{
        id controller = ((id (*)(id, SEL))objc_msgSend)([controllerClass alloc], NSSelectorFromString(@"initForTesting"));
        id model = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"modelController"));
        if (!model) {
            model = [modelClass new];
            ((void (*)(id, SEL, id))objc_msgSend)(controller, NSSelectorFromString(@"setModelController:"), model);
        }
        NSArray *pages = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"pageModelControllers"));
        id page = pages.count ? pages[0] : nil;
        if (!page) {
            page = [pageClass new];
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(model,
                NSSelectorFromString(@"insertObject:inPageModelControllersAtIndex:"), page, 0);
        }
        id rectangle = [rectangleClass new];
        ((void (*)(id, SEL, CGRect))objc_msgSend)(rectangle, NSSelectorFromString(@"setRectangle:"), CGRectMake(x, y, width, height));
        ((void (*)(id, SEL, double))objc_msgSend)(rectangle, NSSelectorFromString(@"setStrokeWidth:"), strokeWidth);
        ((void (*)(id, SEL, id))objc_msgSend)(rectangle, NSSelectorFromString(@"setStrokeColor:"), NSColor.systemBlueColor);
        ((void (*)(id, SEL, id))objc_msgSend)(rectangle, NSSelectorFromString(@"setFillColor:"), [NSColor colorWithWhite:1 alpha:0]);
        NSArray *annotations = ((id (*)(id, SEL))objc_msgSend)(page, NSSelectorFromString(@"annotations"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(page,
            NSSelectorFromString(@"insertObject:inAnnotationsAtIndex:"), rectangle, annotations.count);
        id writer = [writerClass new];
        result = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(writer,
            NSSelectorFromString(@"encodedModelFromAnnotationsController:encrypt:"), controller, NO);
    })) return nil;
    if (!result.length && error && !*error) *error = NCError(@"MarkupUI returned empty scan markup data");
    return result.length ? result : nil;
}

static BOOL NCLoadAttachmentMarkup(NSError **error) {
    return NCLoadFramework(@"/System/Library/PrivateFrameworks/AnnotationKit.framework/AnnotationKit", @"AnnotationKit", error) &&
        NCLoadFramework(@"/System/Library/PrivateFrameworks/MarkupUI.framework/MarkupUI", @"MarkupUI", error);
}

static id NCNewAttachmentMarkupController(NSData *data, NSError **error) {
    if (!NCLoadAttachmentMarkup(error)) return nil;
    Class controllerClass = NSClassFromString(@"AKController");
    Class modelClass = NSClassFromString(@"AKModelController");
    Class pageClass = NSClassFromString(@"AKPageModelController");
    if (!NCRequireInstanceClass(controllerClass, @[@"initForTesting", @"modelController", @"setModelController:"], @"opening attachment markup", error) ||
        !NCRequireInstanceClass(modelClass, @[@"pageModelControllers", @"insertObject:inPageModelControllersAtIndex:"], @"opening attachment markup", error) ||
        !NCRequireInstanceClass(pageClass, @[@"annotations", @"insertObject:inAnnotationsAtIndex:", @"removeObjectFromAnnotationsAtIndex:"], @"opening attachment markup", error)) return nil;
    __block id controller = nil;
    if (!NCCatch(@"opening attachment markup", error, ^{
        controller = ((id (*)(id, SEL))objc_msgSend)([controllerClass alloc], NSSelectorFromString(@"initForTesting"));
        id model = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"modelController"));
        if (!model) {
            model = [modelClass new];
            ((void (*)(id, SEL, id))objc_msgSend)(controller, NSSelectorFromString(@"setModelController:"), model);
        }
        if (data.length) {
            Class readerClass = NSClassFromString(@"MUImageReader");
            if (!NCRequireInstanceClass(readerClass, @[@"readAnnotationsFromArchivedModelData:toController:"], @"decoding attachment markup", error)) {
                controller = nil;
                return;
            }
            id reader = [readerClass new];
            BOOL decoded = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(reader,
                NSSelectorFromString(@"readAnnotationsFromArchivedModelData:toController:"), data, controller);
            if (!decoded) {
                if (error && !*error) *error = NCError(@"MarkupUI could not decode the attachment markup archive");
                controller = nil;
                return;
            }
        }
        model = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"modelController"));
        NSArray *pages = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"pageModelControllers"));
        if (!pages.count) {
            id page = [pageClass new];
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(model,
                NSSelectorFromString(@"insertObject:inPageModelControllersAtIndex:"), page, 0);
        }
    })) return nil;
    return controller;
}

static NSData *NCEncodeAttachmentMarkup(id controller, NSError **error) {
    Class writerClass = NSClassFromString(@"MUImageWriter");
    if (!NCRequireInstanceClass(writerClass, @[@"encodedModelFromAnnotationsController:encrypt:"], @"encoding attachment markup", error)) return nil;
    __block NSData *result = nil;
    if (!NCCatch(@"encoding attachment markup", error, ^{
        result = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([writerClass new],
            NSSelectorFromString(@"encodedModelFromAnnotationsController:encrypt:"), controller, NO);
    })) return nil;
    if (!result.length && error && !*error) *error = NCError(@"MarkupUI returned empty attachment markup data");
    return result.length ? result : nil;
}

static NSArray *NCMarkupPages(id controller) {
    id model = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"modelController"));
    return ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"pageModelControllers"));
}

static id NCMarkupBaseImage(NSURL *url, NSError **error) {
    Class readerClass = NSClassFromString(@"MUImageReader");
    if (!NCRequireInstanceClass(readerClass, @[@"readBaseImageFromImageAtURL:baseWasValid:"],
                                @"reading the markup base image", error)) return nil;
    __block id image = nil;
    __block BOOL valid = NO;
    if (!NCCatch(@"reading the markup base image", error, ^{
        image = ((id (*)(id, SEL, id, BOOL *))objc_msgSend)([readerClass new],
            NSSelectorFromString(@"readBaseImageFromImageAtURL:baseWasValid:"), url, &valid);
    })) return nil;
    if (!image && error && !*error) *error = NCError(@"MarkupUI could not read the attachment base image");
    return image;
}

static NSColor *NCMarkupColor(NSString *hex, NSError **error) {
    NSString *value = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (value.length != 6 && value.length != 8) {
        if (error) *error = NCError(@"Markup colors must be RRGGBB or RRGGBBAA hex values");
        return nil;
    }
    unsigned long long raw = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    if (![scanner scanHexLongLong:&raw] || !scanner.isAtEnd) {
        if (error) *error = NCError(@"Markup colors must be valid hex values");
        return nil;
    }
    double red, green, blue, alpha = 1;
    if (value.length == 8) {
        red = ((raw >> 24) & 255) / 255.0; green = ((raw >> 16) & 255) / 255.0;
        blue = ((raw >> 8) & 255) / 255.0; alpha = (raw & 255) / 255.0;
    } else {
        red = ((raw >> 16) & 255) / 255.0; green = ((raw >> 8) & 255) / 255.0;
        blue = (raw & 255) / 255.0;
    }
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
}

+ (NSData *)attachmentMarkupDataByAddingType:(NSString *)type data:(NSData *)data
                                           x:(double)x y:(double)y width:(double)width height:(double)height
                                        text:(NSString *)text points:(NSArray<NSNumber *> *)points
                                 strokeWidth:(double)strokeWidth color:(NSString *)color error:(NSError **)error {
    NSArray *values = @[@(x), @(y), @(width), @(height), @(strokeWidth)];
    for (NSNumber *value in values) if (!isfinite(value.doubleValue)) {
        if (error) *error = NCError(@"Markup geometry must be finite"); return nil;
    }
    if (strokeWidth <= 0 || width < 0 || height < 0) {
        if (error) *error = NCError(@"Markup dimensions must be nonnegative and stroke width must be positive"); return nil;
    }
    NSColor *stroke = NCMarkupColor(color, error);
    if (!stroke) return nil;
    id controller = NCNewAttachmentMarkupController(data, error);
    if (!controller) return nil;
    __block id annotation = nil;
    if (!NCCatch(@"creating attachment markup annotation", error, ^{
        CGRect rectangle = CGRectMake(x, y, width, height);
        if ([type isEqualToString:@"rectangle"] || [type isEqualToString:@"oval"] || [type isEqualToString:@"text"]) {
            NSString *className = [type isEqualToString:@"rectangle"] ? @"AKRectAnnotation" :
                ([type isEqualToString:@"oval"] ? @"AKOvalAnnotation" : @"AKTextBoxAnnotation");
            Class cls = NSClassFromString(className);
            if (!NCRequireInstanceClass(cls, @[@"setRectangle:", @"setStrokeWidth:", @"setStrokeColor:", @"setFillColor:"], @"creating attachment markup shape", error)) return;
            annotation = [cls new];
            ((void (*)(id, SEL, CGRect))objc_msgSend)(annotation, NSSelectorFromString(@"setRectangle:"), rectangle);
            ((void (*)(id, SEL, double))objc_msgSend)(annotation, NSSelectorFromString(@"setStrokeWidth:"), strokeWidth);
            ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setStrokeColor:"), stroke);
            ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setFillColor:"), [NSColor colorWithWhite:1 alpha:0]);
            if ([type isEqualToString:@"text"]) {
                if (!text.length || ![annotation respondsToSelector:NSSelectorFromString(@"setAnnotationText:")]) {
                    if (error && !*error) *error = NCError(@"Text annotations require nonempty text"); annotation = nil; return;
                }
                NSDictionary *attributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:12],
                                              NSForegroundColorAttributeName: stroke };
                NSTextStorage *storage = [[NSTextStorage alloc] initWithString:text attributes:attributes];
                ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setAnnotationText:"), storage);
                if ([annotation respondsToSelector:NSSelectorFromString(@"setTypingAttributes:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setTypingAttributes:"), attributes);
                }
                ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setForegroundColor:"), stroke);
            }
        } else if ([type isEqualToString:@"arrow"] || [type isEqualToString:@"line"]) {
            Class cls = NSClassFromString(@"AKArrowAnnotation");
            if (!NCRequireInstanceClass(cls, @[@"setStartPoint:", @"setEndPoint:", @"setStrokeWidth:", @"setStrokeColor:", @"setArrowHeadStyle:"], @"creating attachment markup line", error)) return;
            annotation = [cls new];
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(annotation, NSSelectorFromString(@"setStartPoint:"), CGPointMake(x, y));
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(annotation, NSSelectorFromString(@"setEndPoint:"), CGPointMake(x + width, y + height));
            ((void (*)(id, SEL, double))objc_msgSend)(annotation, NSSelectorFromString(@"setStrokeWidth:"), strokeWidth);
            ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setStrokeColor:"), stroke);
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(annotation, NSSelectorFromString(@"setArrowHeadStyle:"), [type isEqualToString:@"arrow"] ? 1 : 0);
        } else if ([type isEqualToString:@"ink"]) {
            if (points.count < 4 || points.count % 2 != 0) {
                if (error) *error = NCError(@"Ink annotations require at least two x,y points"); return;
            }
            Class annotationClass = NSClassFromString(@"AKDoodleAnnotation");
            if (!NCRequireInstanceClass(annotationClass, @[@"setPath:", @"setStrokeWidth:", @"setStrokeColor:", @"setRectangle:"], @"creating attachment markup ink", error)) return;
            NSBezierPath *path = [NSBezierPath bezierPath];
            CGPoint first = CGPointMake(points[0].doubleValue, points[1].doubleValue);
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(path, NSSelectorFromString(@"moveToPoint:"), first);
            for (NSUInteger index = 2; index < points.count; index += 2) {
                CGPoint point = CGPointMake(points[index].doubleValue, points[index + 1].doubleValue);
                ((void (*)(id, SEL, CGPoint))objc_msgSend)(path, NSSelectorFromString(@"lineToPoint:"), point);
            }
            CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(path, NSSelectorFromString(@"bounds"));
            annotation = [annotationClass new];
            ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setPath:"), path);
            ((void (*)(id, SEL, CGRect))objc_msgSend)(annotation, NSSelectorFromString(@"setRectangle:"), bounds);
            ((void (*)(id, SEL, double))objc_msgSend)(annotation, NSSelectorFromString(@"setStrokeWidth:"), strokeWidth);
            ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setStrokeColor:"), stroke);
        } else if ([type isEqualToString:@"highlight"]) {
            Class cls = NSClassFromString(@"AKHighlightAnnotation");
            if (!NCRequireInstanceClass(cls, @[@"setQuadPoints:", @"setColor:", @"setStyle:"], @"creating attachment markup highlight", error)) return;
            annotation = [cls new];
            NSArray *quad = @[[NSValue valueWithPoint:NSMakePoint(x, y)],
                              [NSValue valueWithPoint:NSMakePoint(x + width, y)],
                              [NSValue valueWithPoint:NSMakePoint(x, y + height)],
                              [NSValue valueWithPoint:NSMakePoint(x + width, y + height)]];
            ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setQuadPoints:"), quad);
            ((void (*)(id, SEL, id))objc_msgSend)(annotation, NSSelectorFromString(@"setColor:"), stroke);
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(annotation, NSSelectorFromString(@"setStyle:"), 0);
        } else {
            if (error) *error = NCError(@"Unknown attachment markup annotation type"); return;
        }
        if (!annotation) return;
        id page = [NCMarkupPages(controller) firstObject];
        NSArray *annotations = ((id (*)(id, SEL))objc_msgSend)(page, NSSelectorFromString(@"annotations"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(page,
            NSSelectorFromString(@"insertObject:inAnnotationsAtIndex:"), annotation, annotations.count);
    })) return nil;
    if (!annotation) return nil;
    return NCEncodeAttachmentMarkup(controller, error);
}

+ (NSArray<NSDictionary<NSString *,id> *> *)attachmentMarkupAnnotationsInData:(NSData *)data error:(NSError **)error {
    id controller = NCNewAttachmentMarkupController(data, error);
    if (!controller) return nil;
    NSMutableArray *result = [NSMutableArray array];
    if (!NCCatch(@"listing attachment markup annotations", error, ^{
        [NCMarkupPages(controller) enumerateObjectsUsingBlock:^(id page, NSUInteger pageIndex, BOOL *stop) {
            NSArray *annotations = ((id (*)(id, SEL))objc_msgSend)(page, NSSelectorFromString(@"annotations"));
            [annotations enumerateObjectsUsingBlock:^(id annotation, NSUInteger index, BOOL *innerStop) {
                id uuid = ((id (*)(id, SEL))objc_msgSend)(annotation, NSSelectorFromString(@"UUID"));
                NSString *identifier = [uuid respondsToSelector:@selector(UUIDString)] ? [uuid UUIDString] : [uuid description];
                CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(annotation, NSSelectorFromString(@"drawingBounds"));
                id textValue = [annotation respondsToSelector:NSSelectorFromString(@"annotationText")] ?
                    ((id (*)(id, SEL))objc_msgSend)(annotation, NSSelectorFromString(@"annotationText")) : nil;
                NSString *text = [textValue respondsToSelector:@selector(string)] ? [textValue string] :
                    ([textValue isKindOfClass:NSString.class] ? textValue : nil);
                NSMutableDictionary *item = [@{@"id": identifier ?: @"", @"type": NSStringFromClass([annotation class]),
                                               @"page": @(pageIndex), @"index": @(index),
                                               @"x": @(bounds.origin.x), @"y": @(bounds.origin.y),
                                               @"width": @(bounds.size.width), @"height": @(bounds.size.height)} mutableCopy];
                if (text.length) item[@"text"] = text;
                [result addObject:item];
            }];
        }];
    })) return nil;
    return result;
}

+ (NSData *)attachmentMarkupDataByRemovingIdentifier:(NSString *)identifier data:(NSData *)data error:(NSError **)error {
    id controller = NCNewAttachmentMarkupController(data, error);
    if (!controller) return nil;
    __block BOOL removed = NO;
    __block NSUInteger remaining = 0;
    if (!NCCatch(@"removing attachment markup annotation", error, ^{
        for (id page in NCMarkupPages(controller)) {
            NSArray *annotations = [((id (*)(id, SEL))objc_msgSend)(page, NSSelectorFromString(@"annotations")) copy];
            for (NSInteger index = (NSInteger)annotations.count - 1; index >= 0; index--) {
                id annotation = annotations[(NSUInteger)index];
                id uuid = ((id (*)(id, SEL))objc_msgSend)(annotation, NSSelectorFromString(@"UUID"));
                NSString *value = [uuid respondsToSelector:@selector(UUIDString)] ? [uuid UUIDString] : [uuid description];
                if (!removed && [value caseInsensitiveCompare:identifier] == NSOrderedSame) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(page,
                        NSSelectorFromString(@"removeObjectFromAnnotationsAtIndex:"), (NSUInteger)index);
                    removed = YES;
                } else { remaining++; }
            }
        }
    })) return nil;
    if (!removed) { if (error) *error = NCError(@"No markup annotation matches that identifier"); return nil; }
    if (remaining == 0) return [NSData data];
    return NCEncodeAttachmentMarkup(controller, error);
}

+ (NSData *)renderAttachmentMarkupData:(NSData *)data baseImageURL:(NSURL *)baseImageURL error:(NSError **)error {
    id controller = NCNewAttachmentMarkupController(data, error);
    if (!controller) return nil;
    id baseImage = NCMarkupBaseImage(baseImageURL, error);
    NSImage *image = [baseImage isKindOfClass:NSData.class]
        ? [[NSImage alloc] initWithData:baseImage]
        : ([baseImage isKindOfClass:NSImage.class] ? baseImage : nil);
    if (!image) { if (error) *error = NCError(@"The attachment image or PDF could not be rendered"); return nil; }
    CGRect proposed = CGRectMake(0, 0, image.size.width, image.size.height);
    CGImageRef base = [image CGImageForProposedRect:&proposed context:nil hints:nil];
    if (!base) { if (error) *error = NCError(@"The attachment produced no renderable image"); return nil; }
    id page = [NCMarkupPages(controller) firstObject];
    if (!NCRequireObject(page, @[@"renderAnnotationsOnImage:wantsHDR:opaque:withTransform:shouldApplyCropRect:forPreview:"],
                         @"rendering attachment markup", error)) return nil;
    __block CGImageRef rendered = nil;
    if (!NCCatch(@"rendering attachment markup", error, ^{
        rendered = ((CGImageRef (*)(id, SEL, CGImageRef, BOOL, BOOL, CGAffineTransform, BOOL, BOOL))objc_msgSend)(page,
            NSSelectorFromString(@"renderAnnotationsOnImage:wantsHDR:opaque:withTransform:shouldApplyCropRect:forPreview:"),
            base, NO, NO, CGAffineTransformIdentity, NO, NO);
    })) return nil;
    if (!rendered) { if (error) *error = NCError(@"MarkupUI produced no rendered image"); return nil; }
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:rendered];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png.length && error) *error = NCError(@"The rendered markup could not be encoded as PNG");
    return png.length ? png : nil;
}

+ (NSData *)attachmentImageDataByEmbeddingMarkupData:(NSData *)data baseImageURL:(NSURL *)baseImageURL
                                                error:(NSError **)error {
    if (!baseImageURL.isFileURL) { if (error) *error = NCError(@"The markup base image must be a file URL"); return nil; }
    if (!NCLoadAttachmentMarkup(error)) return nil;
    id controller = NCNewAttachmentMarkupController(data, error);
    if (!controller) return nil;
    id baseImage = NCMarkupBaseImage(baseImageURL, error);
    if (!baseImage) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)baseImageURL, nil);
    CFStringRef sourceType = source ? CGImageSourceGetType(source) : nil;
    NSString *imageType = sourceType ? (__bridge NSString *)sourceType : @"public.png";
    NSMutableData *result = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)result);
    if (!consumer) {
        if (source) CFRelease(source);
        if (error) *error = NCError(@"Could not create a markup image data consumer");
        return nil;
    }
    Class writerClass = NSClassFromString(@"MUImageWriter");
    NSString *selectorName = @"writeUsingBaseImage:withAnnotationsFromController:asImageOfType:toConsumer:embedSourceImageAndAnnotationsAsMetadata:encryptPrivateMetadata:error:";
    if (!NCRequireInstanceClass(writerClass, @[selectorName], @"writing embedded attachment markup", error)) {
        CGDataConsumerRelease(consumer);
        if (source) CFRelease(source);
        return nil;
    }
    __block BOOL written = NO;
    __block NSError *writeError = nil;
    BOOL caught = NCCatch(@"writing embedded attachment markup", error, ^{
        written = ((BOOL (*)(id, SEL, id, id, id, CGDataConsumerRef, BOOL, BOOL, NSError **))objc_msgSend)(
            [writerClass new], NSSelectorFromString(selectorName), baseImage, controller, imageType, consumer,
            data.length > 0, NO, &writeError
        );
    });
    CGDataConsumerRelease(consumer);
    if (source) CFRelease(source);
    if (!caught) return nil;
    if ((!written || !result.length) && error) {
        *error = writeError ?: NCError(@"MarkupUI could not encode the attachment image");
    }
    return written && result.length ? result : nil;
}

+ (BOOL)replaceAttachmentMediaWithURL:(NSURL *)url filename:(NSString *)filename
                            attachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!url.isFileURL || !filename.length) {
        if (error) *error = NCError(@"Replacement attachment media is incomplete");
        return NO;
    }
    if (!NCRequireObject(attachment,
        @[@"addMediaWithURL:filename:updateFileBasedAttributes:", @"invalidateAttachmentPreviewImages"],
        @"replacing attachment media", error)) return NO;
    return NCCatch(@"replacing attachment media", error, ^{
        ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(attachment,
            NSSelectorFromString(@"addMediaWithURL:filename:updateFileBasedAttributes:"), url, filename, NO);
        ((void (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"invalidateAttachmentPreviewImages"));
    });
}

+ (NSData *)embeddedAttachmentMarkupDataAtURL:(NSURL *)url error:(NSError **)error {
    if (!url.isFileURL) { if (error) *error = NCError(@"The attachment markup source must be a file URL"); return nil; }
    if (!NCLoadAttachmentMarkup(error)) return nil;
    Class readerClass = NSClassFromString(@"MUImageReader");
    if (!NCRequireInstanceClass(readerClass, @[@"readArchivedModelDataFromImageURL:"],
                                @"reading embedded attachment markup", error)) return nil;
    __block NSData *result = nil;
    if (!NCCatch(@"reading embedded attachment markup", error, ^{
        result = ((id (*)(id, SEL, id))objc_msgSend)([readerClass new],
            NSSelectorFromString(@"readArchivedModelDataFromImageURL:"), url);
    })) return nil;
    if (!result.length && error) *error = NCError(@"The attachment file has no embedded editable markup archive");
    return result.length ? result : nil;
}

+ (BOOL)setScanOrientation:(NSInteger)orientation pageIdentifier:(NSString *)pageIdentifier
                    gallery:(NSManagedObject *)gallery error:(NSError **)error {
    if (orientation < 0 || orientation > 3) { if (error) *error = NCError(@"Scan orientation must be between 0 and 3"); return NO; }
    NSArray *order = [self galleryPageIdentifiers:gallery error:error];
    NSUInteger index = [order indexOfObject:pageIdentifier];
    if (!order || index == NSNotFound) {
        if (error && !*error) *error = NCError(@"The scan page is not in this gallery");
        return NO;
    }
    id<NCScanEditor> editor = NCNewScanEditor(gallery, error);
    if (!editor) return NO;
    return NCCatch(@"rotating scanned document page", error, ^{
        [editor setOrientation:orientation forAttachmentAtIndex:index];
        [editor saveAndUpdatePreview:YES];
    });
}

+ (BOOL)moveScanPage:(NSString *)pageIdentifier toIndex:(NSUInteger)index
              gallery:(NSManagedObject *)gallery error:(NSError **)error {
    NSArray *order = [self galleryPageIdentifiers:gallery error:error];
    if (!order || ![order containsObject:pageIdentifier]) {
        if (error && !*error) *error = NCError(@"The scan page is not in this gallery");
        return NO;
    }
    if (index >= order.count) { if (error) *error = NCError(@"Scan page destination exceeds the page count"); return NO; }
    id<NCScanEditor> editor = NCNewScanEditor(gallery, error);
    if (!editor) return NO;
    __block BOOL moved = NO;
    if (!NCCatch(@"moving scanned document page", error, ^{
        moved = [editor moveObjectWithIdentifier:pageIdentifier toIndex:index];
        if (moved) [editor saveAndUpdatePreview:YES];
    })) return NO;
    if (!moved && error) *error = NCError(@"Notes did not move the scanned document page");
    return moved;
}
+ (BOOL)setScanCropBottomLeftX:(double)bottomLeftX bottomLeftY:(double)bottomLeftY
                  bottomRightX:(double)bottomRightX bottomRightY:(double)bottomRightY
                      topLeftX:(double)topLeftX topLeftY:(double)topLeftY
                     topRightX:(double)topRightX topRightY:(double)topRightY
                pageIdentifier:(NSString *)pageIdentifier gallery:(NSManagedObject *)gallery
                          error:(NSError **)error {
    double values[] = { bottomLeftX, bottomLeftY, bottomRightX, bottomRightY,
                        topLeftX, topLeftY, topRightX, topRightY };
    for (NSUInteger index = 0; index < 8; index++) {
        if (!isfinite(values[index]) || values[index] < 0 || values[index] > 1) {
            if (error) *error = NCError(@"Scan crop coordinates must be finite values between 0 and 1");
            return NO;
        }
    }
    NSArray *order = [self galleryPageIdentifiers:gallery error:error];
    if (!order || ![order containsObject:pageIdentifier]) {
        if (error && !*error) *error = NCError(@"The scan page is not in this gallery");
        return NO;
    }
    Class quadClass = NSClassFromString(@"ICDocCamImageQuad");
    if (!NCRequireClass(quadClass, @[@"quadFromCGRect:"], @"editing scanned document crop", error)) return NO;
    id<NCScanEditor> editor = NCNewScanEditor(gallery, error);
    if (!editor) return NO;
    if (!NCRequireObject(editor, @[@"subAttachmentWithIdentifier:"], @"reading scanned document dimensions", error)) return NO;
    id page = [editor subAttachmentWithIdentifier:pageIdentifier];
    if (!NCRequireObject(page, @[@"fileURL"], @"reading scanned document dimensions", error)) return NO;
    NSURL *fileURL = ((id (*)(id, SEL))objc_msgSend)(page, NSSelectorFromString(@"fileURL"));
    CGImageSourceRef source = fileURL ? CGImageSourceCreateWithURL((__bridge CFURLRef)fileURL, nil) : nil;
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nil) : nil;
    size_t width = image ? CGImageGetWidth(image) : 0;
    size_t height = image ? CGImageGetHeight(image) : 0;
    if (image) CGImageRelease(image);
    if (source) CFRelease(source);
    if (width == 0 || height == 0) {
        if (error) *error = NCError(@"The scan page image is not downloaded or has no readable pixel dimensions");
        return NO;
    }
    id<NCImageQuad> quad = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        quadClass, NSSelectorFromString(@"quadFromCGRect:"), CGRectMake(0, 0, width, height));
    if (!NCRequireObject(quad, @[@"setBottomLeft:", @"setBottomRight:", @"setTopLeft:", @"setTopRight:", @"isValid"],
                         @"editing scanned document crop", error)) return NO;
    [quad setBottomLeft:CGPointMake(bottomLeftX * width, bottomLeftY * height)];
    [quad setBottomRight:CGPointMake(bottomRightX * width, bottomRightY * height)];
    [quad setTopLeft:CGPointMake(topLeftX * width, topLeftY * height)];
    [quad setTopRight:CGPointMake(topRightX * width, topRightY * height)];
    if (![quad isValid]) { if (error) *error = NCError(@"The scan crop is not a valid convex quadrilateral"); return NO; }
    return NCCatch(@"cropping scanned document page", error, ^{
        [editor setQuad:quad forAttachmentWithIdentifier:pageIdentifier];
        [editor saveAndUpdatePreview:YES];
    });
}
+ (BOOL)deleteScanPage:(NSString *)pageIdentifier gallery:(NSManagedObject *)gallery error:(NSError **)error {
    NSArray *order = [self galleryPageIdentifiers:gallery error:error];
    NSUInteger index = [order indexOfObject:pageIdentifier];
    if (!order || index == NSNotFound) {
        if (error && !*error) *error = NCError(@"The scan page is not in this gallery");
        return NO;
    }
    if (order.count <= 1) {
        if (error) *error = NCError(@"Refusing to delete the only page in a scanned document");
        return NO;
    }
    id<NCScanEditor> editor = NCNewScanEditor(gallery, error);
    if (!editor) return NO;
    return NCCatch(@"deleting scanned document page", error, ^{
        [editor deletePagesAtIndexes:[NSIndexSet indexSetWithIndex:index]];
        [editor saveAndUpdatePreview:YES];
    });
}
+ (BOOL)deleteScanPages:(NSArray<NSString *> *)pageIdentifiers gallery:(NSManagedObject *)gallery error:(NSError **)error {
    if (pageIdentifiers.count == 0) { if (error) *error = NCError(@"No scanned document pages were provided"); return NO; }
    NSArray *order = [self galleryPageIdentifiers:gallery error:error];
    if (!order) return NO;
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    for (NSString *identifier in pageIdentifiers) {
        NSUInteger index = [order indexOfObject:identifier];
        if (index == NSNotFound) { if (error) *error = NCError(@"A scan page is not in this gallery"); return NO; }
        [indexes addIndex:index];
    }
    if (indexes.count != pageIdentifiers.count) { if (error) *error = NCError(@"Duplicate scan page identifiers are not allowed"); return NO; }
    if (indexes.count >= order.count) { if (error) *error = NCError(@"Refusing to delete every page in a scanned document"); return NO; }
    id<NCScanEditor> editor = NCNewScanEditor(gallery, error);
    if (!editor) return NO;
    return NCCatch(@"deleting scanned document pages", error, ^{
        [editor deletePagesAtIndexes:indexes];
        [editor saveAndUpdatePreview:YES];
    });
}
+ (BOOL)undeleteScanPage:(NSManagedObject *)page pageIdentifier:(NSString *)pageIdentifier
                 toIndex:(NSUInteger)index gallery:(NSManagedObject *)gallery error:(NSError **)error {
    NSArray *before = [self galleryPageIdentifiers:gallery error:error];
    if (!before || [before containsObject:pageIdentifier]) {
        if (error && !*error) *error = NCError(@"The scan page is already active in this gallery");
        return NO;
    }
    if (index > before.count) {
        if (error) *error = NCError(@"Scan page restore index exceeds the page count");
        return NO;
    }
    id<NCScanEditor> editor = NCNewScanEditor(gallery, error);
    if (!editor) return NO;
    id<NCGalleryModel> model = [editor galleryModel];
    if (!NCRequireObject(model, @[@"indexOfSubAttachmentWithIdentifier:", @"insertSubAttachment:atIndex:"],
                         @"restoring scanned document page", error)) return NO;
    if (!NCCatch(@"restoring scanned document page", error, ^{
        [editor undeleteSubAttachment:page];
        if ([model indexOfSubAttachmentWithIdentifier:pageIdentifier] == NSNotFound) {
            [model insertSubAttachment:page atIndex:index];
        }
        [editor saveAndUpdatePreview:YES];
    })) return NO;
    return YES;
}
+ (NSDictionary<NSString *, id> *)populateScanGallery:(NSManagedObject *)gallery preparation:(NCPreparedScan *)preparation
                                               context:(NSManagedObjectContext *)context error:(NSError **)error {
    if (![self validateScanPopulation:preparation error:error]) return nil;
    Class utilities = NSClassFromString(@"ICGalleryAttachmentUtilities");
    __block NSArray *created = nil;
    BOOL ok = NCCatch(@"creating scanned document pages", error, ^{
        created = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(utilities,
            NSSelectorFromString(@"createAndAddSubAttachmentsToGalleryAttachment:fromDocuments:imageCache:context:"),
            gallery, preparation.documents, preparation.imageCache, context);
    });
    if (!ok || ![created isKindOfClass:NSArray.class] || created.count != preparation.pageCount) {
        if (error && !*error) *error = NCError(@"Notes created an incomplete scanned document");
        return nil;
    }
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:created.count];
    NSMutableArray<NSString *> *types = [NSMutableArray arrayWithCapacity:created.count];
    for (id value in created) {
        id child = value;
        if ([value isKindOfClass:NSString.class]) {
            NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICAttachment"];
            request.predicate = [NSPredicate predicateWithFormat:@"identifier == %@ AND parentAttachment == %@", value, gallery];
            request.fetchLimit = 2;
            NSArray *matches = [context executeFetchRequest:request error:error];
            if (!matches || matches.count != 1) {
                if (error && !*error) *error = NCError(@"Notes returned a scan page identifier without one matching child attachment");
                return nil;
            }
            child = matches.firstObject;
        }
        if (!NCRequireObject(child, @[@"identifier", @"typeUTI", @"parentAttachment"], @"reading scanned document page", error)) return nil;
        NSString *identifier = [child valueForKey:@"identifier"];
        NSString *type = [child valueForKey:@"typeUTI"];
        if (!identifier.length || !type.length || [child valueForKey:@"parentAttachment"] != gallery) {
            if (error) *error = NCError(@"A scanned document page has invalid identity or parentage");
            return nil;
        }
        [identifiers addObject:identifier];
        [types addObject:type];
    }
    if ([NSSet setWithArray:identifiers].count != identifiers.count) {
        if (error) *error = NCError(@"Scanned document page identifiers are not unique");
        return nil;
    }
    return @{ @"pageIDs": identifiers, @"pageTypes": types, @"pageCount": @(identifiers.count) };
}
+ (NSDictionary<NSString *,NSString *> *)recognizeTextInImageAtURL:(NSURL *)url
                                                          languages:(NSArray<NSString *> *)languages
                                                              title:(NSString *)title
                                                              error:(NSError **)error {
    if (!url.isFileURL) {
        if (error) *error = NCErrorWithCode(3, @"OCR input must be a file URL");
        return nil;
    }
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory]) {
        if (error) *error = NCErrorWithCode(3, @"OCR input does not exist");
        return nil;
    }
    if (isDirectory) {
        if (error) *error = NCErrorWithCode(3, @"OCR input must be a file");
        return nil;
    }
    if (![NSFileManager.defaultManager isReadableFileAtPath:url.path]) {
        if (error) *error = NCErrorWithCode(3, @"OCR input is not readable");
        return nil;
    }

    NSError *loadError = nil;
    if (!NCLoad(&loadError)) {
        if (error) *error = NCErrorWithCode(2, loadError.localizedDescription ?: @"Notes OCR runtime is unavailable");
        return nil;
    }
    Class generator = NSClassFromString(@"ICOCRGenerator");
    SEL selector = NSSelectorFromString(@"ocrStringFromImageURL:title:languages:");
    if (!generator || ![generator respondsToSelector:selector]) {
        if (error) *error = NCErrorWithCode(2, @"Apple Notes OCR is unavailable: +[ICOCRGenerator ocrStringFromImageURL:title:languages:] is missing");
        return nil;
    }

    __block id recognizedText = nil;
    __block id recognizedTitle = title;
    if (!NCCatch(@"recognizing image text", error, ^{
        recognizedText = ((id (*)(id, SEL, id, id *, id))objc_msgSend)(generator, selector, url, &recognizedTitle, languages ?: @[]);
    })) return nil;
    NSString *text = NCPlain(recognizedText);
    if (!recognizedText || !text) {
        if (error) *error = NCError(@"Apple Notes OCR returned no result");
        return nil;
    }
    NSString *resolvedTitle = NCPlain(recognizedTitle);
    return @{ @"text": text, @"title": resolvedTitle ?: @"" };
}

+ (NSDictionary<NSString *,id> *)recognizeHandwritingInAttachment:(NSManagedObject *)attachment
                                                            locale:(NSString *)localeIdentifier
                                                             error:(NSError **)error {
    NSError *loadError = nil;
    if (!NCLoad(&loadError) ||
        !NCLoadFramework(@"/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", @"NotesUI", &loadError) ||
        !NCLoadFramework(@"/System/Library/Frameworks/PencilKit.framework/PencilKit", @"PencilKit", &loadError)) {
        if (error) *error = NCErrorWithCode(2, loadError.localizedDescription ?: @"handwriting recognition runtime is unavailable");
        return nil;
    }
    if (!NCRequireObject(attachment, @[@"attachmentModel"], @"opening handwriting attachment", error)) return nil;
    id model = ((id (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"attachmentModel"));
    Class drawingClass = NSClassFromString(@"CHDrawing");
    Class recognizerClass = NSClassFromString(@"CHRecognizer");
    if (!NCRequireInstanceClass(drawingClass, @[@"addStartTime:", @"addPoint:", @"addEndTime:", @"endStroke"],
                                @"building handwriting recognition input", error) ||
        !NCRequireInstanceClass(recognizerClass, @[@"initWithMode:locale:", @"textRecognitionResultForDrawing:options:shouldCancel:"],
                                @"recognizing handwriting", error)) return nil;

    __block NSArray *strokes = nil;
    __block id characterDrawing = nil;
    __block NSUInteger pointCount = 0;
    __block double clock = 0;
    if (!NCCatch(@"decoding handwriting strokes", error, ^{
        NSMutableArray *allStrokes = [NSMutableArray array];
        SEL mergeableDrawing = NSSelectorFromString(@"newDrawingFromMergeableData");
        if ([model respondsToSelector:mergeableDrawing]) {
            id drawing = ((id (*)(id, SEL))objc_msgSend)(model, mergeableDrawing);
            NSArray *values = ((id (*)(id, SEL))objc_msgSend)(drawing, NSSelectorFromString(@"strokes"));
            if (values) [allStrokes addObjectsFromArray:values];
        } else {
            Class helper = NSClassFromString(@"ICSystemPaperDrawingsHelper");
            SEL drawingsSelector = NSSelectorFromString(@"drawingsForAttachment:");
            if (helper && [helper respondsToSelector:drawingsSelector]) {
                NSArray *drawings = ((id (*)(id, SEL, id))objc_msgSend)(helper, drawingsSelector, attachment);
                for (id drawing in drawings) {
                    NSArray *values = ((id (*)(id, SEL))objc_msgSend)(drawing, NSSelectorFromString(@"strokes"));
                    if (values) [allStrokes addObjectsFromArray:values];
                }
            }
        }
        strokes = allStrokes;
        characterDrawing = [drawingClass new];
        for (id stroke in strokes) {
            id path = ((id (*)(id, SEL))objc_msgSend)(stroke, NSSelectorFromString(@"path"));
            NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(path, NSSelectorFromString(@"count"));
            if (count < 2) continue;
            ((void (*)(id, SEL, double))objc_msgSend)(characterDrawing, NSSelectorFromString(@"addStartTime:"), clock);
            for (NSUInteger index = 0; index < count; index++) {
                CGPoint point;
                SEL transformed = NSSelectorFromString(@"_locationAtIndex:applyStrokeTransform:");
                if ([stroke respondsToSelector:transformed]) {
                    point = ((CGPoint (*)(id, SEL, NSUInteger, BOOL))objc_msgSend)(stroke, transformed, index, YES);
                } else {
                    SEL location = NSSelectorFromString(@"locationAtIndex:");
                    if (![stroke respondsToSelector:location]) continue;
                    point = ((CGPoint (*)(id, SEL, NSUInteger))objc_msgSend)(stroke, location, index);
                }
                ((void (*)(id, SEL, CGPoint))objc_msgSend)(characterDrawing, NSSelectorFromString(@"addPoint:"), point);
                double timestamp = [stroke respondsToSelector:NSSelectorFromString(@"timestampAtIndex:")]
                    ? ((double (*)(id, SEL, NSUInteger))objc_msgSend)(stroke, NSSelectorFromString(@"timestampAtIndex:"), index)
                    : clock + 0.001;
                clock = MAX(clock + 0.001, timestamp);
                pointCount++;
            }
            ((void (*)(id, SEL, double))objc_msgSend)(characterDrawing, NSSelectorFromString(@"addEndTime:"), clock);
            ((void (*)(id, SEL))objc_msgSend)(characterDrawing, NSSelectorFromString(@"endStroke"));
            clock += 0.05;
        }
    })) return nil;
    if (!strokes.count || !pointCount) {
        if (error) *error = NCError(@"The Paper attachment has no recognizable handwriting strokes");
        return nil;
    }

    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:localeIdentifier.length ? localeIdentifier : @"en-US"];
    __block id recognizer = nil;
    __block id result = nil;
    BOOL (^shouldCancel)(void) = ^BOOL { return NO; };
    if (!NCCatch(@"recognizing handwriting", error, ^{
        recognizer = ((id (*)(id, SEL, int, id))objc_msgSend)([recognizerClass alloc],
            NSSelectorFromString(@"initWithMode:locale:"), 2, locale);
        result = ((id (*)(id, SEL, id, id, id))objc_msgSend)(recognizer,
            NSSelectorFromString(@"textRecognitionResultForDrawing:options:shouldCancel:"),
            characterDrawing, nil, shouldCancel);
    })) return nil;
    if (!result || !NCRequireObject(result,
            @[@"topTranscription", @"rawTranscription", @"topModelTranscription", @"score"],
            @"reading handwriting recognition result", error)) return nil;
    NSString *top = ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"topTranscription")) ?: @"";
    NSString *raw = ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"rawTranscription")) ?: @"";
    NSString *modelText = ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"topModelTranscription")) ?: @"";
    double score = ((double (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"score"));
    return @{ @"text": top, @"raw": raw, @"model": modelText, @"score": @(score),
              @"strokes": @(strokes.count), @"points": @(pointCount) };
}

+ (BOOL)setHandwritingSummary:(NSString *)summary attachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCRequireObject(attachment, @[@"updateHandwritingSummary:"], @"updating handwriting summary", error)) return NO;
    __block BOOL changed = NO;
    if (!NCCatch(@"updating handwriting summary", error, ^{
        changed = ((BOOL (*)(id, SEL, id))objc_msgSend)(attachment,
            NSSelectorFromString(@"updateHandwritingSummary:"), summary);
    })) return NO;
    return changed;
}

+ (BOOL)setOCRSummary:(NSString *)summary version:(NSInteger)version attachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCRequireObject(attachment, @[@"setOcrSummary:", @"ocrSummary", @"ocrSummaryVersion"],
                         @"updating OCR summary", error)) return NO;
    return NCCatch(@"updating OCR summary", error, ^{
        ((void (*)(id, SEL, id))objc_msgSend)(attachment, NSSelectorFromString(@"setOcrSummary:"), summary);
        [attachment setValue:@(summary != nil ? version : 0) forKey:@"ocrSummaryVersion"];
    });
}

+ (BOOL)setImageClassificationSummary:(NSString *)summary version:(NSInteger)version attachment:(NSManagedObject *)attachment error:(NSError **)error {
    if (!NCRequireObject(attachment, @[@"setImageClassificationSummary:", @"imageClassificationSummary",
                                      @"imageClassificationSummaryVersion"],
                         @"updating image classification summary", error)) return NO;
    return NCCatch(@"updating image classification summary", error, ^{
        ((void (*)(id, SEL, id))objc_msgSend)(attachment,
            NSSelectorFromString(@"setImageClassificationSummary:"), summary);
        [attachment setValue:@(summary != nil ? version : 0) forKey:@"imageClassificationSummaryVersion"];
    });
}

+ (NSDictionary<NSString *,id> *)regenerateFallbackPDFForAttachment:(NSManagedObject *)attachment
                                                               error:(NSError **)error {
    NSError *loadError = nil;
    if (!NCLoad(&loadError)) {
        if (error) *error = NCErrorWithCode(2, loadError.localizedDescription ?: @"Paper runtime is unavailable");
        return nil;
    }
    Class modelClass = NSClassFromString(@"ICAttachmentPaperBundleModel");
    if (!NCRequireClass(modelClass, @[@"generateFallbackPDFDataForAttachment:"], @"generating fallback PDF", error) ||
        !NCRequireObject(attachment, @[@"writeFallbackPDFData:", @"fallbackPDFURL"], @"writing fallback PDF", error)) return nil;
    __block NSData *data = nil;
    __block BOOL wrote = NO;
    __block NSURL *url = nil;
    if (!NCCatch(@"regenerating fallback PDF", error, ^{
        data = ((id (*)(id, SEL, id))objc_msgSend)(modelClass,
            NSSelectorFromString(@"generateFallbackPDFDataForAttachment:"), attachment);
        if (data.length) {
            wrote = ((BOOL (*)(id, SEL, id))objc_msgSend)(attachment,
                NSSelectorFromString(@"writeFallbackPDFData:"), data);
            url = ((id (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"fallbackPDFURL"));
        }
    })) return nil;
    if (!data.length || !wrote || !url) {
        if (error) *error = NCError(@"Notes could not generate and store a fallback PDF for this attachment");
        return nil;
    }
    return @{ @"byteCount": @(data.length), @"url": url.path ?: url.absoluteString ?: @"", @"wrote": @YES };
}

+ (NSData *)archivePaperBundleForAttachment:(NSManagedObject *)attachment error:(NSError **)error {
    NSError *loadError = nil;
    if (!NCLoad(&loadError) ||
        !NCLoadFramework(@"/System/Library/Frameworks/PaperKit.framework/PaperKit", @"PaperKit", &loadError)) {
        if (error) *error = NCErrorWithCode(2, loadError.localizedDescription ?: @"Paper runtime is unavailable");
        return nil;
    }
    if (!NCRequireObject(attachment, @[@"paperBundleModel"], @"opening Paper bundle", error)) return nil;
    __block id model = nil;
    __block NSURL *archiveURL = nil;
    __block NSError *archiveError = nil;
    if (!NCCatch(@"archiving Paper bundle", error, ^{
        model = ((id (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"paperBundleModel"));
        if (model && [model respondsToSelector:NSSelectorFromString(@"archivePaperBundleToDiskWithError:")]) {
            archiveURL = ((id (*)(id, SEL, NSError **))objc_msgSend)(
                model, NSSelectorFromString(@"archivePaperBundleToDiskWithError:"), &archiveError);
        }
    })) return nil;
    if (!model || ![model respondsToSelector:NSSelectorFromString(@"archivePaperBundleToDiskWithError:")]) {
        if (error) *error = NCError(@"The Paper attachment model cannot create a sync archive");
        return nil;
    }
    if (!archiveURL.isFileURL) {
        if (error) *error = archiveError ?: NCError(@"Notes returned no local Paper bundle archive");
        return nil;
    }
    NSNumber *directory = nil;
    if (![archiveURL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:&archiveError]) {
        if (error) *error = archiveError ?: NCError(@"The Paper bundle archive could not be inspected");
        return nil;
    }
    NSData *payload = nil;
    NSString *format = nil;
    if (directory.boolValue) {
        NSFileWrapper *wrapper = [[NSFileWrapper alloc] initWithURL:archiveURL options:0 error:&archiveError];
        payload = wrapper.serializedRepresentation;
        format = @"file-wrapper-v1";
    } else {
        payload = [NSData dataWithContentsOfURL:archiveURL options:NSDataReadingMappedIfSafe error:&archiveError];
        format = @"file-v1";
    }
    if (!payload.length) {
        if (error) *error = archiveError ?: NCError(@"The Paper bundle archive was empty");
        return nil;
    }
    NSString *name = archiveURL.lastPathComponent.length ? archiveURL.lastPathComponent : @"paper.bundle";
    NSDictionary *envelope = @{
        @"version": @1,
        @"format": format,
        @"name": name,
        @"payload": payload,
    };
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:envelope
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&archiveError];
    if (!encoded.length && error) *error = archiveError ?: NCError(@"The Paper bundle archive could not be encoded");
    return encoded;
}

+ (BOOL)restorePaperBundleArchive:(NSData *)archive attachment:(NSManagedObject *)attachment
                            error:(NSError **)error {
    NSError *loadError = nil;
    if (!archive.length) {
        if (error) *error = NCError(@"The Paper bundle archive is empty");
        return NO;
    }
    if (!NCLoad(&loadError) ||
        !NCLoadFramework(@"/System/Library/Frameworks/PaperKit.framework/PaperKit", @"PaperKit", &loadError)) {
        if (error) *error = NCErrorWithCode(2, loadError.localizedDescription ?: @"Paper runtime is unavailable");
        return NO;
    }
    if (!NCRequireObject(attachment, @[@"paperBundleModel"], @"restoring Paper bundle", error)) return NO;
    NSPropertyListFormat plistFormat = NSPropertyListBinaryFormat_v1_0;
    NSDictionary *envelope = [NSPropertyListSerialization propertyListWithData:archive
        options:NSPropertyListImmutable format:&plistFormat error:&loadError];
    if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"version"] isEqual:@1] ||
        ![envelope[@"format"] isKindOfClass:NSString.class] ||
        ![envelope[@"payload"] isKindOfClass:NSData.class]) {
        if (error) *error = loadError ?: NCError(@"The Paper bundle archive envelope is invalid");
        return NO;
    }
    NSString *format = envelope[@"format"];
    NSData *payload = envelope[@"payload"];
    NSString *name = [envelope[@"name"] isKindOfClass:NSString.class]
        ? [envelope[@"name"] lastPathComponent] : @"paper.bundle";
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) name = @"paper.bundle";
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"notescli-paper-%@", NSUUID.UUID.UUIDString]]
        isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions: @0700} error:&loadError]) {
        if (error) *error = loadError;
        return NO;
    }
    @try {
        BOOL directoryArchive = [format isEqualToString:@"file-wrapper-v1"];
        NSURL *source = [root URLByAppendingPathComponent:name isDirectory:directoryArchive];
        if ([format isEqualToString:@"file-v1"]) {
            if (![payload writeToURL:source options:NSDataWritingAtomic error:&loadError]) {
                if (error) *error = loadError;
                return NO;
            }
        } else if (directoryArchive) {
            NSFileWrapper *wrapper = [[NSFileWrapper alloc] initWithSerializedRepresentation:payload];
            if (!wrapper.isDirectory || ![wrapper writeToURL:source options:NSFileWrapperWritingAtomic
                originalContentsURL:nil error:&loadError]) {
                if (error) *error = loadError ?: NCError(@"The Paper bundle directory archive is invalid");
                return NO;
            }
        } else {
            if (error) *error = NCError(@"The Paper bundle archive format is unsupported");
            return NO;
        }
        __block id model = nil;
        __block BOOL restored = NO;
        __block NSError *restoreError = nil;
        if (!NCCatch(@"restoring Paper bundle", error, ^{
            model = ((id (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"paperBundleModel"));
            if (model && [model respondsToSelector:NSSelectorFromString(@"restorePaperBundleFromArchiveURL:error:")]) {
                restored = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(
                    model, NSSelectorFromString(@"restorePaperBundleFromArchiveURL:error:"), source, &restoreError);
            }
        })) return NO;
        if (!model || ![model respondsToSelector:NSSelectorFromString(@"restorePaperBundleFromArchiveURL:error:")]) {
            if (error) *error = NCError(@"The Paper attachment model cannot restore a sync archive");
            return NO;
        }
        if (!restored) {
            if (error) *error = restoreError ?: NCError(@"Notes rejected the Paper bundle archive");
            return NO;
        }
        if ([attachment respondsToSelector:NSSelectorFromString(@"updateChangeCountWithReason:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(attachment,
                NSSelectorFromString(@"updateChangeCountWithReason:"), @"Restored Paper bundle");
        }
        return YES;
    } @finally {
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    }
}

+ (NSString *)addPaperDocumentAtURL:(NSURL *)url subtype:(NSString *)subtype identifier:(NSString *)identifier
                              toNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    if (!url.isFileURL || ![NSFileManager.defaultManager isReadableFileAtPath:url.path]) {
        if (error) *error = NCError(@"Paper document source must be a readable local file");
        return nil;
    }
    NSError *loadError = nil;
    if (!NCLoad(&loadError) ||
        !NCLoadFramework(@"/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI", @"NotesUI", &loadError) ||
        !NCLoadFramework(@"/System/Library/Frameworks/PaperKit.framework/PaperKit", @"PaperKit", &loadError)) {
        if (error) *error = NCErrorWithCode(2, loadError.localizedDescription ?: @"Paper document runtime is unavailable");
        return nil;
    }
    NSString *symbolName = [subtype caseInsensitiveCompare:@"pdf"] == NSOrderedSame
        ? @"ICAttachmentUTTypePaperDocumentPDF"
        : ([subtype caseInsensitiveCompare:@"scan"] == NSOrderedSame ? @"ICAttachmentUTTypePaperDocumentScan" : nil);
    if (!symbolName) {
        if (error) *error = NCError(@"Paper document subtype must be pdf or scan");
        return nil;
    }
    void *notesHandle = dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW | RTLD_LOCAL);
    void *symbol = notesHandle ? dlsym(notesHandle, symbolName.UTF8String) : NULL;
    NSString *nativeSubtype = symbol ? *(__unsafe_unretained NSString **)symbol : nil;
    Class helperClass = NSClassFromString(@"ICPaperAttachmentCreationHelper");
    if (!nativeSubtype ||
        !NCRequireObject(note, @[@"addPaperDocumentAttachmentWithIdentifier:subtype:"], @"creating Paper document", error) ||
        !NCRequireClass(helperClass, @[@"createPaperDocumentForAttachment:fromLegacyMediaAtURL:error:"],
                        @"converting Paper document", error)) {
        if (!nativeSubtype && error && !*error) *error = NCError(@"The requested Paper document type constant is unavailable");
        return nil;
    }
    if (![[NSUUID alloc] initWithUUIDString:identifier]) {
        if (error) *error = NCError(@"Paper document identifier must be a UUID");
        return nil;
    }
    __block id attachment = nil;
    __block BOOL converted = NO;
    __block NSError *conversionError = nil;
    if (!NCCatch(@"creating Paper document", error, ^{
        attachment = ((id (*)(id, SEL, id, id))objc_msgSend)(note,
            NSSelectorFromString(@"addPaperDocumentAttachmentWithIdentifier:subtype:"), identifier, nativeSubtype);
        if (attachment) {
            converted = ((BOOL (*)(id, SEL, id, id, NSError **))objc_msgSend)(helperClass,
                NSSelectorFromString(@"createPaperDocumentForAttachment:fromLegacyMediaAtURL:error:"),
                attachment, url, &conversionError);
        }
    })) return nil;
    if (!attachment || !converted) {
        if (error) *error = conversionError ?: NCError(@"Notes could not convert the source into a Paper document");
        return nil;
    }
    NSString *createdType = [attachment valueForKey:@"typeUTI"];
    if (!createdType.length) {
        if (error) *error = NCError(@"The created Paper document has no type");
        return nil;
    }
    if (type) *type = createdType;
    return identifier;
}

+ (NSString *)addPaperDocumentArchive:(NSData *)archive subtype:(NSString *)subtype identifier:(NSString *)identifier
                                 toNote:(NSManagedObject *)note type:(NSString **)type error:(NSError **)error {
    if (!archive.length) {
        if (error) *error = NCError(@"Paper document archive is empty");
        return nil;
    }
    NSError *loadError = nil;
    if (!NCLoad(&loadError) ||
        !NCLoadFramework(@"/System/Library/Frameworks/PaperKit.framework/PaperKit", @"PaperKit", &loadError)) {
        if (error) *error = NCErrorWithCode(2, loadError.localizedDescription ?: @"Paper document runtime is unavailable");
        return nil;
    }
    NSString *symbolName = [subtype caseInsensitiveCompare:@"pdf"] == NSOrderedSame
        ? @"ICAttachmentUTTypePaperDocumentPDF"
        : ([subtype caseInsensitiveCompare:@"scan"] == NSOrderedSame ? @"ICAttachmentUTTypePaperDocumentScan" : nil);
    if (!symbolName) {
        if (error) *error = NCError(@"Paper document subtype must be pdf or scan");
        return nil;
    }
    void *notesHandle = dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW | RTLD_LOCAL);
    void *symbol = notesHandle ? dlsym(notesHandle, symbolName.UTF8String) : NULL;
    NSString *nativeSubtype = symbol ? *(__unsafe_unretained NSString **)symbol : nil;
    if (!nativeSubtype ||
        !NCRequireObject(note, @[@"addPaperDocumentAttachmentWithIdentifier:subtype:"], @"creating Paper document", error)) {
        if (!nativeSubtype && error && !*error) *error = NCError(@"The requested Paper document type constant is unavailable");
        return nil;
    }
    if (![[NSUUID alloc] initWithUUIDString:identifier]) {
        if (error) *error = NCError(@"Paper document identifier must be a UUID");
        return nil;
    }
    __block id attachment = nil;
    if (!NCCatch(@"creating Paper document", error, ^{
        attachment = ((id (*)(id, SEL, id, id))objc_msgSend)(note,
            NSSelectorFromString(@"addPaperDocumentAttachmentWithIdentifier:subtype:"), identifier, nativeSubtype);
    })) return nil;
    if (!attachment) {
        if (error) *error = NCError(@"Notes created no Paper document attachment");
        return nil;
    }
    NSError *restoreError = nil;
    if (![self restorePaperBundleArchive:archive attachment:attachment error:&restoreError]) {
        if ([attachment respondsToSelector:NSSelectorFromString(@"markForDeletion")]) {
            ((void (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"markForDeletion"));
        }
        if (error) *error = restoreError ?: NCError(@"Notes could not restore the Paper document archive");
        return nil;
    }
    NSString *createdType = [attachment valueForKey:@"typeUTI"];
    if (!createdType.length) {
        if (error) *error = NCError(@"The restored Paper document has no type");
        return nil;
    }
    if (type) *type = createdType;
    return identifier;
}

+ (NSString *)addSystemPaperArchive:(NSData *)archive identifier:(NSString *)identifier toNote:(NSManagedObject *)note
                                type:(NSString **)type error:(NSError **)error {
    if (!archive.length) {
        if (error) *error = NCError(@"System Paper archive is empty");
        return nil;
    }
    NSError *loadError = nil;
    if (!NCLoad(&loadError) ||
        !NCLoadFramework(@"/System/Library/Frameworks/PaperKit.framework/PaperKit", @"PaperKit", &loadError)) {
        if (error) *error = NCErrorWithCode(2, loadError.localizedDescription ?: @"System Paper runtime is unavailable");
        return nil;
    }
    if (!NCRequireObject(note, @[@"addSystemPaperAttachmentWithIdentifier:"], @"creating System Paper attachment", error)) {
        return nil;
    }
    if (![[NSUUID alloc] initWithUUIDString:identifier]) {
        if (error) *error = NCError(@"System Paper identifier must be a UUID");
        return nil;
    }
    __block id attachment = nil;
    if (!NCCatch(@"creating System Paper attachment", error, ^{
        attachment = ((id (*)(id, SEL, id))objc_msgSend)(note,
            NSSelectorFromString(@"addSystemPaperAttachmentWithIdentifier:"), identifier);
    })) return nil;
    if (!attachment) {
        if (error) *error = NCError(@"Notes created no System Paper attachment");
        return nil;
    }
    NSError *restoreError = nil;
    if (![self restorePaperBundleArchive:archive attachment:attachment error:&restoreError]) {
        if ([attachment respondsToSelector:NSSelectorFromString(@"markForDeletion")]) {
            ((void (*)(id, SEL))objc_msgSend)(attachment, NSSelectorFromString(@"markForDeletion"));
        }
        if (error) *error = restoreError ?: NCError(@"Notes could not restore the System Paper archive");
        return nil;
    }
    NSString *createdType = [attachment valueForKey:@"typeUTI"];
    if (!createdType.length) {
        if (error) *error = NCError(@"The restored System Paper attachment has no type");
        return nil;
    }
    if (type) *type = createdType;
    return identifier;
}

+ (NSURL *)paperBundleURLForIdentifier:(NSString *)identifier account:(NSManagedObject *)account
                                  error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    Class modelClass = NSClassFromString(@"ICAttachmentPaperBundleModel");
    if (!NCRequireClass(modelClass, @[@"paperBundleURLForAttachmentIdentifier:inAccount:"],
                        @"resolving Paper bundle path", error)) return nil;
    __block NSURL *url = nil;
    if (!NCCatch(@"resolving Paper bundle path", error, ^{
        url = ((id (*)(id, SEL, id, id))objc_msgSend)(modelClass,
            NSSelectorFromString(@"paperBundleURLForAttachmentIdentifier:inAccount:"), identifier, account);
    })) return nil;
    if (!url.isFileURL && error && !*error) *error = NCError(@"Notes returned no local Paper bundle path");
    return url.isFileURL ? url : nil;
}

+ (NSURL *)paperBundlesDirectoryURLForAccount:(NSManagedObject *)account error:(NSError **)error {
    if (!NCLoad(error) || !NCRequireObject(account, @[@"systemPaperBundlesDirectoryURL"],
                                           @"resolving Paper bundle directory", error)) return nil;
    __block NSURL *url = nil;
    if (!NCCatch(@"resolving Paper bundle directory", error, ^{
        url = ((id (*)(id, SEL))objc_msgSend)(account, NSSelectorFromString(@"systemPaperBundlesDirectoryURL"));
    })) return nil;
    if (!url.isFileURL && error && !*error) *error = NCError(@"Notes returned no local Paper bundle directory");
    return url.isFileURL ? url : nil;
}

+ (NSArray<NSURL *> *)paperFileURLsForIdentifier:(NSString *)identifier account:(NSManagedObject *)account
                                            error:(NSError **)error {
    if (!NCLoad(error)) return nil;
    Class attachmentClass = NSClassFromString(@"ICAttachment");
    NSArray<NSString *> *selectors = @[
        @"fallbackImageFallbackURLForIdentifier:account:",
        @"fallbackImageEncryptedFallbackURLForIdentifier:account:",
        @"fallbackImageContainerURLForIdentifier:account:",
        @"fallbackPDFFallbackURLForIdentifier:account:",
        @"fallbackPDFEncryptedFallbackURLForIdentifier:account:",
        @"fallbackPDFContainerURLForIdentifier:account:",
    ];
    if (!NCRequireClass(attachmentClass, selectors, @"resolving Paper fallback paths", error)) return nil;
    NSURL *bundleURL = [self paperBundleURLForIdentifier:identifier account:account error:error];
    if (!bundleURL) return nil;
    __block NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithObject:bundleURL];
    if (!NCCatch(@"resolving Paper fallback paths", error, ^{
        for (NSString *selectorName in selectors) {
            NSURL *url = ((id (*)(id, SEL, id, id))objc_msgSend)(attachmentClass,
                NSSelectorFromString(selectorName), identifier, account);
            if (url.isFileURL) [urls addObject:url];
        }
    })) return nil;
    return [urls copy];
}

+ (BOOL)purgePaperFilesForIdentifier:(NSString *)identifier account:(NSManagedObject *)account
                                error:(NSError **)error {
    if (!NCLoad(error)) return NO;
    Class attachmentClass = NSClassFromString(@"ICAttachment");
    if (!NCRequireClass(attachmentClass, @[@"purgeAttachmentFilesForIdentifiers:account:"],
                        @"purging Paper attachment files", error)) return NO;
    return NCCatch(@"purging Paper attachment files", error, ^{
        ((void (*)(id, SEL, id, id))objc_msgSend)(attachmentClass,
            NSSelectorFromString(@"purgeAttachmentFilesForIdentifiers:account:"), @[identifier], account);
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
    if ([operations containsObject:@"replace"]) {
        BOOL hasAttributedReplace = [(id)_mergeable respondsToSelector:NSSelectorFromString(@"replaceCharactersInRange:withAttributedString:")];
        BOOL hasStringReplace = [(id)_mergeable respondsToSelector:NSSelectorFromString(@"replaceCharactersInRange:withString:")];
        if (!hasAttributedReplace && !hasStringReplace) {
            [mergeableSelectors addObject:@"replaceCharactersInRange:withString:"];
        } else if (!hasAttributedReplace) {
            [mergeableSelectors addObject:@"setAttributes:range:"];
        }
        [noteSelectors addObject:@"edited:range:changeInLength:"];
    }
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
- (BOOL)replaceRange:(NSRange)range withText:(NSAttributedString *)text error:(NSError **)error {
    SEL attributedSelector = NSSelectorFromString(@"replaceCharactersInRange:withAttributedString:");
    SEL stringSelector = NSSelectorFromString(@"replaceCharactersInRange:withString:");
    BOOL hasAttributedReplace = [(id)_mergeable respondsToSelector:attributedSelector];
    BOOL hasStringReplace = [(id)_mergeable respondsToSelector:stringSelector];
    if (!hasAttributedReplace && !hasStringReplace) {
        return NCRequireObject(_mergeable, @[@"replaceCharactersInRange:withString:"], @"replacing body text", error);
    }
    if ((!hasAttributedReplace && !NCRequireObject(_mergeable, @[@"setAttributes:range:"], @"replacing body text", error)) ||
        !NCRequireObject(_note, @[@"edited:range:changeInLength:"], @"replacing body text", error)) return NO;
    return NCCatch(@"replacing body text", error, ^{
        if (hasAttributedReplace) {
            ((void (*)(id, SEL, NSRange, id))objc_msgSend)(self->_mergeable, attributedSelector, range, text);
        } else {
            ((void (*)(id, SEL, NSRange, id))objc_msgSend)(self->_mergeable, stringSelector, range, text.string);
            if (text.length) {
                [text enumerateAttributesInRange:NSMakeRange(0, text.length) options:0
                                      usingBlock:^(NSDictionary<NSAttributedStringKey,id> *attributes,
                                                   NSRange attributeRange, BOOL *stop) {
                    [self->_mergeable setAttributes:attributes
                                              range:NSMakeRange(range.location + attributeRange.location,
                                                                attributeRange.length)];
                }];
            }
        }
        NSInteger delta = (NSInteger)text.length - (NSInteger)range.length;
        [(id<NCNote>)self->_note edited:3 range:NSMakeRange(range.location, text.length) changeInLength:delta];
    });
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
    __block BOOL saved = NO;
    BOOL completed = NCCatch(@"finishing body edit", error, ^{
        [self->_note setValue:NSDate.date forKey:@"modificationDate"];
        [(id<NCNote>)self->_note endEditing];
        saved = [(id<NCNote>)self->_note saveNoteData];
    });
    if (completed && !saved && error) *error = NCError(@"Notes refused to save the note body");
    return completed && saved;
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
- (BOOL)reverseColumnDirection:(NSError **)error {
    if (![self prepareToSave:error] || !NCRequireObject(_table, @[@"reverseColumnDirection"], @"reversing table column direction", error)) return NO;
    return NCCatch(@"reversing table column direction", error, ^{ [self->_table reverseColumnDirection]; });
}
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
