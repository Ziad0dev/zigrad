/// A direct-mapped cache: each memory line can live in exactly one slot.
const Cache = struct {
    const line_bytes = 64;
    slots: usize,
    tags: [256]?usize = @splat(null),
    misses: usize = 0,
    hits: usize = 0,

    fn access(c: *Cache, addr: usize) void {
        const line = addr / line_bytes;
        const slot = line % c.slots;
        const tag = line / c.slots;
        if (c.tags[slot] == tag) {
            c.hits += 1;
        } else {
            c.misses += 1;
            c.tags[slot] = tag; // evict whatever was there
        }
    }
};
