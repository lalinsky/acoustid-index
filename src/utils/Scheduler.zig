const std = @import("std");

const Priority = enum(u8) {
    high = 0,
    medium = 1,
    low = 2,
    do_not_run = 3,
};

const TaskStatus = struct {
    reschedule: usize = 0,
    scheduled: bool = false,
    done: std.Thread.ResetEvent = .{},
    priority: Priority,
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

const Queue = std.DoublyLinkedList(TaskStatus);
pub const Task = *Queue.Node;

const Self = @This();

allocator: std.mem.Allocator,
threads: std.ArrayListUnmanaged(std.Thread) = .{},

queue: Queue = .{},
queue_not_empty: std.Thread.Condition = .{},
queue_mutex: std.Thread.Mutex = .{},
stopping: bool = false,

num_tasks: usize = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.stop();
    self.threads.deinit(self.allocator);

    std.debug.assert(self.num_tasks == 0);
}

pub fn createTask(self: *Self, priority: Priority, func: anytype, ctx: anytype) !Task {
    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();

    const task = try self.allocator.create(Queue.Node);
    errdefer self.allocator.destroy(task);

    const Wrapper = struct {
        pub fn run(c: *anyopaque) void {
            @call(.auto, func, .{@as(@TypeOf(ctx), @ptrCast(@alignCast(c)))});
        }
    };

    task.* = .{
        .data = .{
            .priority = priority,
            .ctx = ctx,
            .func = Wrapper.run,
        },
    };
    task.data.done.set();

    self.num_tasks += 1;

    return task;
}

pub fn destroyTask(self: *Self, task: Task) void {
    self.queue_mutex.lock();
    if (task.data.scheduled) {
        self.queue.remove(task);
    }
    self.queue_mutex.unlock();

    task.data.done.wait();

    self.allocator.destroy(task);

    std.debug.assert(self.num_tasks > 0);
    self.num_tasks -= 1;
}

pub fn scheduleTask(self: *Self, task: Task) void {
    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();

    if (task.data.scheduled) {
        task.data.reschedule += 1;
        return;
    }

    self.addToQueue(task);
}

fn addToQueue(self: *Self, task: *Queue.Node) void {
    task.data.scheduled = true;
    self.queue.prepend(task);
    self.queue_not_empty.signal();
}

fn getTaskToRun(self: *Self) ?*Queue.Node {
    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();

    while (!self.stopping) {
        const task = self.queue.popFirst() orelse {
            self.queue_not_empty.timedWait(&self.queue_mutex, std.time.us_per_min) catch {};
            continue;
        };
        task.prev = null;
        task.next = null;
        task.data.done.reset();
        return task;
    }
    return null;
}

fn markAsDone(self: *Self, task: *Queue.Node) void {
    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();

    if (task.data.reschedule > 0) {
        task.data.reschedule -= 1;
        self.addToQueue(task);
    } else {
        task.data.scheduled = false;
    }

    task.data.done.set();
}

fn workerThreadFunc(self: *Self) void {
    while (true) {
        const task = self.getTaskToRun() orelse break;
        defer self.markAsDone(task);

        task.data.func(task.data.ctx);
    }
}

pub fn start(self: *Self, thread_count: usize) !void {
    errdefer self.stop();

    self.queue_mutex.lock();
    defer self.queue_mutex.unlock();

    self.stopping = false;

    try self.threads.ensureUnusedCapacity(self.allocator, thread_count);
    for (0..thread_count) |_| {
        const thread = try std.Thread.spawn(.{}, workerThreadFunc, .{self});
        self.threads.appendAssumeCapacity(thread);
    }
}

pub fn stop(self: *Self) void {
    {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        self.stopping = true;
        self.queue_not_empty.broadcast();
    }

    for (self.threads.items) |*thread| {
        thread.join();
    }
    self.threads.clearRetainingCapacity();
}

test "Scheduler: smoke test" {
    var scheduler = Self.init(std.testing.allocator);
    defer scheduler.deinit();

    const Counter = struct {
        count: usize = 0,

        fn incr(self: *@This()) void {
            self.count += 1;
        }
    };
    var counter: Counter = .{};

    const task = try scheduler.createTask(.high, Counter.incr, &counter);
    defer scheduler.destroyTask(task);

    for (0..3) |_| {
        scheduler.scheduleTask(task);
    }

    try scheduler.start(2);
    std.time.sleep(std.time.us_per_s);
    scheduler.stop();

    try std.testing.expect(counter.count == 3);
}