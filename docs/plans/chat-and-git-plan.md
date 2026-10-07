# Plan: git status in the sidebar + chat view from herdr-web-ui

Fork: `jw-gsl/uherdr` (origin), upstream `MrMySQL/uherdr`. Chat source: `devswha/herdr-web-ui` v0.3.52 (MIT).
Target herdr: protocol 22 / schema_version 1.

Two independent workstreams. Ship **git status first** (small, no new dependencies), then chat.

---

## Workstream 1 — Git branch / ahead / behind in the sidebar

### What herdr does (so we match it)
- herdr's public API does **not** carry branch or ahead/behind. `WorkspaceInfo` has only
  `worktree {repo_key, repo_name, repo_root, checkout_path, is_linked_worktree}` and client-set `tokens`
  (herdr `src/api/schema/workspaces.rs:62-85`). The TUI gets `branch` / `git_ahead_behind` over the private
  bincode client-shell protocol (`src/protocol/wire.rs:1044-1056`) — not something to depend on.
- Branch = HEAD's branch; detached HEAD shows nothing (`src/workspace/git/status.rs:233-292`).
- Ahead/behind = `rev-list --left-right --count HEAD...@{upstream}`, i.e. relative to the **upstream tracking
  branch** (`status.rs:294-343`). Shown as `↑N` / `↓N`, hidden when both are 0 (`src/ui/sidebar/tokens.rs:157-160`).
- Directory = live cwd of the first tab's root pane, falling back to the workspace's identity cwd
  (`src/workspace.rs:1011-1020`). Refresh every 1.5 s on a background thread (`src/app/mod.rs:40`).
- Linked-worktree workspaces are indented under their repo and use the branch as the label (`src/client/shell/sidebar.rs:669-687`).
- herdr has **no dirty indicator**.

### Design for uherdr
1. **Model** — decode `worktree` on `Workspace` (`Sources/HerdrCore/Models.swift:7-19`); add a
   `WorkspaceGit { branch: String?, ahead: Int, behind: Int, dirty: Bool? }` value kept in `SessionStore`
   keyed by workspace id (not in the decoded snapshot).
