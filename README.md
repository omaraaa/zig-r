# zig-r
A zig library that provides a type to mark resources, a method to clean resources, and a resource tracker to catch any leaks.

## R
`R(T)` is a type that wraps a resource a `T`. For example, `R([]u8)` warps a slice of u8. To initialize it, call `R([]u8).init`. For example:
```zig
var r = R([]u8).init(try allocator.alloc(u8, 100), allocator, Allocator.mem.free);
```


`R(T).init` has the following signature:
```zig
//function signature of init
pub fn init(value: T, resource_manager: anytype, comptime deinit_fn: anytype) @This() {...}
```
For type `T`, `R(T).init` will take:
1. `value: T` is the resource created by the `resource_manager`
2. `resource_manager` is a pointer to the object used to create the resource
3. `deinit_fn` is a function that takes `resource_manager` and `T` as it's arguments to free the resource

`R(T)` is basically a super fat pointer, so it recommend to not pass it around to other structs. Instead, use `R(T).get` to get the wrapped resource and pass that around. 
```zig
  var r_array: []u8 = r.get();
```
Finally, you can call `R(T).deinit` manually to free the resource.
```zig
  r.deinit(); //calls allocator.free(value) internally
```

## clean

This library provides the function `clean`. This function iterates over a passed value's fields and calls any `deinit` it finds.

example:
```zig
const Foo = struct {
    data: R([]u8),
    single: R(*u64),

    pub fn init(allocator: *std.mem.Allocator) !@This() {
        var data = R([]u8).init(try allocator.alloc(u8, 10), allocator, std.mem.Allocator.free);
        errdefer clean(data);

        var data_v = data.get();
        @memset(data_v.ptr, 0, data_v.len);

        var single = R(*u64).init(try allocator.create(u64), allocator, std.mem.Allocator.destroy);
        errdefer clean(single);

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
    }
}
```

## ResourceTracker

`ResourceTraker` is a type that will track `R` resources. To track `R` resources allocations, put the following at the start of your program:
```zig
    var resource_tracker = ResourceTracker.init(std.testing.allocator);
    ResourceTracker.set(&resource_tracker);
    defer clean(resource_tracker);
```
