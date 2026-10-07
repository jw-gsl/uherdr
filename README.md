# uHerdr client for macOS

A native SwiftUI + AppKit client for the herdr runtime. Spaces map to herdr workspaces; each space has tabs with nested, resizable terminal panes. The Agents view shows detected agents and their status.

<img width="1299" height="909" alt="Screenshot 2026-09-23 at 16 18 45" src="https://github.com/user-attachments/assets/dfc6656a-3202-41ab-bbf7-e28acb92b190" />

## Requirements

- macOS 14 or newer.
- Swift command-line tools (Swift 6.0 or newer) to build.
- herdr 0.9.0 or newer with `herdr terminal session control` support.

## Build and run

```sh
git clone https://github.com/MrMySQL/uherdr.git
cd uherdr
./scripts/build-app.sh
open dist/Herdr.app
```

Open `Package.swift` in Xcode to develop the app, or use `swift build` and `swift run HerdrCoreTests` from a terminal. Swift Package Manager downloads GhosttyTerminal's checksummed native XCFramework and MSDisplayLink on the first build. The pinned Swift wrapper is vendored in this repository.

The sidebar groups spaces and agents by device. Beside each computer icon, a battery outline shows that Mac’s charge percentage, with a bolt when connected to power; Macs without an internal battery show a plug. Power status refreshes on connection or reconnection and every minute while connected. Disconnected devices and unavailable readings hide the indicator. **This Mac** uses your default local herdr socket and preserves existing connection preferences. Under each space, the sidebar shows its Git branch with ↑ahead / ↓behind its upstream, as herdr's own sidebar does; it follows the first tab's first pane's directory, refreshes every 5 seconds (20 seconds over SSH, one connection for all spaces), and spaces outside a branch show their tab and pane counts instead. Use the menu beside a device to edit its socket and local herdr executable. Start herdr first, or use the local device's Start Server button. Quit detaches the client; shells and agents remain owned by herdr.

## Connect another device over SSH

1. On the other Mac, enable Remote Login and start herdr. Install a compatible herdr CLI on this Mac too; the app uses it for compatibility with other server protocol versions.
2. Configure SSH key authentication and connect once from Terminal (for example, `ssh alex@mac-mini.local`) to verify the host key. Existing SSH aliases, keys, agents, ports, and jump hosts in `~/.ssh/config` are supported. Password-only authentication and interactive passphrase prompts are not supported in the app; unlock encrypted keys in your SSH agent first.
3. Click **Add device…** in the sidebar. Enter a name and SSH host, such as `alex@mac-mini.local` or an SSH-config alias. Username, port, and identity file are optional overrides.
4. Leave **Remote socket** empty to discover the remote default socket. For a named session, enter `~/.config/herdr/sessions/<name>/herdr.sock`. The executable field always refers to the herdr CLI on this Mac.
5. Click **Save and connect**. All devices stay visible together. Click a space to work on its device; each device remembers its selection. When creating a remote space, enter an absolute folder path on that device.

Each remote device has its own SSH connection forwarding two private Unix sockets: the workspace API socket and herdr's companion `-client.sock` terminal socket, using [OpenSSH local socket forwarding](https://man.openbsd.org/ssh.1#L). Host verification stays enabled. The remote SSH server must allow Unix-socket forwarding (`AllowStreamLocalForwarding`). No herdr TCP listener is required.

Connection errors appear under the affected device and in its detail view. Failed remote connections retry every ten seconds. Use the device menu to reconnect immediately, disconnect, edit, or remove a saved connection. Disconnecting or removing a device leaves its remote workspaces and processes running. Start/stop of remote herdr servers is managed on the remote device.

## Interaction

