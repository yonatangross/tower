import Foundation

/// Watches the quota cache for the resource subscriptions.
///
/// The store replaces `accounts.json` and the mirror atomically (a new inode each
/// save), so the watch sits on the directory, not the file: a vnode source on the
/// mirror itself would fire once and then follow a dead inode. On each directory
/// event the watcher reads the file, compares a digest per account row and one for
/// the whole file against what it last saw, and tells the server which resource URIs
/// changed. New or vanished rows raise `list_changed` as well.
final class MCPQuotaWatcher {
    private let service: TowerMCPService
    private let server: MCPServer
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    private var lastFile: Data?
    private var lastRows: [String: JSON] = [:]
    private let queue = DispatchQueue(label: "tower.mcp.watch")

    init(service: TowerMCPService, server: MCPServer) {
        self.service = service
        self.server = server
        self.directory = service.env.mirrorPath.deletingLastPathComponent()
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        snapshot(notify: false)
        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            MCPStdio.log("tower mcp: cannot watch \(directory.path); resource notifications are off")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleSnapshot() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Saves come as a temp write followed by a rename, so one save is several
    /// directory events. Coalesce them before reading.
    private func scheduleSnapshot() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snapshot(notify: true) }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func snapshot(notify: Bool) {
        let file = try? Data(contentsOf: service.env.mirrorPath)
        let now = service.env.now()
        let accounts = service.env.store.load()
        let active = service.activeEmail(accounts)
        var rows: [String: JSON] = [:]
        for (id, a) in accounts { rows[id] = TowerMCPService.accountJSON(a, activeEmail: active, now: now) }

        defer {
            lastFile = file
            lastRows = rows
        }
        guard notify else { return }

        var changed: [String] = []
        if file != lastFile { changed.append(TowerMCPService.quotaCacheURI) }
        for (id, json) in rows where lastRows[id] != json {
            changed.append(TowerMCPService.accountURIPrefix + id)
        }
        let listChanged = Set(rows.keys) != Set(lastRows.keys)
        guard !changed.isEmpty || listChanged else { return }
        let server = self.server
        Task {
            if !changed.isEmpty { await server.resourcesUpdated(changed) }
            if listChanged { await server.resourceListChanged() }
        }
    }
}
