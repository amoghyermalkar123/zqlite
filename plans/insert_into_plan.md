# Task Plan: INSERT INTO Support

## Goal

Add end-to-end support for `INSERT INTO` so the CLI can insert rows into user tables in an existing SQLite database file. The path runs from SQL text through tokenize/parse/plan/execute, persists a new B-tree leaf cell (with record payload), and leaves the file in a valid on-disk layout.

**Starting state:** Parser accepts `SELECT` and `CREATE TABLE` only. Planner compiles only `SELECT` to `SeqScan`. Pager is read-only. `encode_record` / `encode_table_leaf_cell` / `encode_leaf_page` exist and are tested. Table metadata is loaded from `sqlite_master` at open time.

**End state:** `INSERT INTO table [(cols)] VALUES (literals)` works for tables created by standard SQLite (single leaf page or small tree). Inserts validate column count/names and types, allocate a new `rowid`, write the page back to disk, and report success in the CLI.

---

## Phases

1. Lexer and literal tokens (keywords, numbers, quoted strings, `NULL`)
2. AST and parser for `INSERT INTO`
3. Value binding: SQL literals → `RecordFieldEntry` using table metadata
4. Execution operator and planner wiring
5. Rowid allocation and leaf-page mutation (in-memory)
6. Pager write path and cache coherence
7. Overflow pages for large payloads (if needed beyond MVP)
8. B-tree growth: page full, splits, new pages (stretch)
9. CLI integration and integration tests
10. Cleanup, docs, and optional syntax extensions

---

## Scope

### In scope (MVP)

| Feature | Notes |
|--------|--------|
| `INSERT INTO t VALUES (...)` | All columns, declaration order |
| `INSERT INTO t (a, b) VALUES (...)` | Explicit column list |
| One value tuple per statement | `VALUES (1, 'x')` only |
| Literals | `NULL`, integer, single-quoted string |
| Target | User tables already in DB (`tables_metadata`) |
| Storage | Append cell on existing leaf when space allows |
| Rowid | `max(existing rowids) + 1` via table scan |
| Persistence | Write modified page bytes to file |

### Out of scope (initially; add in later phases)

- `INSERT ... SELECT`
- `INSERT OR REPLACE` / `IGNORE` / conflict clauses
- `DEFAULT` values
- Blob literals (`X'...'`)
- Real/float literals
- Multi-row `VALUES (...), (...)`
- `CREATE TABLE` execution from CLI (parsed today, not executed)
- Freelist / new page allocation for brand-new tables
- Full interior-page splits and balanced B-tree maintenance

### Prerequisite awareness

- **Pager rewrite** (`plans/rewrite.md` phases 7–9): INSERT needs *some* write API. Implement a minimal `write_page` + `flush` on the current dual-hashmap pager first; migrate to dirty-tracking pager later without changing the insert operator’s interface.
- **CREATE TABLE**: Not required for INSERT MVP if tests use `.db` files built with the `sqlite3` CLI.

---

## Key Decisions

- **Statement → operator union:** Introduce `Plan` (or extend planner output) as `union(enum) { SeqScan, Insert }` instead of forcing INSERT through `SeqScan`.
- **Literal AST:** Reuse a small `ast.Literal` / `ast.Expr` union shared later by `UPDATE`/`WHERE`; INSERT only needs literals in phase 1.
- **Column binding:** Resolve insert columns to `TableMetadata.cols` indices; omitted column list means all columns in schema order.
- **Typing:** Map declared `ast.Create.Type` to `encode_page.RecordFieldEntry`; reject unsupported literal kinds (e.g. string into INTEGER for MVP, or coerce per SQLite affinity rules in a follow-up).
- **Rowid:** 64-bit integer key in leaf cell; no `AUTOINCREMENT` metadata in MVP—always scan for max.
- **Cell order:** New cell inserted in **ascending `rowid` order** on the leaf page (SQLite invariant).
- **Page encoding:** Rebuild full leaf page with `encode_leaf_page` from all cell byte slices (existing cells + new cell), not incremental patch of raw bytes.
- **Cache:** After write, update `bufs` raw slice and invalidate or re-parse `pages` entry for that page number.