- Sidebar: switch between Spaces and Agents, grouped by device; select a space or jump to an agent. Agents show their own product's mark in the sidebar, pane header, and tabs (Claude Code, Codex, and the other agents herdr detects); agents without one show ✦. Tabs stack up to three marks, then show +N. The marks belong to their owners; their sources are listed in `Sources/HerdrMac/Resources/AgentIcons/SOURCES.md`. Command-1 through Command-9 select the first nine spaces across devices in sidebar order. Hold Command or Control to reveal shortcut badges on the space cards and tabs. Search filtering and collapsing devices do not renumber shortcuts. Command-Shift-R renames the current space.
- Tabs: create with Command-T and rename the current tab with Command-R. Control-1 through Control-9 select the first nine tabs in the current space, and Control-0 selects the tenth. Control-Tab selects the next tab, and Control-Shift-Tab selects the previous tab, wrapping at either end. Command-Shift-] and Command-Shift-[ also cycle tabs. Rename and close from the context menu. Drag a tab to the left or right edge of another tab to reorder it. The order is saved locally per device and workspace and is used by keyboard tab navigation.
- Panes: Command-D splits side by side; Command-Shift-D stacks panes; Command-Return toggles zoom for the focused pane. Command-[ selects the previous pane and Command-] selects the next pane in the current tab, wrapping at either end. Control-backtick also selects the next pane. Drag the divider to resize. Drag a pane’s header to the top, bottom, left, or right edge of another pane in the same tab. A translucent rectangle previews its half of the new split. Dropping moves the pane there and collapses its old split. To move between tabs, drop the pane header onto another tab in the same space, or choose **Move to tab** in the pane’s actions menu. The destination opens with the moved pane in a side-by-side split. Moving a tab’s last pane removes the empty tab; running shells and agents are preserved. Restore the split layout in both tabs before moving a pane between them. Use the pane header to focus, zoom, rename, start an agent, or close.
- Start an agent: creates a Git worktree from the pane’s repository, opens it in a new space, and launches the selected agent there. Herdr generates the branch name. The selected agent CLI must be installed. If launching fails, the new space stays available for retrying in its terminal.
- Terminal: normal keyboard input, Shift-Enter for a new line in Claude Code and Codex, native text selection with automatic copying on release, Command-C/Command-V, and mouse-wheel scrolling. Command-plus (or Command-equals) increases text size; Command-minus decreases it, in one-point steps from 10 to 22 pt. The size is saved with your appearance preferences.
- Long multiline paste uses the existing input connection with stock Herdr 0.9.0 or newer. No custom server patch or reconnect on paste is needed; see [paste handling](docs/terminal-paste.md).
- Find in pane: Command-F or the pane actions menu opens a searchable output snapshot, including up to 10,000 recent scrollback lines. Matching is literal and case-insensitive. Return / Shift-Return or Command-G / Command-Shift-G navigate highlighted matches with wraparound. Refresh reads new output; Escape closes search and returns keyboard focus to the running terminal. Truncated history is labeled.
- Links: click a web URL or labeled hyperlink in terminal output to open it in your default browser, including in mouse-enabled applications such as Claude Code. Command-click also works; dragging selects text and copies it on release. With stock Herdr 0.9.0 (protocol 22), application mouse events and OSC 52 clipboard writes are forwarded too. Hold Shift while dragging to select and copy locally instead.
- File drops: drag one or more files from Finder onto a Codex, Claude Code, or other terminal pane. Local panes paste quoted local paths. For devices connected through Herdr’s SSH profiles, files upload over SSH first, then their remote paths are pasted. The pane shows upload progress and reports failures. Each drop uses a private `/tmp/herdr-drop-…` directory, preserving filenames without overwriting earlier uploads. Remote uploads support regular files, including images; folders are not supported. Files remain available until the remote system cleans its temporary directory. The target pane gains keyboard focus; press Enter when your prompt is ready. SSH or containers launched manually inside a local pane are not detected as remote devices.
- Command-N creates a space. Command-comma opens Settings.

Closing a pane, tab, or space terminates its processes and therefore asks for confirmation. Terminal ownership conflicts are shown on the affected pane; Take Control explicitly replaces the previous writable controller.

## Architecture

`HerdrCore` contains Codable protocol/device models, bounded JSON line parsing, Unix socket requests, and managed SSH processes. `HerdrMac` contains the SwiftUI shell, a device store with one independent session store per device, and the GhosttyTerminal AppKit bridge. For server protocol 22, each terminal uses the stock binary terminal socket directly, forwarding structured mouse events and receiving mouse-capture updates. A focused native pane with application mouse capture opens a client-shell connection for application clipboard writes; that connection closes when focus leaves. Other protocol versions use the local `herdr terminal session control` JSON stream. Each remote device forwards both its API socket and the companion terminal socket over its SSH connection. Ghostty's host-managed in-memory backend renders these frames and encodes keyboard/mouse input; Herdr owns the shell and scrollback. The native protocol is version-gated; the CLI handles negotiation for the compatibility transport. Shells are never spawned as substitutes for server panes.

GhosttyTerminal is the sole terminal backend in this prototype. The Swift wrapper is vendored from `1.5.20260906` with a small addition exposing the native replay API; see [vendor provenance and patch notes](Vendor/GhosttyTerminal/README.md). The community binary carries host-managed I/O patches over Ghostty. Native font/theme changes update the existing surface. Terminal-query replies generated while rendering server frames are suppressed at their source, because Herdr handles those queries upstream. Mouse-wheel events continue to use Herdr's scroll protocol.

Connection state is refreshed from authoritative snapshots. UI actions use explicit server resource IDs. Window geometry and connection/appearance preferences are persisted locally.

## Distribution

The build script creates an ad-hoc-signed app for local use. Distribution to other Macs requires your own Developer ID signing and notarization. The herdr runtime is installed separately.

## Dependencies

[GhosttyTerminal / libghostty-spm](https://github.com/Lakr233/libghostty-spm) supplies the Swift/AppKit integration around [Ghostty](https://github.com/ghostty-org/ghostty), with [MSDisplayLink](https://github.com/Lakr233/MSDisplayLink) for display scheduling. These dependencies are MIT licensed; their notices are included in the built app. [Herdr](https://github.com/herdrdev/herdr) supplies the runtime and terminal/control protocols.

## Verification

```sh
swift run HerdrCoreTests  # Protocol, layout, selection, and error handling
./scripts/test-hotkeys.sh # Command/Control hint lifecycle and app hotkeys
bash scripts/test-agent-worktree.sh # Worktree agent launch and failure handling
bash scripts/test-terminal-keyboard.sh # Real Ghostty rendering, keyboard, paste, resize, and teardown
bash scripts/test-terminal-paste.sh # End-to-end long paste (stock Herdr 0.9.0+)
bash scripts/test-agent-file-drops.sh # Opt-in: real Codex/Claude text+image drops, local and loopback SSH
bash scripts/test-tab-drag.sh # Tab ordering, persistence, and drag validation
bash scripts/test-performance.sh # Polling and terminal publication regressions
bash scripts/test-git-status.sh # Sidebar branch polling, intervals, directory changes and disconnect
./scripts/test.sh         # Also starts and cleans up an isolated herdr server
bash scripts/test-agent-icons.sh # Agent marks: coverage of herdr's agents, sources, sizes, safe lookup
bash scripts/test-devices.sh # Two isolated servers, overlapping IDs, and forwarded terminal control
```

The standalone Swift test runner works with Command Line Tools; XCTest is not required. Live tests cover workspace/tab/pane lifecycle, nested right/down splits, divider ratios, shell input/output, agent status fixtures, terminal ANSI streaming, resize, scrolling, and detach preservation. They accept only an explicitly disposable socket under `/tmp`.

Topology and agent status refresh independently per device every 1.25 seconds and after actions; terminal output streams continuously. Only visible terminals acquire writable controllers. Switching devices releases the previous terminal controllers without stopping their shells. The multi-device tests use a controlled SSH stand-in with real Unix-stream forwarding, not a physical remote Mac. Kitty graphics overlays are not included in this version.

## Contributing

Issues and pull requests are welcome. Include your macOS, Swift, and herdr versions when reporting a bug, along with steps to reproduce it. For code changes, run the verification commands above and describe any manual UI checks in your pull request.

## License

[MIT](LICENSE). Third-party dependencies retain their own licenses.
