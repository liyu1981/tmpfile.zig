# tmpfile.zig

## why

So far as I found there is no good lib in `zig` for creating temp files, so I write one for myself. This util file provides methods to create temp dir or temp file in system temp folder less tedious and manageable.

see code for example

```zig
var tmp_file = try ThisModule.tmpFile(.{});
defer tmp_file.deinit(); // file will be deleted when deinit
try tmp_file.f.writeAll("hello, world!");
try tmp_file.f.seekTo(0);
var buf: [4096]u8 = undefined;
var read_count = try tmp_file.f.readAll(&buf);
try testing.expectEqual(read_count, "hello, world!".len);
try testing.expectEqualSlices(u8, buf[0..read_count], "hello, world!");
```

or complexer

```zig
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
```

## useage

use zig packager

```bash
zig fetch --save https://github.com/liyu1981/tmpfile.zig/archive/refs/heads/main.tar.gz
```

(or lock on any commit as)
```bash
zig fetch --save zig fetch https://github.com/liyu1981/zcmd.zig/archive/<commit hash>.tar.gz
```

this lib is also provided for `build.zig`, use like

```zig
// in build.zig
const tmpfile = @import("tmpfile").tmpfile;
```

## license

MIT