---

## Architecture (target)

```
  SQL string
      │
      ▼
  token.zig          Insert, Into, Values, Null, Integer, StringLiteral, …
      │
      ▼
  parser.zig         ast.Statement.Insert
      │
      ▼
  planner.zig        Plan.Insert { table, bound_fields, … }
      │
      ▼
  insert.zig (new)   execute: rowid → encode_record → encode_table_leaf_cell
      │              → mutate leaf → pager.write_page → pager.flush
      ▼
  sqlite .db file
```

ASCII: one insert through the stack

```
  zsqlite> INSERT INTO users (id, name) VALUES (3, 'bob');

  [tokenize]  insert · into · id · name · values · ( · 3 · 'bob' · )
       │
  [parse]     InsertStatement { table=users, cols=[id,name], values=[3,'bob'] }
       │
  [bind]      RecordFieldEntry.{ .I64=3, .String='bob' }  (order matches cols)
       │
  [plan]      table.first_page, encoded cell bytes, target leaf page num
       │
  [exec]      rowid=4 → encode → rebuild leaf page → write page N to file
```

---

## Detailed Steps

### Phase 1: Lexer and literal tokens

#### Step 1.1: Extend `Token` enum

Add tokens (names can match existing style):

- `Insert`, `Into`, `Values`, `Null`
- `Integer: i64` (or `[]const u8` if you prefer parse-at-bind time)
- `StringLiteral: []u8` (owned, lowercasing **not** applied to string contents)

**Dependencies:** None

#### Step 1.2: Keyword recognition in `tokenize`

Map `insert`, `into`, `values`, `null` to keyword tokens (same pattern as `select` / `from`).

**Tests:** tokenize `insert into t values (null)`; tokenize case-insensitive `INSERT`

**Dependencies:** Step 1.1

#### Step 1.3: Numeric literals

In `tokenize` `else` branch, if first char is digit or `-`, scan integer with `std.fmt.parseInt(i64, …)`.

- MVP: decimal integers only
- Reject bare `+` unless you add it explicitly

**Tests:** `42`, `-1`, reject `12.34` with clear error (or defer float to later)

**Dependencies:** Step 1.1

#### Step 1.4: Quoted string literals

Handle `'` … `'` with SQLite-style doubling: `'it''s'` → `it's`.

- Do not treat quoted text as `Identifier`
- Return `Token.StringLiteral` with owned content

**Tests:** empty string `''`, escaped quote, reject unterminated string

**Dependencies:** Step 1.1

#### Step 1.5: Tokenizer tests module

Expand `src/parser/token.zig` tests (or add `src/parser/token_test.zig`) covering INSERT-shaped inputs end-to-end at token level.

**Dependencies:** Steps 1.2–1.4

---

### Phase 2: AST and parser

#### Step 2.1: Add `ast/insert.zig`

Define:

```zig
pub const InsertStatement = struct {
    table: []const u8,
    columns: ?[]const []const u8,  // null => all columns in schema order
    values: []Literal,
};

pub const Literal = union(enum) {
    Null,
    Integer: i64,
    String: []const u8,
};
```

**Dependencies:** None

#### Step 2.2: Extend `ast.Statement` union

Add `Insert: InsertStatement` beside `Select` and `CreateTable`.

**Dependencies:** Step 2.1

#### Step 2.3: Implement `parse_insert` in `parser.zig`

Grammar (MVP):

```
insert_stmt ::= INSERT INTO identifier
                [ '(' column_list ')' ]
                VALUES '(' literal_list ')'

column_list   ::= identifier ( ',' identifier )*
literal_list  ::= literal ( ',' literal )*
literal       ::= NULL | integer | string_literal
```

Flow:

