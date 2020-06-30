# zig-orm
**This is a work in progress. Crashes are expected to happen.**

A database ORM. Currently only supports PostgreSQL but the goal is to let other database drivers be easily written. The current PostgreSQL driver uses libpq.

# Getting Started

First, a model needs to be defined. A model requires two definitions, `Table` which denotes the table name, and `Allocator` which specifies the allocator used on a select query.

```zig
const User = struct {
    // required declarations used by the orm
    pub const Table = "test_table";
    pub const Allocator = std.testing.allocator;

    test_value: []const u8,
    test_num: u32,
    test_bool: bool,
};
```

Next, a database connection needs to be established.

```zig
const PqDatabase = Database(PqDriver);
var db = PqDatabase.init(std.testing.allocator);
try db.connect("postgres://testuser:testpassword@localhost:5432/testdb");
```

Now, we can try to insert a User.

```zig
var new_user = User{ 
  .test_value = "foo",
  .test_num = 42,
  .test_bool = true
};
try db.insert(User, new_user).send();
```

Or, we can select a User and even specify "where" conditions.

```zig
if (try db.select(User).where(.{ .test_value = "foo" }).send()) |model| {
    // required to clean up the select result
    defer db.deinitModel(model);

    std.testing.expect(std.mem.eql(u8, model.test_value, "foo"));
}
```

You can also specify the select query to return an array of models
```zig
if (try db.select([]UserModel).send()) |models| {
    // required to clean up the select result
    defer db.deinitModel(models);
}
```
