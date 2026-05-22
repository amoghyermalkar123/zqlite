# Task Plan: Rewrite Decoder, Varint API, Pager, and Tests

## Goal

Replace the offset-computing decoder pattern with a streaming decoder, unify the varint encode/decode API, redesign the pager to eliminate dual-hashmap coupling, and replace raw-byte test construction with a PageBuilder test helper.

## Phases

1. Create unified varint module (`src/varint.zig`)
2. Update encoder (`encode_page.zig`) to use new varint API
3. Rewrite streaming Decoder in `page.zig`
4. Rewrite all `parse_*` functions to streaming style
5. Create PageBuilder test helper
6. Rewrite all tests to use PageBuilder
7. Make cell payloads owned (eliminate borrowed slices)
8. Rewrite pager to single cache + dirty tracking
9. Simplify Cursor to borrow from cached cell
10. Final cleanup and test pass

## Key Decisions

- Single `Varint{len, value}` struct replaces both `EncodedVarint` and the anonymous decoder return struct
- `u64` everywhere for varint values; callers cast to `i64` where needed
- Cells own their payloads via `alloc.dupe` during parse; raw buffers freed after parsing
- Single cache hashmap replaces dual `bufs` + `pages` hashmaps in pager
- Dirty tracking via separate dirty hashmap + `flush()` method
- `Decoder.seekTo(offset)` supported for overflow page chains

---

## Detailed Steps

### [done] Phase 1: Create unified varint module (`src/varint.zig`)

#### [done] Step 1.1: Create `src/varint.zig` with Varint struct and encode

- Create new file `src/varint.zig`
- Define `pub const Varint = struct { len: u8, value: u64 }`
- Implement `pub fn encode(value: u64, out: []u8) Varint`:
  - Assert `out.len >= 9`
  - Handle zero shortcut: `value == 0` -> `out[0] = 0`, return `{ .len = 1, .value = 0 }`
  - Handle normal 1..8-byte form (values <= `0x00ff_ffff_ffff_ffff`): write chunks right-to-left into `out`, set continuation bits
  - Handle special 9-byte form (values > 56 bits): last byte stores 8 bits, first 8 bytes store 7 bits each with continuation bit forced on
  - Logic should match existing `encode_varint` in `encode_page.zig:15-105` but write directly into `out`

**Tests:** encode zero, 300, max 8-byte, max 9-byte, verify buffer contents

**Dependencies:** None

#### [done] Step 1.2: Add `encodeAppend` and `lenFor` to varint module

- Add `pub fn lenFor(value: u64) u8` - returns byte count without writing (bit-width checks)
- Add `pub fn encodeAppend(value: u64, out: *std.ArrayList(u8)) !void` - ensures capacity, encodes, appends

**Tests:** lenFor for 0/300/max/9-byte, encodeAppend roundtrip

**Dependencies:** Step 1.1

#### [done] Step 1.3: Add `decode` and `decodeSlice` to varint module

- Add `pub fn decode(buf: []const u8, offset: usize) !Varint` - reads varint at offset, matches existing `read_varint_at` logic
- Add `pub fn decodeSlice(buf: []const u8) !struct { varint: Varint, remaining: []const u8 }`

**Tests:** decode zero/300, roundtrip all sizes, decodeSlice returns remaining, bounds check

**Dependencies:** Step 1.1


---

### [done] Phase 2: Create encoder using varint API (`src/encode_page.zig`)

#### [done] Step 2.1: Create `src/encode_page.zig` with `encode_record`

- Create new file `src/encode_page.zig`
- Add `const std = @import("std");`
- Add `const varint = @import("varint.zig");`
- Add `const cnst = @import("constants.zig");`
- Add `const page = @import("page.zig");`
- Implement `pub fn encode_record(alloc: std.mem.Allocator, fields: []const page.RecordFieldEntry) ![]u8`:
  - First pass: compute serial types and header size using `varint.lenFor`
  - Allocate record buffer: header_size + total payload size
  - Write header size varint at position 0
  - Write serial type varints after header size
  - Write field data (integers as big-endian, strings/blobs as raw bytes)
  - Return owned slice

**Tests:** encode empty record, encode single integer, encode string, encode mixed types, verify buffer layout

**Dependencies:** Step 1.4

#### [done] Step 2.2: Add `encode_table_leaf_cell`

