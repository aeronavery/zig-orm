const std = @import("std");

// utility for checking if a value is a string. follows optionals and pointers. if string then returns the string value
pub fn isString(value: var) ?[]const u8 {
    const Info = @typeInfo(@TypeOf(value));
    switch (Info) {
        .Pointer => |p| {
            if (p.size == .Slice and p.child == u8) {
                return value;
            } else {
                return isString(value.*);
            }
        },
        .Array => |arr| {
            if (arr.child == u8) {
                return value[0..];
            }
        },
        .Optional => |opt| {
            if (value) |val| {
                return isString(val);
            } else {
                return null;
            }
        },
        else => {
            return null;
        },
    }
    return null;
}

test "isString" {
    std.testing.expect(isString("hi") != null);
}

pub fn isStringType(comptime T: type) bool {
    const Info = @typeInfo(T);
    return switch (Info) {
        .Pointer => |p| p.size == .Slice and p.child == u8,
        .Array => |arr| arr.child == u8,
        .Optional => |opt| isStringType(opt.child),
        else => false,
    };
}

test "isStringType" {
    std.testing.expect(isStringType([]const u8));
    std.testing.expect(isStringType([]u8));
    std.testing.expect(isStringType([4]u8));
    std.testing.expect(isStringType(?[]const u8));

    std.testing.expect(!isStringType(u8));
    std.testing.expect(!isStringType([]u32));
}

pub fn isInteger(comptime T: type) bool {
    comptime {
        const Info = @typeInfo(T);
        if (Info == .Int or Info == .ComptimeInt) {
            return true;
        }
        return false;
    }
}

pub fn isFloat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Float, .ComptimeFloat => true,
        else => false,
    };
}

// converts any string into the Pascal-Kebab-Case that http headers use
pub fn toPascalKebabCase(str: []u8) void {
    var i: usize = 0;
    var uppercase = true;
    while (i < str.len) : (i += 1) {
        if (uppercase) {
            str[i] = std.ascii.toUpper(str[i]);
            uppercase = false;
        } else if (str[i] == '-') {
            uppercase = true;
        } else {
            str[i] = std.ascii.toLower(str[i]);
        }
    }
}

const StrToNumError = error{ CannotBeLessThanZero, OverflowOrUnderflow, InvalidCharacter };

pub fn strToNum(comptime T: type, str: []const u8) StrToNumError!T {
    var result: T = 0;
    var negate: usize = 0;
    if (str.len > 0 and str[0] == '-') {
        if (std.math.minInt(T) == 0) {
            return error.CannotBeLessThanZero;
        } else {
            negate = 1;
        }
    }
    for (str[negate..]) |c| {
        if (@mulWithOverflow(T, result, 10, &result)) {
            return error.OverflowOrUnderflow;
        }
        var char: u8 = c - 48;
        if (char < 0 or char > 9) {
            return error.InvalidCharacter;
        }
        if (char > std.math.maxInt(T)) {
            return error.OverflowOrUnderflow;
        }
        if (@addWithOverflow(T, result, @intCast(T, char), &result)) {
            return error.OverflowOrUnderflow;
        }
    }
    if (negate > 0) {
        if (std.math.minInt(T) < 0) {
            if (@mulWithOverflow(T, result, -1, &result)) {
                return error.OverflowOrUnderflow;
            }
        }
    }
    return result;
}

test "strToNum" {
    var num = try strToNum(i32, "500");
    std.testing.expect(num == 500);

    overflow: {
        var overflow = strToNum(i8, "500") catch break :overflow;
        unreachable;
    }

    var neg = try strToNum(i32, "-500");
    std.testing.expect(neg == -500);

    underflow: {
        var underflow = strToNum(u8, "-42") catch break :underflow;
        unreachable;
    }
}
