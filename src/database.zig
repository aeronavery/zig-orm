const std = @import("std");
const c = @import("c.zig");
const utility = @import("utility.zig");

const Query = struct {
    fn Select(comptime M: type, comptime DbHandle: type) type {
        const MInfo = @typeInfo(M);
        comptime var model_type: type = M;
        comptime var is_array = false;
        if (MInfo == .Pointer and MInfo.Pointer.size == .Slice) {
            model_type = MInfo.Pointer.child;
            is_array = true;
        }
        if (@typeInfo(model_type) != .Struct) {
            @compileError("M must be a struct");
        }

        if (!@hasDecl(model_type, "Table")) {
            @compileError("M must have Table declaration");
        }

        if (!@hasDecl(model_type, "Allocator")) {
            @compileError("M must have Allocator declaration for Select queries");
        }

        comptime var result_type: type = if (is_array) []model_type else model_type;

        return struct {
            const Self = @This();
            pub const Model = model_type;
            pub const Result = result_type;
            const PossibleError = OrmWhere.Error || error{ None, ModelMustBeStruct, TestError };

            allocator: *std.mem.Allocator,
            db_handle: *DbHandle,
            orm_where: OrmWhere,
            err: PossibleError,

            pub fn init(allocator: *std.mem.Allocator, db: *DbHandle) Self {
                return Self{
                    .allocator = allocator,
                    .db_handle = db,
                    .orm_where = OrmWhere.init(),
                    .err = PossibleError.None,
                };
            }

            pub fn deinit(self: Self) void {
                self.orm_where.deinit();
            }

            pub fn where(self: *Self, args: var) *Self {
                if (self.err != PossibleError.None) {
                    // don't bother doing extra work if there's already an error
                    return self;
                }

                self.orm_where.parseArguments(self.allocator, args) catch |err| {
                    self.err = PossibleError.TestError;
                };
                return self;
            }

            pub fn send(self: *Self) !?Result {
                // clean itself up so the user doesn't have to create a tmp variable just to clean it up
                defer self.deinit();
                if (self.err != Self.PossibleError.None) {
                    return self.err;
                }

                var query_result = try self.db_handle.sendSelectQuery(Self, self);
                defer query_result.deinit();

                const send_type = if (is_array) std.ArrayList(Model) else Result;
                var result: send_type = undefined;
                if (is_array) {
                    result = send_type.init(self.allocator);
                }

                var rows = query_result.numberOfRows();
                var columns = query_result.numberOfColumns();

                if (rows == 0) {
                    return null;
                }

                var x: usize = 0;
                while (x < rows) : (x += 1) {
                    var y: usize = 0;
                    var tmp: Model = undefined;
                    inner: while (y < columns) : (y += 1) {
                        var opt_column_name = query_result.columnName(y);
                        if (opt_column_name) |column_name| {
                            var field_value = query_result.getValue(x, y);
                            const ModelInfo = @typeInfo(Model);
                            inline for (ModelInfo.Struct.fields) |field| {
                                if (std.mem.eql(u8, field.name, column_name)) {
                                    const field_type = @TypeOf(@field(tmp, field.name));
                                    const Info = @typeInfo(field_type);
                                    if ((Info == .Pointer and Info.Pointer.size == .Slice and Info.Pointer.child == u8) or (Info == .Array and Info.Array.child == u8)) {
                                        @field(tmp, field.name).len = 0;
                                    }
                                }
                            }

                            if (field_value) |value| {
                                inline for (ModelInfo.Struct.fields) |field| {
                                    if (std.mem.eql(u8, field.name, column_name)) {
                                        var column_type = query_result.getType(y);
                                        const field_type = @TypeOf(@field(tmp, field.name));
                                        const Info = @typeInfo(field_type);
                                        const new_value: field_type = try column_type.castValue(field_type, value);
                                        if ((Info == .Pointer and Info.Pointer.size == .Slice and Info.Pointer.child == u8) or (Info == .Array and Info.Array.child == u8)) {
                                            var heap_value = try Model.Allocator.alloc(u8, new_value.len);
                                            std.mem.copy(u8, heap_value[0..], new_value[0..]);
                                            @field(tmp, field.name) = heap_value;
                                        } else {
                                            @field(tmp, field.name) = new_value;
                                        }
                                        // Uncommenting this will crash the compiler
                                        // continue :inner;
                                    }
                                }
                            } else {
                                // if no value on this row or column then we're obviously out of columns and no point in continuing (if we would have without the break)
                                break;
                            }
                        } else {
                            // if no value on this row or column then we're obviously out of columns and no point in continuing (if we would have without the break)
                            break;
                        }
                    }
                    if (is_array) {
                        try result.append(tmp);
                    } else {
                        result = tmp;
                    }
                }

                if (is_array) {
                    return result.toOwnedSlice();
                }
                return result;
            }
        };
    }

    fn Insert(comptime M: type, comptime DbHandle: type) type {
        if (@typeInfo(M) != .Struct) {
            @compileError("M must be a struct");
        }

        if (!@hasDecl(M, "Table")) {
            @compileError("M must have Table declaration");
        }

        return struct {
            const Self = @This();

            pub const Model = M;
            pub const PossibleError = error{None};

            db_handle: *DbHandle,
            value: M,

            pub fn init(db_handle: *DbHandle, value: M) Self {
                return Self{
                    .db_handle = db_handle,
                    .value = value,
                };
            }

            pub fn send(self: *Self) !void {
                var query_result = try self.db_handle.sendInsertQuery(Self, self);
                defer query_result.deinit();
            }
        };
    }

    fn Delete(comptime M: type, comptime DbHandle: type) type {
        if (@typeInfo(M) != .Struct) {
            @compileError("M must be a struct");
        }

        if (!@hasDecl(M, "Table")) {
            @compileError("M must have Table declaration");
        }

        return struct {
            const Self = @This();
            pub const Model = M;
            pub const PossibleError = error{None};

            db_handle: *DbHandle,
            value: M,

            pub fn init(db_handle: *DbHandle, value: M) Self {
                return Self{
                    .db_handle = db_handle,
                    .value = value,
                };
            }

            pub fn send(self: *Self) !void {
                var query_result = try self.db_handle.sendDeleteQuery(Self, self);
                defer query_result.deinit();
            }
        };
    }

    fn DeleteAll(comptime M: type, comptime DbHandle: type) type {
        if (@typeInfo(M) != .Struct) {
            @compileError("M must be a struct");
        }

        if (!@hasDecl(M, "Table")) {
            @compileError("M must have Table declaration");
        }

        return struct {
            const Self = @This();
            pub const Model = M;
            pub const PossibleError = error{None};

            db_handle: *DbHandle,

            pub fn init(db_handle: *DbHandle) Self {
                return Self{
                    .db_handle = db_handle,
                };
            }

            pub fn send(self: *Self) !void {
                var query_result = try self.db_handle.sendDeleteAllQuery(Self);
                defer query_result.deinit();
            }
        };
    }
};

