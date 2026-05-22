# INSERT INTO — implementation plan

## Product scope (v1)

| In scope | Out of scope (later) |
|----------|----------------------|
| `INSERT INTO table VALUES (...)` | Column list: `INSERT INTO t (a,b) VALUES (...)` |
| Integer and text string literals | Blob, real, `NULL` (add when needed) |
| Tables already in the DB (`tables_metadata`) | `CREATE TABLE` + INSERT in one session |
| Append-only: new row on **rightmost leaf**, new `rowid = max+1` | Ordered insert, leaf split, interior growth |
| Persist via pager write + flush | Freelist, `INSERT ... SELECT` |

**Prerequisite:** [rewrite.md](rewrite.md) phases **1–6** (decoder, varint, encoder, PageBuilder tests).

---

## Architecture

```
  INSERT INTO t VALUES (1, 'hi')
           │
           ▼
  ┌─────────────────┐
  │ I1: parse       │  InsertStatement { table, values[] }
  └────────┬────────┘
           ▼
  ┌─────────────────┐
  │ I2: encode row  │  encode_record → encode_table_leaf_cell
  └────────┬────────┘
           ▼
  ┌─────────────────┐
  │ I5: btree       │  walk to rightmost leaf, append cell if space
  │ append          │  rebuild leaf with encode_leaf_page
  └────────┬────────┘
           ▼
  ┌─────────────────┐
  │ I4: pager write │  mark_dirty → flush → write_raw_page
  │ (I3 ownership)  │
  └────────┬────────┘
           ▼
       disk file

  SELECT read path (after insert works):
  ┌─────────────────┐
  │ I7: cursor      │  borrow payload from cache; drop scanner copy
  └─────────────────┘
```

---

## Phase I1 — SQL surface

**Goal:** Parse insert statements; no execution.

1. **Tokens** (`token.zig`): `Insert`, `Into`, `Values`; literal forms for integer and quoted string (reuse identifier/number rules where possible).
2. **AST** (`ast.zig`): `InsertStatement { table: []const u8, values: []Literal }` with `Literal = .Int(i64) | .String([]const u8)`.
3. **Parser** (`parser.zig`): `INSERT INTO identifier VALUES ( literal (',' literal)* )` optional trailing `;`.
4. **Statement union:** add `.Insert`.
5. **Tests:** parse-only cases; malformed SQL errors.

**Done when:** `parse_statement("insert into foo values (1, 'a')")` builds AST; `zig build test` green.

---

## Phase I2 — Values → record bytes

**Goal:** Reuse encoders; no file I/O.

1. **`encode_row`** (new in `encode_page.zig` or small `insert_encode.zig`):
   - Input: `TableMetadata` (or col count + types) + `[]Literal`.
   - Check `values.len == table.cols.len`.
   - Map each literal → `RecordFieldEntry` (int → `.I64` or smallest int serial type; text → `.String`).
2. Call `encode_record` → `encode_table_leaf_cell(alloc, db_header, rowid, record, null)`.
3. **Tests:** known record bytes for `(1, 'hi')`; no pager.

**Done when:** owned cell bytes match PageBuilder-built cells for same data.

---

## Phase I3 — Owned parsed pages (rewrite phase 7)

**Goal:** Cached btree data does not depend on temporary read buffers.

**Repo note:** Much of this may already be landed (`TableLeafCell.payload: []u8`, `deinitPage`, pager `deinit` frees payloads). Verify and finish gaps.

1. Confirm `parse_table_leaf_cell` dupes local payload; `errdefer` on failure.
2. Confirm `pager.deinit` / `deinitPage` free every leaf payload.
3. Any test that calls `parse_page` directly must `defer deinitPage(...)`.

**Done when:** leak-free tests; parsed leaf cells survive after raw read buffer is freed.

