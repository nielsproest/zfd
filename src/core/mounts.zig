//! Mounted removable/external volumes for the sidebar's Devices section, parsed
//! from /proc/mounts (ported from GoFileDialog's mounts handling). We only surface
//! user-relevant mountpoints (under /run/media, /media, or /mnt), not the dozens
//! of pseudo-filesystems. Pure parse (content in), so it's unit-tested; a thin
//! `read` wrapper reads the real /proc/mounts.

const std = @import("std");

pub const Mount = struct {
    device: []const u8, // owned
    mountpoint: []const u8, // owned
    fstype: []const u8, // owned
};

const prefixes = [_][]const u8{ "/run/media/", "/media/", "/mnt/" };

/// parse turns /proc/mounts text into the external mounts. Caller owns the result;
/// free with `free`.
pub fn parse(alloc: std.mem.Allocator, content: []const u8) ![]Mount {
    var list = std.ArrayList(Mount).empty;
    errdefer freeList(alloc, &list);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = fields.next() orelse continue;
        const mnt_raw = fields.next() orelse continue;
        const fs = fields.next() orelse continue;

        var buf: [4096]u8 = undefined;
        const mnt = unescape(mnt_raw, &buf);
        if (!isExternal(mnt)) continue;
        // Network shares (e.g. an NFS export mounted under /mnt) are surfaced by
        // parseNetwork/readNetwork instead; skip them here so they don't appear
        // twice in the sidebar's Devices section.
        if (isNetworkFs(fs)) continue;

        try list.append(alloc, .{
            .device = try alloc.dupe(u8, dev),
            .mountpoint = try alloc.dupe(u8, mnt),
            .fstype = try alloc.dupe(u8, fs),
        });
    }
    return list.toOwnedSlice(alloc);
}

/// readProcFile reads a /proc (or /sys) file whole. These report a size of 0, and
/// Dir.readFileAlloc trusts the size (it returns nothing for them), so this reads
/// until end of file instead. Owned; at most `limit` bytes.
pub fn readProcFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var buf: [16 * 1024]u8 = undefined;
    while (out.items.len < limit) {
        const rc = std.os.linux.read(f.handle, &buf, buf.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.InputOutput,
        }
        if (rc == 0) break;
        try out.appendSlice(alloc, buf[0..@min(rc, limit - out.items.len)]);
    }
    return out.toOwnedSlice(alloc);
}

/// read parses the real /proc/mounts.
pub fn read(io: std.Io, alloc: std.mem.Allocator) ![]Mount {
    const content = try readProcFile(io, alloc, "/proc/mounts", 1 << 20);
    defer alloc.free(content);
    return parse(alloc, content);
}

// Real network filesystems that appear in /proc/mounts with their own mountpoint.
const network_fs = [_][]const u8{
    "cifs",        "smb3",  "nfs",         "nfs4",      "fuse.sshfs",
    "fuse.rclone", "davfs", "fuse.davfs2", "9p",        "ncpfs",
    "afpfs",       "ceph",  "glusterfs",   "fuse.s3fs", "fuse.curlftpfs",
};

/// isNetworkFs reports whether a /proc/mounts fstype is a network filesystem.
pub fn isNetworkFs(fs: []const u8) bool {
    for (network_fs) |n| {
        if (std.mem.eql(u8, fs, n)) return true;
    }
    return false;
}

/// isBridgeMount reports whether a mount is a FUSE "bridge" that exposes virtual
/// shares as SUBDIRECTORIES: GNOME's gvfs (/run/user/UID/gvfs) or KDE's kio-fuse
/// (/run/user/UID/kio-fuse-XXXX). We list their children as the network places.
pub fn isBridgeMount(fs: []const u8, mnt: []const u8) bool {
    if (std.mem.eql(u8, fs, "fuse.gvfsd-fuse")) return true;
    if (std.mem.indexOf(u8, fs, "kio-fuse") != null) return true;
    const base = std.fs.path.basename(mnt);
    return std.mem.eql(u8, base, "gvfs") or std.mem.startsWith(u8, base, "kio-fuse");
}

