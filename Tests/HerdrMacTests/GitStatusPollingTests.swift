import Foundation
import HerdrCore

@main struct GitStatusPollingTests {
    @MainActor static func main() async throws {
        let suite = "dev.herdr.git-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = DeviceProfile(name: "Git test", kind: .local, socketPath: "/tmp/git-test.sock", executable: "/tmp/unused")
        let client = GitSnapshotClient()
        var reads: [[String]] = []
        var branches = ["/repo": WorkspaceGitStatus(branch: "main", ahead: 77), "/other": WorkspaceGitStatus(branch: "feature/x")]
        var failGit = false
        var pending: CheckedContinuation<[String: WorkspaceGitStatus], Error>?
        var delay = false
        let store = SessionStore(profile: profile, defaults: defaults, client: client, powerReader: { _ in nil }, gitReader: { requestedProfile, directories in
            precondition(requestedProfile.id == profile.id)
            reads.append(directories)
            if delay { return try await withCheckedThrowingContinuation { pending = $0 } }
            if failGit { throw HerdrError.message("git failed") }
            return branches.filter { directories.contains($0.key) }
        })
        defer { store.disconnect() }
        await store.refresh()
        try await wait { store.gitStatus == ["w1": branches["/repo"]!, "w2": branches["/repo"]!] }
        precondition(reads == [["/repo"]], "One read per refresh, each directory once, first tab's first pane only: \(reads)")
        for _ in 0..<5 { await store.refresh() }
        precondition(reads.count == 1, "Workspace polls must not run git every time")

        let later = Date().addingTimeInterval(6)
        branches["/repo"] = WorkspaceGitStatus(branch: "main", ahead: 78, behind: 1)
        store.refreshGitIfNeeded(now: later)
        try await wait { store.gitStatus["w1"] == branches["/repo"] }
        precondition(reads.count == 2)
        store.refreshGitIfNeeded(now: later.addingTimeInterval(4))
        precondition(reads.count == 2, "Do not read before the interval")

        await client.setCwd("/other")
        await store.refresh()
        try await wait { store.gitStatus["w2"] == branches["/other"] }
        precondition(reads.count == 3, "A changed directory is read at once")

        failGit = true
        store.refreshGitIfNeeded(now: later.addingTimeInterval(10))
        try await wait { reads.count == 4 }
        for _ in 0..<10 { await Task.yield() }
        precondition(store.gitStatus["w2"] == branches["/other"] && store.connected, "A failed read keeps the last branches and the connection")
        failGit = false

        delay = true
        store.refreshGitIfNeeded(now: later.addingTimeInterval(20))
        try await wait { pending != nil }
        store.disconnect()
        precondition(store.gitStatus.isEmpty)
        delay = false
        store.reconnect()
        try await wait { store.gitStatus["w2"] == branches["/other"] }
        pending?.resume(returning: ["/repo": WorkspaceGitStatus(branch: "stale")])
        pending = nil
        for _ in 0..<10 { await Task.yield() }
        precondition(store.gitStatus["w1"] == branches["/repo"], "An old read must not overwrite a reconnected device")
        store.disconnect()
        let count = reads.count
        store.refreshGitIfNeeded(now: later.addingTimeInterval(60))
        for _ in 0..<10 { await Task.yield() }
        precondition(store.gitStatus.isEmpty && reads.count == count, "Disconnected devices must stop running git")
        print("PASS: git branch polling, interval, directory changes, failure isolation, reconnect, stale-result rejection and disconnect")
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(condition(), "Timed out waiting for git status")
    }
}

private actor GitSnapshotClient: HerdrRequesting {
    var cwd = "/repo"
    func setCwd(_ value: String) { cwd = value }
    func request(_ method: String, params: [String: JSONValue], timeout: Int) async throws -> JSONValue {
        if method == "layout.export", case .string(let tab)? = params["tab_id"] {
            let pane = ["t1": "p1", "t1b": "p1b", "t2": "p2"][tab] ?? "p1"
            return .object(["layout": .object(["tab_id": .string(tab), "zoomed": .bool(false), "root": .object(["type": .string("pane"), "pane_id": .string(pane)])])])
        }
        precondition(method == "session.snapshot")
        func workspace(_ id: String, _ tab: String) -> JSONValue {
            .object(["workspace_id": .string(id), "label": .string(id), "active_tab_id": .string(tab), "pane_count": .number(1), "tab_count": .number(1), "agent_status": .string("idle")])
        }
        func tab(_ id: String, _ workspace: String) -> JSONValue {
            .object(["tab_id": .string(id), "workspace_id": .string(workspace), "label": .string(id), "pane_count": .number(1), "agent_status": .string("idle")])
        }
        func pane(_ id: String, _ tab: String, _ workspace: String, _ cwd: String) -> JSONValue {
            .object(["pane_id": .string(id), "terminal_id": .string("t" + id), "workspace_id": .string(workspace), "tab_id": .string(tab), "cwd": .string(cwd), "agent_status": .string("idle")])
        }
        return .object(["snapshot": .object([
            "version": .string("test"), "protocol": .number(22),
            "workspaces": .array([workspace("w1", "t1"), workspace("w2", "t2")]),
            "tabs": .array([tab("t1", "w1"), tab("t1b", "w1"), tab("t2", "w2")]),
            // w1's first tab decides; its second tab and second pane are ignored. w2 follows the shared cwd.
            "panes": .array([pane("p1", "t1", "w1", "/repo"), pane("p1x", "t1", "w1", "/plain-ignored"), pane("p1b", "t1b", "w1", "/plain"), pane("p2", "t2", "w2", cwd)]),
            "agents": .array([])
        ])])
    }
}
