#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NCPreparedScan : NSObject
@property(nonatomic, readonly) NSUInteger pageCount;
- (void)invalidate;
@end

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
+ (nullable id)paragraphStyle:(NSInteger)style indent:(NSInteger)indent quote:(NSInteger)quote checked:(NSInteger)checked
                 startNumber:(NSInteger)startNumber basedOn:(nullable id)existing error:(NSError **)error
    NS_SWIFT_NAME(paragraphStyle(_:indent:quote:checked:startNumber:basedOn:));
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
+ (nullable NSString *)makeTag:(NSString *)name inNote:(NSManagedObject *)note parent:(nullable NSManagedObject *)parent error:(NSError **)error
    NS_SWIFT_NAME(makeTag(_:in:parent:));
+ (nullable NSString *)makeNoteLinkTo:(NSManagedObject *)target from:(NSManagedObject *)source text:(NSString *)text error:(NSError **)error
    NS_SWIFT_NAME(makeNoteLink(to:from:text:));
+ (nullable NSString *)makeNoteLinkTo:(NSManagedObject *)target from:(NSManagedObject *)source text:(NSString *)text
                                parent:(nullable NSManagedObject *)parent error:(NSError **)error
    NS_SWIFT_NAME(makeNoteLink(to:from:text:parent:));
+ (nullable NSString *)makeParagraphLinkTo:(NSManagedObject *)target paragraphName:(nullable NSString *)paragraphName
                               paragraphID:(NSUUID *)paragraphID from:(NSManagedObject *)source text:(NSString *)text
                                    parent:(nullable NSManagedObject *)parent error:(NSError **)error
    NS_SWIFT_NAME(makeParagraphLink(to:paragraphName:paragraphID:from:text:parent:));
+ (BOOL)applyParagraphID:(nullable NSUUID *)paragraphID checklistID:(nullable NSUUID *)checklistID
                 checked:(NSInteger)checked toStyle:(id)style error:(NSError **)error
    NS_SWIFT_NAME(applyParagraphID(_:checklistID:checked:to:));
+ (nullable NSString *)makeDividerInNote:(NSManagedObject *)note type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(makeDivider(in:type:));
+ (nullable NSString *)makeDividerInNote:(NSManagedObject *)note parent:(nullable NSManagedObject *)parent
                                    type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(makeDivider(in:parent:type:));
+ (nullable NSString *)makeMathExpression:(NSString *)expression inNote:(NSManagedObject *)note
                                      type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(makeMathExpression(_:in:type:));
+ (nullable NSString *)makeMathExpression:(NSString *)expression inNote:(NSManagedObject *)note
                                    parent:(nullable NSManagedObject *)parent
                                      type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(makeMathExpression(_:in:parent:type:));
+ (nullable NSString *)makeMention:(NSString *)text userRecordName:(NSString *)userRecordName inNote:(NSManagedObject *)note
                               type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(makeMention(_:userRecordName:in:type:));
+ (nullable NSString *)makeMention:(NSString *)text userRecordName:(NSString *)userRecordName inNote:(NSManagedObject *)note
                             parent:(nullable NSManagedObject *)parent
                               type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(makeMention(_:userRecordName:in:parent:type:));
+ (nullable NSString *)allMentionUserRecordName:(NSError **)error NS_SWIFT_NAME(allMentionUserRecordName());
+ (nullable NSString *)addFile:(NSURL *)file toNote:(NSManagedObject *)note title:(NSString *)title
                           type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(addFile(_:to:title:type:));
+ (nullable NSString *)addFile:(NSURL *)file toNote:(NSManagedObject *)note title:(NSString *)title
                        typeUTI:(NSString *)typeUTI filename:(NSString *)filename
                   resultingType:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(addFile(_:to:title:typeUTI:filename:resultingType:));
+ (nullable NSURL *)mediaFileURLForAttachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(mediaFileURL(for:));
+ (nullable NSArray<NSString *> *)transformAudioAttachment:(NSManagedObject *)attachment duration:(double)duration
                                                     error:(NSError **)error
    NS_SWIFT_NAME(transformAudioAttachment(_:duration:));
