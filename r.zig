const std = @import("std");

const ResourceTracker = struct {
    const Self = @This();
    var instance: ?*@This() = null;

    resources: std.AutoHashMap(usize, usize),
    resources_trace: std.AutoHashMap(usize, std.builtin.StackTrace),
    resource_count: usize = 0,
    alloc: *std.mem.Allocator,

    pub fn get() ?*@This() {
        return instance;
    }

    pub fn set(rs: *ResourceTracker) void {
        instance = rs;
    }

    pub fn init(alloc: *std.mem.Allocator) @This() {
        return @This(){
            .alloc = alloc,
            .resources = std.AutoHashMap(usize, usize).init(alloc),
            .resources_trace = std.AutoHashMap(usize, std.builtin.StackTrace).init(alloc),
        };
    }

    pub fn track(self: *Self, resource: anytype) void {
        resource.index = self.resource_count;
        self.resource_count += 1;
        var trace = std.builtin.StackTrace{
            .instruction_addresses = self.alloc.alloc(u64, 32) catch unreachable,
            .index = 0,
        };
        _ = std.debug.captureStackTrace(null, &trace);
        self.resources_trace.put(resource.index, trace) catch unreachable;
    }

    pub fn untrack(self: *Self, resource: anytype) void {
        self.alloc.free(self.resources_trace.get(resource.index).?.instruction_addresses);
        _ = self.resources_trace.remove(resource.index);
    }

    pub fn deinit(self: *Self) void {
        // const stderr = std.io.getStdErr().writer();
        var iter = self.resources_trace.iterator();
        var panic = false;
        while (iter.next()) |entry| {
            if (self.resources_trace.get(entry.key_ptr.*)) |trace| {
                std.debug.print("\n!!! RESOURCE LEAK STACK TRACE BEGIN !!!\n", .{});
                std.debug.dumpStackTrace(trace);
                std.debug.print("!!! RESOURCE LEAK STACK TRACE END !!!\n", .{});
            }
            panic = true;
        }

        var values = self.resources_trace.iterator();
        while (values.next()) |v| {
            self.alloc.free(v.value_ptr.instruction_addresses);
        }
        self.resources_trace.deinit();
        self.resources.deinit();

        if (panic)
            std.debug.panic("Some resources remain allocated\n", .{});
    }
};

pub fn R(comptime T: type) type {
    return struct {
        pub const __IsResource__ = true;

        value: T,
        resource_manager: usize,
        deinit_fn: fn (usize, T) void,
        index: usize = 0,

        pub fn init(value: T, resource_manager: anytype, comptime deinit_fn: anytype) @This() {
            const RM = @TypeOf(resource_manager);
            const inner = struct {
                pub fn deinit(rm: usize, v: T) void {
                    deinit_fn(@intToPtr(RM, rm), v);
                }
            };

            var self = @This(){
                .value = value,
                .resource_manager = @ptrToInt(resource_manager),
                .deinit_fn = inner.deinit,
            };
            if (ResourceTracker.get()) |rs|
                rs.track(&self);
            return self;
        }

        pub fn get(self: *@This()) T {
            return self.value;
        }

        pub fn deinit(self: *@This()) void {
            if (ResourceTracker.get()) |rs|
                rs.untrack(self);
            self.deinit_fn(self.resource_manager, self.value);
        }
    };
}

pub fn clean(value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "deinit")) {
                //hack to avoid *const
                var v_ptr = @intToPtr(*T, @ptrToInt(&value));
                v_ptr.deinit();
            } else {
                const fields = std.meta.fields(T);
                inline for (fields) |field| {
                    clean(@field(value, field.name));
                }
            }
        },
        .Array => {
            for (value) |e| {
                clean(e);
            }
        },
        .Optional => {
            if (value) |v| {
                clean(v);
            }
        },
        .Union => |u| {
            if (u.tag_type != null) {
                var active = std.meta.activeTag(value);
                const fields = std.meta.fields(@TypeOf(value));
                inline for (fields) |f| {
                    if (std.cstr.cmp(f.name[0.. :0], @tagName(active)) == 0) {
                        clean(@field(value, f.name));
                    }
                }
            }
        },

        else => {},
    }
}

const Foo = struct {
    data: R([]u8),
    single: R(*u64),

    pub fn init(allocator: *std.mem.Allocator) !@This() {
        var data = R([]u8).init(try allocator.alloc(u8, 10), allocator, std.mem.Allocator.free);
        errdefer clean(&data);

        var data_v = data.get();
        @memset(data_v.ptr, 0, data_v.len);

        var single = R(*u64).init(try allocator.create(u64), allocator, std.mem.Allocator.destroy);
        errdefer clean(&single);

        return @This(){
            .data = data,
            .single = single,
        };
    }
};

//clean only works on tagged unions. for untagged unions, the struct should implement a deinit function
const FooU = union(enum) {
    foo: Foo,
};

const Bar = struct {
    foo: [2]?FooU = undefined, //an array of optional tagged unions, will get cleaned by clean
    array: std.ArrayList(u8), //has a deinit function that takes no parameters, will be called by clean

    pub fn init(allocator: *std.mem.Allocator) !@This() {
        return @This(){
            .foo = .{ .{ .foo = try Foo.init(allocator) }, .{ .foo = try Foo.init(allocator) } },
            .array = std.ArrayList(u8).init(allocator),
        };
    }
};

test "R" {
    var resource_tracker = ResourceTracker.init(std.testing.allocator);
    ResourceTracker.set(&resource_tracker);
    defer clean(resource_tracker);
    {
        var foo = try Foo.init(std.testing.allocator);
        defer clean(foo);

        var bar = try Bar.init(std.testing.allocator);
        defer clean(bar);
        try bar.array.append('a');

        var foo2 = try Foo.init(std.testing.allocator);
        defer clean(foo2);
    }
}
