pub const InsertStatement = struct {
    table: []const u8,
    columns: ?[]const []const u8,
    values: []Literal,
};

/// As the name suggests, represents an actual value written in the source code
/// i.e. SQL such as the integer 3 or the text "hello"
pub const Literal = union(enum) {
    Null,
    Integer: i64,
    String: []const u8,
};
