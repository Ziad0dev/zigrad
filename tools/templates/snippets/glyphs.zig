// ─── The dataset: noisy 8x8 digits ───
//
// Ten 5x7 digit shapes, placed at a random position on an 8x8 canvas,
// with Gaussian noise (060) on every pixel. A tiny stand-in for MNIST.

const glyph_rows = [10][7]*const [5]u8{
    .{ " ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### " },
    .{ "  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### " },
    .{ " ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####" },
    .{ "#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### " },
    .{ "   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # " },
    .{ "#####", "#    ", "#### ", "    #", "    #", "#   #", " ### " },
    .{ "  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### " },
    .{ "#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   " },
    .{ " ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### " },
    .{ " ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  " },
};

const pixels = 64; // 8 x 8
const classes = 10;

fn makeExample(rand: std.Random, class: usize, out: []f64) void {
    const dx = rand.uintLessThan(usize, 4); // 8 - 5 + 1 positions
    const dy = rand.uintLessThan(usize, 2); // 8 - 7 + 1 positions
    for (0..8) |y| {
        for (0..8) |x| {
            var on = false;
            if (y >= dy and y < dy + 7 and x >= dx and x < dx + 5) on = glyph_rows[class][y - dy][x - dx] == '#';
            out[y * 8 + x] = (if (on) @as(f64, 1) else 0) + 0.25 * rand.floatNorm(f64);
        }
    }
}

/// n examples with random classes. xs is [n, 64], ys is [n].
fn makeDataset(rand: std.Random, xs: []f64, ys: []usize) void {
    for (ys, 0..) |*y, i| {
        y.* = rand.uintLessThan(usize, classes);
        makeExample(rand, y.*, xs[i * pixels ..][0..pixels]);
    }
}
