#!/usr/bin/env python3
"""Debug: use MAGIC's drc find to get per-rule violation counts (tile-based)."""
import os, pathlib, subprocess, sys, tempfile, collections

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))

if "spout" not in sys.modules:
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "spout", str(ROOT / "python" / "__init__.py"),
        submodule_search_locations=[str(ROOT / "python")],
    )
    if spec and spec.loader:
        mod = importlib.util.module_from_spec(spec)
        sys.modules["spout"] = mod
        spec.loader.exec_module(mod)

from spout.config import SpoutConfig, SaConfig
from spout.pipeline import run_pipeline

BENCHMARKS_DIR = ROOT / "fixtures" / "benchmark"
pdk_root = os.environ.get("PDK_ROOT", "")
tech_file = pathlib.Path(pdk_root) / "sky130A" / "libs.tech" / "magic" / "sky130A.tech"

with tempfile.TemporaryDirectory() as tmp:
    netlist = BENCHMARKS_DIR / "current_mirror.spice"
    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    config = SpoutConfig(backend="klayout", pdk="sky130", sa_config=sa,
                         use_ml=False, use_gradient=False, use_repair=False)
    gds_path = str(pathlib.Path(tmp) / "test.gds")
    result = run_pipeline(str(netlist), config, output_path=gds_path)
    print(f"Spout DRC total: {result.drc_violations}")

    # Read Spout breakdown
    bf = pathlib.Path("/tmp/spout_drc_breakdown.txt")
    if bf.exists():
        print(f"\nSpout breakdown:\n{bf.read_text()}")

    # Use drc find to iterate individual errors
    tcl = f"""\
tech load {tech_file}
gds read {gds_path}
load current_mirror
select top cell
drc check
drc catchup
set cr [drc listall count]
foreach item $cr {{
    puts "TOTAL: [lindex $item 0] [lindex $item 1]"
}}
# Iterate each error using drc find
set idx 1
set found 0
while {{$idx <= 500}} {{
    set box [drc find $idx]
    if {{$box eq ""}} break
    set reasons [drc why]
    foreach reason $reasons {{
        puts "FIND: $idx | $reason"
    }}
    incr found
    incr idx
}}
puts "FOUND_TOTAL: $found"
quit
"""
    r = subprocess.run(["magic", "-dnull", "-noconsole"],
                       input=tcl, capture_output=True, text=True, timeout=120)

    # Parse results
    rule_counts = collections.Counter()
    total = 0
    found_total = 0
    for line in r.stdout.splitlines():
        if line.startswith("TOTAL:"):
            parts = line.split()
            if len(parts) >= 3:
                total = int(parts[2])
        elif line.startswith("FIND:"):
            # FIND: idx | reason
            if " | " in line:
                reason = line.split(" | ", 1)[1].strip()
                rule_counts[reason] += 1
        elif line.startswith("FOUND_TOTAL:"):
            found_total = int(line.split(":")[1].strip())

    print(f"\nMAGIC total (drc listall count): {total}")
    print(f"MAGIC found via drc find: {found_total}")
    print(f"Sum of per-rule find counts: {sum(rule_counts.values())}")
    print(f"\nPer-rule counts (from drc find):")
    for rule, count in rule_counts.most_common():
        print(f"  {count:>4}  {rule}")
