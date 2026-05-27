# Known Caveats

Operational limits and on-disk layout edge cases for zsqlite. This file is separate from implementation plans; it records behavior that is acceptable for the current MVP but important to understand before extending the engine.

---

## Page 1 write layout (INSERT)

### Summary

`encode_leaf_page` produces a **plain B-tree leaf page** (page-type byte at offset 0). That matches pages 2, 3, … but **not** the full on-disk layout of **page 1**. Writing that buffer to page 1 with `write_raw_page(1, …)` without preserving the first 100 bytes would corrupt the database file header.

This does **not** affect the current MVP insert path for normal user tables.

### Why page 1 is different

Every SQLite file stores fixed-size page slots back-to-back. Page 1 starts at file offset 0.

```
  Page 1 slot (e.g. 4096 bytes)
  ┌─────────────────────────┬──────────────────────────────────┐
  │  File header (100 B)    │  B-tree page (sqlite_master)     │
  │  "SQLite format 3\0"    │  0x0D leaf, cells, …             │
  └─────────────────────────┴──────────────────────────────────┘
   bytes 0 .. 99              bytes 100 .. page_size - 1

  Page 2+ slot
  ┌──────────────────────────────────────────────────────────────┐
  │  B-tree page only (type byte at offset 0)                  │
  └──────────────────────────────────────────────────────────────┘
```

On **read**, zsqlite handles page 1 correctly: `parse_page` skips the first 100 bytes when `page_num == 1` (`src/page.zig`).

On **write**, `write_raw_page` copies the supplied buffer over the **entire** page slot. There is no special case for page 1.

### What the insert path does

INSERT rebuilds a leaf with `encode_leaf_page`, then:

```zig
try db.pager.write_raw_page(tl.page_num, new_page_buf);
try db.pager.flush();
```

`tl.page_num` comes from `TableMetadata.table_root_page`, which is read from `sqlite_master` column `rootpage` when the database is opened (`src/db.zig`).

### When the bug would trigger

| Target table | Typical `rootpage` | Safe with current write path? |
|--------------|-------------------|-------------------------------|
| User table (`users`, …) on a normal `sqlite3`-built file | 2 or higher | Yes |
| `sqlite_master` | 1 | No — would overwrite file header |
| Any table with corrupt/wrong `rootpage` in master | Possibly 1 | No |

### Why MVP is unaffected

- User tables created by the standard `sqlite3` CLI get a new page for row storage; page 1 is already used by `sqlite_master`, so the first user table is usually root page **2**.
- zsqlite does **not** support schema maintenance: no in-engine `CREATE TABLE`, and no intended `INSERT INTO sqlite_master` to register tables. MVP assumes an existing `.db` built externally.
- Normal usage is `INSERT INTO <user_table> …`, which writes to page 2+.

There is currently **no explicit guard** that rejects `INSERT INTO sqlite_master` by name. That statement is out of scope for MVP; if it were allowed, it could hit this bug. Product-wise we do not support writing to `sqlite_master`.

### Fix (when needed)

Before writing page 1, preserve or rebuild the 100-byte file header:

- Copy bytes `0..100` from the existing `bufs[1]` entry and place the new B-tree image starting at offset 100, **or**
- Use the `PageBuilder.buildPageFile(1)` pattern from `src/testing/page_builder.zig`, which produces a full page-1 file image (header + B-tree).

Do not pass raw `encode_leaf_page` output to `write_raw_page(1, …)` alone.

---

## Overflow pages: EOF append without catalog updates (INSERT)

### Summary

When a row needs overflow storage, the MVP plan is to **append new pages at the end of the file** and chain them from the leaf cell. That path does **not**:

- take pages from the SQLite **freelist** (reclaimed deleted pages), or
- update the **database header page count** after growing the file.

`sqlite_master` is also **unchanged** for overflow-only inserts (table `rootpage` stays the same).

### Freelist allocation

SQLite records unused pages in a freelist so new allocations can reuse space instead of growing the file forever.

| Approach | MVP overflow path | Full SQLite behavior |
|----------|-------------------|----------------------|
| New pages | `file_size / page_size + 1`, consecutive page numbers | Prefer freelist; extend file only if empty |
| After many deletes | Dead pages may remain unused in file | Freelist hands them back out |

**When you need freelist:** Deletes, `VACUUM`-style reuse, long-lived databases where file size must not monotonically grow.

**MVP OK without it:** Append-only tests and inserts; zsqlite does not delete rows or shrink files yet.

### Database header page count

The 100-byte file header includes how many pages the database is supposed to have. Readers and `sqlite3` use that for bounds and integrity checks.

If INSERT (or overflow allocation) writes bytes past the old end of file but **does not** bump the header’s page count, the on-disk file can be **longer than the header claims**.

**When you need to update it:** Any time you extend the file (overflow pages, new btree pages, splits). Required for strict compatibility with the `sqlite3` CLI and tools that trust the header over raw file length.

**MVP risk:** zsqlite’s own pager often uses file size for the next page number; external tools opening the same file may warn or misbehave until the header is synced.

### `sqlite_master` (root page)

`sqlite_master` stores each table’s **`rootpage`** (B-tree root). Normal `INSERT` into an existing user table does **not** change it—the leaf (or interior) root is already correct.

**When you need to update `sqlite_master`:** B-tree **splits** or a **new root** (e.g. interior page added, root page number changes). Phase 8-style growth, not overflow-only append to an unchanged leaf root.

### Related code touchpoints

- Next page number from file length: `pager_manager` (planned `alloc_next_page_number` for 7.2).
- Overflow bytes on disk: `encode_overflow_page` + `write_raw_page` + `flush`.
- Leaf overflow pointer: `encode_table_leaf_cell` with `first_ov_page`.

---

## Related MVP limits (INSERT)

Broader INSERT limitations (single-leaf tables, no splits, etc.) are tracked in `plans/insert_into_plan.md`. Overflow **detection** (7.1) and **allocation** (7.2) progress there; this section records on-disk metadata gaps once overflow writes land.