/// parseNetwork extracts direct network mounts (cifs/nfs/sshfs/…) from /proc/mounts
/// content. Pure, so it's unit-tested; FUSE-bridge child scanning is done in
/// `readNetwork` (it needs I/O). Caller frees with `free`.
pub fn parseNetwork(alloc: std.mem.Allocator, content: []const u8) ![]Mount {
    var list = std.ArrayList(Mount).empty;
    errdefer freeList(alloc, &list);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = fields.next() orelse continue;
        const mnt_raw = fields.next() orelse continue;
        const fs = fields.next() orelse continue;
        if (!isNetworkFs(fs)) continue;
        var buf: [4096]u8 = undefined;
        const mnt = unescape(mnt_raw, &buf);
        try list.append(alloc, .{
            .device = try alloc.dupe(u8, dev),
            .mountpoint = try alloc.dupe(u8, mnt),
            .fstype = try alloc.dupe(u8, fs),
        });
    }
    return list.toOwnedSlice(alloc);
}

/// readNetwork lists network places from /proc/mounts (no DE linking, matching Go's
/// CLI/standard-file philosophy): direct network mounts, plus the virtual shares
/// under any gvfs/kio-fuse bridge (works on GNOME *and* KDE). Best-effort.
pub fn readNetwork(io: std.Io, alloc: std.mem.Allocator) []Mount {
    const content = readProcFile(io, alloc, "/proc/mounts", 1 << 20) catch return &.{};
    defer alloc.free(content);

    var list = std.ArrayList(Mount).empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = fields.next() orelse continue;
        const mnt_raw = fields.next() orelse continue;
        const fs = fields.next() orelse continue;
        var buf: [4096]u8 = undefined;
        const mnt = unescape(mnt_raw, &buf);
        if (isNetworkFs(fs)) {
            appendMount(alloc, &list, dev, mnt, fs);
        } else if (isBridgeMount(fs, mnt)) {
            scanBridge(io, alloc, &list, mnt, fs);
        }
    }
    const owned = list.toOwnedSlice(alloc) catch return &.{};
    std.mem.sort(Mount, owned, {}, byMountpoint);
    return owned;
}

fn byMountpoint(_: void, a: Mount, b: Mount) bool {
    return std.mem.lessThan(u8, a.mountpoint, b.mountpoint);
}

fn appendMount(alloc: std.mem.Allocator, list: *std.ArrayList(Mount), dev: []const u8, mnt: []const u8, fs: []const u8) void {
    const device = alloc.dupe(u8, dev) catch return;
    const mountpoint = alloc.dupe(u8, mnt) catch {
        alloc.free(device);
        return;
    };
    const fstype = alloc.dupe(u8, fs) catch {
        alloc.free(device);
        alloc.free(mountpoint);
        return;
    };
    list.append(alloc, .{ .device = device, .mountpoint = mountpoint, .fstype = fstype }) catch {
        alloc.free(device);
        alloc.free(mountpoint);
        alloc.free(fstype);
    };
}

fn scanBridge(io: std.Io, alloc: std.mem.Allocator, list: *std.ArrayList(Mount), bridge: []const u8, fs: []const u8) void {
    var d = std.Io.Dir.cwd().openDir(io, bridge, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        var pbuf: [4200]u8 = undefined;
        const child = std.mem.print(&pbuf, "{s}/{s}", .{ bridge, e.name }) catch continue;
        appendMount(alloc, list, bridge, child, fs);
    }
}

/// readPlaces lists the immediate directory entries under the conventional external-
/// mount roots (/mnt and /media directly, plus the udisks layout /run/media/<user>/)
/// as sidebar Devices shortcuts. This surfaces every mount target provisioned there
/// even when it isn't a distinct /proc/mounts line, so "everything in /mnt" shows up.
/// `exclude` is the set of mountpoints already listed (real mounts) so we don't repeat
/// them. Only readdir on the roots (never a descent), so it can't stall on a slow
/// network mount. Best-effort; caller frees with `free`.
pub fn readPlaces(io: std.Io, alloc: std.mem.Allocator, user: []const u8, exclude: []const []const u8) []Mount {
    var list = std.ArrayList(Mount).empty;
    listChildren(io, alloc, &list, "/mnt", exclude);
    listChildren(io, alloc, &list, "/media", exclude);
    if (user.len > 0) {
        var pbuf: [256]u8 = undefined;
        if (std.mem.print(&pbuf, "/run/media/{s}", .{user})) |umedia| {
            listChildren(io, alloc, &list, umedia, exclude);
        } else |_| {}
    }
    const owned = list.toOwnedSlice(alloc) catch return &.{};
    std.mem.sort(Mount, owned, {}, byMountpoint);
    return owned;
}

