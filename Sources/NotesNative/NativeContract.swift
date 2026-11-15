import CoreData
import CoreImage
import CryptoKit
import Darwin
import Foundation
import NotesCore
import ObjectiveC.runtime
import SQLite3

public enum NativeContractFeature: String, Codable, CaseIterable, Sendable {
    case core, tags, tables, scans, recordings, paper
}

public enum NativeContractFailureKind: String, Codable, Sendable {
    case `class`, selector, methodEncoding = "method_encoding", entity, attribute, column, kvc, ivar
}

public struct NativeContractFailure: Codable, Equatable, Sendable {
    public var kind: NativeContractFailureKind
    public var name: String
    public var expected: String?
    public var actual: String?
}

public struct NativeFeatureContractReport: Codable, Sendable {
    public var feature: NativeContractFeature
    public var failures: [NativeContractFailure]
    public var ok: Bool
}

public struct NativeContractReport: Codable, Sendable {
    public var schemaVersion: Int
    public var verifiedOSBuild: String
    public var osBuild: String
    public var macOS: String
    public var dyldSharedCacheUUID: String
    public var manifestHash: String
    public var cliVersion: String
    public var cacheKey: String
    public var checkedAt: Date
    public var classCount: Int
    public var selectorCount: Int
    public var kvcKeyCount: Int
    public var ivarCount: Int
    public var objcMessageCount: Int
    public var abiEncodingCount: Int
    public var features: [NativeFeatureContractReport]
    public var ok: Bool

    public func feature(_ feature: NativeContractFeature) -> NativeFeatureContractReport {
        features.first { $0.feature == feature } ?? .init(
            feature: feature,
            failures: [.init(kind: .class, name: "missing_\(feature.rawValue)_contract_report",
                             expected: nil, actual: nil)],
            ok: false
        )
    }

    public func require(_ feature: NativeContractFeature) throws {
        let failures = self.feature(.core).failures + (feature == .core ? [] : self.feature(feature).failures)
        guard failures.isEmpty else {
            let names = failures.map(\.name).sorted().joined(separator: ", ")
            throw NotesError(
                "native_contract_changed",
                "The native \(feature.rawValue) contract changed: \(names). Nothing was written.",
                hint: "Run notescli doctor --native --json for the full report. Plain-text writes may use AppleScript; rich writes require a compatible NotesCLI update."
            )
        }
    }
}

struct NativeObjCMessageContract: Sendable {
    var selector: String
    var signature: String
    var feature: NativeContractFeature
    var source: String
}

enum NativeContractRequirement: Sendable {
    case classNamed(feature: NativeContractFeature, name: String)
    case selector(feature: NativeContractFeature, className: String?, selector: String,
                  isClassMethod: Bool?, encoding: String?)
    case attribute(feature: NativeContractFeature, entity: String, name: String)
    case column(feature: NativeContractFeature, table: String, name: String)
    case kvc(feature: NativeContractFeature, name: String)
    case ivar(feature: NativeContractFeature, name: String)

}

protocol NativeContractRuntime {
    var osBuild: String { get }
    var macOS: String { get }
    func classExists(_ name: String) -> Bool
    func methodEncoding(class name: String, selector: String, isClassMethod: Bool) -> String?
    func methodEncodings(selector: String) -> Set<String>
    func attributes(entity: String) -> Set<String>?
    func hasKVCKey(_ key: String) -> Bool
    func hasIvar(_ name: String) -> Bool
    func columns(table: String) -> Set<String>?
}

extension NativeContractRuntime {
    func methodEncodings(selector: String) -> Set<String> { [] }
    func hasKVCKey(_ key: String) -> Bool {
        methodEncodings(selector: key).isEmpty == false ||
            methodEncodings(selector: "set\(key.prefix(1).uppercased())\(key.dropFirst()):").isEmpty == false
    }
    func hasIvar(_ name: String) -> Bool { false }
}

enum NativeContractManifest {
    static let verifiedOSBuild = "26B131"