pub fn Database(comptime D: type) type {
    return struct {
        const Self = @This();
        pub const Driver = D;

        driver: Driver,
        allocator: *std.mem.Allocator,

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .driver = Driver.init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {}

        /// Used to clean-up the result model given by a Select query
        pub fn deinitModel(self: Self, model: var) void {
            const ModelType = @TypeOf(model);
            const ModelInfo = @typeInfo(ModelType);
            if (ModelInfo == .Pointer and ModelInfo.Pointer.size == .Slice) {
                if (@typeInfo(ModelInfo.Pointer.child) != .Struct) {
                    @compileError("Unknown Model type");
                }
                for (model) |m| {
                    const MInfo = @typeInfo(@TypeOf(m));
                    inline for (MInfo.Struct.fields) |field| {
                        // only string types are allocated
                        const Info = @typeInfo(field.field_type);
                        if ((Info == .Pointer and Info.Pointer.size == .Slice and Info.Pointer.child == u8) or (Info == .Array and Info.Array.child == u8)) {
                            if (@field(m, field.name).len > 0) {
                                ModelInfo.Pointer.child.Allocator.free(@field(m, field.name));
                            }
                        }
                    }
                }

                self.allocator.free(model);
                return;
            } else if (ModelInfo != .Struct) {
                @compileError("Unknown Model type");
                return;
            }

            inline for (ModelInfo.Struct.fields) |field| {
                // only string types are allocated
                const Info = @typeInfo(field.field_type);
                if ((Info == .Pointer and Info.Pointer.size == .Slice and Info.Pointer.child == u8) or (Info == .Array and Info.Array.child == u8)) {
                    if (@field(model, field.name).len > 0) {
                        ModelType.Allocator.free(@field(model, field.name));
                    }
                }
            }
        }

        pub fn connect(self: *Self, conn_str: []const u8) !void {
            try self.driver.connect(conn_str);
        }

        pub fn select(self: *Self, comptime T: type) Query.Select(T, Self) {
            return Query.Select(T, Self).init(self.allocator, self);
        }

        pub fn insert(self: *Self, comptime T: type, value: T) Query.Insert(T, Self) {
            return Query.Insert(T, Self).init(self, value);
        }

        pub fn delete(self: *Self, comptime T: type, value: T) Query.Delete(T, Self) {
            return Query.Delete(T, Self).init(self, value);
        }

        pub fn deleteAll(self: *Self, comptime T: type) Query.DeleteAll(T, Self) {
            return Query.DeleteAll(T, Self).init(self);
        }

        fn sendSelectQuery(self: Self, comptime SelectType: type, query: *SelectType) !Driver.Result {
            var sql = try self.driver.selectQueryToSql(SelectType, query);
            defer self.driver.free(sql);

            var db_result = try self.driver.exec(sql);

            return db_result;
        }

        fn sendInsertQuery(self: Self, comptime InsertQuery: type, query: *InsertQuery) !Driver.Result {
            var sql = try self.driver.insertQueryToSql(InsertQuery, query);
            defer self.driver.free(sql);

            var db_result = try self.driver.exec(sql);

            return db_result;
        }

        fn sendDeleteQuery(self: Self, comptime DeleteQuery: type, query: *DeleteQuery) !Driver.Result {
            var sql = try self.driver.deleteQueryToSql(DeleteQuery, query);
            defer self.driver.free(sql);

            var db_result = try self.driver.exec(sql);
            return db_result;
        }

        fn sendDeleteAllQuery(self: Self, comptime DeleteAllQuery: type) !Driver.Result {
            var sql = try self.driver.deleteAllQueryToSql(DeleteAllQuery);
            defer self.driver.free(sql);

            var db_result = try self.driver.exec(sql);
            return db_result;
        }
    };
}

