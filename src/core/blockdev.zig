//! Block volumes for the sidebar's Devices section — the things a file manager lets
//! you mount, open and eject (USB sticks, SD cards, a second disk's partitions). Parsed
//! from `lsblk -J` so we need no udev/D-Bus linking; the actions themselves go through
//! `udisksctl` (see devices.zig), which is what makes mounting work without root.
//!
//! Pure: JSON text in, a filtered Volume list out — unit-tested. The filter is the whole
//! point: a raw lsblk tree is full of things no one wants in a sidebar (swap, ZFS/LVM/
//! RAID members, the EFI partition, the root filesystem).

const std = @import("std");

pub const Volume = struct {
    path: []const u8, // block device, e.g. /dev/sdb1 (owned)
    name: []const u8, // display name: label, else partition label, else "<size> Volume" (owned)
    fstype: []const u8, // owned
    size: u64,
    mountpoint: []const u8, // "" when not mounted (owned)
    drive: []const u8, // the whole disk it lives on (for eject / power-off) (owned)
    removable: bool, // USB/SD/optical — ejectable, and mountable without admin auth
    locked: bool = false, // an encrypted (LUKS) container awaiting its passphrase
    crypt_parent: []const u8 = "", // for an unlocked volume: its LUKS container (owned; "" = none)
    uuid: []const u8 = "", // filesystem (or LUKS) UUID — stable across plugs, for bookmarks (owned; "" = none)

    pub fn mounted(v: Volume) bool {
        return v.mountpoint.len > 0;
    }
};

/// The lsblk invocation parse() expects: bytes (-b), JSON (-J), these columns.
const lsblk_columns = "NAME,PATH,LABEL,PARTLABEL,PARTTYPE,SIZE,FSTYPE,MOUNTPOINTS,RM,HOTPLUG,TYPE,TRAN,UUID";
pub const lsblk_argv = [_][]const u8{ "lsblk", "-J", "-b", "-o", lsblk_columns };

// Filesystems that are parts of something else (pools, arrays, encrypted containers)
// or not files at all. Mounting one directly is either impossible or harmful.
const skip_fstypes = [_][]const u8{
    "swap",   "zfs_member",      "LVM2_member",     "linux_raid_member",
    "bcache", "ddf_raid_member", "isw_raid_member", "promise_fasttrack_raid_member",
    "BitLocker", // needs unlocking first; offering "Mount" would only fail
};

// GPT partition types that exist for the firmware or the OS, not for files.
const hidden_parttypes = [_][]const u8{
    "c12a7328-f81f-11d2-ba4b-00a0c93ec93b", // EFI System
    "e3c9e316-0b5c-4db8-817d-f92df00215ae", // Microsoft Reserved
    "de94bba4-06d1-4d40-a16a-bfd50179d6ac", // Windows Recovery
    "21686148-6449-6e6f-744e-656564454649", // BIOS boot
    "0x27", // MBR: Windows recovery (hidden NTFS)
    "0xef", // MBR: EFI System
};

// Where user-facing mounts live. A mounted volume elsewhere (/, /boot, /home, /var)
// is part of the running system, not a "device", unless it is removable.
const user_mount_prefixes = [_][]const u8{ "/run/media/", "/media/", "/mnt/" };

/// parse turns `lsblk -J` output (with lsblk_argv's columns) into the volumes worth
/// showing. Caller owns the result; free with `free`.
pub fn parse(alloc: std.mem.Allocator, json: []const u8) ![]Volume {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    var list = std.ArrayList(Volume).empty;
    errdefer {
        freeStrings(alloc, list.items);
        list.deinit(alloc);
    }
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadLsblkOutput,
    };
    const devs = root.get("blockdevices") orelse return error.BadLsblkOutput;
    if (devs != .array) return error.BadLsblkOutput;
    for (devs.array.items) |d| try walk(alloc, &list, d, "", false, "");
    return list.toOwnedSlice(alloc);
}

