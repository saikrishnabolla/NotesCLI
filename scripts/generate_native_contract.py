#!/usr/bin/env python3
"""Generate the private Notes runtime inventory from native source literals."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Sources/NotesNative/NativeContract.generated.swift"
SOURCE_GLOBS = (
    "Sources/NotesNativeObjC/*.m",
    "Sources/NotesNativeObjC/*.mm",
    "Sources/NotesNative/*.swift",
)

PROTOCOL_OWNERS = {
    "NCNoteContextClass": ("ICNoteContext", True),
    "NCNoteContext": ("ICNoteContext", False),
    "NCNote": ("ICNote", False),
    "NCNoteClass": ("ICNote", True),
    "NCMergeable": ("NotesShared.ICTTMergeableAttributedString", False),
    "NCParagraph": ("ICTTParagraphStyle", False),
    "NCTodo": ("ICTTTodo", False),
    "NCInlineClass": ("ICInlineAttachment", True),
    "NCTableModel": ("ICAttachmentTableModel", False),
    "NCTable": ("ICTable", False),
    "NCScanEditor": ("ICDocCamScannedDocumentEditor", False),
    "NCGalleryModel": ("ICAttachmentGalleryModel", False),
    "NCImageQuad": ("ICDocCamImageQuad", False),
}

FEATURE_OWNER_CLASSES = {
    "dividers": ["ICInlineAttachment"],
    "sectionLinks": ["ICTTParagraphStyle"],
    "core": ["ICNote", "ICNoteContext", "ICAttachment", "ICFolder", "ICInlineAttachment",
             "ICTTMergeableAttributedString", "NSMutableAttributedString", "SYContentItem"],
    "tags": ["ICHashtag", "ICHashtagController", "ICInlineAttachment", "ICNote", "ICTagSelection"],
    "tables": ["ICAttachmentTableModel", "ICTable", "ICNote", "ICTTMergeableAttributedString"],
    "scans": ["ICAttachment", "ICAttachmentGalleryModel", "ICDocCamScannedDocumentEditor",
              "ICDocCamImageCache", "ICDocCamDocumentInfo", "ICDocCamImageQuad",
              "ICGalleryAttachmentUtilities"],
    "markup": ["AKController", "AKModelController", "AKPageModelController", "AKRectAnnotation",
               "AKArrowAnnotation", "AKDoodleAnnotation", "AKHighlightAnnotation", "MUImageReader", "MUImageWriter"],
    "links": ["ICNote", "ICAttachment", "ICInlineAttachment", "SYContentItem"],
    "recordings": ["ICAttachment", "ICAttachmentAudioModel", "ICTTMergeableAttributedString",
                   "NotesShared.ICTTTranscriptSegment"],
    "paper": ["ICAttachment", "ICAttachmentDrawingModel", "ICAttachmentPaperBundleModel", "ICDrawing",
              "ICPaperAttachmentCreationHelper", "ICSystemPaperDrawingsHelper", "CHDrawing", "CHRecognizer",
              "PKDrawing", "PKStroke", "PKStrokePath"],
}

SELECTOR_OWNER_OVERRIDES: dict[tuple[str, str], tuple[list[str], bool | None] | None] = {
    ("attributedString", "core"): (["ICTTMergeableString"], False),
    ("beginEditing", "core"): (["ICNote", "ICTTMergeableString", "ICTTMergeableAttributedString"], False),
    ("deleteCharactersInRange:", "core"): (["ICTTMergeableString", "ICTTMergeableAttributedString"], False),
    ("endEditing", "core"): (["ICNote", "ICTTMergeableString", "ICTTMergeableAttributedString"], False),
    ("insertAttributedString:atIndex:", "core"): (["ICTTMergeableString"], False),
    ("insertString:atIndex:", "core"): (["ICTTMergeableString", "ICTTMergeableAttributedString"], False),
    ("replaceCharactersInRange:withAttributedString:", "core"): (["ICTTMergeableString", "ICTTMergeableAttributedString"], False),
    ("replaceCharactersInRange:withString:", "core"): (["ICTTMergeableString", "ICTTMergeableAttributedString"], False),
    ("setAttributes:range:", "core"): (["ICTTMergeableAttributedString"], False),
    ("boolValue", "core"): (["NSNumber"], False),
    ("generateFallbackPDFDataForAttachment:", "core"): (["ICAttachmentPaperBundleModel"], True),
    ("ocrStringFromImageURL:title:languages:", "core"): (["ICOCRGenerator"], True),
    ("boolValue", "tags"): (["NSNumber"], False),
    ("objc_queryForNotesMatchingTagSelection:", "tags"): (["ICQueryObjC"], True),
    ("objc_smartFolderWithQuery:account:", "tags"): (["ICFolder"], True),
    ("containsObject:", "tables"): (["NSArray", "NSSet"], False),
    ("ic_convertParagraphStyleToBodyInRange:", "tables"): None,
    ("UUIDString", "markup"): (["NSUUID"], False),
    ("addMediaWithURL:filename:updateFileBasedAttributes:", "markup"): (["ICAttachment"], False),
    ("bounds", "markup"): (["NSBezierPath"], False),
    ("deletePDFForAttachmentIfExists:", "markup"): (["ICDocCamPDFGenerator"], True),
    ("invalidateAttachmentPreviewImages", "markup"): (["ICAttachment"], False),
    ("lineToPoint:", "markup"): (["NSBezierPath"], False),
    ("moveToPoint:", "markup"): (["NSBezierPath"], False),
    ("string", "markup"): (["NSAttributedString"], False),
    ("addObject:", "recordings"): (["NSMutableArray"], False),
    ("compare:", "recordings"): (["NSString"], False),
    ("setCallType:", "recordings"): (["ICTTAudioDocument"], False),
    ("setIsCallRecording:", "recordings"): (["ICTTAudioDocument"], False),
    ("addAttachmentWithUTI:", "paper"): (["ICNote"], False),
    ("addPaperDocumentAttachmentWithIdentifier:subtype:", "paper"): (["ICNote"], False),
    ("addSystemPaperAttachmentWithIdentifier:", "paper"): (["ICNote"], False),
    ("color", "paper"): (["ICDrawingCommandData"], False),
    ("identifier", "paper"): (["NFAttachment"], False),
    ("markAsSystemPaperIfNeeded:", "paper"): (["ICNote"], False),
    ("newDrawingFromMergeableData", "paper"): (["ICAttachmentInlineDrawingModel"], False),
    ("rawTranscription", "paper"): (["CHTokenizedTextResult"], False),
    ("score", "paper"): (["CHTokenizedTextResult"], False),
    ("setColor:", "paper"): (["ICDrawingCommandData"], False),
    ("systemPaperBundlesDirectoryURL", "paper"): (["ICAccount"], False),
    ("topModelTranscription", "paper"): (["CHTokenizedTextResult"], False),
    ("topTranscription", "paper"): (["CHTokenizedTextResult"], False),
    ("typeUTI", "paper"): (["NFAttachment"], False),
}


def feature(text: str) -> str:
    value = text.lower()
    if value.startswith(("newdividerlineattachmentwithidentifier:",
                         "icinlineattachmentnewdividerlineattachmentwithidentifier:")):
        return "dividers"
    if value.startswith("supportssectionlinks"):
        return "sectionLinks"
    if any(word in value for word in ("annotation", "markup", "muimage")):
        return "markup"
    if any(word in value for word in ("synapse", "richlink", "linkattachment", "urlattachment", "linkpreview")):
        return "links"
    if any(word in value for word in ("doccam", "scan", "gallery", "quad")):
        return "scans"
    if any(word in value for word in ("paper", "drawing", "stroke", "pencil", "handwriting", "sketch")):
        return "paper"
    if any(word in value for word in ("audio", "recording", "transcript", "fragment")):
        return "recordings"
    if any(word in value for word in ("table", "column", "rowindex", "rowcount")):
        return "tables"
    if "hashtag" in value or re.search(r"\btag(?:s|ged)?\b", value):
        return "tags"
    return "core"


def source_files() -> list[Path]:
    return sorted({path for pattern in SOURCE_GLOBS for path in ROOT.glob(pattern)})


def source_context(source: str, start: int, end: int, relative: str) -> str:
    prefix = source[:start]
    signatures = list(re.finditer(
        r'(?m)^(?:\s*[+-]\s*\([^\n]+|\s*(?:public\s+|private\s+|fileprivate\s+|internal\s+)?func\s+[^\n]+)',
        prefix,
    ))
    signature = signatures[-1].group(0) if signatures else ""
    local = source[max(0, start - 300):min(len(source), end + 300)]
    return signature + local + relative


def add_feature(rows: dict[str, set[str]], name: str, owner: str) -> None:
    rows.setdefault(name, set()).add(owner)


def message_selector(source: str, start: int, end: int) -> str:
    tail = source[end:end + 500]
    call = re.match(
        r'\s*\(\s*[^,\n]+,\s*(?:'
        r'NSSelectorFromString\(@"([^"]+)"\)|'
        r'sel_registerName\("([^"]+)"\)|'
        r'@selector\(([^)]+)\)|'
        r'([A-Za-z_][A-Za-z0-9_]*))',
        tail,
    )
    if not call:
        return "<dynamic>"
    direct = next((value for value in call.groups()[:3] if value), None)
    if direct:
        return direct
    variable = call.group(4)
    prefix = source[max(0, start - 2500):start]
    assignments = list(re.finditer(
        rf'\bSEL\s+{re.escape(variable)}\s*=\s*NSSelectorFromString\(@"([^"]+)"\)',
        prefix,
    ))
    return assignments[-1].group(1) if assignments else f"<dynamic:{variable}>"


def objc_method_selector(declaration: str) -> str | None:
    tail = re.sub(r'^\s*[+-]\s*\([^)]*\)\s*', '', declaration.strip())
    pieces = re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*:', tail)
    if pieces:
        return ''.join(piece + ':' for piece in pieces)
    match = re.match(r'([A-Za-z_][A-Za-z0-9_]*)', tail)
    return match.group(1) if match else None


def selector_tables(source: str) -> list[tuple[str, str, bool]]:
    rows: list[tuple[str, str, bool]] = []
    for function, is_class_method in (("NCClassSelectors", True), ("NCInstanceSelectors", False)):
        body = re.search(
            rf'static\s+NSDictionary[^\n]+\*{function}\(void\)\s*\{{\s*return\s*@\{{(.*?)\n\s*\}};\s*\}}',
            source, re.S,
        )
        if not body:
            continue
        for entry in re.finditer(r'@"([^"]+)"\s*:\s*@\[(.*?)\](?=\s*,|\s*\n\s*\})', body.group(1), re.S):
            for selector in re.findall(r'@"([^"]+)"', entry.group(2)):
                rows.append((entry.group(1), selector, is_class_method))
    return rows


def inventory() -> dict[str, object]:
    selectors: dict[str, set[str]] = {}
    classes: dict[str, set[str]] = {}
    kvc: dict[str, set[str]] = {}
    ivars: dict[str, set[str]] = {}
    messages: list[dict[str, str | int]] = []
    selector_owners: dict[tuple[str, bool | None, str], set[str]] = {}

    for path in source_files():
        source = path.read_text()
        relative = str(path.relative_to(ROOT))
        for pattern in (
            r'NSSelectorFromString\(@"([^"]+)"\)',
            r'@selector\(([^)]+)\)',
            r'sel_registerName\("([^"]+)"\)',
        ):
            for match in re.finditer(pattern, source):
                name = match.group(1)
                add_feature(selectors, name, feature(name + source_context(source, match.start(), match.end(), relative)))

        if path.name == "NotesNativeObjC.m":
            for class_name, selector, is_class_method in selector_tables(source):
                owner_feature = feature(class_name + selector)
                add_feature(selectors, selector, owner_feature)
                add_feature(classes, class_name, owner_feature)
                selector_owners.setdefault((selector, is_class_method, owner_feature), set()).add(class_name)
            for protocol in re.finditer(r'@protocol\s+(\w+)(.*?)(?=@end)', source, re.S):
                owner = PROTOCOL_OWNERS.get(protocol.group(1))
                if not owner:
                    continue
                class_name, is_class_method = owner
                for declaration in re.findall(r'(?m)^\s*[+-]\s*\([^;]+;', protocol.group(2)):
                    selector = objc_method_selector(declaration)
                    if not selector:
                        continue
                    owner_feature = feature(class_name + selector)
                    add_feature(selectors, selector, owner_feature)
                    add_feature(classes, class_name, owner_feature)
                    selector_owners.setdefault((selector, is_class_method, owner_feature), set()).add(class_name)

        for match in re.finditer(r'NSClassFromString\(@"([^"]+)"\)', source):
            name = match.group(1)
            add_feature(classes, name, feature(name + source_context(source, match.start(), match.end(), relative)))
        for match in re.finditer(r'class_getInstanceVariable\([^,]+,\s*"([^"]+)"\)', source):
            name = match.group(1)
            add_feature(ivars, name, feature(name + source_context(source, match.start(), match.end(), relative)))
        for match in re.finditer(r'@"([A-Za-z_][A-Za-z0-9_.]+)"\s*:\s*@\[', source):
            name = match.group(1)
            add_feature(classes, name, feature(name + source_context(source, match.start(), match.end(), relative)))

        kvc_patterns = (
            r'valueForKey\s*:\s*@?"([A-Za-z_][A-Za-z0-9_]*)"',
            r'forKey\s*:\s*@"([A-Za-z_][A-Za-z0-9_]*)"',
            r'(?<!remove)\bvalue\([^\n]{0,120}?,\s*"([A-Za-z_][A-Za-z0-9_]*)"\)',
            r'\bsetValue\([^\n]{0,180}?forKey:\s*"([A-Za-z_][A-Za-z0-9_]*)"',
        )
        for pattern in kvc_patterns:
            for match in re.finditer(pattern, source):
                name = match.group(1)
                add_feature(kvc, name, feature(name + source_context(source, match.start(), match.end(), relative)))

        for match in re.finditer(r'\(\(([^;\n]{1,220}?\(\*\)\([^;\n]{1,220}?)\)objc_msgSend\)', source):
            signature = " ".join(match.group(1).split())
            selector = message_selector(source, match.start(), match.end())
            line = source.count("\n", 0, match.start()) + 1
            messages.append({
                "selector": selector,
                "signature": signature,
                "feature": feature(selector + source_context(source, match.start(), match.end(), relative)),
                "source": f"{relative}:{line}",
            })

    owned_selectors = {selector for selector, _, _ in selector_owners}
    for selector, features in selectors.items():
        if selector in owned_selectors:
            continue
        for owner_feature in features:
            owners = FEATURE_OWNER_CLASSES[owner_feature]
            selector_owners[(selector, None, owner_feature)] = set(owners)

    for (selector, owner_feature), override in SELECTOR_OWNER_OVERRIDES.items():
        for key in [key for key in selector_owners if key[0] == selector and key[2] == owner_feature]:
            del selector_owners[key]
        if override is None:
            continue
        owner_names, is_class_method = override
        selector_owners[(selector, is_class_method, owner_feature)] = set(owner_names)
        for class_name in owner_names:
            add_feature(classes, class_name, owner_feature)

    payload = {
        "selectors": {key: sorted(value) for key, value in sorted(selectors.items())},
        "classes": {key: sorted(value) for key, value in sorted(classes.items())},
        "kvc": {key: sorted(value) for key, value in sorted(kvc.items())},
        "ivars": {key: sorted(value) for key, value in sorted(ivars.items())},
        "selectorOwners": [
            {"selector": selector, "classNames": sorted(class_names),
             "isClassMethod": is_class_method, "feature": owner_feature}
            for (selector, is_class_method, owner_feature), class_names in sorted(
                selector_owners.items(), key=lambda row: (row[0][0], str(row[0][1]), row[0][2]))
        ],
        "objcMessages": sorted(messages, key=lambda row: (str(row["source"]), str(row["selector"]))),
    }
    payload["hash"] = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return payload


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def render(data: dict[str, object]) -> str:
    def feature_map(name: str) -> str:
        rows = data[name]
        assert isinstance(rows, dict)
        body = "\n".join(
            f"        {swift_string(key)}: [{', '.join('.' + item for item in value)}],"
            for key, value in rows.items()
        )
        return f"[\n{body}\n    ]"

    messages = data["objcMessages"]
    assert isinstance(messages, list)
    message_rows = "\n".join(
        "        .init(selector: %s, signature: %s, feature: .%s, source: %s),"
        % (swift_string(str(row["selector"])), swift_string(str(row["signature"])),
           row["feature"], swift_string(str(row["source"])))
        for row in messages
    )
    owners = data["selectorOwners"]
    assert isinstance(owners, list)
    owner_rows = "\n".join(
        "        .init(classNames: [%s], selector: %s, isClassMethod: %s, feature: .%s),"
        % (", ".join(swift_string(str(value)) for value in row["classNames"]),
           swift_string(str(row["selector"])),
           "nil" if row["isClassMethod"] is None else str(row["isClassMethod"]).lower(),
           row["feature"])
        for row in owners
    )
    return f'''// Generated by scripts/generate_native_contract.py. Do not edit.
import Foundation

extension NativeContractManifest {{
    static let generatedHash = {swift_string(str(data["hash"]))}
    static let generatedSelectorFeatures: [String: Set<NativeContractFeature>] = {feature_map("selectors")}
    static let generatedSelectorContracts: [NativeSelectorContract] = [
{owner_rows}
    ]
    static let generatedClassFeatures: [String: Set<NativeContractFeature>] = {feature_map("classes")}
    static let generatedKVCFeatures: [String: Set<NativeContractFeature>] = {feature_map("kvc")}
    static let generatedIvarFeatures: [String: Set<NativeContractFeature>] = {feature_map("ivars")}
    static let generatedObjCMessages: [NativeObjCMessageContract] = [
{message_rows}
    ]
}}
'''


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    expected = render(inventory())
    if arguments.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != expected:
            print(f"{OUTPUT.relative_to(ROOT)} is stale; run scripts/generate_native_contract.py")
            return 1
        return 0
    OUTPUT.write_text(expected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