fn listChildren(io: std.Io, alloc: std.mem.Allocator, list: *std.ArrayList(Mount), parent: []const u8, exclude: []const []const u8) void {
    var d = std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        var pbuf: [4200]u8 = undefined;
        const child = std.mem.print(&pbuf, "{s}/{s}", .{ parent, e.name }) catch continue;
        if (mountpointListed(exclude, child)) continue;
        appendMount(alloc, list, parent, child, "dir"); // fstype unused for places (label is the basename)
    }
}

fn mountpointListed(list: []const []const u8, path: []const u8) bool {
    for (list) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

pub fn free(alloc: std.mem.Allocator, mounts: []Mount) void {
    for (mounts) |m| {
        alloc.free(m.device);
        alloc.free(m.mountpoint);
        alloc.free(m.fstype);
    }
    alloc.free(mounts);
}

fn freeList(alloc: std.mem.Allocator, list: *std.ArrayList(Mount)) void {
    for (list.items) |m| {
        alloc.free(m.device);
        alloc.free(m.mountpoint);
        alloc.free(m.fstype);
    }
    list.deinit(alloc);
}

fn isExternal(mnt: []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, mnt, p)) return true;
    }
    return false;
}

/// unescape decodes /proc/mounts octal escapes (\040 space, \011 tab, …) into buf,
/// returning the decoded slice (or the original if it doesn't fit).
fn unescape(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) {
        if (s[i] == '\\' and i + 3 < s.len and octal(s[i + 1]) and octal(s[i + 2]) and octal(s[i + 3])) {
            const v = (s[i + 1] - '0') * 64 + (s[i + 2] - '0') * 8 + (s[i + 3] - '0');
            buf[n] = v;
            n += 1;
            i += 4;
        } else {
            buf[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return buf[0..n];
}

fn octal(ch: u8) bool {
    return ch >= '0' and ch <= '7';
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "parse keeps only external local mounts and decodes escapes" {
    const a = testing.allocator;
    const sample =
        "proc /proc proc rw,nosuid 0 0\n" ++
        "/dev/sda2 / ext4 rw 0 0\n" ++
        "/dev/sdb1 /run/media/user/My\\040Disk vfat rw 0 0\n" ++
        "tmpfs /run tmpfs rw 0 0\n" ++
        "nas:/vol /mnt/newfiles nfs4 rw 0 0\n" ++ // network share under /mnt → readNetwork's job, not here
        "/dev/sdc1 /mnt/data btrfs rw 0 0\n";
    const mounts = try parse(a, sample);
    defer free(a, mounts);

    // The two external *local* mounts only, not proc/root/tmpfs, and not the NFS
    // share (it belongs to parseNetwork, so it isn't listed twice in the sidebar).
    try testing.expectEqual(@as(usize, 2), mounts.len);
    try testing.expectEqualStrings("/run/media/user/My Disk", mounts[0].mountpoint); // \040 → space
    try testing.expectEqualStrings("vfat", mounts[0].fstype);
    try testing.expectEqualStrings("/mnt/data", mounts[1].mountpoint);
}

test "parseNetwork keeps only network filesystems" {
    const a = testing.allocator;
    const sample =
        "/dev/sda2 / ext4 rw 0 0\n" ++ // local → skipped
        "//server/share /mnt/smb cifs rw 0 0\n" ++ // network
        "nas:/vol /mnt/nfs nfs4 rw 0 0\n" ++ // network
        "gvfsd-fuse /run/user/1000/gvfs fuse.gvfsd-fuse rw 0 0\n"; // bridge → not "direct"
    const nets = try parseNetwork(a, sample);
    defer free(a, nets);

    try testing.expectEqual(@as(usize, 2), nets.len); // cifs + nfs4, not ext4 or the bridge itself
    try testing.expect(isNetworkFs("cifs") and isNetworkFs("nfs4") and !isNetworkFs("ext4"));
    try testing.expect(isBridgeMount("fuse.gvfsd-fuse", "/run/user/1000/gvfs"));
    try testing.expect(isBridgeMount("fuse.kio-fuse", "/run/user/1000/kio-fuse-Ab12Cd"));
}

test "readProcFile reads /proc files that report size 0" {
    const got = try readProcFile(testing.io, testing.allocator, "/proc/self/mounts", 1 << 20);
    defer testing.allocator.free(got);
    try testing.expect(got.len > 0);
}