2. **Reader** — new `Sources/HerdrCore/WorkspaceGitStatus.swift`, modelled on `DevicePowerStatus.swift:22-34`:
   - Per directory: `git --no-optional-locks -c core.fsmonitor=false -C <dir> status --porcelain=v2 --branch --untracked-files=no`
     → parse `# branch.head`, `# branch.ab +A -B`, and any non-`#` line = dirty. One call gives everything;
     `--no-optional-locks` avoids taking `index.lock` while agents are committing.
   - Local device: `Process` per directory (or a single `sh -c` loop).
   - SSH device: **one** `ssh <profile.sshArguments()> -- host '<script>'` per refresh that loops over all
     workspace dirs and prints one delimited record each (reuse `RemoteFileTransfer`'s quoter, `:82`).
     Use `command -v git || /usr/bin/git` because non-login SSH PATHs may lack git.
3. **Directory choice** — `worktree.checkout_path` when present; else `cwd` (not `foreground_cwd`) of the first
   pane of the workspace's first tab. Dedupe by directory so N workspaces in one repo cost one call.
4. **Cadence** — its own task like `refreshPowerIfNeeded` (`Sources/HerdrMac/SessionStore.swift:321-335`), never on
   the 1.25 s snapshot poll. Local ~3–5 s; remote ~20 s plus immediately when the workspace set or a root cwd
   changes. These intervals are estimates — every remote call is a fresh SSH handshake because
   `sshArguments` disables ControlMaster (`DeviceProfile.swift:44-49`); measure before tuning.
   One task in flight per device; cancel and clear on `disconnect()`.
5. **UI** — replace the `"N tabs · N panes"` line in `spaceRow` (`Sources/HerdrMac/DeviceSidebarView.swift:126`)
   with `branch` (tail-truncated, secondary colour) + `↑N` (green) / `↓N`. Hide the row when there's no branch
   (keep tabs/panes in a tooltip). Optional uherdr-only extra: a small dot when dirty — make it a setting.
   Later: group linked worktrees under their repo like herdr.
6. **Tests** — parser unit tests in `HerdrCoreTests` (normal, detached, no upstream, gone upstream, non-repo,
   unicode branch); a fixture repo test with an upstream set up via a local bare remote; extend
   `Tests/Fixtures/ssh-fixture.py` for the batched remote script.

Rough size: ~300–400 lines including tests (estimate).

---

## Workstream 2 — Chat view from herdr-web-ui

### Decision: native SwiftUI renderer, web-ui server as the data source (option A)
Options considered:
- **A. Call herdr-web-ui's Bun server over HTTP (chosen).** Its server already resolves each pane to its
  transcript (Claude via `agent.get` → `sessions/<pid>.json` → `projects/<cwd>/<uuid>.jsonl`; Codex via
  `agent_session` / `lsof` / state DB; plus omp, omo, gjc, pi), pages it, caches it, and screen-scrapes
  approval prompts into cards (`server/prompt.ts`, 2.8k lines of per-agent regex we do not want to own).
  Loopback with no `HERDR_WEB_TOKEN` is allowed without auth (`server/access.ts:93`), and POSTs without an
  `Origin` header pass the same-origin check, so `URLSession` works unchanged. It installs as a herdr plugin and
  herdr auto-starts it on `127.0.0.1:7317`.
- B. Port the parsers to Swift — feasible for Claude (~115 lines) and Codex (~320) parsing, but resolution and
  prompt cards are the bulk, and for **SSH devices the transcripts live on the remote disk**, which uherdr cannot
  read today. Keep as a later "no Bun" fallback for local Claude/Codex only.
- C. WKWebView of the web-ui — fastest, but ChatView is not a standalone route (App.tsx owns the shell), it won't
  feel native, and it brings its own WebSocket attach.

### Dependency on the user's machines
Every device that should show chat needs `herdr plugin install devswha/herdr-web-ui` (Bun 1.4+, Node 18+).
uherdr should detect absence (`GET /api/health`) and fall back to the terminal with an "Install chat support" hint
rather than failing.

### Transport
- Local: `http://127.0.0.1:7317`.
- SSH device: add a third forward to `SSHTunnel` (`SSHTunnel.swift:43-46`): `-L <localUnixSock or ephemeral port>:127.0.0.1:7317`.
  It arrives on the remote as loopback, so it's treated as local access. Make the port configurable per device.
- New `Sources/HerdrCore/WebUIClient.swift` (`URLSession`, async/await, ETag support). Pin a minimum web-ui
  version via `/api/health` and degrade gracefully on unknown versions — its API is internal and moves fast.

### Endpoints used (shapes in web-ui `shared/protocol.ts:249-394, 542-588`)
| Need | Endpoint |
|---|---|
| Transcript | `GET /api/pane/conversation?pane_id=&before=&since=` — ETag/304, 409 `history_changed` → reload |
| Full tool output / images | `GET /api/pane/conversation/tool-output`, `/conversation/image` |
| Prompt cards | `GET /api/pane/prompt?pane_id=`, `POST /api/pane/prompt/answer` (409 `prompt_changed` → re-read) |
| Slash commands | `GET /api/pane/commands` (cache 60 s) |
| @file mentions | `GET /api/pane/files?q=` (debounce 150 ms) |
| Image attach | `POST /api/pane/image` → returns a path, insert `@path ` |

**Sending messages goes straight to herdr, not the web-ui**: call herdr's `agent.prompt` over uherdr's existing
socket (exists at herdr `src/api/schema.rs:138`); on `agent_not_found` / `agent_not_ready` fall back to
`pane.send_text` + `pane.send_keys ["Enter"]`, mirroring web-ui `server/index.ts:409-436`. `agent_blocked` → show
the prompt card instead. Stop = send Escape.

### Swift models
Port `ConversationResponse` / `ConversationTurn` / `ConversationPart` (`text`, `thinking`, `skill`, `tool`, `image`,
`compact`, `notice`, `task_result`) and `InteractivePrompt` as `Codable` enums in `HerdrCore`. Unknown part kinds
decode to `.unsupported` so new web-ui releases don't break decoding. Also decode `agent_session` on `Pane`
(`Models.swift:34-53`) — useful for gating the chat toggle and for a future option B.

### UI
- Per-pane **Terminal ⇄ Chat** toggle in the pane header; the chat view overlays the pane in `PaneCard`'s ZStack
  (`PaneLayoutView.swift:329-361`). Keep `TerminalSurface` mounted underneath (`TerminalTabDeck` already keeps
  hidden terminals alive, `TerminalTabDeck.swift:52-70`), so switching back is instant and nothing re-attaches.
  Only offer Chat for panes whose `agent` is a supported one.
- `ChatView` (SwiftUI `ScrollView` + `LazyVStack`): user/assistant turns, collapsible "work blocks" grouping tools +
  thinking (port the grouping rules from web-ui `src/lib/workBlocks.ts`), tool rows with lazy full output, edit diffs,
  images, todo lists, load-older on scroll-to-top.
- Markdown: start with `AttributedString(markdown:)` for inline formatting plus a small block renderer
  (headings, lists, fenced code with monospaced background, tables as a grid). Skip KaTeX initially.
- `PromptCardView`: options as buttons, multi-select, custom text; disable after send until the next poll.
- `Composer`: multiline `TextEditor`, Return to send / Shift-Return newline, `/` command popover, `@` file popover,
  paste/drop image → upload → insert path (reuse the existing file-drop staging where possible).
- Sidebar "Needs you" badge already exists via `agent_status == blocked`; tapping it should open the pane in Chat
  with the card visible.

### Refresh
Web-ui polls (no push for transcripts): conversation every 2 s with ETag, prompt every 2 s. Do the same but only
for **visible** chat panes, and poll prompt only when `agent_status` is `blocked` or `working` (the 1.25 s snapshot
already tells us). Faster poll (~1 s) while `working`, back off to 5 s when `idle`/`done` — estimates to tune.

### Phases
1. `WebUIClient` + `Conversation` models + decoding tests against captured JSON fixtures from a live web-ui.
2. Read-only `ChatView` for local Claude Code panes (text, thinking, tools collapsed). Toggle in pane header.
3. Composer sending via `agent.prompt`; Stop.
4. Prompt cards (read + answer).
5. Codex + other agents; diffs, images, tool output, paging.
6. SSH devices: port-forward 7317, health detection, install hint.
7. Slash/@ popovers, image attach, polish, settings (web-ui port, chat on/off per device).

Rough size: phases 1–4 ~1.5–2.5k lines of Swift; the full set ~3–4k (estimates based on the size of the
React components being replaced: ChatView 918, Composer 1042, PromptCard 217, Markdown + parser ~510).

---

## Risks / open questions
- **web-ui API churn**: 632 commits in ~3 weeks, mostly one author. Capture JSON fixtures, version-gate, and keep
  decoding lenient. Consider contributing a documented `/api/v1` upstream.
- **Codex `agent_session`** is not always reported by herdr for shared app-server TUIs (web-ui
  `docs/chat-mode-audit.md:238-240`); web-ui's screen-match fallback covers it, which is another reason for option A.
- **Bun on remote hosts** — check what's installed on the remote devices (e.g. Ember).
- **Upstream sync** — keep changes in new files where possible and small hooks in `PaneLayoutView` /
  `DeviceSidebarView` / `SSHTunnel`, so `git merge upstream/main` stays easy. Workstream 1 is a good candidate to
  offer back upstream as a PR.
- **Licensing** — both MIT; keep web-ui's copyright notice for any ported logic (e.g. work-block grouping) in a
  `docs/licenses/herdr-web-ui-LICENSE`, as is already done for Ghostty.

---

## Findings log

### 2026-10-07 — spike results
- **Workstream 1 shipped on `feat/workspace-git-status`.** Uses `symbolic-ref` + `rev-list --left-right --count HEAD...@{upstream}`
  instead of `git status` (no working-tree scan, no index lock). Verified against live workspaces locally (0.2 s for 10
  repos) and on Ember over SSH (0.15 s, one connection). Matches herdr's values; differences from the 2026-10-06
  screenshot were traced to branches/fetches that changed since.
- **Chat data source works locally.** herdr-web-ui installed as a herdr plugin (Bun 1.4.2 via `npm i -g bun`; Homebrew
  refused due to Xcode version). `/api/health` reports `auth.via = local` with no token. `/api/pane/conversation` returned
  `source: claude-transcript` for every Claude pane tried (herdr reports `agent_session` for all of them), 12–26 turns,
  **160–385 KB per page**; ETag revalidation returns 304. opencode panes fall back to `scrollback` (unsupported agent).
- **Part discriminator is `kind`, not `type`** (`{"kind":"text"|"tool"|"thinking",...}`). Metadata includes
  `model`, `reasoning_effort`, `context {used, window}` — worth showing in the chat header.
- **Ember is Linux aarch64**, herdr 0.9.3 / protocol 22, socket at `~/.config/herdr/herdr.sock`, Node 18.19, git present,
  **no Bun and no web-ui plugin**. `~/.local/bin` is not on the non-interactive SSH PATH (handled in the git script by
  extending PATH; the chat sidecar install there needs Bun first).
- Payload size suggests requesting with `since` for live updates rather than re-fetching whole pages, and decoding off the
  main actor.