1. `expect Insert`, `expect Into`, table name
2. Optional `(` column_list `)`
3. `expect Values`, `expect Lpar`, `parse_literal_list`, `expect Rpar`
4. Optional trailing `;` when `trailing_semicolon` is true (match `parse_statement` behavior)

**Tests:** parse full statement; parse with/without column list; wrong token → `UnexpectedToken`

**Dependencies:** Phase 1, Step 2.2

#### Step 2.4: Wire `parse_statement` and `ParseResult.deinit`

- Dispatch on `Token.Insert`
- Free `columns` slice, string literals in `values`, table name as per existing ownership rules

**Dependencies:** Step 2.3

#### Step 2.5: Parser tests

Add `src/parser/parser.zig` tests (or dedicated test file) with allocator cleanup via `ParseResult.deinit`.

Cases:

- `insert into t values (1, 'a')`
- `insert into t (b, a) values ('x', 2)`
- column count ≠ value count → error
- unknown trailing tokens → error

**Dependencies:** Step 2.4

---

### Phase 3: Value binding

#### Step 3.1: Add `bind_insert_values` helper

Location: new `src/bind.zig` or method on planner module.

Inputs:

- `TableMetadata`
- `?[]const []const u8` column names from AST
- `[]Literal`

Output: `[]encode_page.RecordFieldEntry` in **storage column order** (field index 0 .. n-1).

Rules (MVP):

| Schema type | Literal | Record field |
|-------------|---------|----------------|
| Integer | Null | `.Null` or error (choose: reject NULL for NOT NULL later) |
| Integer | Integer | smallest fitting `.I8` … `.I64` |
| Text | String | `.String` |
| Text | Null | `.Null` |
| Blob | String | `.Blob` (same bytes) |
| Blob | Null | `.Null` |

Reject: string literal into Integer column (clear `TypeMismatch` error).

**Tests:** bind all columns; bind subset with column list; mismatch errors

**Dependencies:** Phase 2

#### Step 3.2: Column count validation

- No column list: `values.len == table.cols.len`
- With column list: `columns.len == values.len` and each name exists in schema

**Dependencies:** Step 3.1

---

### Phase 4: Execution operator and planner

#### Step 4.1: Define `Plan` union in `planner.zig` (or `plan.zig`)

```zig
pub const Plan = union(enum) {
    Select: Operator.SeqScan,
    Insert: InsertOp,
};

pub const InsertOp = struct {
    table: *const TableMetadata,  // or table name + resolved metadata
    fields: []RecordFieldEntry,   // owned, column order
};
```

**Dependencies:** Phase 3

#### Step 4.2: `compile_insert` in planner

- Resolve table by name from `db.tables_metadata` → `TableNotFound`
- Call binder → owned `fields` slice
- Return `Plan.Insert`

**Dependencies:** Step 4.1

#### Step 4.3: Add `execute_insert` module (`src/insert.zig`)

Responsibilities (stub first, then fill):

1. Allocate `rowid` (phase 5)
2. `encode_record(alloc, fields)`
3. `encode_table_leaf_cell(alloc, db.header, rowid, record, overflow_page)`
4. Locate target leaf page and existing cells (phase 5–6)
5. Rebuild page, `write_page`, `flush`

Return: `rows_inserted: usize = 1` or void.

**Dependencies:** Steps 4.1–4.2

#### Step 4.4: Change `Planner.compile` signature

`compile(...) !Plan` with switch on `ast.Statement` including `.Insert`.

Keep `compile_select` returning `Plan.Select`.

**Dependencies:** Steps 4.2–4.3

---

### Phase 5: Rowid allocation and leaf mutation (in-memory)

#### Step 5.1: `max_rowid_for_table`

Use existing `Scanner` starting at `table.first_page`:

- Walk all leaf cells in table B-tree
- Track maximum `row_id`
- Return `max + 1`, or `1` if table empty

**Tests:** empty table → 1; table with rows 1,5 → 6

