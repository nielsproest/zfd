//! /etc/fstab entries that aren't mounted right now (a NAS share marked noauto, a
//! data disk that failed at boot), so the sidebar can offer "Mount" for them like a
//! plugged-in USB stick. System mounts (/, /boot, /home, …), swap and pseudo
//! filesystems are left out. GUI-free; parsing is unit-tested.

const std = @import("std");
const Dir = std.Io.Dir;
const readProcFile = @import("mounts.zig").readProcFile;

pub const Entry = struct {
    spec: []u8, // what to mount: UUID=…, /dev/…, //nas/share, host:/export (owned)
    target: []u8, // where (owned)
    fstype: []u8, // (owned)
    user_mountable: bool, // "user"/"users"/"owner"/"group": `mount <target>` works unprivileged

    /// label is what the sidebar shows: the mount point's last component.
    pub fn label(self: Entry) []const u8 {
        const b = std.fs.path.basename(self.target);
        return if (b.len > 0) b else self.target;
    }
};

/// System mount points that are never offered (they're part of the running system).
const system_targets = [_][]const u8{ "/", "/boot", "/boot/efi", "/efi", "/home", "/usr", "/var", "/tmp", "/opt", "/root", "/srv", "/nix", "/gnu" };

/// Filesystem types with nothing for a user to browse.
const skip_types = [_][]const u8{ "swap", "proc", "sysfs", "devpts", "tmpfs", "devtmpfs", "cgroup", "cgroup2", "securityfs", "debugfs", "efivarfs", "none", "zfs" };

/// parse returns the mountable entries of fstab `content` whose target is not in
/// `mounted` (mount points currently in use). Owned; free with `free`.
pub fn parse(alloc: std.mem.Allocator, content: []const u8, mounted: []const []const u8) ![]Entry {
    var out = std.ArrayList(Entry).empty;
    errdefer {
        for (out.items) |e| freeEntry(alloc, e);
        out.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const spec_raw = f.next() orelse continue;
        const target_raw = f.next() orelse continue;
        const fstype = f.next() orelse continue;
        const opts = f.next() orelse "defaults";
        if (contains(&skip_types, fstype)) continue;
        if (hasOpt(opts, "bind") or hasOpt(opts, "rbind")) continue;

        const target = try unescape(alloc, target_raw);
        errdefer alloc.free(target);
        const t = trimSlash(target);
        if (t.len == 0 or t[0] != '/' or contains(&system_targets, t) or contains(mounted, t)) {
            alloc.free(target);
            continue;
        }
        const spec = try unescape(alloc, spec_raw);
        errdefer alloc.free(spec);
        const ty = try alloc.dupe(u8, fstype);
        try out.append(alloc, .{
            .spec = spec,
            .target = target,
            .fstype = ty,
            .user_mountable = hasOpt(opts, "user") or hasOpt(opts, "users") or hasOpt(opts, "owner") or hasOpt(opts, "group"),
        });
    }
    return out.toOwnedSlice(alloc);
}

/// read parses /etc/fstab against the mount points in /proc/self/mounts.
pub fn read(io: std.Io, alloc: std.mem.Allocator) []Entry {
    const fstab = Dir.cwd().readFileAlloc(io, "/etc/fstab", alloc, .limited(1 << 20)) catch return &.{};
    defer alloc.free(fstab);
    const mounts = readProcFile(io, alloc, "/proc/self/mounts", 4 << 20) catch return &.{};
    defer alloc.free(mounts);
    var targets = std.ArrayList([]const u8).empty;
    defer {
        for (targets.items) |t| alloc.free(t);
        targets.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, mounts, '\n');
    while (it.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next() orelse continue;
        const mp = f.next() orelse continue;
        const t = unescape(alloc, mp) catch continue;
        targets.append(alloc, t) catch alloc.free(t);
    }
    return parse(alloc, fstab, targets.items) catch &.{};
}

pub fn free(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| freeEntry(alloc, e);
    if (entries.len > 0) alloc.free(entries);
}

/// dup deep-copies `entries` (for handing a snapshot to the UI).
pub fn dup(alloc: std.mem.Allocator, entries: []const Entry) ![]Entry {
    var out = try alloc.alloc(Entry, entries.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |e| freeEntry(alloc, e);
        alloc.free(out);
    }
    for (entries) |e| {
        const s = try alloc.dupe(u8, e.spec);
        errdefer alloc.free(s);
        const t = try alloc.dupe(u8, e.target);
        errdefer alloc.free(t);
        out[n] = .{ .spec = s, .target = t, .fstype = try alloc.dupe(u8, e.fstype), .user_mountable = e.user_mountable };
        n += 1;
    }
    return out;
}

fn freeEntry(alloc: std.mem.Allocator, e: Entry) void {
    alloc.free(e.spec);
    alloc.free(e.target);
    alloc.free(e.fstype);
}

fn hasOpt(opts: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, opts, ',');
    while (it.next()) |o| if (std.mem.eql(u8, o, name)) return true;
    return false;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn trimSlash(p: []const u8) []const u8 {
    return if (p.len > 1 and p[p.len - 1] == '/') p[0 .. p.len - 1] else p;
}

/// unescape decodes fstab/mtab octal escapes ("\040" = space). Owned.
fn unescape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 4 <= s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8)) |ch| {
                out.appendAssumeCapacity(ch);
                i += 4;
                continue;
            } else |_| {}
        }
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "parse offers unmounted data mounts and skips system, swap and mounted ones" {
    const fstab =
        \\# comment
        \\UUID=abc  /          ext4  defaults 0 1
        \\UUID=def  /boot      vfat  defaults 0 2
        \\UUID=111  none       swap  defaults 0 0
        \\//nas/media  /mnt/media  cifs  noauto,user,credentials=/x 0 0
        \\UUID=222  /mnt/data  ext4  defaults 0 2
        \\nas:/export/My\040Files  /mnt/my\040files  nfs  noauto 0 0
        \\/srv/a  /mnt/bound  none  bind 0 0
    ;
    const mounted = [_][]const u8{ "/", "/boot", "/mnt/data" };
    const got = try parse(testing.allocator, fstab, &mounted);
    defer free(testing.allocator, got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("/mnt/media", got[0].target);
    try testing.expect(got[0].user_mountable);
    try testing.expectEqualStrings("media", got[0].label());
    try testing.expectEqualStrings("/mnt/my files", got[1].target);
    try testing.expectEqualStrings("nas:/export/My Files", got[1].spec);
    try testing.expect(!got[1].user_mountable);
}
