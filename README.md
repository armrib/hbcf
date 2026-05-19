# HBCF — Hash-Block Configuration Format

A zero-allocation Zig parser for the Hash-Block Configuration Format (HBCF). Parse configuration files with multiple APIs:

- **Streaming API** (`parse`) — Callback-based iteration, minimal overhead
- **Typed API** (`parseInto`) — Struct-driven parsing with compile-time validation
- **Comptime API** (`parseComptime`) — Embed configs at compile time
- **Allocating API** (`parseIntoAlloc`) — Support unbounded list sizes with heap allocation

## Format

HBCF uses a simple block-based syntax:

```
>block_name
key = value
another_key = foo, bar, baz

>another_block
setting = 42
```

Features:
- Comments with `#`
- Comma-separated lists
- Type coercion (bool, int, float, enum, string, slices)
- CRLF/LF line ending support

## Quick Start

### Prerequisites

- Zig 0.13.0 or later

### Building

```bash
zig build
```

### Example Usage

```zig
const hbcf = @import("hbcf");

const Config = struct {
    build: struct {
        cmd: []const u8 = "",
        jobs: u32 = 1,
    } = .{},
};

var config: Config = .{};
try hbcf.parseInto(Config, source, &config);
```

See `src/root.zig` for comprehensive examples and API documentation.

## Testing

```bash
zig build test
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
