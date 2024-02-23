const Schema = @This();

const std = @import("std");
const assert = std.debug.assert;
const Diagnostic = @import("Diagnostic.zig");
const Ast = @import("Ast.zig");
const Node = Ast.Node;

const log = std.log.scoped(.schema);

root: Rule,
literals: std.StringHashMapUnmanaged(struct { comment: u32, name: u32 }) = .{},
structs: std.StringArrayHashMapUnmanaged(StructRule) = .{},

pub const StructRule = struct {
    comment: u32,
    name: u32,
    fields: std.StringArrayHashMapUnmanaged(Field) = .{},

    pub const Field = struct {
        comment: u32,
        name: u32,
        rule: Rule,
    };
};

pub const Rule = struct {
    // index into nodes
    node: u32,
};

/// Nodes are usually `ast.nodes.toOwnedSlice()` and `diagnostic` can also be reused
/// from AST parsing.
pub fn init(
    gpa: std.mem.Allocator,
    nodes: []const Node,
    code: [:0]const u8,
    diagnostic: ?*Diagnostic,
) !Schema {
    var names = std.ArrayList(u32).init(gpa);
    defer names.deinit();

    const root_expr = nodes[1];
    assert(root_expr.last_child_id != 0);

    var schema: Schema = .{
        .root = .{ .node = root_expr.last_child_id },
    };
    errdefer schema.deinit(gpa);

    var idx = root_expr.next_id;
    while (idx != 0) {
        const literal = nodes[idx];
        if (literal.tag == .@"struct") {
            break;
        }

        var comment_id = literal.first_child_id;
        if (nodes[comment_id].tag != .doc_comment) {
            comment_id = 0;
        }
        const name_id = literal.last_child_id;
        assert(nodes[name_id].tag == .identifier);
        log.debug("literal '{s}'", .{nodes[name_id].loc.src(code)});

        const gop = try schema.literals.getOrPut(gpa, nodes[name_id].loc.src(code));
        if (gop.found_existing) {
            if (diagnostic) |d| {
                d.tok = .{
                    .tag = .identifier,
                    .loc = nodes[name_id].loc,
                };
                d.err = .{
                    .duplicate_field = .{
                        .first_loc = nodes[gop.value_ptr.name].loc,
                    },
                };
            }
            return error.DuplicateField;
        }
        gop.value_ptr.* = .{ .comment = comment_id, .name = name_id };
        idx = literal.next_id;
    }

    while (idx != 0) {
        const struct_def = nodes[idx];
        assert(struct_def.tag == .@"struct");

        var child_idx = struct_def.first_child_id;
        assert(child_idx != 0);

        var struct_comment_id: u32 = 0;
        if (nodes[child_idx].tag == .doc_comment) {
            struct_comment_id = child_idx;
            child_idx = nodes[child_idx].next_id;
        }

        const struct_name_id = child_idx;
        const struct_name = nodes[child_idx];
        child_idx = struct_name.next_id;

        log.debug("struct '{s}'", .{struct_name.loc.src(code)});

        var fields: std.StringArrayHashMapUnmanaged(StructRule.Field) = .{};
        while (child_idx != 0) {
            const f = nodes[child_idx];
            assert(f.tag == .struct_field);
            var field_child_id = f.first_child_id;
            var comment_id: u32 = 0;
            if (nodes[field_child_id].tag == .doc_comment) {
                comment_id = field_child_id;
                field_child_id = nodes[field_child_id].next_id;
            }

            const name_id = field_child_id;
            assert(nodes[name_id].tag == .identifier);
            const rule_id = nodes[name_id].next_id;
            assert(rule_id != 0);

            const gop = try fields.getOrPut(gpa, nodes[name_id].loc.src(code));
            if (gop.found_existing) {
                if (diagnostic) |d| {
                    d.tok = .{
                        .tag = .identifier,
                        .loc = nodes[name_id].loc,
                    };
                    d.err = .{
                        .duplicate_field = .{
                            .first_loc = nodes[gop.value_ptr.name].loc,
                        },
                    };
                }
                return error.DuplicateField;
            }
            gop.value_ptr.* = .{
                .comment = comment_id,
                .name = name_id,
                .rule = .{ .node = rule_id },
            };
            child_idx = f.next_id;
        }

        const gop = try schema.structs.getOrPut(gpa, struct_name.loc.src(code));
        if (gop.found_existing) {
            if (diagnostic) |d| {
                d.tok = .{
                    .tag = .identifier,
                    .loc = struct_name.loc,
                };
                d.err = .{
                    .duplicate_field = .{
                        .first_loc = nodes[gop.value_ptr.name].loc,
                    },
                };
            }
            return error.DuplicateField;
        }
        gop.value_ptr.* = .{
            .comment = struct_comment_id,
            .name = struct_name_id,
            .fields = fields,
        };

        idx = struct_def.next_id;
    }

    // Analysis
    log.debug("beginning analysis", .{});
    try schema.analyzeRule(gpa, schema.root, nodes, code, diagnostic);
    log.debug("root_rule analized", .{});
    for (schema.structs.keys(), schema.structs.values()) |s_name, s| {
        for (s.fields.keys(), s.fields.values()) |f_name, f| {
            log.debug("analyzeRule '{s}.{s}'", .{ s_name, f_name });
            try schema.analyzeRule(gpa, f.rule, nodes, code, diagnostic);
        }
    }

    return schema;
}