- Implement `pub fn encode_table_leaf_cell(alloc: std.mem.Allocator, db_header: page.DbHeader, rowid: u64, record_payload: []const u8) ![]u8`:
  - Cell layout: varint(payload_size) + varint(rowid) + payload_bytes + [4-byte overflow pointer if overflow]
  - Use `varint.encodeAppend` for payload size and rowid
  - Compute local payload size using `page.PageHeader.local_payload_size`
  - If overflow, append 4-byte big-endian overflow page number
  - Return owned slice

**Tests:** encode cell with small payload, encode cell with overflow, verify byte layout

**Dependencies:** Step 2.1

#### [done] Step 2.3: Add `encode_table_interior_cell`

- Implement `pub fn encode_table_interior_cell(left_child_page: u32, key: u64) ![]u8`:
  - Cell layout: 4 bytes (left_child_page, big-endian u32) + varint(key)
  - Allocate buffer, write left_child as big-endian u32, `varint.encode(key, buf[4..])`
  - Return owned slice

**Tests:** encode interior cell, verify byte layout

**Dependencies:** Step 2.1

#### [done] Step 2.4: Add `encode_page` (full page encoder)

- Implement `pub fn encode_leaf_page(alloc: std.mem.Allocator, db_header: page.DbHeader, cells: []const []const u8) ![]u8`:
  - Compute total page size: 8-byte header + 2*cell_count cell pointers + sum of cell sizes
  - Allocate buffer, zero it
  - Write page header (type=0x0D, freeblock=0, cell_count, content_offset, fragmented=0)
  - Write cell pointers at offset 8 + 2*i (big-endian u16)
  - Write cell content from end of buffer backwards (SQLite convention)
  - Return owned buffer

**Tests:** encode page with one cell, encode page with multiple cells, verify roundtrip encode→parse

**Dependencies:** Step 2.2

---

### Phase [done] 3: Rewrite streaming Decoder in `page.zig`

#### Step [done] 3.1: Rewrite Decoder struct with position tracking

Replace existing Decoder struct (lines 129-151) with:

```zig
pub const Decoder = struct {
    buffer: []const u8,
    pos: usize,

    pub fn init(buffer: []const u8) Decoder
    pub fn initAt(buffer: []const u8, offset: usize) Decoder
    pub fn remaining(self: *const Decoder) []const u8
    pub fn pos(self: *const Decoder) usize
    pub fn seekTo(self: *Decoder, offset: usize) void
    pub fn readVarint(self: *Decoder) !varint.Varint    // advances pos
    pub fn readInt(self: *Decoder, comptime T: type) !T // advances pos
    pub fn readEnum(self: *Decoder, comptime T: type) !T
    pub fn readSlice(self: *Decoder, len: usize) ![]const u8
    pub fn skip(self: *Decoder, len: usize) !void
};
```

- Add `const varint = @import("varint.zig");` at top of `page.zig`

**Dependencies:** Step 1.4

#### Step [done] 3.2: Add Decoder tests

- `test "Decoder readVarint advances position"` - value=300, len=2, pos=2, remaining=[0xFF]
- `test "Decoder readInt advances position"` - readInt(u16) -> 1, pos=2
- `test "Decoder readSlice advances position"` - readSlice(2) -> "he", pos=2
- `test "Decoder seekTo"` - seekTo(3), readInt(u8) -> byte at index 3
- `test "Decoder bounds checks"` - readInt past end -> `error.BufferExhausted`

**Dependencies:** Step 3.1

---

### [done] Phase 4: Rewrite all `parse_*` functions to streaming style

#### Step [done] 4.1: Rewrite `parse_table_leaf_cell` to streaming style

- Change signature: remove `*Decoder` param, take `raw_buf: []const u8` and `cell_ptr: u16`
- Create local decoder: `var decoder = Decoder.initAt(raw_buf, cell_ptr)`
- Replace `read_varint_at(decoder, cell_ptr)` -> `decoder.readVarint()`
- Remove all manual offset math (`row_id_offset`, `actual_payload_offset`)
- Replace `decoder.read_slice(actual_payload_offset, local_size)` -> `decoder.readSlice(local_size)`

**Dependencies:** Step 3.1

#### Step [done] 4.2: Rewrite `parse_table_internal_cell` to streaming style

- Change signature: take `raw_buf: []const u8` and `cell_ptr: u16`
- Create `var decoder = Decoder.initAt(raw_buf, cell_ptr)`
- Replace `decoder.read_int(cell_ptr, u32)` -> `decoder.readInt(u32)`
- Replace `read_varint_at(decoder, cell_ptr + 4)` -> `decoder.readVarint()`

**Dependencies:** Step 3.1

#### Step [done] 4.3: Update `parse_table_leaf_page` to pass raw buffer to cell parsers

