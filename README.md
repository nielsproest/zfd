# ZFD: Zig File Dialog

A **Zig** rewrite of [GoFileDialog](../GoFileDialog): an xdg-desktop-portal
FileChooser backend plus a standalone tabbed file explorer, sharing one Dear ImGui
UI. Sister-project experiment to test whether Zig (and a non-SDL windowing layer)
is the better foundation. Same goals as the Go original: fast (syscalls off the
render thread), strict layering, native X11, low dependency, familiar file-manager
conventions.

## Status

A navigable browser exists, built on an off-thread scanner:

- Pure `core`, all tested: `glob`, `xdg`, `fsops` (filters/mime/uniqueName),
  `scan` (readDir/sort/humanizeSize), `scanner` (the off-thread worker), `browser`
  (navigation model).
- **Off-thread scanning** (goal 1): a single worker thread reads + sorts
  directories; the render loop folds results in via a non-blocking `poll()`. Stale
  reads are dropped by generation. The threading is unit-tested.
- **File metadata**: size + mtime statted off-thread in the worker.
- **Selection model** (`core/selection.zig`, tested): click / Ctrl-toggle /
  Shift-range, plus a keyboard cursor.
- **Sorting + hidden filter** (`core`, tested): sort by Name/Size/Date × asc/desc
  (dirs always first); dotfiles hidden until toggled. The browser exposes a
  filtered+sorted *view* over the raw listing.
- **Browser UI** (shell + table view): breadcrumb path bar (click a segment to go,
  middle-click for a new tab, drop files onto one; click the blank part or Ctrl+L to
  type a path), a sortable/reorderable column table, and a status line with item
  count, selection size and the folder's free space. Folders **refresh themselves**
  when something else changes them (inotify), keeping your selection.
  Mouse: click / Ctrl-click / Shift-click / rubber-band select, double-click opens,
  middle-click a folder opens it in a background tab, thumb buttons go back/forward.
  Keyboard: arrows, Enter, Backspace, type-ahead, Ctrl+A, Ctrl+I (invert),
  Ctrl+H (hidden files), F4 (terminal here), F5.
- **Search**: the quick-search filters the current folder instantly (the default); tick
  **Subfolders** to also search every folder below it (background walk, streamed,
  Stop-able, capped at 5000, switches itself off when you leave the folder).
- **Split view** (F3): a second pane beside the current tab; drag between them.
- **File operations** (off-thread, tested): copy/move/trash/rename via an op-runner
  worker. Ctrl+C / Ctrl+X / Ctrl+V, Delete → trash, Shift+Delete → permanent, F2 →
  inline rename (several selected → **batch rename** with a numbering pattern or
  find/replace and a live preview), **Create Link**, and **Ctrl+Z undo** for rename,
  create, trash, move, copy and batch rename. Name clashes ask **Replace / Skip /
  Keep both** (Replace sends the old file to the trash; folders merge). Large copies
  cancel mid-file (8 MiB copy_file_range steps).
- **Drag-and-drop**: onto a folder row, a list's empty space, a breadcrumb, a sidebar
  place/bookmark/device, another tab or split pane, or Trash; move by default, Ctrl =
  copy. A drag carries a snapshot of the dragged paths and names its source, so a
  rescan mid-drag can't re-point it; the list auto-scrolls at its edges.
- **Properties**: full metadata, a folder's total size counted live in the
  background, and editable permissions (owner/group/others × rwx).