+ (nullable NSDictionary<NSString *, id> *)createRecordingInNote:(NSManagedObject *)note
                                                       fragments:(NSArray<NSDictionary<NSString *, id> *> *)fragments
                                                           title:(nullable NSString *)title duration:(double)duration
                                                           error:(NSError **)error
    NS_SWIFT_NAME(createRecording(in:fragments:title:duration:));
+ (nullable NSNumber *)appendTranscriptSegments:(NSArray<NSDictionary<NSString *, id> *> *)segments
                              toAudioAttachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(appendTranscriptSegments(_:toAudioAttachment:));
+ (BOOL)applyRecordingMetadata:(NSDictionary<NSString *, id> *)metadata
             toAudioAttachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(applyRecordingMetadata(_:toAudioAttachment:));
+ (BOOL)deleteRecordingSummaryForAttachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(deleteRecordingSummary(for:));
+ (nullable NSString *)addURL:(NSURL *)url toNote:(NSManagedObject *)note
                          type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(addURL(_:to:type:));
+ (nullable NSString *)addSynapseLink:(NSURL *)url title:(NSString *)title toNote:(NSManagedObject *)note
                                 type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(addSynapseLink(_:title:to:type:));
+ (nullable NSString *)synapseWebSourceIdentifier:(NSError **)error NS_SWIFT_NAME(synapseWebSourceIdentifier());
+ (nullable NSDictionary<NSString *, id> *)synapseLinkInfoForAttachment:(NSManagedObject *)attachment
                                                                  error:(NSError **)error
    NS_SWIFT_NAME(synapseLinkInfo(for:));
+ (nullable NSString *)addSystemPaperDrawing:(id)drawing toNote:(NSManagedObject *)note
                                      type:(NSString *_Nullable *_Nonnull)type error:(NSError **)error
    NS_SWIFT_NAME(addSystemPaperDrawing(_:to:type:));
+ (nullable NSArray *)systemPaperDrawingsForAttachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(systemPaperDrawings(for:));
+ (BOOL)setPreferredImageSize:(NSString *)size attachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(setPreferredImageSize(_:attachment:));
+ (BOOL)renameTag:(NSManagedObject *)tag to:(NSString *)name error:(NSError **)error NS_SWIFT_NAME(renameTag(_:to:));
+ (BOOL)reviveTagAttachment:(NSManagedObject *)attachment error:(NSError **)error NS_SWIFT_NAME(reviveTagAttachment(_:));
+ (BOOL)markForDeletion:(NSManagedObject *)object error:(NSError **)error NS_SWIFT_NAME(markForDeletion(_:));
+ (BOOL)unmarkForDeletion:(NSManagedObject *)object error:(NSError **)error NS_SWIFT_NAME(unmarkForDeletion(_:));
+ (BOOL)setPinned:(BOOL)pinned note:(NSManagedObject *)note error:(NSError **)error NS_SWIFT_NAME(setPinned(_:note:));
+ (BOOL)setSystemPaper:(BOOL)enabled note:(NSManagedObject *)note error:(NSError **)error NS_SWIFT_NAME(setSystemPaper(_:note:));
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
+ (BOOL)updateChangeCountOfObject:(id)object reason:(NSString *)reason error:(NSError **)error
    NS_SWIFT_NAME(updateChangeCount(of:reason:));
+ (BOOL)checklistAutoSortEnabled;
+ (BOOL)setChecklistAutoSortEnabled:(BOOL)enabled error:(NSError **)error NS_SWIFT_NAME(setChecklistAutoSort(_:));
+ (nullable id)folderSortTypeWithOrder:(NSInteger)order direction:(NSInteger)direction error:(NSError **)error
    NS_SWIFT_NAME(folderSortType(order:direction:));
+ (nullable NSString *)storedDefaultAccountIdentifier:(NSError **)error NS_SWIFT_NAME(storedDefaultAccountIdentifier());
+ (nullable NSString *)frameworkDefaultAccountIdentifier:(NSError **)error NS_SWIFT_NAME(frameworkDefaultAccountIdentifier());
+ (nullable NSDictionary<NSString *, id> *)notesPreferencesInApplicationDomain:(BOOL)application error:(NSError **)error
    NS_SWIFT_NAME(notesPreferences(inApplicationDomain:));
