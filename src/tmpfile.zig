/// a small zig lib for creating and using sys temp files
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ThisModule = @This();

const random_bytes_count = 12;
const random_path_len = std.fs.base64_encoder.calcSize(random_bytes_count);

/// return the sys temp dir as string. The return string is owned by user
pub fn getSysTmpDir(a: std.mem.Allocator) ![]const u8 {
    const Impl = switch (builtin.os.tag) {
        .linux, .macos => struct {
            pub fn get(allocator: std.mem.Allocator) ![]const u8 {
                // cpp17's temp_directory_path gives good reference
                // https://en.cppreference.com/w/cpp/filesystem/temp_directory_path
                // POSIX standard, https://en.wikipedia.org/wiki/TMPDIR
                return std.process.getEnvVarOwned(allocator, "TMPDIR") catch {
                    return std.process.getEnvVarOwned(allocator, "TMP") catch {
                        return std.process.getEnvVarOwned(allocator, "TEMP") catch {
                            return std.process.getEnvVarOwned(allocator, "TEMPDIR") catch {
                                std.debug.print("tried env TMPDIR/TMP/TEMP/TEMPDIR but not found, fallback to /tmp, caution it may not work!", .{});
                                return try allocator.dupe(u8, "/tmp");
                            };
                        };
                    };
                };
            }
        },
        .windows => struct {
            const DWORD = std.os.windows.DWORD;
            const LPWSTR = std.os.windows.LPWSTR;
            const MAX_PATH = std.os.windows.MAX_PATH;
            const WCHAR = std.os.windows.WCHAR;

            pub extern "C" fn GetTempPath2W(BufferLength: DWORD, Buffer: LPWSTR) DWORD;

            pub fn get(allocator: std.mem.Allocator) ![]const u8 {
                // use GetTempPathW2, https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
                var wchar_buf: [MAX_PATH + 2]WCHAR = undefined;
                wchar_buf[MAX_PATH + 1] = 0;
                const ret = GetTempPath2W(MAX_PATH + 1, &wchar_buf);
                if (ret != 0) {
                    const path = wchar_buf[0..ret];
                    return std.unicode.utf16leToUtf8Alloc(allocator, path);
                } else {
                    return error.GetTempPath2WFailed;
                }
            }
        },
        else => {
            @panic("Not support, os=" ++ @tagName(std.builtin.os.tag));
        },
    };

    return Impl.get(a);
}

/// TmpDir holds the info a new created tmp dir in sys temp dir, it can be created by TmpDir.init or module level tmpDir
pub const TmpDir = struct {
    pub const TmpDirArgs = struct {
        prefix: ?[]const u8 = null,
        opts: std.fs.Dir.OpenDirOptions = .{},
    };

    allocator: std.mem.Allocator,
    abs_path: []const u8,
    // parent_dir_path is slice of abs_path, and it is abs path
    parent_dir_path: []const u8,
    // sub_path is slice of abs_path
    sub_path: []const u8,
    parent_dir: std.fs.Dir,
    dir: std.fs.Dir,

    /// deinit will cleanup the files, close all file handle and then release resources
    pub fn deinit(self: *TmpDir) void {
        self.cleanup();
        self.allocator.free(self.abs_path);
        self.abs_path = undefined;
        self.parent_dir_path = undefined;
        self.sub_path = undefined;
    }

    /// cleanup will only clean the dir (deleting everything in it), but not release resources
    pub fn cleanup(self: *TmpDir) void {
        self.dir.close();
        self.dir = undefined;
        self.parent_dir.deleteTree(self.sub_path) catch {};
        self.parent_dir.close();
        self.parent_dir = undefined;
    }

    /// return a TmpDir created in system tmp folder
    pub fn init(allocator: std.mem.Allocator, args: TmpDirArgs) !TmpDir {
        var random_bytes: [ThisModule.random_bytes_count]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var random_path: [ThisModule.random_path_len]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&random_path, &random_bytes);

        const sys_tmp_dir_path = try getSysTmpDir(allocator);
        defer allocator.free(sys_tmp_dir_path);
        var sys_tmp_dir = try std.fs.openDirAbsolute(sys_tmp_dir_path, .{});

        const abs_path = brk: {
            var path_buf = std.ArrayList(u8).init(allocator);
            defer path_buf.deinit();
            try path_buf.writer().print("{s}{c}{s}_{s}", .{
                sys_tmp_dir_path,
                sepbrk: {
                    switch (builtin.os.tag) {
                        .linux, .macos => break :sepbrk std.fs.path.sep_posix,
                        .windows => break :sepbrk std.fs.path.sep_windows,
                        else => {
                            @compileError("Not support, os=" ++ @tagName(builtin.os.tag));
                        },
                    }
                },
                if (args.prefix != null) args.prefix.? else "tmpdir",
                random_path,
            });
            break :brk try path_buf.toOwnedSlice();
        };
        const sub_path = abs_path[sys_tmp_dir_path.len + 1 ..]; // +1 for the sep
        const parent_dir_path = abs_path[0..sys_tmp_dir_path.len];

        const tmp_dir = try sys_tmp_dir.makeOpenPath(sub_path, .{});

        return .{
            .allocator = allocator,
            .abs_path = abs_path,
            .parent_dir_path = parent_dir_path,
            .sub_path = sub_path,
            .parent_dir = sys_tmp_dir,
            .dir = tmp_dir,
        };
    }

    /// init a tmpdir but from heap, the struct is owned by user, and need to be destory later by user too
    pub inline fn initOwned(allocator: std.mem.Allocator, args: TmpDirArgs) !*TmpDir {
        const tmp_dir = try allocator.create(TmpDir);
        tmp_dir.* = try TmpDir.init(allocator, args);
        return tmp_dir;
    }
};