/// walk visits one lsblk node and its children. `drive`/`drive_removable` come from the
/// nearest "disk"/"rom" ancestor (a partition's own RM flag is often unset).
fn walk(alloc: std.mem.Allocator, list: *std.ArrayList(Volume), node: std.json.Value, drive: []const u8, drive_removable: bool, luks_parent: []const u8) !void {
    if (node != .object) return;
    const o = node.object;
    const typ = str(o, "type");
    const path = str(o, "path");
    const is_drive = std.mem.eql(u8, typ, "disk") or std.mem.eql(u8, typ, "rom");
    const tran = str(o, "tran");
    const removable = drive_removable or boolean(o, "rm") or boolean(o, "hotplug") or
        std.mem.eql(u8, tran, "usb") or std.mem.eql(u8, typ, "rom");
    const this_drive = if (is_drive) path else drive;
    const is_luks = std.ascii.eqlIgnoreCase(str(o, "fstype"), "crypto_LUKS");
    const children = o.get("children");
    const has_children = children != null and children.? == .array and children.?.array.items.len > 0;

    // An encrypted container: listed as LOCKED until it has an unlocked mapping; once
    // unlocked, the mapping (its child, type "crypt") is the volume you actually use.
    if (is_luks and !has_children) {
        var name_buf: [96]u8 = undefined;
        try list.append(alloc, .{
            .path = try alloc.dupe(u8, path),
            .name = try alloc.dupe(u8, displayName(o, &name_buf)),
            .fstype = try alloc.dupe(u8, "crypto_LUKS"),
            .size = size(o),
            .mountpoint = try alloc.dupe(u8, ""),
            .drive = try alloc.dupe(u8, if (this_drive.len > 0) this_drive else path),
            .removable = removable,
            .locked = true,
            .uuid = try dupeOrEmpty(alloc, str(o, "uuid")),
        });
    }
    const parent_for_children = if (is_luks) path else "";

    if (!is_luks and keep(o)) {
        const mp = userMountpoint(o, removable);
        const mounted_elsewhere = mp == null and hasMountpoint(o);
        if (!mounted_elsewhere) {
            var name_buf: [96]u8 = undefined;
            const name = displayName(o, &name_buf);
            const v: Volume = .{
                .path = try alloc.dupe(u8, path),
                .name = try alloc.dupe(u8, name),
                .fstype = try alloc.dupe(u8, str(o, "fstype")),
                .size = size(o),
                .mountpoint = try alloc.dupe(u8, mp orelse ""),
                .drive = try alloc.dupe(u8, if (this_drive.len > 0) this_drive else path),
                .removable = removable,
                .crypt_parent = try alloc.dupe(u8, luks_parent),
                .uuid = try dupeOrEmpty(alloc, str(o, "uuid")),
            };
            try list.append(alloc, v);
        }
    }
    if (o.get("children")) |ch| {
        if (ch == .array) for (ch.array.items) |c| try walk(alloc, list, c, this_drive, removable, parent_for_children);
    }
}

/// keep decides whether a node is a mountable filesystem worth listing at all.
fn keep(o: std.json.ObjectMap) bool {
    const fs = str(o, "fstype");
    if (fs.len == 0) return false; // no filesystem (a whole partitioned disk, an empty slot)
    for (skip_fstypes) |s| if (std.ascii.eqlIgnoreCase(fs, s)) return false;
    const pt = str(o, "parttype");
    for (hidden_parttypes) |h| if (std.ascii.eqlIgnoreCase(pt, h)) return false;
    return true;
}

/// userMountpoint returns the mountpoint to show, or null when the volume is unmounted
/// or only mounted somewhere system-internal (then the caller hides it).
fn userMountpoint(o: std.json.ObjectMap, removable: bool) ?[]const u8 {
    const mps = o.get("mountpoints") orelse return null;
    if (mps != .array) return null;
    for (mps.array.items) |m| {
        if (m != .string) continue;
        const p = m.string;
        if (p.len == 0 or p[0] != '/') continue; // "[SWAP]" and friends
        if (removable) return p;
        for (user_mount_prefixes) |pre| if (std.mem.startsWith(u8, p, pre)) return p;
    }
    return null;
}

fn hasMountpoint(o: std.json.ObjectMap) bool {
    const mps = o.get("mountpoints") orelse return false;
    if (mps != .array) return false;
    for (mps.array.items) |m| if (m == .string and m.string.len > 0) return true;
    return false;
}