+ (nullable NSDictionary<NSString *, id> *)shadowNotesGroupPreferences:(NSError **)error NS_SWIFT_NAME(shadowNotesGroupPreferences());
+ (BOOL)setNotesPreference:(NSString *)key integerValue:(NSInteger)value inApplicationDomain:(BOOL)application error:(NSError **)error
    NS_SWIFT_NAME(setNotesPreference(_:integerValue:inApplicationDomain:));
+ (BOOL)removeNotesPreference:(NSString *)key inApplicationDomain:(BOOL)application error:(NSError **)error
    NS_SWIFT_NAME(removeNotesPreference(_:inApplicationDomain:));
+ (BOOL)setDefaultAccountIdentifier:(NSString *)identifier error:(NSError **)error NS_SWIFT_NAME(setDefaultAccountIdentifier(_:));
+ (nullable NSNumber *)noteDefaultNamedStyle:(NSError **)error NS_SWIFT_NAME(noteDefaultNamedStyle());
+ (BOOL)setNoteDefaultNamedStyle:(NSUInteger)style error:(NSError **)error NS_SWIFT_NAME(setNoteDefaultNamedStyle(_:));
+ (nullable NSNumber *)currentNoteListSortType:(NSError **)error NS_SWIFT_NAME(currentNoteListSortType());
+ (BOOL)setCurrentNoteListSortType:(NSInteger)type error:(NSError **)error NS_SWIFT_NAME(setCurrentNoteListSortType(_:));
+ (nullable NSNumber *)defaultDateHeadersType:(NSError **)error NS_SWIFT_NAME(defaultDateHeadersType());
+ (BOOL)setDefaultDateHeadersType:(NSInteger)type error:(NSError **)error NS_SWIFT_NAME(setDefaultDateHeadersType(_:));
+ (nullable NSNumber *)globalZoomFactorIndex:(NSError **)error NS_SWIFT_NAME(globalZoomFactorIndex());
+ (BOOL)setGlobalZoomFactorIndex:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(setGlobalZoomFactorIndex(_:));
+ (nullable NSNumber *)shouldResumeLastQuickNote:(NSError **)error NS_SWIFT_NAME(shouldResumeLastQuickNote());
+ (BOOL)setShouldResumeLastQuickNote:(BOOL)enabled error:(NSError **)error NS_SWIFT_NAME(setShouldResumeLastQuickNote(_:));
+ (nullable NSNumber *)shouldAutoConvertToTag:(NSError **)error NS_SWIFT_NAME(shouldAutoConvertToTag());
+ (BOOL)setShouldAutoConvertToTag:(BOOL)enabled error:(NSError **)error NS_SWIFT_NAME(setShouldAutoConvertToTag(_:));
+ (nullable NSDictionary<NSString *, NSString *> *)evaluateMathExpression:(NSString *)expression error:(NSError **)error
    NS_SWIFT_NAME(evaluateMathExpression(_:));
+ (BOOL)applyDateHeadersType:(NSInteger)type toFolder:(NSManagedObject *)folder error:(NSError **)error
    NS_SWIFT_NAME(applyDateHeadersType(_:to:));
+ (nullable NSDictionary<NSString *, id> *)addLocationToMapAttachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(addLocation(toMapAttachment:));
+ (nullable NCPreparedScan *)prepareScanImageURLs:(NSArray<NSURL *> *)urls error:(NSError **)error
    NS_SWIFT_NAME(prepareScan(imageURLs:));
+ (BOOL)validateScanPopulation:(NCPreparedScan *)preparation error:(NSError **)error
    NS_SWIFT_NAME(validateScanPopulation(_:));
+ (nullable NSManagedObject *)newScanGalleryInNote:(NSManagedObject *)note identifier:(NSString *)identifier error:(NSError **)error
    NS_SWIFT_NAME(newScanGallery(in:identifier:));