- Pass `decoder.buffer` (the raw buffer) to `parse_table_leaf_cell` and `parse_table_internal_cell`
- Keep Decoder for parsing cell pointers (at known offsets)

**Dependencies:** Steps 4.1, 4.2

#### [done] Step 4.4: Rewrite `parse_record_header` to streaming style

- Replace `var decoder = Decoder{ .buffer = cell_payload }` -> `var decoder = Decoder.init(cell_payload)`
- Replace `read_varint_at(&decoder, 0)` -> `decoder.readVarint()`
- Remove `record_header_cursor` - decoder tracks position automatically
- Keep `field_payload_cursor` for tracking where field data starts

**Dependencies:** Step 3.1

#### [done] Step 4.5: Delete `read_varint_at` function

- Delete the `read_varint_at` function (lines 289-324)
- Remove any remaining references

**Dependencies:** Steps 4.1-4.4

#### Step [done] 4.6: Update `parse_page_header` to streaming style

- `decoder.seekTo(page_offset)` once, then call `readEnum`, `readInt` sequentially
- Remove explicit offset calculations like `page_offset + cnst.PAGE_FIRST_FREEBLOCK_OFFSET`

**Dependencies:** Step 3.1

#### [done] Step 4.7: Update `parse_cell_pointers` to streaming style

- Create `Decoder.initAt(buffer, page_offset + header_size)` and call `readInt(u16)` in a loop

**Dependencies:** Step 3.1

---

### [done] Phase 5: Create PageBuilder test helper

#### [done] Step 5.1: Create `src/testing/page_builder.zig` with basic structure

- Create new file with `PageBuilder` struct containing: `alloc`, `page_type`, `db_header`, `cells: std.ArrayList(EncodedCell)`, `rightmost_pointer`
- Define `EncodedCell = struct { data: []u8 }` (owned)
- Stub methods: `init`, `addLeafCell`, `addInteriorCell`, `setRightmostPointer`, `build`, `deinit`

**Dependencies:** Steps 2.2, 2.3

#### [done] Step 5.2: Implement `addLeafCell`

- Call `encode_record(alloc, values)` -> record bytes
- Call `encode_table_leaf_cell(alloc, db_header, @intCast(rowid), record)` -> cell bytes
- Free record bytes, store cell bytes in cells

**Dependencies:** Step 5.1

#### [done] Step 5.3: Implement `addInteriorCell`

- Interior cell layout: 4 bytes (`left_child_page`, big-endian u32) + varint (key)
- Allocate buffer, write `left_child` as big-endian u32, `varint.encode(key, buf[4..])`
- Store in cells

**Dependencies:** Step 5.1

#### [done] Step 5.4: Implement `build`

- Compute total page size: header + cell_pointers(2*n) + cell_content_sum + rightmost_pointer(4 if interior)
- Allocate buffer, zero it
- Write page header (type, freeblock=0, cell_count, content_offset, fragmented=0, rightmost)
- Write cell pointers at `header_size + 2*i` (big-endian u16)
- Write cell content from end of buffer backwards (SQLite convention)
- Return owned buffer

**Dependencies:** Step 5.3

#### [done] Step 5.5: Implement `deinit` and add PageBuilder tests

- `deinit`: free all cell data slices, deinit cells ArrayList
- Tests: build leaf page with one cell, multiple cells, interior page, roundtrip encode->parse

**Dependencies:** Step 5.4

---

### [done] Phase 6: Rewrite all tests to use PageBuilder

#### [done] Step 6.1: Rewrite `page.zig` test `"parse_page_rest"`

- Remove all `buf[N] = 0xXX` raw byte assignments
- Use PageBuilder to construct the page, parse, verify

**Dependencies:** Step 5.5

#### [done] Step 6.2: Rewrite `page.zig` test `"parse_page"`

- Remove all `buf[100] = 0x0D` etc. raw byte assignments
- Use PageBuilder to construct the page, parse, verify

**Dependencies:** Step 6.1

#### [done] Step 6.3: Rewrite `pager_manager.zig` test `"load_page"`

- Remove all `full_page[N] = 0xXX` raw byte assignments
- Use PageBuilder to construct page bytes, write to test file, parse via pager

**Dependencies:** Step 6.1

#### [done] Step 6.4: Update `encode_page.zig` tests

- Update tests to use `varint.decode` instead of `read_varint_at`
- Replace raw byte page construction with PageBuilder in roundtrip test

**Dependencies:** Steps 5.5, 6.1

---
