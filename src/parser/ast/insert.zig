pub const InsertStatement = struct {
    table: []const u8,
    columns: ?[]const []const u8,
    values: []Literal,
};

pub const Literal = union(enum) {
    Null,
    Integer: i64,
    String: []const u8,
};
