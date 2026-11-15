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


def feature(text: str) -> str:
    value = text.lower()
    if any(word in value for word in ("doccam", "scan", "gallery", "quad", "markup")):
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


def inventory() -> dict[str, object]:
    selectors: dict[str, set[str]] = {}
    classes: dict[str, set[str]] = {}
    kvc: dict[str, set[str]] = {}
    ivars: dict[str, set[str]] = {}
    messages: list[dict[str, str | int]] = []

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

    payload = {
        "selectors": {key: sorted(value) for key, value in sorted(selectors.items())},
        "classes": {key: sorted(value) for key, value in sorted(classes.items())},
        "kvc": {key: sorted(value) for key, value in sorted(kvc.items())},
        "ivars": {key: sorted(value) for key, value in sorted(ivars.items())},
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
    return f'''// Generated by scripts/generate_native_contract.py. Do not edit.
import Foundation

extension NativeContractManifest {{
    static let generatedHash = {swift_string(str(data["hash"]))}
    static let generatedSelectorFeatures: [String: Set<NativeContractFeature>] = {feature_map("selectors")}
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