pub const PqDriver = struct {
    const Self = @This();

    pub const Error = error{ ConnectionFailure, QueryFailure, NotConnected };

    // These values come from running `select oid, typname from pg_type;`
    pub const ColumnType = enum(usize) {
        Unknown = 0,
        Bool = 16,
        Char = 18,
        Int8 = 20,
        Int2 = 21,
        Int4 = 23,
        Text = 25,
        Float4 = 700,
        Float8 = 701,
        Varchar = 1043,
        Date = 1082,
        Time = 1083,
        Timestamp = 1114,

        pub fn castValue(column_type: ColumnType, comptime T: type, str: []const u8) !T {
            const Info = @typeInfo(T);
            switch (column_type) {
                .Int8, .Int4, .Int2 => {
                    if (Info == .Int or Info == .ComptimeInt) {
                        return utility.strToNum(T, str) catch return error.TypesNotCompatible;
                    }
                    return error.TypesNotCompatible;
                },
                .Float4, .Float8 => {
                    // TODO need a function similar to strToNum but can understand the decimal point
                    return error.NotImplemented;
                },
                .Bool => {
                    if (T == bool and str.len > 0) {
                        return str[0] == 't';
                    } else {
                        return error.TypesNotCompatible;
                    }
                },
                .Char, .Text, .Varchar => {
                    // FIXME Zig compiler says this cannot be done at compile time
                    // if (utility.isStringType(T)) {
                    //     return str;
                    // }
                    // Workaround
                    if ((Info == .Pointer and Info.Pointer.size == .Slice and Info.Pointer.child == u8) or (Info == .Array and Info.Array.child == u8)) {
                        return str;
                    } else if (Info == .Optional) {
                        const ChildInfo = @typeInfo(Info.Optional.child);
                        if (ChildInfo == .Pointer and ChildInfo.Pointer.Size == .Slice and ChildInfo.Pointer.child == u8) {
                            return str;
                        }
                        if (ChildInfo == .Array and ChildInfo.child == u8) {
                            return str;
                        }
                    }
                    return error.TypesNotCompatible;
                },
                .Date => {
                    return error.NotImplemented;
                },
                .Time => {
                    return error.NotImplemented;
                },
                .Timestamp => {
                    return error.NotImplemented;
                },
                else => {
                    return error.TypesNotCompatible;
                },
            }
            unreachable;
        }
    };

    pub const Result = struct {
        res: *c.PGresult,

        pub fn numberOfRows(self: Result) usize {
            return @intCast(usize, c.PQntuples(self.res));
        }

        pub fn numberOfColumns(self: Result) usize {
            return @intCast(usize, c.PQnfields(self.res));
        }

        pub fn columnName(self: Result, column_number: usize) ?[]const u8 {
            var name = @as(?[*:0]const u8, c.PQfname(self.res, @intCast(c_int, column_number)));
            if (name) |str| {
                return str[0..std.mem.len(str)];
            }
            return null;
        }

        pub fn getValue(self: Result, row_number: usize, column_number: usize) ?[]const u8 {
            var value = @as(?[*:0]const u8, c.PQgetvalue(self.res, @intCast(c_int, row_number), @intCast(c_int, column_number)));
            if (value) |str| {
                return str[0..std.mem.len(str)];
            }
            return null;
        }

        pub fn getType(self: Result, column_number: usize) PqDriver.ColumnType {
            var oid = @intCast(usize, c.PQftype(self.res, @intCast(c_int, column_number)));
            return std.meta.intToEnum(PqDriver.ColumnType, oid) catch return PqDriver.ColumnType.Unknown;
        }

        pub fn deinit(self: Result) void {
            c.PQclear(self.res);
        }
    };

    allocator: *std.mem.Allocator,
    connected: bool,
    _conn: *c.PGconn,

    pub fn init(allocator: *std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .connected = false,
            ._conn = undefined,
        };
    }

    pub fn free(self: Self, val: var) void {
        self.allocator.free(val);
    }

    pub fn connect(self: *Self, url: []const u8) !void {
        var conn_info = try std.cstr.addNullByte(self.allocator, url);
        defer self.allocator.free(conn_info);
        if (c.PQconnectdb(conn_info)) |conn| {
            self._conn = conn;
        }

        if (@enumToInt(c.PQstatus(self._conn)) != c.CONNECTION_OK) {
            return Self.Error.ConnectionFailure;
        }

        self.connected = true;
    }

    pub fn finish(self: *Self) void {
        c.PQfinish(self._conn);
    }

    pub fn exec(self: Self, query: []const u8) !Result {
        if (!self.connected) {
            return Error.NotConnected;
        }

        var cstr_query = try std.cstr.addNullByte(self.allocator, query);
        defer self.allocator.free(cstr_query);

        var res = c.PQexec(self._conn, cstr_query);

        var response_code = @enumToInt(c.PQresultStatus(res));
        if (response_code != c.PGRES_TUPLES_OK and response_code != c.PGRES_COMMAND_OK and response_code != c.PGRES_NONFATAL_ERROR) {
            var msg = @as([*:0]const u8, c.PQresultErrorMessage(res));
            std.debug.warn("{}\n", .{msg});
            c.PQclear(res);
            return Self.Error.QueryFailure;
        }

        if (res) |result| {
            return Result{ .res = result };
        } else {
            return Self.Error.QueryFailure;
        }
    }

    pub fn selectQueryToSql(self: Self, comptime QueryType: type, query: *QueryType) ![]const u8 {
        var string_builder = std.ArrayList(u8).init(self.allocator);
        defer string_builder.deinit();

        var out = string_builder.outStream();

        try out.writeAll("select ");

        const ModelInfo = @typeInfo(QueryType.Model);
        inline for (ModelInfo.Struct.fields) |field, i| {
            try out.writeAll(field.name);
            if (i + 1 < ModelInfo.Struct.fields.len) {
                try out.writeAll(",");
            }
        }
        try out.print(" from {}", .{QueryType.Model.Table});

        if (query.orm_where.arguments) |arguments| {
            try out.writeAll(" where ");

            var it = arguments.iterator();
            var i: usize = 0;
            while (it.next()) |arg| : (i += 1) {
                switch (arg.value) {
                    .String => |str| {
                        try out.print("{}='{}'", .{ arg.key, str });
                    },
                    .Other => |other| {
                        try out.print("{}={}", .{ arg.key, other });
                    },
                }
                if (i + 1 < arguments.size) {
                    try out.writeAll(" and ");
                }
            }
        }

        try out.writeAll(";");

        return string_builder.toOwnedSlice();
    }

    pub fn insertQueryToSql(self: Self, comptime QueryType: type, query: *QueryType) ![]const u8 {
        var string_builder = std.ArrayList(u8).init(self.allocator);
        defer string_builder.deinit();

        var out = string_builder.outStream();

        try out.print("insert into {} (", .{QueryType.Model.Table});

        const ModelInfo = @typeInfo(QueryType.Model);
        inline for (ModelInfo.Struct.fields) |field, i| {
            try out.writeAll(field.name);

            if (i + 1 < ModelInfo.Struct.fields.len) {
                try out.writeAll(",");
            }
        }
        try out.writeAll(") values(");

        inline for (ModelInfo.Struct.fields) |field, i| {
            var field_value = @field(query.value, field.name);

            if (utility.isString(field_value)) |str| {
                try out.print("'{}'", .{str});
            } else {
                try out.print("{}", .{field_value});
            }
            if (i + 1 < ModelInfo.Struct.fields.len) {
                try out.writeAll(",");
            }
        }

        try out.writeAll(");");

        return string_builder.toOwnedSlice();
    }

    pub fn deleteQueryToSql(self: Self, comptime QueryType: type, query: *QueryType) ![]const u8 {
        var string_builder = std.ArrayList(u8).init(self.allocator);
        defer string_builder.deinit();

        var out = string_builder.outStream();

        try out.print("delete from {} ", .{QueryType.Model.Table});

        const ModelInfo = @typeInfo(QueryType.Model);
        if (ModelInfo.Struct.fields.len > 0) {
            try out.writeAll("where ");
            inline for (ModelInfo.Struct.fields) |field, i| {
                var field_value = @field(query.value, field.name);
                try out.print("{}=", .{field.name});

                if (utility.isString(field_value)) |str| {
                    try out.print("'{}'", .{str});
                } else {
                    try out.print("{}", .{field_value});
                }

                if (i + 1 < ModelInfo.Struct.fields.len) {
                    try out.writeAll(" and ");
                }
            }
        }

        try out.writeAll(";");

        return string_builder.toOwnedSlice();
    }

    pub fn deleteAllQueryToSql(self: Self, comptime QueryType: type) ![]const u8 {
        var string_builder = std.ArrayList(u8).init(self.allocator);
        defer string_builder.deinit();

        var out = string_builder.outStream();

        try out.print("delete from {};", .{QueryType.Model.Table});

        return string_builder.toOwnedSlice();
    }
};

