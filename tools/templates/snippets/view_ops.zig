
    // Movement ops (exercises 010-013). None of them copy any data.

    fn reshape(v: View, shape: []const usize) View {
        std.debug.assert(v.isContiguous() and product(shape) == v.numel());
        var out = View.init(shape);
        out.offset = v.offset;
        return out;
    }

    fn permute(v: View, order: []const usize) View {
        var out = v;
        for (order, 0..) |old, new| {
            out.shape[new] = v.shape[old];
            out.strides[new] = v.strides[old];
        }
        return out;
    }

    fn expand(v: View, shape: []const usize) View {
        var out = v;
        for (shape, 0..) |size, i| {
            if (v.shape[i] == size) continue;
            std.debug.assert(v.shape[i] == 1);
            out.shape[i] = size;
            out.strides[i] = 0;
        }
        return out;
    }

    fn shrink(v: View, ranges: []const [2]usize) View {
        var out = v;
        for (ranges, 0..) |r, i| {
            out.offset += int(r[0]) * v.strides[i];
            out.shape[i] = r[1] - r[0];
        }
        return out;
    }

    fn flip(v: View, axis: usize) View {
        var out = v;
        out.offset += int(v.shape[axis] - 1) * v.strides[axis];
        out.strides[axis] = -v.strides[axis];
        return out;
    }