**Dependencies:** `scanner.zig` (read path)

#### Step 5.2: Collect existing leaf cells as byte slices

For target leaf page:

- Read parsed `TableLeafPage`
- For each cell, re-encode with existing `row_id` and payload OR keep original encoded bytes if you store them (re-encode is simpler but must preserve overflow pointers)

MVP shortcut: only support tables whose **data** root is a **single leaf page** with all rows (common for small test DBs). Document limitation in plan progress notes.

**Tests:** read `testdata/users.db` leaf page, roundtrip cell count unchanged after re-encode without insert

**Dependencies:** `encode_table_leaf_cell`, `encode_leaf_page`

#### Step 5.3: Insert new cell in sorted order

- Encode new cell with new `rowid`
- Merge into `[]const []u8` cells sorted by decoded rowid
- `encode_leaf_page` → full page buffer

Handle page 1 storage offset: use `PageBuilder.buildPageFile(page_num)` pattern from tests for correct file image.

**Tests:** in-memory leaf gains one cell; cell count increments; rowids sorted

**Dependencies:** Steps 5.1–5.2

#### Step 5.4: `PageFull` error

If `encode_leaf_page` returns `PageTooSmall`, propagate `error.PageFull` (handled in phase 8).

**Dependencies:** Step 5.3

---

### Phase 6: Pager write path

#### Step 6.1: `write_raw_page(page_num, bytes)`

- Assert `bytes.len == page_size`
- Copy into `bufs` entry (allocate if missing)
- Remove or invalidate parsed entry in `pages` for that page number

**Dependencies:** None

#### Step 6.2: `flush` to file

- For each dirty page in `bufs` (or explicit dirty set): `seekTo((page_num-1)*page_size)`, `writeAll`
- Page 1: write only from byte 0 of buffer (file image already includes header in buffer from `buildPageFile`)

**Tests:** tmp file → insert → reopen → `SELECT` shows new row (manual or automated)

**Dependencies:** Step 6.1

#### Step 6.3: Wire `execute_insert` to pager

After in-memory page build:

```zig
try pager.write_raw_page(leaf_page_num, new_bytes);
try pager.flush();
```

**Dependencies:** Phase 5, Step 6.2

#### Step 6.4: Optional: refresh `tables_metadata`

Not required for INSERT into user tables if schema unchanged. Skip unless you cache row counts.

**Dependencies:** Step 6.3

---

### Phase 7: Overflow pages

#### Step 7.1: Detect overflow need

When `encode_table_leaf_cell` would set overflow pointer, payload does not fit local slot.

**Dependencies:** `encode_table_leaf_cell` (already supports `first_ov_page`)

#### Step 7.2: Allocate overflow chain (MVP)

- Append new page(s) at end of file (read `db.header` page size, file length / page_size + 1)
- Write overflow pages with `encode` layout matching `parse_overflow_page`
- Pass first overflow page number into `encode_table_leaf_cell`

**Tests:** insert row with large text/blob exceeding local payload threshold

**Dependencies:** Phase 6

**Note:** Defer if MVP test DBs only use small rows; keep phase in plan for completeness.

---

### Phase 8: B-tree growth (stretch)

#### Step 8.1: Find correct leaf in multi-page tree

Extend scanner logic: descend interior pages by key (`rowid`) to find leaf where new key belongs.

**Dependencies:** Phase 5

#### Step 8.2: Page split

When `PageFull`:

- Allocate new leaf page
- Move half the cells (or new cell only) per SQLite split rules
- Update parent interior or create new root interior page

**Dependencies:** Step 8.1, Phase 6 (allocate pages)

#### Step 8.3: Update `sqlite_master` root page

Only if root changes (advanced); user tables store `rootpage` in master—INSERT into deep tree may require updating that field. **Defer** until interior inserts are required.

**Dependencies:** Step 8.2

---

### Phase 9: CLI and integration tests