+ (nullable NSArray<NSString *> *)galleryPageIdentifiers:(NSManagedObject *)gallery error:(NSError **)error
    NS_SWIFT_NAME(galleryPageIdentifiers(in:));
+ (BOOL)validateScanEditing:(NSError **)error NS_SWIFT_NAME(validateScanEditing());
+ (BOOL)applyScanFilter:(short)filter pageIdentifier:(NSString *)pageIdentifier gallery:(NSManagedObject *)gallery
                   error:(NSError **)error NS_SWIFT_NAME(applyScanFilter(_:pageIdentifier:gallery:));
+ (BOOL)setScanMarkupData:(NSData *)data pageIdentifier:(NSString *)pageIdentifier gallery:(NSManagedObject *)gallery
                     error:(NSError **)error NS_SWIFT_NAME(setScanMarkupData(_:pageIdentifier:gallery:));
+ (nullable NSData *)scanRectangleMarkupDataWithX:(double)x y:(double)y width:(double)width height:(double)height
                                      strokeWidth:(double)strokeWidth error:(NSError **)error
    NS_SWIFT_NAME(scanRectangleMarkupData(x:y:width:height:strokeWidth:));
+ (nullable NSData *)attachmentMarkupDataByAddingType:(NSString *)type
                                                data:(nullable NSData *)data
                                                   x:(double)x y:(double)y width:(double)width height:(double)height
                                                text:(nullable NSString *)text
                                              points:(nullable NSArray<NSNumber *> *)points
                                         strokeWidth:(double)strokeWidth
                                               color:(NSString *)color
                                               error:(NSError **)error
    NS_SWIFT_NAME(attachmentMarkupData(adding:data:x:y:width:height:text:points:strokeWidth:color:));
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)attachmentMarkupAnnotationsInData:(NSData *)data
                                                                                  error:(NSError **)error
    NS_SWIFT_NAME(attachmentMarkupAnnotations(data:));
+ (nullable NSData *)attachmentMarkupDataByRemovingIdentifier:(NSString *)identifier
                                                         data:(NSData *)data
                                                        error:(NSError **)error
    NS_SWIFT_NAME(attachmentMarkupData(removing:data:));
+ (nullable NSData *)renderAttachmentMarkupData:(NSData *)data
                                    baseImageURL:(NSURL *)baseImageURL
                                           error:(NSError **)error
    NS_SWIFT_NAME(renderAttachmentMarkup(data:baseImageURL:));
+ (nullable NSData *)embeddedAttachmentMarkupDataAtURL:(NSURL *)url error:(NSError **)error
    NS_SWIFT_NAME(embeddedAttachmentMarkupData(at:));
+ (nullable NSData *)attachmentImageDataByEmbeddingMarkupData:(nullable NSData *)data
                                                  baseImageURL:(NSURL *)baseImageURL
                                                         error:(NSError **)error
    NS_SWIFT_NAME(attachmentImageData(embedding:baseImageURL:));
+ (BOOL)replaceAttachmentMediaWithURL:(NSURL *)url filename:(NSString *)filename
                            attachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(replaceAttachmentMedia(url:filename:attachment:));
+ (BOOL)setScanOrientation:(NSInteger)orientation pageIdentifier:(NSString *)pageIdentifier gallery:(NSManagedObject *)gallery
                      error:(NSError **)error NS_SWIFT_NAME(setScanOrientation(_:pageIdentifier:gallery:));
+ (BOOL)moveScanPage:(NSString *)pageIdentifier toIndex:(NSUInteger)index gallery:(NSManagedObject *)gallery
                error:(NSError **)error NS_SWIFT_NAME(moveScanPage(_:toIndex:gallery:));
+ (BOOL)setScanCropBottomLeftX:(double)bottomLeftX bottomLeftY:(double)bottomLeftY
                  bottomRightX:(double)bottomRightX bottomRightY:(double)bottomRightY
                      topLeftX:(double)topLeftX topLeftY:(double)topLeftY
                     topRightX:(double)topRightX topRightY:(double)topRightY
                pageIdentifier:(NSString *)pageIdentifier gallery:(NSManagedObject *)gallery
                          error:(NSError **)error
    NS_SWIFT_NAME(setScanCrop(bottomLeftX:bottomLeftY:bottomRightX:bottomRightY:topLeftX:topLeftY:topRightX:topRightY:pageIdentifier:gallery:));
