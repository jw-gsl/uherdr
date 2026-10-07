import Foundation

/// The branch line herdr's own sidebar shows: the checked-out branch, and commits ahead of and behind its upstream.
public struct WorkspaceGitStatus: Equatable, Sendable {
    public let branch: String
    public let ahead: Int
    public let behind: Int

    public init(branch: String, ahead: Int = 0, behind: Int = 0) {
        self.branch = branch; self.ahead = ahead; self.behind = behind
    }

    private static let marker = "herdr-git"

    /// One POSIX script reads every directory, so a remote device costs a single SSH connection per refresh.
    /// Neither command scans the working tree or takes the index lock, so polling stays cheap while agents commit.
    /// Ahead/behind is relative to the upstream tracking branch, as in herdr; detached HEAD and non-repositories report no branch.
    public static func script(directories: [String]) -> String {
        let list = directories.map(quote).joined(separator: " ")
        return #"PATH="$PATH:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"; export LC_ALL=C GIT_OPTIONAL_LOCKS=0; i=0; "#
            + "for d in \(list); do "
            + #"c=; b=$(git -C "$d" symbolic-ref --quiet --short HEAD 2>/dev/null) && c=$(git -C "$d" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null); "#
            + #"printf '\#(marker)\t%s\t%s\t%s\n' "$i" "$b" "$c"; i=$((i+1)); done"#
    }

    /// Maps each directory to its status. Directories without a branch are omitted; unrelated output such as login banners is ignored.
    public static func parse(_ output: String, directories: [String]) -> [String: Self] {
        var result: [String: Self] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, fields[0] == marker, let index = Int(fields[1]), directories.indices.contains(index) else { continue }
            let branch = fields[2]
            guard !branch.isEmpty, !branch.contains(where: \.isNewline) else { continue }
            var ahead = 0, behind = 0
            if fields.count == 5, let a = Int(fields[3]), let b = Int(fields[4]), a >= 0, b >= 0 { ahead = a; behind = b }
            result[directories[index]] = Self(branch: branch, ahead: ahead, behind: behind)
        }
        return result
    }

    @MainActor public static func read(_ profile: DeviceProfile, directories: [String], sshExecutable: String = "/usr/bin/ssh") async throws -> [String: Self] {
        guard !directories.isEmpty else { return [:] }
        try Task.checkCancellation()
        let script = script(directories: directories)
        let process: ManagedProcess
        if profile.kind == .ssh {
            // An explicit sh keeps the script POSIX whatever the remote login shell is.
            process = try ManagedProcess(executable: sshExecutable, arguments: profile.sshArguments() + ["--", profile.host, "sh -c \(quote(script))"])
        } else {
            process = try ManagedProcess(executable: "/bin/sh", arguments: ["-c", script])
        }
        let output = try await process.result(timeout: 12)
        try Task.checkCancellation()
        return parse(output, directories: directories)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
