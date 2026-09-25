//
// ─── Exercise 106: command queues and signals ──────────────────────────
//
// Chapter 20: down to the metal. When tinygrad "runs" a kernel on a GPU,
// the CPU doesn't wait for it. It writes a command into a *queue* in
// memory the GPU reads, and moves on. The GPU works through its queue in
// order, on its own time.
//
// So how does the CPU know when results are ready? A *timeline signal*:
// a counter in memory that only goes up. Every command gets the next
// value, and the GPU writes that value to the signal when it finishes
// the command. "Wait until signal >= 5" means "wait until command 5 and
// everything before it is done". (tinygrad's HCQ layer, "hardware command
// queues", talks to AMD and NVIDIA GPUs at exactly this level, with no
// vendor runtime in between.)
//
// Queues can depend on each other: a GPU has separate copy and compute
// engines, and the compute queue can be told "don't start this kernel
// until the copy queue's signal reaches 3".
//
// The simulation: tick() is the GPU doing one command.
//
// YOUR TASK: finish submit(), tick()'s dependency check, and wait().
//
const std = @import("std");

const Command = struct {
    name: []const u8,
    /// Don't start until `after_queue`'s signal reaches `after_value`.
    after_queue: ?*const Queue = null,
    after_value: u64 = 0,
    value: u64 = 0, // the signal value this command will set
};

const Queue = struct {
    commands: [16]Command = undefined,
    submitted: usize = 0,
    next: usize = 0, //      the next command the GPU will run
    signal: u64 = 0, //      written by the "GPU"
    last_value: u64 = 0,

    /// CPU side: queue a command, get back the signal value that marks it done.
    fn submit(q: *Queue, cmd: Command) u64 {
        ⟪q.last_value += 1;|||???;⟫
        var c = cmd;
        c.value = ⟪q.last_value|||???⟫;
        q.commands[q.submitted] = c;
        q.submitted += 1;
        return c.value;
    }

    /// GPU side: run one command, if there is one and it's allowed to start.
    fn tick(q: *Queue) bool {
        if (q.next == q.submitted) return false;
        const c = q.commands[q.next];
        if (c.after_queue) |other| {
            if (⟪other.signal < c.after_value|||???⟫) return false; // blocked
        }
        q.signal = c.value; // done
        q.next += 1;
        return true;
    }

    /// CPU side: block until the signal reaches `value`. Here, that means
    /// letting the GPU work.
    fn wait(q: *Queue, value: u64) void {
        while (⟪q.signal < value|||???⟫) {
            if (!q.tick()) @panic("deadlock: waiting on work that can't run");
        }
    }
};

test "submitting doesn't wait" {
    var q: Queue = .{};
    _ = q.submit(.{ .name = "matmul" });
    _ = q.submit(.{ .name = "relu" });
    const last = q.submit(.{ .name = "sum" });
    try std.testing.expectEqual(3, last);
    try std.testing.expectEqual(0, q.signal); // the CPU is already free, nothing ran yet

    q.wait(2);
    try std.testing.expectEqual(2, q.signal); // matmul and relu are done...
    try std.testing.expectEqual(2, q.next); //   ...sum is still queued
}

test "compute waits for the copy" {
    var copy: Queue = .{};
    var compute: Queue = .{};
    const copied = copy.submit(.{ .name = "copy weights to GPU" });
    _ = compute.submit(.{ .name = "kernel", .after_queue = &copy, .after_value = copied });

    try std.testing.expect(!compute.tick()); // blocked: the data isn't there yet
    try std.testing.expect(copy.tick());
    try std.testing.expect(compute.tick()); // now it can go
    try std.testing.expectEqual(1, compute.signal);
}
