import Foundation
import HerdrCore

struct WorkspaceGitTests {
    @MainActor static func run() async throws {
        let dirs = ["/a", "/b", "/c", "/d"]
        let output = "Login banner\nherdr-git\t0\tmain\t77\t0\nherdr-git\t1\t\t\nherdr-git\t2\tfeature/x\t\nherdr-git\t3\tdev\t2\t5\nherdr-git\t9\tstray\t1\t1\nnoise\t0\tmain\n"
        XCTAssertEqual(WorkspaceGitStatus.parse(output, directories: dirs), [
            "/a": WorkspaceGitStatus(branch: "main", ahead: 77),
            "/c": WorkspaceGitStatus(branch: "feature/x"),
            "/d": WorkspaceGitStatus(branch: "dev", ahead: 2, behind: 5),
        ])
        XCTAssertEqual(WorkspaceGitStatus.parse("herdr-git\t0\tmain\t-1\t2\n", directories: ["/a"]), ["/a": WorkspaceGitStatus(branch: "main")])
        XCTAssertEqual(WorkspaceGitStatus.parse("", directories: dirs), [:])

        // A real repository with an upstream, read through the same script the app runs.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-git-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/it's a repo", remote = root + "/remote.git", detached = root + "/detached", plain = root + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        try git(root, "init", "-q", "--bare", "-b", "main", remote)
        try git(root, "clone", "-q", remote, repo)
        for n in 1...3 { try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "c\(n)") }
        try git(repo, "push", "-q", "origin", "main")
        try git(repo, "reset", "-q", "--hard", "HEAD~1")
        for n in 4...5 { try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "c\(n)") }
        try git(repo, "checkout", "-q", "-b", "no-upstream")
        try git(root, "clone", "-q", remote, detached)
        try git(detached, "checkout", "-q", "--detach")
        let local = DeviceProfile(name: "Local", kind: .local, socketPath: "/tmp/unused.sock", executable: "/tmp/unused")
        var read = try await WorkspaceGitStatus.read(local, directories: [repo, detached, plain, root + "/missing"])
        XCTAssertEqual(read, [repo: WorkspaceGitStatus(branch: "no-upstream")])
        try git(repo, "checkout", "-q", "main")
        read = try await WorkspaceGitStatus.read(local, directories: [repo])
        XCTAssertEqual(read, [repo: WorkspaceGitStatus(branch: "main", ahead: 2, behind: 1)])
        XCTAssertEqual(try await WorkspaceGitStatus.read(local, directories: []), [:])

        // Remote devices run the script with sh in a single SSH command.
        let profile = DeviceProfile(name: "Git fixture", host: "git.test", user: "tester", port: "2222", executable: "/bin/herdr")
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/ssh-git-fixture.sh"
        let remoteRead = try await WorkspaceGitStatus.read(profile, directories: [repo, plain], sshExecutable: fixture)
        XCTAssertEqual(remoteRead, [repo: WorkspaceGitStatus(branch: "main", ahead: 2, behind: 1)])
        print("PASS: workspace git branches, ahead/behind, detached, no upstream, non-repositories, quoting and remote query")
    }

    private static func git(_ directory: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HerdrError.message("git \(arguments.joined(separator: " ")) failed") }
    }
}