**Not in I3:** scanner/cursor copy removal (that's I7).

---

## Phase I4 — Pager write path (rewrite phase 8.5–8.7)

**Goal:** Persist page images; justified by INSERT.

**Repo note:** 8.1–8.4 (single `cache`, temp raw on read) may already exist. This phase completes **writes**.

1. **`write_raw_page(n, raw: []const u8)`**
   - Assert `raw.len == header.page_size`.
   - Seek `(n-1)*page_size`, `writeAll`.
   - `cache.fetchRemove(n)` → free that entry (`deinitPage` / overflow payload).

2. **`alloc_page()`**
   - Extend file by one page; return new 1-based page number.
   - Zero-fill or leave garbage (only used when you add overflow/new leaf later).

3. **`mark_dirty(n)`** — `dirty.put(n, {})`.

4. **`flush()`**
   - For each `n` in `dirty`: get cached page, **serialize to raw** (see I5 helper `encode_page_to_raw`), `write_raw_page`, clear dirty.
   - Pages not in cache but dirty should not happen in v1.

5. **Test:** PageBuilder leaf → put in cache (or parse+insert path) → flush → new pager → `read_page` matches.

**Done when:** mutating a cached leaf and flushing changes bytes on disk.

---

## Phase I5 — Append-only B-tree insert

**Goal:** One new row on an existing table.

1. **`next_rowid(table)`** — scan table via existing `Scanner`; track max `rowid`; return `max+1` (empty table → `1`).

2. **`find_rightmost_leaf(root_page)`** — walk interior always to rightmost child (`rightmost_pointer` on last interior step).

3. **`leaf_has_space(leaf, new_cell_len, db_header)`** — compare used bytes + new cell vs usable space (reuse `encode_leaf_page` size math or conservative check).

4. **`append_cell_to_leaf(leaf_page_num, cell_bytes)`**
   - `read_page` leaf.
   - Collect existing cell encodings (re-encode from parsed cells **or** keep raw cell bytes if you store them — prefer re-encode from `TableLeafCell` + `encode_table_leaf_cell` for clarity).
   - Append new cell; `encode_leaf_page` → raw buffer.
   - Update in-memory cache entry; `mark_dirty(leaf_page_num)`.

5. **Overflow:** v1 may return `error.RowTooLarge` if record does not fit local payload; document limit. Overflow chains + `alloc_page` later.

6. **`execute_insert(db, stmt)`** — resolve table by name from `tables_metadata`; encode row; append; `flush()`.

7. **Tests:** temp file with PageBuilder DB (one table, one leaf); INSERT second row; SELECT or parse leaf sees two cells.

**Done when:** CLI `INSERT INTO t VALUES (...)` on existing test DB works end-to-end.

---

## Phase I6 — Planner + CLI

**Goal:** Wire INSERT through the same path as SELECT.

1. **`Operator.Insert`** (or execute fn on `Db`): holds table metadata + encoded cell + target leaf page num (computed at compile or execute).
2. **`Planner.compile`:** `.Insert => compile_insert` (not `UnsupportedStatement`).
3. **`main.eval_query`:** branch on statement kind; insert runs `execute_insert`, prints one line (`OK` / `inserted 1 row`).
4. **Error UX:** table not found, arity mismatch, table full.

**Done when:** `zig build run -- test.db` accepts INSERT after `.tables`.

---

## Phase I7 — Read path cleanup (rewrite phase 9)

**Goal:** Remove redundant copies after write path is stable.

1. **`Cursor`:** `cell_payload: []const u8` borrowed from cached `TableLeafCell.payload`.
2. **`Scanner`:** stop `ArrayList` copy; pass slice + `record_header`; cursor holds `pager` for overflow only.
3. **Overflow:** `overflow_buffer: ?ArrayList` — allocate only when `field()` needs bytes past local payload.
4. **Tests:** existing cursor test updated; full SELECT after INSERT still passes.

**Done when:** no per-row payload dupe in scanner; SELECT tests green.

**Optional:** Revisit whether I3 dupes are still needed everywhere or only for pages that get mutated.

---

## Phase I8 — Hardening (optional v1.1)

- `NULL` literal
- `error.TableFull` with clearer message
- Integration test: INSERT → SELECT roundtrip in one test block
- `root.zig` exports if you care about library surface

---

## Later (explicit backlog)

| Feature | Notes |
|---------|--------|
| Column list INSERT | Map names → column indices |
| Ordered insert + split | Binary search rowid, new pages via `alloc_page` |
| Interior page growth | New levels when root splits |
| Overflow pages | `encode_table_leaf_cell` + overflow scanner write |
| Freelist | Replace append-only `alloc_page` |
| CREATE TABLE at runtime | Separate from “existing tables only” |

---

## Suggested implementation order

```
I1 → I2 → I3 (verify) → I4 → I5 → I6 → I7 → I8
```

Do **not** block I5 on I7. Do **I4 before I5** so flush persists the appended leaf.

---

## File touch map (expected)

| File | Phases |
|------|--------|
| `parser/token.zig`, `parser/ast/ast.zig`, `parser/parser.zig` | I1 |
| `encode_page.zig` (or `insert_encode.zig`) | I2, I5 |
| `page.zig` | I3 verify |
| `pager_manager.zig` | I3, I4 |
| `db.zig` | I5, I6 |
| `planner.zig`, `operator.zig`, `main.zig` | I6 |
| `scanner.zig`, `cursor.zig` | I7 |
