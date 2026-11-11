import Foundation
import XCTest
@testable import NotesAutomation

final class ScriptSafetyTests: XCTestCase {
    // The JXA runtime executes the actual operation script against an in-memory application.
    // No Notes Apple Events are sent by these tests.
    private func exercise(_ payload: [String: String]) throws -> [String: Any] {
        let fixture = #"""
        let deleted = 0, made = 0;
        const account = {id:()=> 'account', name:()=> 'account', upgraded:()=> true};
        const root = {id:()=> 'root', name:()=> 'Root', container:()=> account, folders:()=> [], notes:()=> [], shared:()=> false};
        const trash = {id:()=> 'trash', name:()=> 'Supprimées récemment', container:()=> account, folders:()=> [], notes:()=> [], shared:()=> false};
        const stale = {container:()=> {const e=new Error('stale'); e.errorNumber=-1728; throw e;}};
        const duplicate = {id:()=> 'duplicate', name:()=> 'Root', container:()=> root, folders:()=> [], notes:()=> [], shared:()=> false};
        const note = {id:()=> 'x-coredata://test/ICNote/p1', name:()=> 'synthetic', container:()=> trash, passwordProtected:()=> false, shared:()=> false};
        account.defaultFolder = ()=> root;
        account.folders = ()=> [root, trash, stale];
        const app = {defaultAccount:()=> account, accounts:()=> [account], notes:{whose:()=> ()=> [note]}, delete:()=> {deleted++;}, make:()=> {made++; return root;}};
        function Application(bundle) {return app;}
        """#
        let operation = NotesScripts.operation.replacingOccurrences(of: "function run(argv)", with: "function perform(argv)")
        let wrapper = #"""
        function run(argv) {
            const p=JSON.parse(argv[0]);
            if (p.duplicates) root.folders=()=> [duplicate];
            if (p.nonempty) root.notes=()=> [note];
            if (p.listFixture) {note.container=()=>root; root.notes=()=>[note]; trash.notes=()=>[note];}
            const reply=JSON.parse(perform(argv));
            return JSON.stringify({reply:reply, deleted:deleted, made:made});
        }
        """#
        let data = try JSONEncoder().encode(payload)
        let output = try OSAScriptRunner().run(source: "function run(argv) {\n" + fixture + "\n" + operation + "\n" + wrapper.replacingOccurrences(of: "function run(argv) {", with: ""), language: .javaScript,
                                              arguments: [String(decoding: data, as: UTF8.self)], timeout: 5)
        XCTAssertEqual(output.status, 0, output.stderr)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
    }
    func testStaleFolderDoesNotBreakRead() throws {
        let result = try exercise(["operation": "folderInfo", "ref": "Root"])
        let reply = try XCTUnwrap(result["reply"] as? [String: Any])
        XCTAssertEqual(reply["folderID"] as? String, "root")
        XCTAssertNil(reply["errorNumber"])
    }
    func testLocalizedTrashNoteCannotBeDeleted() throws {
        let result = try exercise(["operation": "deleteNote", "ref": "x-coredata://test/ICNote/p1",
                                   "protectedFolderNamesJSON": #"["Supprimées récemment"]"#])
        let reply = try XCTUnwrap(result["reply"] as? [String: Any])
        XCTAssertEqual(reply["errorCode"] as? String, "protected_folder", String(describing: result))
        XCTAssertEqual(result["deleted"] as? Int, 0)
    }
    func testLocalizedTrashFolderCannotBeDeleted() throws {
        let result = try exercise(["operation": "deleteFolder", "ref": "Supprimées récemment",
                                   "protectedFolderNamesJSON": #"["Supprimées récemment"]"#])
        let reply = try XCTUnwrap(result["reply"] as? [String: Any])
        XCTAssertEqual(reply["errorCode"] as? String, "protected_folder", String(describing: result))
        XCTAssertEqual(result["deleted"] as? Int, 0)
    }
    func testMissingFolderCannotCreateNote() throws {
        let result = try exercise(["operation": "createNote", "folder": "missing", "title": "test", "html": "test"])
        let reply = try XCTUnwrap(result["reply"] as? [String: Any])
        XCTAssertEqual(reply["errorCode"] as? String, "folder_not_found")
        XCTAssertEqual(result["made"] as? Int, 0)
    }
    func testAmbiguousNameRequiresPath() throws {
        let result = try exercise(["operation": "createNote", "folder": "Root", "duplicates": "yes", "title": "test", "html": "test"])
        let reply = try XCTUnwrap(result["reply"] as? [String: Any])
        XCTAssertEqual(reply["errorCode"] as? String, "ambiguous_folder")
        XCTAssertEqual(result["made"] as? Int, 0)
    }
    func testLocalizedNamesIncludeEnglishAndFrench() throws {
        let names = try XCTUnwrap(ProtectedFolders.names)
        XCTAssertTrue(names.contains("Recently Deleted"))
        XCTAssertTrue(names.contains("Suppr. récentes"))
    }
    func testListExcludesTrashAndStaleReferences() throws {
        let result = try exercise(["operation": "list", "listFixture": "yes",
                                   "protectedFolderNamesJSON": #"["Supprimées récemment"]"#])
        let reply = try XCTUnwrap(result["reply"] as? [String: Any])
        let notes = try XCTUnwrap(reply["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?["title"] as? String, "synthetic")
        XCTAssertEqual(notes.first?["folderPath"] as? [String], ["Root"])
    }

}