    static let abiEncodings: [String: String] = [
        "quadFromCGRect:": "@@:{CGRect={CGPoint=dd}{CGSize=dd}}",
        "setRectangle:": "v@:{CGRect={CGPoint=dd}{CGSize=dd}}",
        "setStrokeWidth:": "v@:d",
        "addStartTime:": "v@:d",
        "_locationAtIndex:applyStrokeTransform:": "{CGPoint=dd}@:QB",
        "locationAtIndex:": "{CGPoint=dd}@:Q",
        "addPoint:": "v@:{CGPoint=dd}",
        "timestampAtIndex:": "d@:Q",
        "addEndTime:": "v@:d",
        "score": "d@:",
        "replaceCharactersInRange:withAttributedString:": "v@:{_NSRange=QQ}@",
        "replaceCharactersInRange:withString:": "v@:{_NSRange=QQ}@",
        "initWithName:size:hints:": "@@:@dI",
        "setStartPoint:": "v@:{CGPoint=dd}",
        "setEndPoint:": "v@:{CGPoint=dd}",
        "moveToPoint:": "v@:{CGPoint=dd}",
        "lineToPoint:": "v@:{CGPoint=dd}",
        "bounds": "{CGRect={CGPoint=dd}{CGSize=dd}}@:",
        "drawingBounds": "{CGRect={CGPoint=dd}{CGSize=dd}}@:",
    ]

    static let schema: [NativeContractRequirement] = [
        .attribute(feature: .core, entity: "ICNote", name: "identifier"),
        .attribute(feature: .core, entity: "ICNote", name: "title"),
        .attribute(feature: .core, entity: "ICNote", name: "noteData"),
        .attribute(feature: .core, entity: "ICNoteData", name: "data"),
        .attribute(feature: .tags, entity: "ICInlineAttachment", name: "tokenContentIdentifier"),
        .attribute(feature: .tables, entity: "ICAttachment", name: "mergeableData"),
        .attribute(feature: .scans, entity: "ICAttachment", name: "markupModelData"),
        .attribute(feature: .recordings, entity: "ICAttachment", name: "duration"),
        .attribute(feature: .paper, entity: "ICAttachment", name: "paperBundleGeneration"),
        .column(feature: .core, table: "ZICCLOUDSYNCINGOBJECT", name: "ZIDENTIFIER"),
        .column(feature: .core, table: "ZICCLOUDSYNCINGOBJECT", name: "ZNOTEDATA"),
        .column(feature: .core, table: "ZICNOTEDATA", name: "ZDATA"),
        .column(feature: .tags, table: "ZICCLOUDSYNCINGOBJECT", name: "ZTOKENCONTENTIDENTIFIER"),
        .column(feature: .tables, table: "ZICCLOUDSYNCINGOBJECT", name: "ZMERGEABLEDATA1"),
        .column(feature: .scans, table: "ZICCLOUDSYNCINGOBJECT", name: "ZMARKUPMODELDATA"),
        .column(feature: .recordings, table: "ZICCLOUDSYNCINGOBJECT", name: "ZDURATION"),
        .column(feature: .paper, table: "ZICCLOUDSYNCINGOBJECT", name: "ZPAPERBUNDLEGENERATION"),
    ]

    static var requirements: [NativeContractRequirement] {
        generatedClassFeatures.flatMap { name, features in
            features.map { .classNamed(feature: $0, name: name) }
        } + generatedSelectorFeatures.flatMap { selector, features in
            features.map {
                .selector(feature: $0, className: nil, selector: selector,
                          isClassMethod: nil, encoding: abiEncodings[selector])
            }
        } + generatedKVCFeatures.flatMap { name, features in
            features.map { .kvc(feature: $0, name: name) }
        } + generatedIvarFeatures.flatMap { name, features in
            features.map { .ivar(feature: $0, name: name) }
        } + schema
    }