/// TmpFile holds the info a new created temp file in sys tmp dir, it can be created by TmpFile.init or module level
/// tmpFile
pub const TmpFile = struct {
    const TmpFileArgs = struct {
        tmp_dir: *TmpDir,
        owned_tmp_dir: bool = false,
        prefix: ?[]const u8 = null,
        dir_prefix: ?[]const u8 = null,
        flags: std.fs.File.CreateFlags = .{ .read = true },
        dir_opts: std.fs.Dir.OpenDirOptions = .{},
    };

    allocator: std.mem.Allocator,
    /// the tmp dir contains this file, it can be owned or not owned
    tmp_dir: *TmpDir,
    /// indicates whether tmp_dir is owned by us. If true, deinit method will destory tmp_dir when called
    owned_tmp_dir: bool,
    abs_path: []const u8,
    /// dir_path is slice of abs_path, and it is abs path
    dir_path: []const u8,
    /// sub_path is slice of abs_path
    sub_path: []const u8,
    f: std.fs.File,

    /// caution: this deinit only clears mem resources, will not close file or delete tmp files & tmp_dir
    /// need manually close file, and clean them with tmp_dir
    pub fn deinit(self: *TmpFile) void {
        defer {
            if (self.owned_tmp_dir) {
                self.tmp_dir.deinit();
                self.allocator.destroy(self.tmp_dir);
                self.tmp_dir = undefined;
                self.owned_tmp_dir = false;
            }
        }
        self.close();
        self.allocator.free(self.abs_path);
        self.abs_path = undefined;
        self.dir_path = undefined;
        self.sub_path = undefined;
    }

    /// This method only close file handles, will not release the path resources
    pub fn close(self: *TmpFile) void {
        self.f.close();
        self.f = undefined;
    }

    /// return a TmpFile created in tmp dir in sys temp dir. Tmp dir must be provided in args. If do not want to provide
    /// tmp dir and let system auto create, use module level tmpFile
    pub fn init(allocator: std.mem.Allocator, args: TmpFileArgs) !TmpFile {
        var random_bytes: [ThisModule.random_bytes_count]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var random_path: [ThisModule.random_path_len]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&random_path, &random_bytes);

        const abs_path = brk: {
            var path_buf = std.ArrayList(u8).init(allocator);
            defer path_buf.deinit();

            try path_buf.writer().print("{s}{c}{s}_{s}", .{
                args.tmp_dir.abs_path,
                sepbrk: {
                    switch (builtin.os.tag) {
                        .linux, .macos => break :sepbrk std.fs.path.sep_posix,
                        .windows => break :sepbrk std.fs.path.sep_windows,
                        else => {
                            @compileError("Not support, os=" ++ @tagName(builtin.os.tag));
                        },
                    }
                },
                if (args.prefix != null) args.prefix.? else "tmp",
                random_path,
            });

            break :brk try path_buf.toOwnedSlice();
        };
        const sub_path = abs_path[args.tmp_dir.abs_path.len + 1 ..]; // +1 for sep
        const dir_path = abs_path[0..args.tmp_dir.abs_path.len];

        const tmp_file = try args.tmp_dir.dir.createFile(sub_path, args.flags);

        return .{
            .allocator = allocator,
            .tmp_dir = args.tmp_dir,
            .owned_tmp_dir = args.owned_tmp_dir,
            .abs_path = abs_path,
            .dir_path = dir_path,
            .sub_path = sub_path,
            .f = tmp_file,
        };
    }

    /// init a tmp file with struct created from heap, user must release the struct
    pub inline fn initOwned(allocator: std.mem.Allocator, args: TmpFileArgs) !*TmpFile {
        const tmp_file = try allocator.create(TmpFile);
        tmp_file.* = try TmpFile.init(allocator, args);
        return tmp_file;
    }
};