/// displayName: the filesystem label, else the GPT partition label, else "<size> <fs>
/// Volume" — what Dolphin/Nautilus show for an unlabeled stick.
fn displayName(o: std.json.ObjectMap, buf: []u8) []const u8 {
    const label = str(o, "label");
    if (label.len > 0) return label;
    const pl = str(o, "partlabel");
    if (pl.len > 0 and !genericPartLabel(pl)) return pl;
    var sb: [24]u8 = undefined;
    const sz = humanSize(&sb, size(o));
    return std.mem.print(buf, "{s} {s} Volume", .{ sz, str(o, "fstype") }) catch "Volume";
}

/// genericPartLabel: partition names that partitioning tools stamp on by default and
/// that say nothing about the volume ("Basic data partition" is every Windows drive).
fn genericPartLabel(pl: []const u8) bool {
    const generic = [_][]const u8{
        "Basic data partition",         "Microsoft basic data", "Linux filesystem", "Linux filesystem data",
        "Main Data Partition",          "primary",              "logical",          "EFI system partition",
        "Microsoft reserved partition",
    };
    for (generic) |g| if (std.ascii.eqlIgnoreCase(pl, g)) return true;
    return false;
}

/// humanSize formats bytes in decimal units (what drive vendors print on the box, and
/// what other file managers show for volumes): 32 GB, not 29.8 GiB.
pub fn humanSize(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1000 and u < units.len - 1) : (u += 1) v /= 1000;
    // Whole numbers drop the ".0" ("32 GB"), as does anything ≥100 or plain bytes.
    const whole = @abs(v - @round(v)) < 0.05;
    if (u == 0 or v >= 100 or whole) return std.mem.print(buf, "{d:.0} {s}", .{ @round(v), units[u] }) catch "?";
    return std.mem.print(buf, "{d:.1} {s}", .{ v, units[u] }) catch "?";
}

fn str(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn boolean(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "1"), // older lsblk prints "0"/"1"
        .integer => |i| i != 0,
        else => false,
    };
}

fn size(o: std.json.ObjectMap) u64 {
    const v = o.get("size") orelse return 0;
    return switch (v) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        else => 0,
    };
}

pub fn free(alloc: std.mem.Allocator, vols: []Volume) void {
    freeStrings(alloc, vols);
    if (vols.len > 0) alloc.free(vols);
}

fn freeStrings(alloc: std.mem.Allocator, vols: []Volume) void {
    for (vols) |v| {
        alloc.free(v.path);
        alloc.free(v.name);
        alloc.free(v.fstype);
        alloc.free(v.mountpoint);
        alloc.free(v.drive);
        if (v.crypt_parent.len > 0) alloc.free(v.crypt_parent);
        if (v.uuid.len > 0) alloc.free(v.uuid);
    }
}

fn dupeOrEmpty(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return if (s.len == 0) "" else try alloc.dupe(u8, s);
}

/// parseMountedAt extracts the mountpoint from `udisksctl mount` output:
/// "Mounted /dev/sdb1 at /run/media/me/STICK" (older versions end with a '.').
/// Only the "Mounted …" line counts: stderr is captured too, and it can carry an
/// unrelated polkit notice ahead of it.
pub fn parseMountedAt(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Mounted ")) continue;
        const key = " at ";
        const i = std.mem.indexOf(u8, line, key) orelse continue;
        var p = std.mem.trim(u8, line[i + key.len ..], " \t");
        if (std.mem.endsWith(u8, p, ".")) p = p[0 .. p.len - 1];
        if (p.len == 0 or p[0] != '/') continue;
        return p;
    }
    return null;
}

/// parseUnlockedAs extracts the cleartext device from `udisksctl unlock` output:
/// "Unlocked /dev/sdb2 as /dev/dm-3." (stderr may carry an unrelated polkit notice).
pub fn parseUnlockedAs(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Unlocked ")) continue;
        const i = std.mem.indexOf(u8, line, " as ") orelse continue;
        var p = line[i + 4 ..];
        if (std.mem.endsWith(u8, p, ".")) p = p[0 .. p.len - 1];
        if (p.len > 0 and p[0] == '/') return p;
    }
    return null;
}

// ---------------------------------------------------------------------------
const testing = std.testing;