- **Devices**: USB sticks and other disks' partitions appear in the sidebar (from
  `lsblk`, hiding swap/pool members/firmware partitions); click an unmounted one to
  mount and open it, right-click to Mount / Unmount / Eject. Encrypted (LUKS)
  volumes show as locked and ask for the passphrase (piped to udisksctl, never on a
  command line); "Unmount and Lock" closes them again. Uses `udisksctl`, so
  polkit decides (no root; your desktop's password prompt when needed). Hotplug is
  picked up within about a second.
- **Tabs** (Ctrl+T new, Ctrl+W / middle-click close, drag to reorder, Ctrl+Tab /
  Ctrl+PgUp/PgDn / Alt+1…9 to switch, Ctrl+Shift+T reopens a closed tab; right-click
  for Duplicate / Close others / Close to the right). One clipboard is shared by all
  tabs. **Tear-off**: drag a tab out of the window for a new window, or onto another
  ZFD window to move it there (X11 property handoff; `--pos X,Y` places the window).
  **Quick-search glob filter** (Ctrl+F, also in the chooser).
- **`--pick` chooser mode**: `zfd --pick [--save --name x] [--multiple]
  [--directory] [--folder DIR] [--parent x11:XID]`; prints chosen path(s) to stdout.
- **Treemap view**: a second content view (recursive disk-usage, off-thread).
- **Drop-in** from other apps (GLFW-native; percent-escapes decoded, drops resolved
  against the folder row / sidebar entry / tab they landed on) and **XDND drag-out**
  to other apps (hand-written X11 source: serves TARGETS, text/uri-list, text/plain
  and UTF8_STRING, negotiates the protocol version, Escape cancels).
- **CSD titlebar**: borderless window, our own titlebar (min/max/close, drag +
  resize via `_NET_WM_MOVERESIZE`); `ZFD_NO_CSD=1` keeps native decorations.
- **`--service`**: the xdg-desktop-portal FileChooser D-Bus backend (sd-bus),
  OpenFile/SaveFile/SaveFiles, spawns `--pick` per request, transient-parented over
  the requesting app. Dropping a file onto the chooser jumps to it (and fills the
  Save name). Requests are asynchronous (several dialogs can be open at once)
  and each exports `org.freedesktop.impl.portal.Request`, so the portal's Close
  (sent when the requesting app dies) kills that dialog instead of wedging the daemon. Registered via `data/zfd.portal` + the D-Bus service file.

The full GoFileDialog feature set is ported and builds. The X11/D-Bus pieces (CSD,
XDND, `--service`) are compiled but need on-machine runtime verification; see the
top of `TODO.md`.

## Architecture

- `src/core/`: **pure Zig, no C / GUI / syscall-heavy deps.** Filesystem & name
  logic, globbing, XDG paths, and (in time) ignore rules, scanning, config, and
  portal option decoding. Its own build module with zero GUI dependencies, so
  `zig build test-core` compiles and tests it in isolation, with strict layering
  enforced by the build graph. **These tests are the conformance suite** the port
  must satisfy against the Go original.
- `src/platform/`: syscalls, threading (directory reads off the render thread),
  and windowing. **GLFW** is the platform backend (window + GL context + input via
  `imgui_impl_glfw`); we force X11 (`GLFW_PLATFORM_X11`). We do **not** hand-roll an
  ImGui platform backend; GLFW is it. Targeted raw-Xlib calls for WM integration
  (transient-for, `_NET_WM_MOVERESIZE`, XDND, CSD) go through `glfwGetX11Window()`.
- `src/ui/`: Dear ImGui draw code, via **cimgui** (the C API), fetched as
  packages (`build.zig.zon`). **Model vs representation is split**: `core/browser.zig` is the
  representation-agnostic model (dir, listing, selection, sort, hidden filter);
  `ui/shell.zig` is the window/toolbar/path-bar chrome and delegates the content
  region to a pluggable `ContentView`. `ui/views/table.zig` is the first view; a
  treemap (disk usage) and icon grid slot in as sibling variants over the *same*
  model.
- `src/main.zig`: dispatch: standalone / `--pick` / `--service`.

## Toolchain

- **Zig 0.17.0** (uses "Juicy Main" `fn main(init: std.process.Init)`, unmanaged
  `std.ArrayList`).
- **Dear ImGui + cimgui**: Zig packages in `build.zig.zon`, each pinned to a
  commit of its docking branch and checked by hash; `zig build` downloads them on
  the first build and compiles them directly (no system package).
- **GLFW**: system package (`pacman -S glfw`), linked via pkg-config.

## Build & test

    zig build            # compile the zfd binary
    zig build run        # build + run the standalone browser
    zig build test       # all tests (core + exe)
    zig build test-core  # only the pure-core tests (no GUI toolchain)

## Packaging

A local/dev `packaging/arch/PKGBUILD` (builds from the repo, no tarball) produces
an Arch package you can copy to other machines:

    cd packaging/arch
    makepkg -f                                        # → zfd-<ver>-x86_64.pkg.tar.zst (~1 MB)
    scp zfd-*.pkg.tar.zst host: && ssh host 'sudo pacman -U zfd-*.pkg.tar.zst'

Runtime deps (`glfw`, `libglvnd`, `libx11`) are pulled in by `pacman -U`. Built
`ReleaseSafe` by default; edit the PKGBUILD for `ReleaseFast`.

Installing the package registers the `.portal` file but does **not** make
xdg-desktop-portal use zfd for file dialogs; that backend is chosen per-user in
`portals.conf`. To activate (also printed by the `pacman` post-install message):

    # ~/.config/xdg-desktop-portal/portals.conf
    [preferred]
    org.freedesktop.impl.portal.FileChooser=zfd

    systemctl --user restart xdg-desktop-portal.service

After **upgrading**, the portal service notices its binary was replaced and exits
within about 30 seconds while no dialog is open; the next file dialog D-Bus-activates
the new one. Builds up to 0.0.1-82 lack this, so when upgrading from one of those,
stop the old service once as your user:

    pkill -f 'zfd --service'

## License

ZFD is free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version. See `LICENSE`.

The libraries built in keep their own licenses: Dear ImGui and cimgui (MIT, in
their packages) and stb_image (MIT or public domain, at the end of
`vendor/stb/stb_image.h`).