+ (BOOL)deleteScanPage:(NSString *)pageIdentifier gallery:(NSManagedObject *)gallery error:(NSError **)error
    NS_SWIFT_NAME(deleteScanPage(_:gallery:));
+ (BOOL)deleteScanPages:(NSArray<NSString *> *)pageIdentifiers gallery:(NSManagedObject *)gallery error:(NSError **)error
    NS_SWIFT_NAME(deleteScanPages(_:gallery:));
+ (BOOL)undeleteScanPage:(NSManagedObject *)page pageIdentifier:(NSString *)pageIdentifier
                 toIndex:(NSUInteger)index gallery:(NSManagedObject *)gallery error:(NSError **)error
    NS_SWIFT_NAME(undeleteScanPage(_:pageIdentifier:toIndex:gallery:));
+ (nullable NSDictionary<NSString *, id> *)populateScanGallery:(NSManagedObject *)gallery preparation:(NCPreparedScan *)preparation
                                                       context:(NSManagedObjectContext *)context error:(NSError **)error
    NS_SWIFT_NAME(populateScanGallery(_:preparation:context:));
+ (nullable NSDictionary<NSString *, NSString *> *)recognizeTextInImageAtURL:(NSURL *)url
                                                                    languages:(nullable NSArray<NSString *> *)languages
                                                                        title:(nullable NSString *)title
                                                                        error:(NSError **)error
    NS_SWIFT_NAME(recognizeText(in:languages:title:));
+ (nullable NSDictionary<NSString *, id> *)recognizeHandwritingInAttachment:(NSManagedObject *)attachment
                                                                      locale:(NSString *)locale
                                                                       error:(NSError **)error
    NS_SWIFT_NAME(recognizeHandwriting(in:locale:));
+ (BOOL)setHandwritingSummary:(nullable NSString *)summary attachment:(NSManagedObject *)attachment
                         error:(NSError **)error
    NS_SWIFT_NAME(setHandwritingSummary(_:attachment:));
+ (BOOL)setOCRSummary:(nullable NSString *)summary version:(NSInteger)version attachment:(NSManagedObject *)attachment
                 error:(NSError **)error
    NS_SWIFT_NAME(setOCRSummary(_:version:attachment:));
+ (BOOL)setImageClassificationSummary:(nullable NSString *)summary version:(NSInteger)version
                             attachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(setImageClassificationSummary(_:version:attachment:));
+ (nullable NSDictionary<NSString *, id> *)regenerateFallbackPDFForAttachment:(NSManagedObject *)attachment
                                                                         error:(NSError **)error
    NS_SWIFT_NAME(regenerateFallbackPDF(for:));
+ (nullable NSData *)archivePaperBundleForAttachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(archivePaperBundle(for:));
+ (BOOL)restorePaperBundleArchive:(NSData *)archive attachment:(NSManagedObject *)attachment
                            error:(NSError **)error
    NS_SWIFT_NAME(restorePaperBundle(_:attachment:));
+ (nullable NSString *)addPaperDocumentAtURL:(NSURL *)url subtype:(NSString *)subtype
                                  identifier:(NSString *)identifier toNote:(NSManagedObject *)note
                                        type:(NSString * _Nullable * _Nullable)type
                                       error:(NSError **)error
    NS_SWIFT_NAME(addPaperDocument(at:subtype:identifier:to:type:));
+ (nullable NSString *)addPaperDocumentArchive:(NSData *)archive subtype:(NSString *)subtype
                                     identifier:(NSString *)identifier toNote:(NSManagedObject *)note
                                           type:(NSString * _Nullable * _Nullable)type
                                          error:(NSError **)error
    NS_SWIFT_NAME(addPaperDocument(archive:subtype:identifier:to:type:));