test "" {
    const Foo = struct {
        bar: var,
    };
    const foo = Foo{ .bar = 5 };
    std.meta.refAllDecls(Foo);

    std.meta.refAllDecls(PqDriver);
}

test "pq" {
    var pq = PqDriver.init(std.testing.allocator);
    try pq.connect("postgres://testuser:testpassword@localhost:5432/testdb");
    defer pq.finish();

    _ = try pq.exec("delete from test_table");

    _ = try pq.exec("insert into test_table (test_value) values('zig');");

    var res = try pq.exec("select * from test_table");

    var column_name = res.columnName(1).?;
    std.testing.expect(std.mem.eql(u8, column_name, "test_value"));
}

fn sanitize(value: []const u8, out: var) !void {
    // FIXME implement sanitize
    try out.writeAll(value);
}

const OrmWhere = struct {
    const Self = @This();

    const Error = error{ArgsMustBeStruct};

    const Argument = union(enum) {
        String: []const u8,
        Other: []const u8,
    };

    arguments: ?std.hash_map.StringHashMap(Argument),
    container: ?std.ArrayList(u8),

    pub fn init() Self {
        return Self{
            .arguments = null,
            .container = null,
        };
    }

    pub fn deinit(self: Self) void {
        if (self.arguments) |args| {
            args.deinit();
        }
        if (self.container) |container| {
            container.deinit();
        }
    }

    pub fn parseArguments(self: *Self, allocator: *std.mem.Allocator, args: var) !void {
        self.arguments = std.hash_map.StringHashMap(Argument).init(allocator);
        self.container = std.ArrayList(u8).init(allocator);

        const ArgsInfo = @typeInfo(@TypeOf(args));
        if (ArgsInfo != .Struct) {
            return Self.Error.ArgsMustBeStruct;
        }

        inline for (ArgsInfo.Struct.fields) |field| {
            var value = @field(args, field.name);
            const field_type = @typeInfo(@TypeOf(value));
            if (utility.isString(value)) |str| {
                if (self.container) |*container| {
                    var start = container.items.len;
                    if (start > 0) {
                        start -= 1;
                    }
                    try sanitize(str, container.outStream());

                    if (self.arguments) |*arguments| {
                        _ = try arguments.put(field.name, Argument{ .String = container.items[start..] });
                    }
                }
            } else {
                if (self.container) |*container| {
                    var start: usize = container.items.len;
                    if (start > 0) {
                        start -= 1;
                    }

                    try std.fmt.formatType(value, "", std.fmt.FormatOptions{}, container.outStream(), std.fmt.default_max_depth);

                    if (self.arguments) |*arguments| {
                        _ = try arguments.put(field.name, Argument{ .Other = container.items[start..] });
                    }
                }
            }
        }
    }
};