pub fn deinit(self: *Schema, gpa: std.mem.Allocator) void {
    self.literals.deinit(gpa);
    for (self.structs.values()) |*v| v.fields.deinit(gpa);
    self.structs.deinit(gpa);
}

fn analyzeRule(
    schema: Schema,
    gpa: std.mem.Allocator,
    rule: Rule,
    nodes: []const Node,
    code: [:0]const u8,
    diagnostic: ?*Diagnostic,
) !void {
    var node = nodes[rule.node];
    while (true) {
        const sel = node.loc.getSelection(code);
        log.debug("analyzing rule '{s}', line: {}, col: {}", .{
            node.loc.src(code),
            sel.start.line,
            sel.start.col,
        });
        switch (node.tag) {
            .bytes, .int, .float, .bool, .any => break,
            .map, .array => node = nodes[node.first_child_id],
            .tag => {
                const src = node.loc.src(code);
                if (!schema.literals.contains(src[1..])) {
                    if (diagnostic) |d| {
                        d.tok = .{
                            .tag = .identifier,
                            .loc = node.loc,
                        };
                        d.err = .unknown_field;
                    }
                    return error.UnknownField;
                }
                break;
            },
            .identifier => {
                const src = node.loc.src(code);
                if (!schema.structs.contains(src)) {
                    if (diagnostic) |d| {
                        d.tok = .{
                            .tag = .identifier,
                            .loc = node.loc,
                        };
                        d.err = .unknown_field;
                    }
                    return error.UnknownField;
                }
                break;
            },
            .struct_union => {
                var idx = node.first_child_id;
                assert(idx != 0);
                var seen_names = std.StringHashMap(u32).init(gpa);
                defer seen_names.deinit();

                while (idx != 0) {
                    const ident = nodes[idx];
                    const src = ident.loc.src(code);
                    const gop = try seen_names.getOrPut(src);
                    if (gop.found_existing) {
                        if (diagnostic) |d| {
                            d.tok = .{
                                .tag = .identifier,
                                .loc = ident.loc,
                            };
                            d.err = .{
                                .duplicate_field = .{
                                    .first_loc = nodes[gop.value_ptr.*].loc,
                                },
                            };
                        }
                        return error.DuplicateField;
                    }
                    gop.value_ptr.* = idx;

                    if (!schema.structs.contains(src)) {
                        if (diagnostic) |d| {
                            d.tok = .{
                                .tag = .identifier,
                                .loc = ident.loc,
                            };
                            d.err = .unknown_field;
                        }
                        return error.UnknownField;
                    }
                    idx = ident.next_id;
                }
                break;
            },

            else => unreachable,
        }
    }
}

test "basics" {
    const case =
        \\root = Frontmatter
        \\
        \\/// Doc comment 1a
        \\/// Doc comment 1b
        \\@date,
        \\
        \\/// Doc comment 2a
        \\/// Doc comment 2b
        \\struct Frontmatter {
        \\    /// Doc comment 3a
        \\    /// Doc comment 3b
        \\    title: bytes,
        \\    date: @date,
        \\    custom: map[any],
        \\}
        \\
    ;

    var diag: Diagnostic = .{ .path = null };
    errdefer std.debug.print("diag: {}", .{diag});
    const ast = try Ast.init(std.testing.allocator, case, &diag);
    defer ast.deinit();

    try std.testing.expect(diag.err == .none);

    var schema = try Schema.init(std.testing.allocator, ast.nodes.items, case, &diag);
    schema.deinit(std.testing.allocator);
}