+ (nullable NSString *)addSystemPaperArchive:(NSData *)archive identifier:(NSString *)identifier
                                      toNote:(NSManagedObject *)note
                                        type:(NSString * _Nullable * _Nullable)type error:(NSError **)error
    NS_SWIFT_NAME(addSystemPaper(archive:identifier:to:type:));
+ (nullable NSURL *)paperBundleURLForIdentifier:(NSString *)identifier account:(NSManagedObject *)account
                                           error:(NSError **)error
    NS_SWIFT_NAME(paperBundleURL(identifier:account:));
+ (nullable NSURL *)paperBundlesDirectoryURLForAccount:(NSManagedObject *)account error:(NSError **)error
    NS_SWIFT_NAME(paperBundlesDirectoryURL(account:));
+ (nullable NSArray<NSURL *> *)paperFileURLsForIdentifier:(NSString *)identifier account:(NSManagedObject *)account
                                                   error:(NSError **)error
    NS_SWIFT_NAME(paperFileURLs(identifier:account:));
+ (BOOL)purgePaperFilesForIdentifier:(NSString *)identifier account:(NSManagedObject *)account
                                error:(NSError **)error
    NS_SWIFT_NAME(purgePaperFiles(identifier:account:));
@end

@interface NCNotesRuntime (LegacyDrawing)
+ (nullable NSData *)legacyDrawingStrokesForAttachment:(NSManagedObject *)attachment error:(NSError **)error
    NS_SWIFT_NAME(legacyDrawingStrokes(for:));
+ (nullable NSString *)addLegacyDrawingWithStrokesData:(NSData *)data toNote:(NSManagedObject *)note
                                                   type:(NSString * _Nullable * _Nullable)type
                                                  error:(NSError **)error
    NS_SWIFT_NAME(addLegacyDrawing(strokesData:to:type:));
@end

@interface NCBodyEditor : NSObject
- (nullable instancetype)initWithNote:(NSManagedObject *)note error:(NSError **)error;
@property(nonatomic, readonly) NSAttributedString *original;
- (BOOL)begin:(NSError **)error NS_SWIFT_NAME(begin());
- (BOOL)prepareWithOperations:(NSArray<NSString *> *)operations error:(NSError **)error NS_SWIFT_NAME(prepare(_:));
- (BOOL)beginWithOperations:(NSArray<NSString *> *)operations error:(NSError **)error NS_SWIFT_NAME(begin(_:));
- (BOOL)insert:(NSAttributedString *)text at:(NSUInteger)index error:(NSError **)error NS_SWIFT_NAME(insert(_:at:));
- (BOOL)deleteRange:(NSRange)range error:(NSError **)error NS_SWIFT_NAME(delete(_:));
- (BOOL)replaceRange:(NSRange)range withText:(NSAttributedString *)text error:(NSError **)error
    NS_SWIFT_NAME(replace(_:with:));
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
- (nullable NSAttributedString *)attributedTextAtColumn:(NSInteger)column row:(NSInteger)row error:(NSError **)error
    NS_SWIFT_NAME(attributedText(column:row:));
- (BOOL)insertRow:(NSInteger)index error:(NSError **)error;
- (BOOL)removeRow:(NSInteger)index error:(NSError **)error;
- (BOOL)insertColumn:(NSInteger)index error:(NSError **)error;
- (BOOL)removeColumn:(NSInteger)index error:(NSError **)error;
- (BOOL)reverseColumnDirection:(NSError **)error NS_SWIFT_NAME(reverseColumnDirection());
- (BOOL)setCellColumn:(NSInteger)column row:(NSInteger)row text:(NSString *)text style:(id)style error:(NSError **)error
    NS_SWIFT_NAME(setCell(column:row:text:style:));
- (BOOL)setAttributedCellColumn:(NSInteger)column row:(NSInteger)row text:(NSAttributedString *)text error:(NSError **)error
    NS_SWIFT_NAME(setAttributedCell(column:row:text:));
- (BOOL)save:(NSError **)error NS_SWIFT_NAME(save());
@end

NS_ASSUME_NONNULL_END