test "orm" {
    const UserModel = struct {
        // required declaration used by the orm
        pub const Table = "test_table";
        pub const Allocator = std.testing.allocator;

        test_value: []const u8,
        test_num: u32,
        test_bool: bool,
    };

    const PqDatabase = Database(PqDriver);
    var db = PqDatabase.init(std.testing.allocator);
    try db.connect("postgres://testuser:testpassword@localhost:5432/testdb");

    try db.deleteAll(UserModel).send();

    var new_user = UserModel{ .test_value = "foo", .test_num = 42, .test_bool = true };
    try db.insert(UserModel, new_user).send();
    try db.insert(UserModel, new_user).send();
    try db.insert(UserModel, new_user).send();

    if (try db.select(UserModel).where(.{ .test_value = "foo" }).send()) |model| {
        defer db.deinitModel(model);

        std.testing.expect(std.mem.eql(u8, model.test_value, "foo"));
        std.testing.expect(model.test_num == 42);
        std.testing.expect(model.test_bool);
    }

    if (try db.select([]UserModel).send()) |models| {
        defer db.deinitModel(models);

        std.testing.expect(models.len == 3);
        for (models) |model| {
            std.testing.expect(std.mem.eql(u8, model.test_value, "foo"));
            std.testing.expect(model.test_num == 42);
            std.testing.expect(model.test_bool);
        }
    }

    if (try db.select(UserModel).where(.{ .test_value = "none" }).send()) |undefined_model| {
        defer db.deinitModel(undefined_model);
    }

    try db.delete(UserModel, new_user).send();

    try db.deleteAll(UserModel).send();
}
