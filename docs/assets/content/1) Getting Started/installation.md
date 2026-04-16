# Installation

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| [Zig](https://ziglang.org/download/) | 0.13+ | Main compiler |
| [Python](https://python.org) | 3.10+ | For Python bindings and scripts |
| [Bun](https://bun.sh) | 1.0+ | Docs dev server only |

## Build from source

```bash
git clone https://github.com/your-org/spout
cd spout
zig build
```

The build produces:

- `zig-out/bin/spout` — CLI
- `zig-out/lib/libspout.so` — Shared library for Python FFI

## Python bindings

```bash
pip install -e python/
```

Or use the bindings directly without installing:

```python
import sys
sys.path.insert(0, "python/")
import spout
```

## Verify

```bash
zig build test
python -c "import spout; print(spout.version())"
```

> [!NOTE]
> The test suite requires `magic` and `netgen` to be installed for DRC/LVS comparison tests. Core routing and placement tests run without them.

## Docs site (dev server)

```bash
cd docs
bun install
bun run dev
# → http://localhost:3000
```

To build static output:

```bash
bun run build
# → docs/dist/
```