    static var hash: String {
        var rows = [generatedHash]
        rows += abiEncodings.keys.sorted().map { "encoding|\($0)|\(abiEncodings[$0]!)" }
        rows += schema.map { requirement in
            switch requirement {
            case .attribute(let feature, let entity, let name):
                return "attribute|\(feature.rawValue)|\(entity)|\(name)"
            case .column(let feature, let table, let name):
                return "column|\(feature.rawValue)|\(table)|\(name)"
            case .classNamed(let feature, let name):
                return "class|\(feature.rawValue)|\(name)"
            case .selector(let feature, let className, let selector, let isClassMethod, let encoding):
                return "selector|\(feature.rawValue)|\(className ?? "")|\(selector)|\(isClassMethod.map(String.init) ?? "")|\(encoding ?? "")"
            case .kvc(let feature, let name):
                return "kvc|\(feature.rawValue)|\(name)"
            case .ivar(let feature, let name):
                return "ivar|\(feature.rawValue)|\(name)"
            }
        }.sorted()
        return SHA256.hash(data: Data(rows.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum NativeContractProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memoryCache: [String: NativeContractReport] = [:]

    static func evaluate(requirements: [NativeContractRequirement], runtime: NativeContractRuntime,
                         dyldUUID: String = "test", cliVersion: String = notesCLIVersion,
                         manifestHash: String = NativeContractManifest.hash) -> NativeContractReport {
        var failures = Dictionary(uniqueKeysWithValues: NativeContractFeature.allCases.map { ($0, [NativeContractFailure]()) })
        func fail(_ feature: NativeContractFeature, _ kind: NativeContractFailureKind,
                  _ name: String, expected: String? = nil, actual: String? = nil) {
            failures[feature, default: []].append(.init(kind: kind, name: name, expected: expected, actual: actual))
        }
        for requirement in requirements {
            switch requirement {
            case .classNamed(let feature, let name):
                if !runtime.classExists(name) { fail(feature, .class, name) }
            case .selector(let feature, let className, let selector, let isClassMethod, let encoding):
                let label = className.map { "\(isClassMethod == true ? "+" : "-")[\($0) \(selector)]" } ?? selector
                let actual: Set<String>
                if let className, let isClassMethod {
                    actual = runtime.methodEncoding(class: className, selector: selector, isClassMethod: isClassMethod).map { [$0] } ?? []
                } else {
                    actual = runtime.methodEncodings(selector: selector)
                }
                if actual.isEmpty {
                    fail(feature, .selector, label)
                    continue
                }
                if let encoding, !actual.map(normalizeEncoding).contains(normalizeEncoding(encoding)) {
                    fail(feature, .methodEncoding, label, expected: encoding, actual: actual.sorted().joined(separator: " | "))
                }
            case .attribute(let feature, let entity, let name):
                guard let attributes = runtime.attributes(entity: entity) else {
                    fail(feature, .entity, entity); continue
                }
                if !attributes.contains(name) { fail(feature, .attribute, "\(entity).\(name)") }
            case .column(let feature, let table, let name):
                guard let columns = runtime.columns(table: table) else {
                    fail(feature, .column, table, expected: name); continue
                }
                if !columns.contains(name) { fail(feature, .column, "\(table).\(name)") }
            case .kvc(let feature, let name):
                if !runtime.hasKVCKey(name) { fail(feature, .kvc, name) }
            case .ivar(let feature, let name):
                if !runtime.hasIvar(name) { fail(feature, .ivar, name) }
            }
        }
        let key = cacheKey(dyldUUID: dyldUUID, manifestHash: manifestHash, cliVersion: cliVersion)
        let featureReports = NativeContractFeature.allCases.map {
            let rows = failures[$0, default: []].sorted { $0.name < $1.name }
            return NativeFeatureContractReport(feature: $0, failures: rows, ok: rows.isEmpty)
        }
        return NativeContractReport(
            schemaVersion: 1,
            verifiedOSBuild: NativeContractManifest.verifiedOSBuild,
            osBuild: runtime.osBuild,
            macOS: runtime.macOS,
            dyldSharedCacheUUID: dyldUUID,
            manifestHash: manifestHash,
            cliVersion: cliVersion,
            cacheKey: key,
            checkedAt: Date(),
            classCount: NativeContractManifest.generatedClassFeatures.count,
            selectorCount: NativeContractManifest.generatedSelectorFeatures.count,
            kvcKeyCount: NativeContractManifest.generatedKVCFeatures.count,
            ivarCount: NativeContractManifest.generatedIvarFeatures.count,
            objcMessageCount: NativeContractManifest.generatedObjCMessages.count,
            abiEncodingCount: NativeContractManifest.generatedObjCMessages.filter {
                $0.signature.contains("CGRect") || $0.signature.contains("CGPoint") ||
                    $0.signature.contains("NSRange") || $0.signature.contains("double")
            }.count,
            features: featureReports,
            ok: featureReports.allSatisfy(\.ok)
        )
    }

    static func live(force: Bool = false) -> NativeContractReport {
        let dyldUUID = LiveNativeContractRuntime.dyldSharedCacheUUID()
        let canCache = dyldUUID != "unknown"
        let key = cacheKey(dyldUUID: dyldUUID, manifestHash: NativeContractManifest.hash,
                           cliVersion: notesCLIVersion)
        lock.lock()
        if canCache, !force, let cached = memoryCache[key] { lock.unlock(); return cached }
        lock.unlock()
        if canCache, !force, let cached = readCache(key: key) {
            lock.lock(); memoryCache[key] = cached; lock.unlock()
            return cached
        }
        let report = evaluate(requirements: NativeContractManifest.requirements,
                              runtime: LiveNativeContractRuntime(), dyldUUID: dyldUUID)
        if canCache {
            writeCache(report)
            lock.lock(); memoryCache[key] = report; lock.unlock()
        }
        return report
    }

    private static func normalizeEncoding(_ value: String) -> String {
        value.replacingOccurrences(of: #"\d+"#, with: "", options: .regularExpression)
    }

    private static func cacheKey(dyldUUID: String, manifestHash: String, cliVersion: String) -> String {
        let data = Data("\(dyldUUID)|\(manifestHash)|\(cliVersion)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NotesCLI/native-contract", isDirectory: true)
    }
    private static func cacheURL(_ key: String) -> URL { cacheDirectory.appendingPathComponent("\(key).json") }
    private static func readCache(key: String) -> NativeContractReport? {
        guard let data = try? Data(contentsOf: cacheURL(key)),
              let report = try? JSONDecoder().decode(NativeContractReport.self, from: data),
              report.cacheKey == key else { return nil }
        return report
    }
    private static func writeCache(_ report: NativeContractReport) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: cacheURL(report.cacheKey), options: .atomic)
    }
}

private final class LiveNativeContractRuntime: NativeContractRuntime {
    let osBuild: String
    let macOS: String
    private var classes: Set<String> = []
    private var encodings: [String: Set<String>] = [:]
    private var modelAttributes: [String: Set<String>] = [:]
    private var schemaColumns: [String: Set<String>] = [:]
    private var ivars: Set<String> = []
    private var kvcKeys: Set<String> = []

    init() {
        osBuild = Self.process("/usr/sbin/sysctl", ["-n", "kern.osversion"]) ?? "unknown"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        macOS = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        Self.frameworks.forEach { _ = dlopen($0, RTLD_NOW | RTLD_LOCAL) }
        indexModel()
        indexMethods()
        indexCoreImageKeys()
        indexSchema()
    }

    func classExists(_ name: String) -> Bool {
        classes.contains(name) || NSClassFromString(name) != nil ||
            name.split(separator: ".").last.flatMap { NSClassFromString(String($0)) } != nil
    }
    func methodEncoding(class name: String, selector: String, isClassMethod: Bool) -> String? {
        guard let cls: AnyClass = NSClassFromString(name) else { return nil }
        let method = isClassMethod ? class_getClassMethod(cls, NSSelectorFromString(selector))
                                  : class_getInstanceMethod(cls, NSSelectorFromString(selector))
        return method.flatMap(method_getTypeEncoding).map { String(cString: $0) }
    }
    func methodEncodings(selector: String) -> Set<String> {
        if let values = encodings[selector], !values.isEmpty { return values }
        if modelAttributes.values.contains(where: { $0.contains(selector) }) { return ["@@:"] }
        if selector.hasPrefix("set"), selector.hasSuffix(":"), selector.count > 4 {
            let start = selector.index(selector.startIndex, offsetBy: 3)
            let end = selector.index(before: selector.endIndex)
            let stem = String(selector[start..<end])
            let key = stem.prefix(1).lowercased() + stem.dropFirst()
            if modelAttributes.values.contains(where: { $0.contains(key) }) { return ["v@:@"] }
        }
        return []
    }
    func attributes(entity: String) -> Set<String>? { modelAttributes[entity] }
    func hasKVCKey(_ key: String) -> Bool {
        kvcKeys.contains(key) || modelAttributes.values.contains { $0.contains(key) } ||
            ivars.contains(key) || ivars.contains("_\(key)") ||
            methodEncodings(selector: key).isEmpty == false ||
            methodEncodings(selector: "set\(key.prefix(1).uppercased())\(key.dropFirst()):").isEmpty == false
    }
    func hasIvar(_ name: String) -> Bool { ivars.contains(name) }
    func columns(table: String) -> Set<String>? { schemaColumns[table] }

    private func indexMethods() {
        let explicit = Set(NativeContractManifest.generatedClassFeatures.keys).union(modelAttributes.keys).union([
            "ICAttachment", "ICAttachmentDrawingModel", "ICAttachmentTableModel", "ICTable", "ICFolder", "ICNote",
            "NSMutableAttributedString", "NSNumber", "NSArray", "NSMutableArray", "NSDictionary", "NSMutableDictionary",
            "NSSet", "NSMutableSet", "NSString", "NSData", "NSURL", "PKDrawing", "PKStroke", "PKStrokePath", "PKInk",
        ])
        var indexed = Set<ObjectIdentifier>()
        func index(_ cls: AnyClass) {
            guard indexed.insert(ObjectIdentifier(cls)).inserted else { return }
            classes.insert(String(cString: class_getName(cls)))
            indexMethods(of: cls)
            if let meta = object_getClass(cls) { indexMethods(of: meta) }
        }
        for name in explicit {
            if let cls: AnyClass = NSClassFromString(name) { index(cls) }
        }

        let expected = objc_getClassList(nil, 0)
        guard expected > 0 else { return }
        let values = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(expected))
        defer { values.deallocate() }
        let actual = objc_getClassList(AutoreleasingUnsafeMutablePointer(values), expected)
        for offset in 0..<Int(actual) {
            guard let cls = values[offset] else { continue }
            let name = String(cString: class_getName(cls))
            if name.hasPrefix("IC") || name.hasPrefix("CH") || name.hasPrefix("SY") ||
                name.hasPrefix("AK") || name.hasPrefix("MU") || name.contains("NotesShared") {
                index(cls)
            }
        }
    }

    private func indexMethods(of cls: AnyClass) {
        var ivarCount: UInt32 = 0
        if let values = class_copyIvarList(cls, &ivarCount) {
            defer { free(values) }
            for index in 0..<Int(ivarCount) {
                if let name = ivar_getName(values[index]) { ivars.insert(String(cString: name)) }
            }
        }
        var propertyCount: UInt32 = 0
        if let values = class_copyPropertyList(cls, &propertyCount) {
            defer { free(values) }
            for index in 0..<Int(propertyCount) {
                kvcKeys.insert(String(cString: property_getName(values[index])))
            }
        }
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return }
        defer { free(methods) }
        for index in 0..<Int(count) {
            let method = methods[index]
            let name = NSStringFromSelector(method_getName(method))
            guard let raw = method_getTypeEncoding(method) else { continue }
            encodings[name, default: []].insert(String(cString: raw))
        }
    }

