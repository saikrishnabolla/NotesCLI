import ArgumentParser
import Carbon
import Foundation
import NotesAutomation
import NotesCore
import NotesHost
import NotesMCP

func automationPermission() -> String {
    var target = AEAddressDesc()
    let bundle = "com.apple.Notes"
    let created = bundle.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, bundle.utf8.count, &target) }
    guard created == noErr else { return "unknown (cannot address Notes.app)" }
    defer { AEDisposeDesc(&target) }
    let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
    switch status {
    case noErr: return "authorized"
    case OSStatus(-1743): return "denied"
    case OSStatus(-1744): return "not determined (permission prompt required)"
    default: return "unknown (OSStatus \(status))"
    }
}

struct AccessProbe: Codable {
    var available: Bool
    var status: String
    var source: String
    var fidelity: String
    var unavailableFields: [String]
    var errorCode: String?
}

struct AccessReadiness: Codable {
    var direct: AccessProbe
    var effective: AccessProbe
    /// Reserved for the signed capability host. `null` can become an object without changing this schema.
    var capabilityHost: AccessProbe?

    private enum CodingKeys: String, CodingKey { case direct, effective, capabilityHost }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(direct, forKey: .direct)
        try container.encode(effective, forKey: .effective)
        if let capabilityHost { try container.encode(capabilityHost, forKey: .capabilityHost) }
        else { try container.encodeNil(forKey: .capabilityHost) }
    }
}

struct AgentReadyState: Codable {
    var ready: Bool
    var blockers: [String]
}

struct AgentDoctorReport: Codable {
    var schemaVersion: Int
    var readiness: AgentReadyState
    var access: AccessReadiness
    var automation: String
    var notesApp: String
    var inventory: [String: Int]?
}

struct Doctor: ParsableCommand {
    @OptionGroup var options: GlobalOptions
    @Flag(name: .customLong("for-agent"), help: "Return a stable readiness contract for agents.")
    var forAgent = false

    func run() throws {
        if forAgent {
            let report = agentReport()
            if options.json { try Output.json(report) }
            else {
                Output.table(["CHECK", "RESULT"], [
                    ["ready", report.readiness.ready ? "yes" : "no"],
                    ["direct", report.access.direct.status],
                    ["effective", "\(report.access.effective.status) (\(report.access.effective.fidelity))"],
                    ["automation", report.automation],
                    ["notes_app", report.notesApp],
                ])
            }
            return
        }

        let path = noteStorePath
        let direct = directAccess(path)
        var report = [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "full_disk_access": direct.available ? "readable" : "unreadable: \(direct.errorCode ?? direct.status)",
            "database_path": path.path,
            "automation": automationPermission(),
            "notes_app": notesAppPresent ? "present" : "missing",
        ]
        do {
            let backend = try options.backends()
            report["accounts"] = String(try backend.reader.accounts().count)
            report["folders"] = String(try backend.reader.folders(account: nil).count)
            report["notes"] = String(try backend.reader.notes(NoteQuery()).count)
        } catch { report["backend_error"] = String(describing: error) }
        if options.json { try Output.json(report) }
        else { Output.table(["CHECK", "RESULT"], report.keys.sorted().map { [$0, report[$0]!] }) }
    }

    func agentReport() -> AgentDoctorReport {
        let direct = directAccess(noteStorePath)
        let effective: AccessProbe
        var capabilityHost: AccessProbe?
        var inventory: [String: Int]?

        if resolvedBackendName == "fake" {
            do {
                let reader = try options.backends().reader
                inventory = try counts(reader)
                effective = AccessProbe(available: true, status: "available", source: "fake",
                                        fidelity: "full", unavailableFields: [], errorCode: nil)
            } catch {
                effective = unavailableProbe(error)
            }
        } else if let hosted = capabilityHostAccess() {
            capabilityHost = hosted.probe
            inventory = hosted.inventory
            effective = hosted.probe
        } else if direct.available {
            do {
                let reader = try options.backends().reader
                inventory = try counts(reader)
                effective = AccessProbe(available: true, status: "available", source: "notestore",
                                        fidelity: "full", unavailableFields: [], errorCode: nil)
            } catch {
                effective = unavailableProbe(error)
            }
        } else {
            do {
                let reader = ScriptingNotesReader()
                inventory = try counts(reader)
                effective = AccessProbe(available: true, status: "available", source: "automation",
                                        fidelity: reader.fidelity.rawValue,
                                        unavailableFields: reader.unavailableFields, errorCode: nil)
            } catch {
                effective = unavailableProbe(error)
            }
        }

        var blockers: [String] = []
        if !notesAppPresent { blockers.append("notes_app_missing") }
        if !effective.available { blockers.append(effective.errorCode ?? "notes_access_unavailable") }
        return AgentDoctorReport(
            schemaVersion: 1,
            readiness: AgentReadyState(ready: blockers.isEmpty, blockers: blockers),
            access: AccessReadiness(direct: direct, effective: effective, capabilityHost: capabilityHost),
            automation: automationPermission(), notesApp: notesAppPresent ? "present" : "missing",
            inventory: inventory
        )
    }

    private func capabilityHostAccess() -> (probe: AccessProbe, inventory: [String: Int]?)? {
        guard ProcessInfo.processInfo.environment["NOTESCLI_HOST_ACTIVE"] != "1",
              CapabilityHostClient.isAvailable() else { return nil }
        do {
            let captured = try CapabilityHostClient.capture(arguments: ["doctor", "--for-agent", "--json"])
            guard captured.exitCode == 0 else {
                return (AccessProbe(available: false, status: "unavailable", source: "capability_host",
                                    fidelity: "none", unavailableFields: [], errorCode: "capability_host_probe_failed"), nil)
            }
            let report = try JSONDecoder().decode(AgentDoctorReport.self, from: captured.stdout)
            var probe = report.access.effective
            probe.source = "capability_host"
            return (probe, report.inventory)
        } catch {
            return (AccessProbe(available: false, status: "unavailable", source: "capability_host",
                                fidelity: "none", unavailableFields: [], errorCode: "capability_host_probe_failed"), nil)
        }
    }

    private var resolvedBackendName: String {
        options.backend ?? ProcessInfo.processInfo.environment["NOTESCLI_BACKEND"] ?? "default"
    }

    private var noteStorePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    private var notesAppPresent: Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Notes.app") ||
            FileManager.default.fileExists(atPath: "/Applications/Notes.app")
    }

    private func directAccess(_ path: URL) -> AccessProbe {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return AccessProbe(available: false, status: "missing", source: "notestore", fidelity: "none",
                               unavailableFields: [], errorCode: "notestore_missing")
        }
        do {
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 16)
            return AccessProbe(available: true, status: "available", source: "notestore", fidelity: "full",
                               unavailableFields: [], errorCode: nil)
        } catch {
            return AccessProbe(available: false, status: "denied", source: "notestore", fidelity: "none",
                               unavailableFields: [], errorCode: "full_disk_access_denied")
        }
    }

    private func counts(_ reader: any NotesReading) throws -> [String: Int] {
        ["accounts": try reader.accounts().count,
         "folders": try reader.folders(account: nil).count,
         "notes": try reader.notes(NoteQuery()).count]
    }

    private func unavailableProbe(_ error: Error) -> AccessProbe {
        let code = (error as? NotesError)?.code ?? "notes_access_unavailable"
        return AccessProbe(available: false, status: "unavailable", source: "none", fidelity: "none",
                           unavailableFields: [], errorCode: code)
    }
}
