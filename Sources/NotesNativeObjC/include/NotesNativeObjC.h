#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runtime-only boundary around NotesShared. Every private call is selector-checked
/// and Objective-C exceptions are converted to NSError.
@interface NCNotesRuntime : NSObject
+ (NSDictionary<NSString *, id> *)doctor;
+ (nullable NSManagedObjectContext *)sharedContext:(NSError **)error NS_SWIFT_NAME(sharedContext());
+ (nullable NSAttributedString *)bodyOfNote:(NSManagedObject *)note error:(NSError **)error NS_SWIFT_NAME(body(of:));
+ (nullable NSManagedObject *)newNoteInFolder:(NSManagedObject *)folder error:(NSError **)error NS_SWIFT_NAME(newNote(in:));
+ (nullable id)valueForKey:(NSString *)key ofObject:(id)object;
+ (BOOL)setValue:(nullable id)value forKey:(NSString *)key ofObject:(id)object error:(NSError **)error
    NS_SWIFT_NAME(setValue(_:forKey:of:));
+ (nullable id)paragraphStyle:(NSInteger)style indent:(NSInteger)indent quote:(NSInteger)quote checked:(NSInteger)checked
                       basedOn:(nullable id)existing error:(NSError **)error
    NS_SWIFT_NAME(paragraphStyle(_:indent:quote:checked:basedOn:));
+ (nullable id)fontWithName:(nullable NSString *)name size:(nullable NSNumber *)size hints:(NSInteger)hints
                    basedOn:(nullable id)existing error:(NSError **)error
    NS_SWIFT_NAME(font(name:size:hints:basedOn:));
+ (nullable NSData *)outlineStateDataWithCollapsedUUIDStrings:(NSArray<NSString *> *)identifiers error:(NSError **)error
    NS_SWIFT_NAME(outlineStateData(collapsedUUIDStrings:));
+ (nullable id)attachmentMarkerWithID:(NSString *)identifier type:(NSString *)type error:(NSError **)error
    NS_SWIFT_NAME(attachmentMarker(id:type:));
+ (nullable NSString *)markerID:(id)marker;
+ (nullable NSString *)markerType:(id)marker;
+ (nullable NSString *)makeTag:(NSString *)name inNote:(NSManagedObject *)note error:(NSError **)error
    NS_SWIFT_NAME(makeTag(_:in:));
+ (nullable NSString *)makeNoteLinkTo:(NSManagedObject *)target from:(NSManagedObject *)source text:(NSString *)text error:(NSError **)error
    NS_SWIFT_NAME(makeNoteLink(to:from:text:));
+ (nullable NSString *)addFile:(NSURL *)file toNote:(NSManagedObject *)note title:(NSString *)title
                           type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(addFile(_:to:title:type:));
+ (nullable NSString *)addURL:(NSURL *)url toNote:(NSManagedObject *)note
                          type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(addURL(_:to:type:));
+ (BOOL)setPreferredImageSize:(NSString *)size attachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(setPreferredImageSize(_:attachment:));
+ (BOOL)renameTag:(NSManagedObject *)tag to:(NSString *)name error:(NSError **)error NS_SWIFT_NAME(renameTag(_:to:));
+ (BOOL)reviveTagAttachment:(NSManagedObject *)attachment error:(NSError **)error NS_SWIFT_NAME(reviveTagAttachment(_:));
+ (BOOL)markForDeletion:(NSManagedObject *)object error:(NSError **)error NS_SWIFT_NAME(markForDeletion(_:));
+ (BOOL)unmarkForDeletion:(NSManagedObject *)object error:(NSError **)error NS_SWIFT_NAME(unmarkForDeletion(_:));
+ (BOOL)setPinned:(BOOL)pinned note:(NSManagedObject *)note error:(NSError **)error NS_SWIFT_NAME(setPinned(_:note:));
+ (BOOL)moveFolder:(NSManagedObject *)folder parent:(nullable NSManagedObject *)parent error:(NSError **)error
    NS_SWIFT_NAME(moveFolder(_:parent:));