    private func indexCoreImageKeys() {
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return }
        kvcKeys.formUnion(filter.inputKeys)
        kvcKeys.formUnion(filter.outputKeys)
    }

    private func indexModel() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/NotesShared.framework/Versions/A/Resources/NoteData.mom")
        guard let model = NSManagedObjectModel(contentsOf: url) else { return }
        for entity in model.entities {
            guard let name = entity.name else { continue }
            modelAttributes[name] = Set(entity.propertiesByName.keys)
        }
    }

    private func indexSchema() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { return }
        defer { sqlite3_close(database) }
        for table in ["ZICCLOUDSYNCINGOBJECT", "ZICNOTEDATA"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
                  let statement else { continue }
            defer { sqlite3_finalize(statement) }
            var names = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: value))
            }
            schemaColumns[table] = names
        }
    }

    static func dyldSharedCacheUUID() -> String {
        guard let output = process("/usr/bin/dyld_info", ["-uuid", "/usr/lib/dyld"]) else { return "unknown" }
        let arch = ProcessInfo.processInfo.machineArchitecture
        let sections = output.components(separatedBy: "/usr/lib/dyld ").filter { !$0.isEmpty }
        let selected = sections.first { $0.contains("[\(arch)") } ??
            sections.first { arch.hasPrefix("arm64") && $0.contains("[arm64") } ?? sections.last
        guard let selected,
              let match = selected.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27,}"#, options: .regularExpression) else {
            return "unknown"
        }
        return String(selected[match]).uppercased()
    }

    private static func process(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let frameworks = [
        "/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared",
        "/System/Library/PrivateFrameworks/NotesUI.framework/NotesUI",
        "/System/Library/PrivateFrameworks/DocumentCamera.framework/DocumentCamera",
        "/System/Library/PrivateFrameworks/NotesEditor.framework/NotesEditor",
        "/System/Library/PrivateFrameworks/Calculate.framework/Calculate",
        "/System/Library/PrivateFrameworks/Synapse.framework/Synapse",
        "/System/Library/PrivateFrameworks/AnnotationKit.framework/AnnotationKit",
        "/System/Library/PrivateFrameworks/MarkupUI.framework/MarkupUI",
        "/System/Library/Frameworks/PencilKit.framework/PencilKit",
        "/System/Library/Frameworks/PaperKit.framework/PaperKit",
    ]
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
