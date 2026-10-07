import SwiftUI
import HerdrCore

struct PaneDragPayload: Codable, Equatable, Sendable {
    let deviceID: UUID
    let connectionGeneration: UUID
    let tabID: String
    let paneID: String
}

struct TabDragPayload: Codable, Equatable, Sendable {
    let deviceID: UUID
    let connectionGeneration: UUID
    let workspaceID: String
    let tabID: String
}

enum PaneDockEdge: CaseIterable {
    case left, right, top, bottom

    static func at(_ point: CGPoint, in size: CGSize) -> Self? {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.x <= size.width, point.y >= 0, point.y <= size.height else { return nil }
        let x = point.x / size.width, y = point.y / size.height
        if min(point.x, size.width - point.x) < min(point.y, size.height - point.y) { return x < 0.5 ? .left : .right }
        return y < 0.5 ? .top : .bottom
    }

    func preview(in size: CGSize) -> CGRect {
        switch self {
        case .left: return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }

    var splitDirection: SplitDirection { self == .left || self == .right ? .right : .down }
    var insertsBefore: Bool { self == .left || self == .top }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var tabs: [HerdrCore.Tab] = []
    @Published var panes: [Pane] = []
    @Published var agents: [Agent] = []
    @Published var layouts: [String: TabLayout] = [:]
    @Published var selectedSpace: String?
    @Published var selectedTab: String?
    @Published var selectedPane: String?
    @Published var paneSearchRequest: (paneID: String, token: UUID)?
    @Published private(set) var powerStatus: DevicePowerStatus?
    /// Keyed by workspace ID; workspaces outside a branch are absent.
    @Published private(set) var gitStatus: [String: WorkspaceGitStatus] = [:]
    @Published var connected = false
    @Published var connecting = false
    @Published var busy = false
    @Published var connectionError: String?
    @Published var operationError: String?
    @Published var version = ""
    @Published private(set) var protocolVersion: Int?
    @Published var sheet: AppSheet?
    @Published var pendingClose: ResourceTarget?
    @Published var connectionGeneration = UUID()
    @Published private(set) var profile: DeviceProfile
    @Published private(set) var effectiveSocketPath: String
    @Published private(set) var remoteHome: String?
    @Published private(set) var suspended = false
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var socketPath: String { profile.socketPath }
    var executable: String { profile.executable }
    var isRemote: Bool { profile.kind == .ssh }
    var defaultDirectory: String { isRemote ? remoteHome ?? "/tmp" : NSHomeDirectory() }
    @Published private var tabOrder: [String: [String]]
    private let defaults: UserDefaults
    private let tunnel: SSHTunnel
    private let fileTransfer: RemoteFileTransfer
    private var fileTransfers: [UUID: Task<PreparedFileDrop, Error>] = [:]
    private var retryAfter = Date.distantPast
    private var client: any HerdrRequesting
    private var pollTask: Task<Void, Never>?
    private let powerReader: @MainActor (DeviceProfile) async throws -> DevicePowerStatus?
    private var powerTask: Task<Void, Never>?
    private var powerReadID: UUID?
    private var nextPowerRefresh = Date.distantPast
    private let gitReader: @MainActor (DeviceProfile, [String]) async throws -> [String: WorkspaceGitStatus]
    private var gitTask: Task<Void, Never>?
    private var gitReadID: UUID?
    private var nextGitRefresh = Date.distantPast
    private var gitDirectories: [String: String] = [:]
    private var refreshingGeneration: UUID?
    private var serverProcess: Process?
    private var selectionRevision = 0
    private var paneMoveID: UUID?
    private var layoutRevision = 0
    private var pendingLayoutRefresh: Set<String> = []
    private var pendingSplitResizes = 0
    private var splitResizeTask: Task<Void, Never>?

    init(profile: DeviceProfile, defaults: UserDefaults = .standard, tunnel: SSHTunnel? = nil, client: (any HerdrRequesting)? = nil, fileTransfer: RemoteFileTransfer? = nil, powerReader: @escaping @MainActor (DeviceProfile) async throws -> DevicePowerStatus? = { try await DevicePowerStatus.read($0) },
         gitReader: @escaping @MainActor (DeviceProfile, [String]) async throws -> [String: WorkspaceGitStatus] = { try await WorkspaceGitStatus.read($0, directories: $1) }) {
        self.profile = profile
        self.defaults = defaults
        self.powerReader = powerReader
        self.gitReader = gitReader
        tabOrder = defaults.dictionary(forKey: "tabOrder:\(profile.id.uuidString)") as? [String: [String]] ?? [:]
        self.tunnel = tunnel ?? SSHTunnel()
        self.fileTransfer = fileTransfer ?? RemoteFileTransfer()
        let socket = profile.kind == .local ? (profile.socketPath as NSString).expandingTildeInPath : ""
        effectiveSocketPath = socket
        appearance = defaults.string(forKey: "appearance") ?? "system"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 13
        self.client = client ?? HerdrClient(socketPath: socket)
        selectedSpace = defaults.string(forKey: "selectedSpace:\(profile.id.uuidString)")
        selectedTab = defaults.string(forKey: "selectedTab:\(profile.id.uuidString)")
    }

    static func findExecutable() -> String {
        let candidates = [NSHomeDirectory() + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/herdr"
    }

    var currentSpace: Workspace? { workspaces.first { $0.id == selectedSpace } }
    var currentTab: HerdrCore.Tab? { tabs.first { $0.id == selectedTab } }
    var currentPane: Pane? { panes.first { $0.id == selectedPane } }
    var visibleTabs: [HerdrCore.Tab] {
        let visible = tabs.filter { $0.workspaceID == selectedSpace }
        guard let space = selectedSpace, let order = tabOrder[space] else { return visible }
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        var seen = Set<String>()
        let ordered = order.compactMap { id -> HerdrCore.Tab? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        return ordered + visible.filter { !seen.contains($0.id) }
    }

    func tabDragPayload(for tabID: String) -> TabDragPayload? {
        guard connected, !suspended, !busy, paneMoveID == nil, sheet == nil,
              pendingClose == nil, operationError == nil,
              let tab = visibleTabs.first(where: { $0.id == tabID }) else { return nil }
        return TabDragPayload(deviceID: profile.id, connectionGeneration: connectionGeneration,
                              workspaceID: tab.workspaceID, tabID: tab.id)
    }

    @discardableResult
    func moveTab(_ source: TabDragPayload, relativeTo targetID: String, after: Bool) -> Bool {
        guard tabDragPayload(for: source.tabID) == source, source.tabID != targetID,
              visibleTabs.contains(where: { $0.id == targetID }) else { return false }
        let current = visibleTabs.map(\.id)
        var order = current.filter { $0 != source.tabID }
        guard let target = order.firstIndex(of: targetID) else { return false }
        order.insert(source.tabID, at: target + (after ? 1 : 0))
        if order != current {
            tabOrder[source.workspaceID] = order
            defaults.set(tabOrder, forKey: "tabOrder:\(profile.id.uuidString)")
        }
        return true
    }
    var visiblePanes: [Pane] { panes.filter { $0.tabID == selectedTab } }
    var currentLayout: TabLayout? { selectedTab.flatMap { layouts[$0] } }
    var attentionCount: Int { agents.filter { $0.agentStatus == .blocked || $0.agentStatus == .done }.count }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    func searchPane(_ paneID: String? = nil) {
        guard connected, sheet == nil, pendingClose == nil, operationError == nil,
              let id = paneID ?? selectedPane, visiblePanes.contains(where: { $0.id == id }) else { return }
        focusPane(id)
        paneSearchRequest = (id, UUID())
    }

    func prepareDroppedFiles(_ urls: [URL]) async throws -> PreparedFileDrop {
        let generation = connectionGeneration
        try Task.checkCancellation()
        guard isRemote else { return PreparedFileDrop(paths: urls.map(\.path)) }
        let id = UUID()
        let profile = self.profile
        let transfer = Task { try await fileTransfer.upload(urls, to: profile) }
        fileTransfers[id] = transfer
        defer { fileTransfers[id] = nil }
        do {
            let files = try await withTaskCancellationHandler {
                try await transfer.value
            } onCancel: { transfer.cancel() }
            guard !Task.isCancelled, generation == connectionGeneration else {
                await files.discard()
                throw CancellationError()
            }
            return files
        } catch {
            guard generation == connectionGeneration else { throw CancellationError() }
            throw error
        }
    }

    func readPaneForSearch(_ paneID: String) async throws -> (text: String, truncated: Bool) {
        let generation = connectionGeneration
        let result = try await client.request("pane.read", params: [
            "pane_id": .string(paneID), "source": .string("recent_unwrapped"),
            "lines": .number(10000), "format": .string("text"), "strip_ansi": .bool(true)
        ])
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
        guard let text = result["read"]["text"].string else {
            throw HerdrError.message("Herdr returned invalid pane output")
        }
        return (text, result["read"]["truncated"] == .bool(true))
    }

    func start() {
        guard pollTask == nil, !suspended else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1.25))
            }
        }
    }

    func reconnect() {
        disconnect()
        suspended = false
        retryAfter = .distantPast
        connectionError = nil
        start()
    }

    func disconnect() {
        pollTask?.cancel(); pollTask = nil
        clearPowerStatus()
        clearGitStatus()
        connectionGeneration = UUID()
        for transfer in fileTransfers.values { transfer.cancel() }
        paneMoveID = nil
        pendingLayoutRefresh = []
        splitResizeTask?.cancel(); splitResizeTask = nil
        pendingSplitResizes = 0
        tunnel.stop()
        suspended = true; connected = false; connecting = false; busy = false
        if isRemote { effectiveSocketPath = "" }
    }

    func updateProfile(_ value: DeviceProfile) {
        disconnect()
        profile = value
        tabOrder = defaults.dictionary(forKey: "tabOrder:\(value.id.uuidString)") as? [String: [String]] ?? [:]
        workspaces = []; tabs = []; panes = []; agents = []; layouts = [:]
        selectedSpace = nil; selectedTab = nil; selectedPane = nil
        reconnect()
    }

    func refresh() async {
        guard !suspended, paneMoveID == nil, pendingSplitResizes == 0,
              refreshingGeneration != connectionGeneration, Date() >= retryAfter else { return }
        let generation = connectionGeneration
        refreshingGeneration = generation
        if connecting != !connected { connecting = !connected }
        defer {
            if refreshingGeneration == generation { refreshingGeneration = nil }
            if connectionGeneration == generation, connecting { connecting = false }
        }
        let revision = selectionRevision
        let expectedLayoutRevision = layoutRevision
        do {
            let path: String
            if isRemote {
                path = try await tunnel.connect(profile)
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                if remoteHome != tunnel.remoteHome { remoteHome = tunnel.remoteHome }
            } else { path = (socketPath as NSString).expandingTildeInPath }
            if effectiveSocketPath != path {
                clearPowerStatus()
                clearGitStatus()
                effectiveSocketPath = path
                client = HerdrClient(socketPath: path)
            }
            let activeClient = client
            let response = try await activeClient.request("session.snapshot")
            let snapshot = try response["snapshot"].decode(SessionSnapshot.self)
            guard generation == connectionGeneration, !Task.isCancelled, expectedLayoutRevision == layoutRevision else { return }
            if version != snapshot.version { version = snapshot.version }
            if protocolVersion != snapshot.protocolVersion { protocolVersion = snapshot.protocolVersion }
            if workspaces != snapshot.workspaces { workspaces = snapshot.workspaces }
            if tabs != snapshot.tabs { tabs = snapshot.tabs }
            if panes != snapshot.panes { panes = snapshot.panes }
            if agents != snapshot.agents { agents = snapshot.agents }
            if revision == selectionRevision {
                if !workspaces.contains(where: { $0.id == selectedSpace }) {
                    let resolved = snapshot.focusedWorkspaceID ?? workspaces.first?.id
                    if selectedSpace != resolved { selectedSpace = resolved }
                }
                if !visibleTabs.contains(where: { $0.id == selectedTab }) {
                    let resolved = currentSpace?.activeTabID ?? visibleTabs.first?.id
                    if selectedTab != resolved { selectedTab = resolved }
                }
                if !visiblePanes.contains(where: { $0.id == selectedPane }) {
                    let resolved = visiblePanes.first(where: { $0.id == snapshot.focusedPaneID })?.id ?? visiblePanes.first?.id
                    if selectedPane != resolved { selectedPane = resolved }
                }
            }
            let liveTabIDs = Set(tabs.map(\.id))
            pendingLayoutRefresh.formIntersection(liveTabIDs)
            let retainedLayouts = layouts.filter { liveTabIDs.contains($0.key) }
            if layouts != retainedLayouts { layouts = retainedLayouts }
            let layoutTabIDs = pendingLayoutRefresh.union(selectedTab.map { [$0] } ?? [])
            for tabID in layoutTabIDs.sorted() {
                let result = try await activeClient.request("layout.export", params: ["tab_id": .string(tabID)])
                let layout = try result["layout"].decode(TabLayout.self)
                guard generation == connectionGeneration, !Task.isCancelled, expectedLayoutRevision == layoutRevision else { return }
                if layouts[tabID] != layout { layouts[tabID] = layout }
                pendingLayoutRefresh.remove(tabID)
                if selectedTab == tabID {
                    let resolved = layout.resolveSelectedPane(selectedPane)
                    if selectedPane != resolved { selectedPane = resolved }
                }
            }
            if !connected { connected = true }
            refreshPowerIfNeeded()
            refreshGitIfNeeded()
            if connectionError != nil { connectionError = nil }
            persistSelection()
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled, expectedLayoutRevision == layoutRevision else { return }
            if connected { connected = false }
            clearPowerStatus()
            if connectionError != error.localizedDescription { connectionError = error.localizedDescription }
            if isRemote { retryAfter = Date().addingTimeInterval(10) }
        }
    }

    /// Called by the session poll, but power queries run independently of workspace requests.
    func refreshPowerIfNeeded(now: Date = Date()) {
        guard connected, !suspended, powerTask == nil, now >= nextPowerRefresh else { return }
        let id = UUID()
        powerReadID = id
        nextPowerRefresh = now.addingTimeInterval(60)
        let profile = profile, reader = powerReader
        powerTask = Task { [weak self] in
            let status = try? await reader(profile)
            guard let self, !Task.isCancelled, self.powerReadID == id else { return }
            if self.powerStatus != status { self.powerStatus = status }
            self.powerTask = nil
            self.powerReadID = nil
        }
    }

    private func clearPowerStatus() {
        powerTask?.cancel()
        powerTask = nil
        powerReadID = nil
        nextPowerRefresh = .distantPast
        if powerStatus != nil { powerStatus = nil }
    }

    /// Like herdr, a workspace's repository follows the working directory of its first tab's first pane.
    var workspaceGitDirectories: [String: String] {
        var result: [String: String] = [:]
        for space in workspaces {
            guard let tab = tabs.first(where: { $0.workspaceID == space.id }),
                  let pane = panes.first(where: { $0.tabID == tab.id }),
                  let directory = pane.cwd ?? pane.foregroundCwd, !directory.isEmpty else { continue }
            result[space.id] = directory
        }
        return result
    }

    /// Called by the session poll; git runs in its own task, sooner when a workspace's directory changes.
    /// A failed read keeps the last branches rather than blanking the sidebar on a transient SSH error.
    func refreshGitIfNeeded(now: Date = Date()) {
        guard connected, !suspended, gitTask == nil else { return }
        let directories = workspaceGitDirectories
        guard now >= nextGitRefresh || directories != gitDirectories else { return }
        let id = UUID()
        gitReadID = id
        gitDirectories = directories
        nextGitRefresh = now.addingTimeInterval(isRemote ? 20 : 5)
        let profile = profile, reader = gitReader
        let unique = Array(Set(directories.values)).sorted()
        gitTask = Task { [weak self] in
            let byDirectory = try? await reader(profile, unique)
            guard let self, !Task.isCancelled, self.gitReadID == id else { return }
            if let byDirectory {
                let status = directories.compactMapValues { byDirectory[$0] }
                if self.gitStatus != status { self.gitStatus = status }
            }
            self.gitTask = nil
            self.gitReadID = nil
        }
    }

    private func clearGitStatus() {
        gitTask?.cancel()
        gitTask = nil
        gitReadID = nil
        nextGitRefresh = .distantPast
        gitDirectories = [:]
        if !gitStatus.isEmpty { gitStatus = [:] }
    }

    func selectSpace(_ space: Workspace) {
        selectionRevision += 1
        selectedSpace = space.id
        selectedTab = space.activeTabID
        selectedPane = layouts[space.activeTabID]?.resolveSelectedPane(nil) ?? panes.first { $0.tabID == space.activeTabID }?.id
        perform("workspace.focus", params: ["workspace_id": .string(space.id)])
        persistSelection()
    }

    func selectTab(_ tab: HerdrCore.Tab) {
        selectionRevision += 1
        selectedSpace = tab.workspaceID
        selectedTab = tab.id
        selectedPane = layouts[tab.id]?.resolveSelectedPane(nil) ?? panes.first { $0.tabID == tab.id }?.id
        perform("tab.focus", params: ["tab_id": .string(tab.id)])
        persistSelection()
    }

    func focusPane(_ id: String) {
        guard selectedPane != id else { return }
        selectedPane = id
        perform("pane.focus", params: ["pane_id": .string(id)], showBusy: false)
    }

    func revealAgent(_ agent: Agent) {
        selectionRevision += 1
        selectedSpace = agent.workspaceID
        selectedTab = agent.tabID
        selectedPane = agent.paneID
        perform("pane.focus", params: ["pane_id": .string(agent.paneID)])
    }

    private func persistSelection() {
        defaults.set(selectedSpace, forKey: "selectedSpace:\(profile.id.uuidString)")
        defaults.set(selectedTab, forKey: "selectedTab:\(profile.id.uuidString)")
    }

    func perform(_ method: String, params: [String: JSONValue], showBusy: Bool = true, completion: ((JSONValue) -> Void)? = nil) {
        guard connected, !suspended else { return }
        let activeClient = client
        let generation = connectionGeneration
        Task {
            defer { if showBusy, generation == connectionGeneration { busy = false } }
            guard generation == connectionGeneration, connected, !suspended else { return }
            if showBusy { busy = true }
            do {
                let result = try await activeClient.request(method, params: params, timeout: method == "agent.start" ? 40 : 8)
                guard generation == connectionGeneration else { return }
                completion?(result)
                await refresh()
            } catch {
                guard generation == connectionGeneration else { return }
                operationError = error.localizedDescription
            }
        }
    }

    func createSpace(label: String, cwd: String) {
        perform("workspace.create", params: ["label": .string(label), "cwd": .string(cwd), "focus": .bool(true)]) { [weak self] result in
            self?.selectionRevision += 1
            self?.selectedSpace = result["workspace"]["workspace_id"].string
            self?.selectedTab = result["tab"]["tab_id"].string
            self?.selectedPane = result["root_pane"]["pane_id"].string
        }
    }

    func createTab(label: String) {
        guard let space = selectedSpace else { return }
        var params: [String: JSONValue] = ["workspace_id": .string(space), "label": .string(label), "focus": .bool(true)]
        if let cwd = currentPane?.directory, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        perform("tab.create", params: params) { [weak self] result in
            self?.selectionRevision += 1
            self?.selectedTab = result["tab"]["tab_id"].string
            self?.selectedPane = result["root_pane"]["pane_id"].string
        }
    }

    func split(_ direction: SplitDirection, paneID: String? = nil) {
        guard let pane = paneID ?? selectedPane else { return }
        perform("pane.split", params: ["target_pane_id": .string(pane), "direction": .string(direction.rawValue), "focus": .bool(true)]) { [weak self] result in
            self?.selectedPane = result["pane"]["pane_id"].string
        }
    }

    func setRatio(tabID: String, path: [Bool], ratio: Double) {
        guard connected, !suspended, paneMoveID == nil else { return }
        let activeClient = client
        let generation = connectionGeneration
        let precedingResize = splitResizeTask
        pendingSplitResizes += 1
        pendingLayoutRefresh.insert(tabID)
        // Reject exports already in flight, and hold new polls until the
        // queued commits finish so they cannot publish intermediate ratios.
        layoutRevision += 1
        splitResizeTask = Task {
            await precedingResize?.value
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            defer {
                if generation == connectionGeneration {
                    pendingSplitResizes -= 1
                    if pendingSplitResizes == 0 { splitResizeTask = nil }
                }
            }
            do {
                let result = try await activeClient.request("layout.set_split_ratio", params: [
                    "tab_id": .string(tabID), "path": .array(path.map(JSONValue.bool)),
                    "ratio": .number(min(0.9, max(0.1, ratio)))
                ])
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                let layout = try result["layout"].decode(TabLayout.self)
                if pendingSplitResizes == 1 {
                    if layouts[tabID] != layout { layouts[tabID] = layout }
                    pendingLayoutRefresh.remove(tabID)
                }
            } catch {
                guard generation == connectionGeneration, !Task.isCancelled else { return }
                operationError = error.localizedDescription
            }
        }
    }

    func paneDragPayload(for paneID: String) -> PaneDragPayload? {
        guard connected, !suspended, !busy, paneMoveID == nil, pendingSplitResizes == 0, sheet == nil, pendingClose == nil,
              let pane = panes.first(where: { $0.id == paneID }),
              selectedTab == pane.tabID, let layout = layouts[pane.tabID],
              !layout.zoomed, layout.root.paneIDs.contains(paneID) else { return nil }
        return PaneDragPayload(deviceID: profile.id, connectionGeneration: connectionGeneration,
                               tabID: pane.tabID, paneID: paneID)
    }

    func canMovePane(_ source: PaneDragPayload, to targetID: String) -> Bool {
        source.paneID != targetID && paneDragPayload(for: source.paneID) == source
            && paneDragPayload(for: targetID)?.tabID == source.tabID
    }

    func canMovePane(_ source: PaneDragPayload, toTab tabID: String) -> Bool {
        paneDragPayload(for: source.paneID) == source && source.tabID != tabID
            && visibleTabs.contains { $0.id == tabID }
    }

    @discardableResult
    func movePane(_ source: PaneDragPayload, toTab tabID: String) -> Bool {
        guard canMovePane(source, toTab: tabID) else { return false }
        busy = true
        operationError = nil
        let activeClient = client, generation = connectionGeneration
        let moveID = UUID(), revision = selectionRevision
        paneMoveID = moveID
        layoutRevision += 1
        Task {
            defer {
                if generation == connectionGeneration, paneMoveID == moveID || paneMoveID == nil { busy = false }
                if paneMoveID == moveID { paneMoveID = nil }
            }
            guard generation == connectionGeneration, connected, !suspended else { return }
            do {
                let result = try await activeClient.request("pane.move", params: [
                    "pane_id": .string(source.paneID), "focus": .bool(true),
                    "destination": .object(["type": .string("tab"), "tab_id": .string(tabID),
                                            "split": .string("right"), "ratio": .number(0.5)])
                ])
                guard generation == connectionGeneration, !suspended else { return }
                guard result["move_result"]["changed"] == .bool(true) else {
                    let message = result["move_result"]["reason"].string == "zoomed_tab"
                        ? "Restore the split layout in both tabs before moving this pane."
                        : "Herdr did not move the pane. Refresh and try again."
                    throw HerdrError.message(message)
                }
                if revision == selectionRevision {
                    selectedTab = tabID
                    selectedPane = source.paneID
                }
            } catch {
                guard generation == connectionGeneration else { return }
                operationError = error.localizedDescription
            }
            // Reconcile both trees even after an ambiguous transport failure.
            // Keep this queued if another snapshot is already in flight.
            pendingLayoutRefresh.formUnion([source.tabID, tabID])
            if paneMoveID == moveID { paneMoveID = nil }
            await refresh()
        }
        return true
    }

    @discardableResult
    func movePane(_ source: PaneDragPayload, to targetID: String, edge: PaneDockEdge) -> Bool {
        guard canMovePane(source, to: targetID), let pane = panes.first(where: { $0.id == source.paneID }) else { return false }
        busy = true
        operationError = nil
        let activeClient = client, generation = connectionGeneration
        let moveID = UUID()
        paneMoveID = moveID
        layoutRevision += 1
        let revision = selectionRevision
        Task {
            defer {
                if generation == connectionGeneration, paneMoveID == moveID || paneMoveID == nil { busy = false }
                if paneMoveID == moveID { paneMoveID = nil }
            }
            guard generation == connectionGeneration, connected, !suspended else { return }
            var parkingTabID: String?
            do {
                // Herdr 0.8.x treats same-tab pane.move as a no-op. Transfer via
                // a temporary tab; moving its last pane back closes it safely.
                // Suppress intermediate polling so the mounted terminals stay put.
                let parked = try await activeClient.request("pane.move", params: [
                    "pane_id": .string(source.paneID), "focus": .bool(false),
                    "destination": .object(["type": .string("new_tab"),
                                            "workspace_id": .string(pane.workspaceID), "label": .string(pane.displayTitle)])
                ])
                guard generation == connectionGeneration, !suspended else { return }
                parkingTabID = parked["move_result"]["pane"]["tab_id"].string
                _ = try await activeClient.request("pane.move", params: [
                    "pane_id": .string(source.paneID), "focus": .bool(true),
                    "destination": .object([
                        "type": .string("tab"), "tab_id": .string(source.tabID),
                        "target_pane_id": .string(targetID),
                        "split": .string(edge.splitDirection.rawValue), "ratio": .number(0.5)
                    ])
                ])
                guard generation == connectionGeneration, !suspended else { return }
                parkingTabID = nil
                // Herdr inserts after the target. Reverse only the newly created
                // pair for top/left docking; the source's old split has collapsed.
                if edge.insertsBefore {
                    _ = try await activeClient.request("pane.swap", params: [
                        "source_pane_id": .string(source.paneID), "target_pane_id": .string(targetID)
                    ])
                }
                guard generation == connectionGeneration else { return }
                if revision == selectionRevision, selectedTab == source.tabID { selectedPane = source.paneID }
            } catch {
                guard generation == connectionGeneration else { return }
                operationError = error.localizedDescription
            }
            if let parkingTabID, generation == connectionGeneration {
                operationError = (operationError ?? "Could not finish moving the pane.") + "\nThe terminal has not been closed. Check its tab before retrying."
                if revision == selectionRevision {
                    selectedSpace = pane.workspaceID
                    selectedTab = parkingTabID
                    selectedPane = source.paneID
                }
            }
            // Fetch the final tree even after failure; never close a temporary
            // tab that still holds the user's live terminal.
            if paneMoveID == moveID { paneMoveID = nil }
            await refresh()
        }
        return true
    }

    func zoom(_ paneID: String) { selectedPane = paneID; perform("pane.zoom", params: ["pane_id": .string(paneID), "mode": .string("toggle")]) }
    func rename(_ target: ResourceTarget, label: String) {
        perform("\(target.kind).rename", params: ["\(target.kind)_id": .string(target.id), "label": .string(label)])
    }
    func close(_ target: ResourceTarget) {
        perform("\(target.kind).close", params: ["\(target.kind)_id": .string(target.id)])
    }
    func startAgent(paneID: String, kind: String, name: String) {
        guard connected, !suspended, !busy else { return }
        guard let pane = panes.first(where: { $0.id == paneID }), pane.directory.hasPrefix("/") else {
            operationError = "Could not find the pane’s project folder. Refresh and try again."
            return
        }
        let activeClient = client
        let generation = connectionGeneration
        let directory = pane.directory
        busy = true
        operationError = nil
        Task {
            defer { if generation == connectionGeneration { busy = false } }
            guard generation == connectionGeneration, connected, !suspended else { return }
            var createdWorktree = false
            do {
                let created = try await activeClient.request("worktree.create", params: [
                    "cwd": .string(directory), "label": .string(name), "focus": .bool(true)
                ], timeout: 60)
                guard generation == connectionGeneration else { return }
                createdWorktree = true
                let rootPane = try created["root_pane"].decode(Pane.self)
                selectionRevision += 1
                selectedSpace = rootPane.workspaceID
                selectedTab = rootPane.tabID
                selectedPane = rootPane.id
                await refresh()
                guard generation == connectionGeneration, connected, !suspended else { return }
                _ = try await activeClient.request("agent.start", params: [
                    "pane_id": .string(rootPane.id), "kind": .string(kind),
                    "name": .string(name), "timeout_ms": .number(30000)
                ], timeout: 40)
            } catch {
                guard generation == connectionGeneration else { return }
                operationError = error.localizedDescription
            }
            guard generation == connectionGeneration else { return }
            if createdWorktree { await refresh() }
        }
    }

    func startServer() {
        guard !isRemote else { return }
        guard serverProcess?.isRunning != true else { return }
        do {
            let path = (socketPath as NSString).expandingTildeInPath
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = [(executable as NSString).expandingTildeInPath, "server"]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "HERDR_SESSION")
            env.removeValue(forKey: "HERDR_CLIENT_SOCKET_PATH")
            env["HERDR_SOCKET_PATH"] = path
            process.environment = env
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            serverProcess = process
        } catch { operationError = error.localizedDescription }
    }
}

struct ResourceTarget: Identifiable {
    let kind: String
    let id: String
    let label: String
    var singular: String { kind == "workspace" ? "space" : kind }
}

enum AppSheet: Identifiable {
    case space, tab, rename(ResourceTarget), agent(String), settings
    var id: String {
        switch self {
        case .space: return "space"
        case .tab: return "tab"
        case .rename(let target): return "rename-\(target.id)"
        case .agent(let id): return "agent-\(id)"
        case .settings: return "settings"
        }
    }
}