+ (nullable NSString *)createSmartFolder:(NSString *)name tags:(NSArray<NSManagedObject *> *)tags matchAll:(BOOL)matchAll
                                  account:(NSManagedObject *)account error:(NSError **)error
    NS_SWIFT_NAME(createSmartFolder(_:tags:matchAll:account:));
+ (BOOL)renameFolder:(NSManagedObject *)folder name:(NSString *)name error:(NSError **)error
    NS_SWIFT_NAME(renameFolder(_:name:));
+ (nullable NSManagedObject *)duplicateNote:(NSManagedObject *)note folder:(NSManagedObject *)folder error:(NSError **)error
    NS_SWIFT_NAME(duplicateNote(_:folder:));
+ (BOOL)saveContext:(NSManagedObjectContext *)context error:(NSError **)error NS_SWIFT_NAME(save(_:));
+ (nullable NSNumber *)checkedIntegerSelector:(NSString *)selector ofObject:(id)object error:(NSError **)error
    NS_SWIFT_NAME(checkedInteger(_:of:));
+ (BOOL)requireInstanceSelectors:(NSArray<NSString *> *)selectors className:(NSString *)className error:(NSError **)error
    NS_SWIFT_NAME(requireInstanceSelectors(_:className:));
+ (BOOL)requireSelectors:(NSArray<NSString *> *)selectors ofObject:(id)object error:(NSError **)error
    NS_SWIFT_NAME(requireSelectors(_:of:));
@end

@interface NCBodyEditor : NSObject
- (nullable instancetype)initWithNote:(NSManagedObject *)note error:(NSError **)error;
@property(nonatomic, readonly) NSAttributedString *original;
- (BOOL)begin:(NSError **)error NS_SWIFT_NAME(begin());
- (BOOL)prepareWithOperations:(NSArray<NSString *> *)operations error:(NSError **)error NS_SWIFT_NAME(prepare(_:));
- (BOOL)beginWithOperations:(NSArray<NSString *> *)operations error:(NSError **)error NS_SWIFT_NAME(begin(_:));
- (BOOL)insert:(NSAttributedString *)text at:(NSUInteger)index error:(NSError **)error NS_SWIFT_NAME(insert(_:at:));
- (BOOL)deleteRange:(NSRange)range error:(NSError **)error NS_SWIFT_NAME(delete(_:));
- (BOOL)setAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes range:(NSRange)range error:(NSError **)error
    NS_SWIFT_NAME(setAttributes(_:range:));
- (nullable NSString *)addTable:(NSString *)tabSeparatedText error:(NSError **)error NS_SWIFT_NAME(addTable(_:));
- (BOOL)finish:(NSError **)error NS_SWIFT_NAME(finish());
@end

@interface NCTableEditor : NSObject
- (nullable instancetype)initWithAttachment:(NSManagedObject *)attachment error:(NSError **)error;
- (nullable NSNumber *)rowCount:(NSError **)error NS_SWIFT_NAME(rowCount());
- (nullable NSNumber *)columnCount:(NSError **)error NS_SWIFT_NAME(columnCount());
- (nullable NSString *)textAtColumn:(NSInteger)column row:(NSInteger)row error:(NSError **)error NS_SWIFT_NAME(text(column:row:));
- (BOOL)insertRow:(NSInteger)index error:(NSError **)error;
- (BOOL)removeRow:(NSInteger)index error:(NSError **)error;
- (BOOL)insertColumn:(NSInteger)index error:(NSError **)error;
- (BOOL)removeColumn:(NSInteger)index error:(NSError **)error;
- (BOOL)setCellColumn:(NSInteger)column row:(NSInteger)row text:(NSString *)text style:(id)style error:(NSError **)error
    NS_SWIFT_NAME(setCell(column:row:text:style:));
- (BOOL)save:(NSError **)error NS_SWIFT_NAME(save());
@end

NS_ASSUME_NONNULL_END