/// module tmpDir will create tmp dir with std.heap.page_allocator, if need a custom allocator, can use TmpDir.init/TmpDir.initAlloc
pub inline fn tmpDir(args: TmpDir.TmpDirArgs) !TmpDir {
    const allocator = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;
    return TmpDir.init(allocator, args);
}

/// module tmpDirOwned will create tmp dir with std.heap.page_allocator and is owned by user
pub inline fn tmpDirOwned(args: TmpDir.TmpDirArgs) !*TmpDir {
    const allocator = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;
    return TmpDir.initOwned(allocator, args);
}

/// module tmpFile will create tmp file with std.heap.page_allocator, if need a custom allocator, can use TmpFile.init/TmpFile.initAlloc
/// this method allows to omit args.tmp_dir. If so, it will create a TmpDir owned by returned TmpFile
pub inline fn tmpFile(args: struct {
    tmp_dir: ?*TmpDir = null,
    prefix: ?[]const u8 = null,
    dir_prefix: ?[]const u8 = null,
    flags: std.fs.File.CreateFlags = .{ .read = true },
    dir_opts: std.fs.Dir.OpenDirOptions = .{},
}) !TmpFile {
    const allocator = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;
    if (args.tmp_dir) |tmp_dir| {
        return TmpFile.init(allocator, .{
            .tmp_dir = tmp_dir,
            .owned_tmp_dir = false,
            .prefix = args.prefix,
            .dir_prefix = args.dir_prefix,
            .flags = args.flags,
            .dir_opts = args.dir_opts,
        });
    } else {
        var tmp_dir = try tmpDirOwned(.{
            .prefix = args.prefix,
            .opts = args.dir_opts,
        });
        _ = &tmp_dir;
        return TmpFile.init(allocator, .{
            .tmp_dir = tmp_dir,
            .owned_tmp_dir = true,
            .prefix = args.prefix,
            .dir_prefix = args.dir_prefix,
            .flags = args.flags,
            .dir_opts = args.dir_opts,
        });
    }
}

/// module tmpFileOwned will create tmp file with std.heap.page_allocator and is owned by user
pub inline fn tmpFileOwned(args: struct {
    tmp_dir: ?*TmpDir = null,
    prefix: ?[]const u8 = null,
    dir_prefix: ?[]const u8 = null,
    flags: std.fs.File.CreateFlags = .{ .read = true },
    dir_opts: std.fs.Dir.OpenDirOptions = .{},
}) !*TmpFile {
    const allocator = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;
    const tmp_file = try allocator.create(TmpFile);
    tmp_file.* = try TmpFile.init(allocator, .{
        .tmp_dir = args.tmp_dir,
        .prefix = args.prefix,
        .dir_prefix = args.dir_prefix,
        .flags = args.flags,
        .dir_opts = args.dir_opts,
    });
    return tmp_file;
}

test "Tmp" {
    {
        var tmp_file = try ThisModule.tmpFile(.{});
        defer tmp_file.deinit();
        try tmp_file.f.writeAll("hello, world!");
        try tmp_file.f.seekTo(0);
        var buf: [4096]u8 = undefined;
        var read_count = try tmp_file.f.readAll(&buf);
        try testing.expectEqual(read_count, "hello, world!".len);
        try testing.expectEqualSlices(u8, buf[0..read_count], "hello, world!");

        var tmp_file2 = try ThisModule.tmpFile(.{});
        defer tmp_file2.deinit();
        try tmp_file2.f.writeAll("hello, world!2");
        try tmp_file2.f.seekTo(0);
        read_count = try tmp_file2.f.readAll(&buf);
        try testing.expectEqual(read_count, "hello, world!2".len);
        try testing.expectEqualSlices(u8, buf[0..read_count], "hello, world!2");
    }

    {
        var tmp_dir = try ThisModule.tmpDirOwned(.{});
        defer {
            tmp_dir.deinit();
            tmp_dir.allocator.destroy(tmp_dir);
        }

        var tmp_file = try ThisModule.tmpFile(.{ .tmp_dir = tmp_dir });
        defer tmp_file.deinit();
        try tmp_file.f.writeAll("hello, world!");
        try tmp_file.f.seekTo(0);
        var buf: [4096]u8 = undefined;
        var read_count = try tmp_file.f.readAll(&buf);
        try testing.expectEqual(read_count, "hello, world!".len);
        try testing.expectEqualSlices(u8, buf[0..read_count], "hello, world!");

        var tmp_file2 = try ThisModule.tmpFile(.{ .tmp_dir = tmp_dir });
        defer tmp_file2.deinit();
        try tmp_file2.f.writeAll("hello, world!2");
        try tmp_file2.f.seekTo(0);
        read_count = try tmp_file2.f.readAll(&buf);
        try testing.expectEqual(read_count, "hello, world!2".len);
        try testing.expectEqualSlices(u8, buf[0..read_count], "hello, world!2");
    }
}