#### Step 9.1: Update `main.zig` `eval_query`

```zig
const plan = try en.compile(parsed.statement);
switch (plan) {
    .Select => |scan| { /* existing row loop */ },
    .Insert => |ins| {
        try insert.execute(&dba, ins);
        // print "INSERT OK" or rows affected
    },
}
```

**Dependencies:** Phase 4, 6

#### Step 9.2: Integration test binary or test block

Workflow:

1. Copy or build minimal `.db` with `CREATE TABLE` + optional seed row via `sqlite3`
2. Open with `db.from_file`
3. `parse_statement` + `compile` + `execute_insert`
4. Reopen file, `SELECT` via existing scan path, assert new row

**Dependencies:** Step 9.1

#### Step 9.3: CLI manual test checklist

- [ ] `INSERT INTO t VALUES (...)` on empty table
- [ ] Insert second row, rowid increments
- [ ] Wrong column count → error message
- [ ] Unknown table → `TableNotFound`
- [ ] `.tables` unchanged; new row visible via `SELECT`

**Dependencies:** Step 9.2

---

### Phase 10: Cleanup and extensions

#### Step 10.1: Error set consolidation

Shared errors: `TableNotFound`, `InvalidColumnName`, `TypeMismatch`, `PageFull`, `UnsupportedInsert`.

**Dependencies:** All prior phases

#### Step 10.2: Document limitations

Short section in `README` or `docs/insert.md`: supported syntax, single-leaf MVP, no `INSERT SELECT`.

**Dependencies:** MVP complete

#### Step 10.3: Optional extensions (pick individually)

- Multi-row `VALUES (...), (...)`
- `REAL` literals and column type
- Blob literal `X'ABCD'`
- Affinity-based coercion (SQLite rules)
- `INSERT OR IGNORE` stub that maps to errors today

**Dependencies:** MVP complete

---

## Testing Strategy Summary

| Layer | What to test |
|-------|----------------|
| Tokenizer | Keywords, integers, strings, `NULL`, rejection cases |
| Parser | AST shape, column lists, deinit/no leaks |
| Binder | Type pairing, column order, errors |
| Rowid scan | Max + 1 on fixture DB |
| Encode | Rebuild leaf with N+1 cells, sorted rowids |
| Pager | Write + flush + reread |
| E2E | insert → reopen → select |

Prefer `PageBuilder` / tmp files over hand-built byte arrays (consistent with `rewrite.md` testing style).

---

## Suggested Implementation Order

```
Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4
                                      │
Phase 5 ◄─────────────────────────────┘
   │
Phase 6 ──► Phase 9 (CLI + E2E)
   │
Phase 7 (if large payloads needed)
   │
Phase 8 (when MVP hits PageFull on real DBs)
   │
Phase 10
```

**Minimum shippable slice:** Phases 1–6 + 9 on a single-leaf table fixture.

---

## Risk Register

| Risk | Mitigation |
|------|------------|
| Pager cache serves stale parsed page after write | Invalidate `pages` on `write_raw_page` |
| Re-encoding cells loses overflow layout | Test overflow roundtrip; use stored `first_overflow` when re-encoding |
| `CREATE TABLE` comma bug in parser (`Semicolon` vs `Comma`) | Fix separately if INSERT tests use in-engine CREATE |
| Page 1 header offset | Always use `buildPageFile(1)` or equivalent for page 1 writes |
| Multi-page user tables | Document MVP limit; Phase 8 before claiming full SQLite compatibility |

---

## Done Criteria (end state)

- [ ] `INSERT INTO name VALUES (...)` parses and tokenizes
- [ ] Optional column list works
- [ ] Planner produces `Plan.Insert`; CLI executes it
- [ ] New row persists in file and is visible via `SELECT`
- [ ] Rowids monotonic per table
- [ ] Tests cover tokenizer, parser, binder, and at least one E2E insert
- [ ] Plan documents known limits (single-leaf / no split) until Phase 8 complete