const sample =
    \\{"blockdevices": [
    \\ {"name":"sda","path":"/dev/sda","label":null,"partlabel":null,"parttype":null,"size":250059350016,
    \\  "fstype":null,"mountpoints":[],"rm":false,"hotplug":false,"type":"disk","tran":"sata",
    \\  "children":[
    \\   {"name":"sda1","path":"/dev/sda1","label":null,"partlabel":null,"parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
    \\    "size":536870912,"fstype":"vfat","mountpoints":["/boot"],"rm":false,"hotplug":false,"type":"part","tran":null},
    \\   {"name":"sda2","path":"/dev/sda2","label":"zroot","partlabel":null,"parttype":null,"size":232341372928,
    \\    "fstype":"zfs_member","mountpoints":[],"rm":false,"hotplug":false,"type":"part","tran":null},
    \\   {"name":"sda3","path":"/dev/sda3","label":null,"partlabel":null,"parttype":null,"size":17179869184,
    \\    "fstype":"swap","mountpoints":["[SWAP]"],"rm":false,"hotplug":false,"type":"part","tran":null},
    \\   {"name":"sda4","path":"/dev/sda4","label":"root","partlabel":null,"parttype":null,"size":100000000000,
    \\    "fstype":"ext4","mountpoints":["/"],"rm":false,"hotplug":false,"type":"part","tran":null},
    \\   {"name":"sda5","path":"/dev/sda5","label":null,"partlabel":"Games","parttype":null,"size":500000000000,
    \\    "fstype":"ntfs","mountpoints":[],"rm":false,"hotplug":false,"type":"part","tran":null}
    \\  ]},
    \\ {"name":"sdb","path":"/dev/sdb","label":null,"partlabel":null,"parttype":null,"size":32000000000,
    \\  "fstype":null,"mountpoints":[],"rm":true,"hotplug":true,"type":"disk","tran":"usb",
    \\  "children":[
    \\   {"name":"sdb1","path":"/dev/sdb1","label":"STICK","partlabel":null,"parttype":"0xc","size":32000000000,
    \\    "fstype":"exfat","mountpoints":["/run/media/me/STICK"],"rm":false,"hotplug":false,"type":"part","tran":null}
    \\  ]},
    \\ {"name":"sdc","path":"/dev/sdc","label":null,"partlabel":null,"parttype":null,"size":16000000000,
    \\  "fstype":"vfat","mountpoints":[null],"rm":"1","hotplug":"1","type":"disk","tran":"usb"}
    \\]}
;

test "parse keeps mountable volumes and hides system/member/firmware partitions" {
    const a = testing.allocator;
    const vols = try parse(a, sample);
    defer free(a, vols);

    // Kept: the unmounted NTFS data partition, the mounted USB stick, the superfloppy.
    // Hidden: EFI (parttype), ZFS member, swap, the root fs mounted at "/".
    try testing.expectEqual(@as(usize, 3), vols.len);

    try testing.expectEqualStrings("/dev/sda5", vols[0].path);
    try testing.expectEqualStrings("Games", vols[0].name); // partlabel fallback
    try testing.expect(!vols[0].mounted());
    try testing.expect(!vols[0].removable);
    try testing.expectEqualStrings("/dev/sda", vols[0].drive);

    try testing.expectEqualStrings("STICK", vols[1].name);
    try testing.expectEqualStrings("/run/media/me/STICK", vols[1].mountpoint);
    try testing.expect(vols[1].removable); // inherited from the USB disk (the partition says rm=false)
    try testing.expectEqualStrings("/dev/sdb", vols[1].drive);

    // A filesystem straight on the disk (no partition table), old-style "1" flags.
    try testing.expectEqualStrings("/dev/sdc", vols[2].path);
    try testing.expect(vols[2].removable);
    try testing.expectEqualStrings("16 GB vfat Volume", vols[2].name); // unlabeled fallback
    try testing.expectEqualStrings("/dev/sdc", vols[2].drive);
}

test "a stock partition label counts as no label" {
    const a = testing.allocator;
    const json =
        \\{"blockdevices":[{"name":"sdx1","path":"/dev/sdx1","label":null,"partlabel":"Basic data partition",
        \\ "parttype":null,"size":120000000000,"fstype":"ntfs","mountpoints":[],"rm":false,"hotplug":false,"type":"part"}]}
    ;
    const vols = try parse(a, json);
    defer free(a, vols);
    try testing.expectEqualStrings("120 GB ntfs Volume", vols[0].name);
}

