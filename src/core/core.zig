//! The pure, GUI-free core of ZFD: filesystem/name logic, globbing, XDG paths,
//! and (in time) ignore rules, scanning, config, and the portal option decoding.
//! Ported from GoFileDialog's core packages and kept strictly free of any C, SDL,
//! X11, or ImGui dependency, so it compiles and tests on its own (`zig build
//! test-core`). That's the same strict layering the Go project enforces, and,
//! since a Zig-native rewrite is the whole point, this module's tests double as
//! the conformance suite any future backend must also satisfy.

pub const glob = @import("glob.zig");
pub const filter = @import("filter.zig");
pub const xdg = @import("xdg.zig");
pub const config = @import("config.zig");
pub const desktop = @import("desktop.zig");
pub const mimeinfo = @import("mimeinfo.zig");
pub const trash = @import("trash.zig");
pub const fsops = @import("fsops.zig");
pub const scan = @import("scan.zig");
pub const scanner = @import("scanner.zig");
pub const selection = @import("selection.zig");
pub const clipboard = @import("clipboard.zig");
pub const progress = @import("progress.zig");
pub const oprunner = @import("oprunner.zig");
pub const archive = @import("archive.zig");
pub const pathcomplete = @import("pathcomplete.zig");
pub const usage = @import("usage.zig");
pub const mounts = @import("mounts.zig");
pub const blockdev = @import("blockdev.zig");
pub const devices = @import("devices.zig");
pub const sizeprobe = @import("sizeprobe.zig");
pub const batchrename = @import("batchrename.zig");
pub const deepsearch = @import("deepsearch.zig");
pub const query = @import("query.zig");
pub const comments = @import("comments.zig");
pub const procwatch = @import("procwatch.zig");
pub const recent = @import("recent.zig");
pub const folderprefs = @import("folderprefs.zig");
pub const fstab = @import("fstab.zig");
pub const tags = @import("tags.zig");
pub const archives = @import("archives.zig");
pub const arcfs = @import("arcfs.zig");
pub const mediainfo = @import("mediainfo.zig");
pub const rclone = @import("rclone.zig");
pub const rcd = @import("rcd.zig");
pub const sshconfig = @import("sshconfig.zig");
pub const dirwatch = @import("dirwatch.zig");
pub const imagetool = @import("imagetool.zig");
pub const exif = @import("exif.zig");
pub const details = @import("details.zig");
pub const bgio = @import("bgio.zig");
pub const bookmarks = @import("bookmarks.zig");
pub const browser = @import("browser.zig");
pub const anim = @import("anim.zig");
pub const elide = @import("elide.zig");
pub const netbrowse = @import("netbrowse.zig");

test {
    // Force each submodule to be analyzed so its `test` blocks join this module's
    // test binary. Add a line here for every new core file.
    _ = glob;
    _ = filter;
    _ = xdg;
    _ = config;
    _ = desktop;
    _ = mimeinfo;
    _ = trash;
    _ = fsops;
    _ = scan;
    _ = arcfs;
    _ = mediainfo;
    _ = scanner;
    _ = selection;
    _ = clipboard;
    _ = progress;
    _ = oprunner;
    _ = anim;
    _ = elide;
    _ = netbrowse;
    _ = usage;
    _ = mounts;
    _ = blockdev;
    _ = devices;
    _ = sizeprobe;
    _ = batchrename;
    _ = deepsearch;
    _ = query;
    _ = comments;
    _ = procwatch;
    _ = recent;
    _ = folderprefs;
    _ = fstab;
    _ = tags;
    _ = archives;
    _ = rclone;
    _ = rcd;
    _ = sshconfig;
    _ = dirwatch;
    _ = imagetool;
    _ = exif;
    _ = details;
    _ = bgio;
    _ = bookmarks;
    _ = browser;
    _ = archive;
    _ = pathcomplete;
}
