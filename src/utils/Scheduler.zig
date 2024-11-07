const std = @import("std");
const log = std.log.scoped(.scheduler);

const Deadline = @import("Deadline.zig");

const Closure = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,

    pub fn init(comptime func: anytype, ctx: anytype) Closure {
        const Ctx = @TypeOf(ctx);
        const ctx_type_info = @typeInfo(Ctx);

        if (ctx_type_info != .Pointer) @compileError("ctx must be a pointer");
        if (ctx_type_info.Pointer.size != .One) @compileError("ctx must be a single item pointer");

        const wrapper = struct {
            pub fn innerFunc(ptr: *anyopaque) void {
                @call(.always_inline, func, .{@as(Ctx, @ptrCast(@alignCast(ptr)))});
            }
        };

        return .{
            .ctx = ctx,
            .func = wrapper.innerFunc,
        };
    }

    pub fn run(self: Closure) void {
        self.func(self.ctx);
    }
};

const Job = struct {
    id: u64,
    func: ?Closure,

    at: i64,
    repeat: ?i64 = null,
};

fn compareJobs(_: void, a: Job, b: Job) std.math.Order {
    const order = std.math.order(a.at, b.at);
    if (order != .eq) {
        return order;
    } else {
        return std.math.order(a.id, b.id);
    }
}

const JobQueue = std.PriorityQueue(Job, void, compareJobs);

const Worker = struct {
    queue: JobQueue,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    running: bool = false,

    pub fn init(self: *Worker, allocator: std.mem.Allocator) void {
        self.* = .{
            .queue = JobQueue.init(allocator, {}),
        };
    }

    pub fn deinit(self: *Worker) void {
        self.stop();

        self.mutex.lock();
        defer self.mutex.unlock();

        self.queue.deinit();
    }

    pub fn isEmpty(self: *Worker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.queue.items.len == 0;
    }

    pub fn cancel(self: *Worker, job_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.queue.items) |*job| {
            if (job.id == job_id) {
                job.func = null;
            }
        }
    }

    pub fn cancelByContext(self: *Worker, ctx: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.queue.items) |*job| {
            if (job.func) |func| {
                if (func.ctx == @as(*anyopaque, ctx)) {
                    job.func = null;
                }
            }
        }
    }

    pub fn schedule(self: *Worker, job: Job) !void {
        var reschedule: bool = false;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.peek()) |first_job| {
                if (first_job.at > job.at) {
                    reschedule = true;
                }
            } else {
                reschedule = true;
            }

            try self.queue.add(job);
        }

        if (reschedule) {
            self.cond.signal();
        }
    }

    pub fn start(self: *Worker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.running == true) {
            return error.AlreadyRunning;
        }

        self.running = true;
        errdefer self.running = false;

        self.thread = try std.Thread.spawn(.{}, Worker.run, .{self});
    }

    pub fn stop(self: *Worker) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.running) {
                return;
            }

            self.running = false;
        }

        self.cond.signal();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn run(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            const ms_until_next = self.processPending();

            if (!self.running) {
                return;
            }

            if (ms_until_next) |timeout_ms| {
                const timeout_ns = @as(u64, @intCast(timeout_ms * std.time.ns_per_ms));
                self.cond.timedWait(&self.mutex, timeout_ns) catch {};
            } else {
                self.cond.wait(&self.mutex);
            }
        }
    }

    fn processPending(self: *Worker) ?i64 {
        while (true) {
            var next_job = self.queue.peek() orelse {
                return null;
            };
            const now = std.time.milliTimestamp();
            if (next_job.at > now) {
                return next_job.at - now;
            }

            if (!self.running) {
                return null;
            }

            var job: Job = undefined;
            if (next_job.repeat) |interval| {
                if (next_job.func != null) {
                    job = next_job;
                    next_job.at = std.time.milliTimestamp() + interval;
                    self.queue.update(job, next_job) catch unreachable;
                } else {
                    job = self.queue.remove();
                }
            } else {
                job = self.queue.remove();
            }

            if (job.func) |func| {
                self.mutex.unlock();
                func.run();
                self.mutex.lock();
            }
        }
    }
};

const WorkerList = std.ArrayList(Worker);

pub const Strand = struct {
    id: u64,
};

const Self = @This();

allocator: std.mem.Allocator,
workers: WorkerList,
mutex: std.Thread.Mutex = .{},
next_job_id: u64 = 0,
next_strand_id: u64 = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .workers = WorkerList.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.stop();
    self.workers.deinit();
}

pub fn stop(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.workers.items) |*worker| {
        worker.stop();
        worker.deinit();
    }
    self.workers.clearRetainingCapacity();
}

pub fn start(self: *Self, num_workers: usize) !void {
    errdefer self.stop();

    self.mutex.lock();
    defer self.mutex.unlock();

    const workers = try self.workers.addManyAsSlice(num_workers);
    for (workers) |*worker| {
        worker.init(self.allocator);
    }

    for (workers) |*worker| {
        try worker.start();
    }
}

pub fn createStrand(self: *Self) Strand {
    self.mutex.lock();
    defer self.mutex.unlock();

    const strand = Strand{ .id = self.next_strand_id };
    self.next_strand_id += 1;
    return strand;
}

pub fn isEmpty(self: *Self) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.workers.items) |*worker| {
        if (!worker.isEmpty()) {
            return false;
        }
    }
    return true;
}

pub const ScheduleOptions = struct {
    in: i64 = 0,
    repeat: ?i64 = null,
    strand: ?Strand = null,
};

pub fn cancel(self: *Self, job_id: u64) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.workers.items) |*worker| {
        worker.cancel(job_id);
    }
}

pub fn cancelByContext(self: *Self, ctx: anytype) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.workers.items) |*worker| {
        worker.cancelByContext(ctx);
    }
}

pub fn schedule(self: *Self, task: anytype, ctx: anytype, opts: ScheduleOptions) !u64 {
    self.mutex.lock();
    defer self.mutex.unlock();

    const job = Job{
        .id = self.next_job_id,
        .func = Closure.init(task, ctx),
        .at = std.time.milliTimestamp() + opts.in,
        .repeat = opts.repeat,
    };

    const strand_id = if (opts.strand) |strand| strand.id else job.id;

    if (self.workers.items.len == 0) {
        return error.NoWorkers;
    }
    const worker_idx = strand_id % self.workers.items.len;
    try self.workers.items[worker_idx].schedule(job);

    self.next_job_id += 1;
    return job.id;
}

const TestTask = struct {
    value: usize = 0,

    pub fn incr(self: *@This()) void {
        self.value += 1;
    }
};

test "scheduler" {
    var scheduler = Self.init(std.testing.allocator);
    defer scheduler.deinit();

    try scheduler.start(1);
    defer scheduler.stop();

    var task: TestTask = .{};
    const job_id = try scheduler.schedule(TestTask.incr, &task, .{ .repeat = 10 });
    std.time.sleep(std.time.us_per_ms * 100);
    scheduler.cancel(job_id);

    try std.testing.expect(task.value > 0);
}