test "an encrypted container shows as locked, then as its unlocked filesystem" {
    const a = testing.allocator;
    const locked_json =
        \\{"blockdevices":[{"name":"sdd","path":"/dev/sdd","label":null,"partlabel":null,"parttype":null,"size":64000000000,
        \\ "fstype":null,"mountpoints":[],"rm":true,"hotplug":true,"type":"disk","tran":"usb","children":[
        \\  {"name":"sdd1","path":"/dev/sdd1","label":"Vault","partlabel":null,"parttype":null,"size":64000000000,
        \\   "fstype":"crypto_LUKS","mountpoints":[],"rm":false,"hotplug":false,"type":"part","tran":null}]}]}
    ;
    const v1 = try parse(a, locked_json);
    defer free(a, v1);
    try testing.expectEqual(@as(usize, 1), v1.len);
    try testing.expect(v1[0].locked and v1[0].removable);
    try testing.expectEqualStrings("Vault", v1[0].name);

    const open_json =
        \\{"blockdevices":[{"name":"sdd","path":"/dev/sdd","label":null,"partlabel":null,"parttype":null,"size":64000000000,
        \\ "fstype":null,"mountpoints":[],"rm":true,"hotplug":true,"type":"disk","tran":"usb","children":[
        \\  {"name":"sdd1","path":"/dev/sdd1","label":"Vault","partlabel":null,"parttype":null,"size":64000000000,
        \\   "fstype":"crypto_LUKS","mountpoints":[],"rm":false,"hotplug":false,"type":"part","tran":null,"children":[
        \\    {"name":"luks-x","path":"/dev/mapper/luks-x","label":"data","partlabel":null,"parttype":null,"size":63000000000,
        \\     "fstype":"ext4","mountpoints":["/run/media/me/data"],"rm":false,"hotplug":false,"type":"crypt","tran":null}]}]}]}
    ;
    const v2 = try parse(a, open_json);
    defer free(a, v2);
    try testing.expectEqual(@as(usize, 1), v2.len); // the container itself is no longer listed
    try testing.expect(!v2[0].locked);
    try testing.expectEqualStrings("/dev/mapper/luks-x", v2[0].path);
    try testing.expectEqualStrings("/dev/sdd1", v2[0].crypt_parent); // so Unmount can lock it again
    try testing.expectEqualStrings("/dev/sdd", v2[0].drive);
}

test "parseUnlockedAs reads the cleartext device" {
    try testing.expectEqualStrings("/dev/dm-3", parseUnlockedAs("Unlocked /dev/sdb2 as /dev/dm-3.\n").?);
    try testing.expect(parseUnlockedAs("Error unlocking /dev/sdb2: wrong passphrase") == null);
}

test "parse rejects output that isn't lsblk JSON" {
    try testing.expectError(error.BadLsblkOutput, parse(testing.allocator, "[]"));
    try testing.expectError(error.BadLsblkOutput, parse(testing.allocator, "{\"x\":1}"));
}

test "parseMountedAt reads udisksctl's mount line (with and without a trailing dot)" {
    try testing.expectEqualStrings("/run/media/me/STICK", parseMountedAt("Mounted /dev/sdb1 at /run/media/me/STICK\n").?);
    try testing.expectEqualStrings("/media/My Disk", parseMountedAt("Mounted /dev/sdb1 at /media/My Disk.\n").?);
    try testing.expect(parseMountedAt("Error mounting /dev/sdb1: ...") == null);
    try testing.expectEqualStrings("/run/media/me/X", parseMountedAt(
        "Error creating textual authentication agent: … (polkit-error-quark, 0)\nMounted /dev/sdb1 at /run/media/me/X\n",
    ).?);
}

test "humanSize uses decimal units like drive labels" {
    var b: [24]u8 = undefined;
    try testing.expectEqualStrings("32 GB", humanSize(&b, 32_000_000_000));
    try testing.expectEqualStrings("1.5 TB", humanSize(&b, 1_500_000_000_000));
    try testing.expectEqualStrings("512 B", humanSize(&b, 512));
}
