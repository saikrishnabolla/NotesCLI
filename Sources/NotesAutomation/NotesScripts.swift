import Foundation

// All caller data arrives as JSON in argv[0]. Never insert it into these sources.
enum NotesScripts {
    static let launch = #"function run(argv) { Application('com.apple.Notes').launch(); return '{}'; }"#

    static let operation = #"""
    function run(argv) {
        const app = Application('com.apple.Notes');
        const p = JSON.parse(argv[0]);
        let changed = false;
        let result = {};
        function fail(code) { const e = new Error(code); e.code = code; throw e; }
        function id(o) { return o.id(); }
        function sameName(a, b) { return String(a).normalize("NFC") === String(b).normalize("NFC"); }
        function unique(items, missing, ambiguous) {
            if (items.length === 0) fail(missing);
            if (items.length !== 1) fail(ambiguous);
            return items[0];
        }
        function account(ref) {
            if (!ref) return app.defaultAccount();
            return unique(app.accounts().filter(a => id(a) === ref || sameName(a.name(), ref)), 'account_not_found', 'ambiguous_account');
        }
        function children(parent) {
            const parentID = id(parent);
            return parent.folders().filter(f => {
                try { return id(f.container()) === parentID; }
                catch (e) {
                    // Notes leaves deleted folder references in this collection.
                    if ((e.errorNumber || e.number) === -1728) return false;
                    throw e;
                }
            });
        }
        function folders(parent, seen) {
            seen = seen || {};
            let found = [];
            children(parent).forEach(f => {
                const key = id(f);
                if (!seen[key]) { seen[key] = true; found.push(f); found = found.concat(folders(f, seen)); }
            });
            return found;
        }
        function folder(ref, a) {
            a = a || app.defaultAccount();
            if (!ref) return a.defaultFolder();
            if (ref.indexOf('x-coredata://') === 0) {
                const candidates = app.accounts().reduce((all, item) => all.concat(folders(item)), []);
                return unique(candidates.filter(f => id(f) === ref), 'folder_not_found', 'ambiguous_folder');
            }
            if (ref.indexOf('>') !== -1) {
                let container = a;
                ref.split('>').map(s => s.trim()).forEach(part => {
                    if (!part) fail('folder_not_found');
                    container = unique(children(container).filter(f => sameName(f.name(), part)), 'folder_not_found', 'ambiguous_folder');
                });
                return container;
            }
            return unique(folders(a).filter(f => sameName(f.name(), ref)), 'folder_not_found', 'ambiguous_folder');
        }
        function path(f) {
            const parts = [];
            const seen = {};
            while (f && !seen[id(f)]) {
                seen[id(f)] = true;
                if (app.accounts().some(a => id(a) === id(f))) break;
                parts.unshift(f.name());
                f = f.container();
            }
            return parts;
        }
        function isTrash(f) {
            const protectedNames = JSON.parse(p.protectedFolderNamesJSON || '["Recently Deleted","Trash"]');
            return protectedNames.some(name => sameName(name, f.name()));
        }
        function activeFolder(f) {
            // app.notes includes trashed notes; deleting them again can be permanent.
            if (isTrash(f)) fail('protected_folder');
            const available = app.accounts().some(a => folders(a).some(candidate => id(candidate) === id(f)));
            if (!available) fail('protected_folder');
        }
        function note(ref) {
            // Check the current container even when a caller holds an old note ID.
            const n = unique(app.notes.whose({id: ref})(), 'note_not_found', 'ambiguous_note');
            activeFolder(n.container());
            return n;
        }
        function writable(n) {
            if (n.passwordProtected()) fail('note_locked');
        }
        function plainEscape(s) {
            return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
        }
        try {
            switch (p.operation) {
            case 'createNote': {
                const f = folder(p.folder);
                activeFolder(f);
                const n = app.make({new: 'note', at: f, withProperties: {body: '<h1>' + plainEscape(p.title) + '</h1>' + p.html}});
                changed = true;
                result = {id: id(n), folderID: id(f)};
                break;
            }
            case 'appendToNote': {
                const n = note(p.ref); writable(n);
                // Replacing rich content through HTML can lose embedded attachments.
                if (n.attachments().length !== 0) fail('attachments_would_be_lost');
                const body = n.body();
                result = {id: id(n), folderID: id(n.container())};
                n.body = body + p.html;
                changed = true;
                break;
            }
            case 'replaceBody': {
                const n = note(p.ref); writable(n);
                result = {id: id(n), folderID: id(n.container())};
                const title = n.name();
                n.body = '<h1>' + plainEscape(title) + '</h1>' + p.html;
                changed = true;
                break;
            }
            case 'renameNote': {
                const n = note(p.ref); writable(n);
                result = {id: id(n), folderID: id(n.container())};
                n.name = p.title;
                changed = true;
                break;
            }
            case 'moveNote': {
                const n = note(p.ref); writable(n);
                const f = folder(p.folder); activeFolder(f);
                result = {id: id(n), folderID: id(f)};
                app.move(n, {to: f});
                changed = true;
                result.id = id(n);
                break;
            }
            case 'deleteNote': {
                const n = note(p.ref); writable(n);
                if (n.shared()) fail('shared_note');
                const owner = app.accounts().find(a => folders(a).some(f => id(f) === id(n.container())));
                if (!owner || !owner.upgraded()) fail('unsupported_account');
                result = {id: id(n)};
                app.delete(n);
                changed = true;
                break;
            }
            case 'createFolder': {
                const a = account(p.account);
                const parent = p.parent ? folder(p.parent, a) : a;
                if (p.parent) {
                    activeFolder(parent);
                    if (!folders(a).some(f => id(f) === id(parent))) fail('account_mismatch');
                }
                if (children(parent).some(f => sameName(f.name(), p.name))) fail('folder_exists');
                const f = app.make({new: 'folder', at: parent, withProperties: {name: p.name}});
                changed = true;
                result = {folderID: id(f)};
                break;
            }
            case 'renameFolder':
            case 'deleteFolder': {
                const f = folder(p.ref); activeFolder(f);
                if (f.shared()) fail('shared_folder');
                if (app.accounts().some(a => id(a.defaultFolder()) === id(f))) fail('protected_folder');
                result = {folderID: id(f)};
                if (p.operation === 'deleteFolder') {
                    if (f.notes().length !== 0 || children(f).length !== 0) fail('folder_not_empty');
                    app.delete(f);
                } else {
                    if (children(f.container()).some(other => id(other) !== id(f) && sameName(other.name(), p.name))) fail('folder_exists');
                    f.name = p.name;
                }
                changed = true;
                break;
            }
            case 'show': {
                app.show(note(p.ref));
                break;
            }
            case 'read': {
                const n = note(p.ref);
                result = {id: id(n), title: n.name(), folderID: id(n.container()), body: n.passwordProtected() ? null : n.body(), attachmentCount: n.attachments().length};
                break;
            }
            case 'folderInfo': {
                const f = folder(p.ref);
                result = {folderID: id(f), name: f.name(), noteCount: f.notes().length, childCount: children(f).length};
                break;
            }
            case 'list': {
                const items = [];
                app.accounts().forEach(a => {
                    folders(a).forEach(f => {
                        if (isTrash(f)) return;
                        f.notes().forEach(n => {
                            try {
                                if (id(n.container()) === id(f)) {
                                    items.push({id: id(n), title: n.name(), folderID: id(f), folderPath: path(f), accountID: id(a)});
                                }
                            } catch (e) {
                                if ((e.errorNumber || e.number) !== -1728) throw e;
                            }
                        });
                    });
                });
                result = {notes: items};
                break;
            }
            default: fail('invalid_operation');
            }
            return JSON.stringify(result);
        } catch (e) {
            // Do not echo Apple Event descriptions: they can contain private note text.
            result.errorCode = e.code || null;
            result.errorNumber = e.errorNumber || e.number || null;
            result.changed = changed;
            return JSON.stringify(result);
        }
    }
    """#

    static let attachment = #"""
    on run argv
        set noteID to item 1 of argv
        set filePath to item 2 of argv
        tell application "Notes"
            set targetNote to note id noteID
            make new attachment at targetNote with data (POSIX file filePath)
        end tell
        return "attached"
    end run
    """#
}
