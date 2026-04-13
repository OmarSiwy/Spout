"""Command-line entry point for the Spout2 pipeline."""

from __future__ import annotations

import argparse
import logging

from .config import SpoutConfig
from .pipeline import run_pipeline


def main() -> None:
    """Command-line entry point for running the Spout2 pipeline."""
    parser = argparse.ArgumentParser(
        description="Spout2 analog layout automation pipeline"
    )
    parser.add_argument("netlist", help="Path to SPICE netlist")
    parser.add_argument(
        "-o", "--output", default="output.gds", help="Output GDSII path"
    )
    parser.add_argument(
        "-p", "--pdk", default="sky130", choices=["sky130", "gf180", "ihp130"],
        help="Process design kit",
    )
    parser.add_argument("--ml", action="store_true", help="Enable ML encode")
    parser.add_argument(
        "--moead",
        action="store_true",
        help="Use MOEA/D placement when the loaded library exposes it",
    )
    parser.add_argument(
        "--pareto",
        action="store_true",
        help="Dump Pareto front plots after MOEA/D placement",
    )
    parser.add_argument(
        "--pareto-dir",
        default=".",
        metavar="DIR",
        help="Directory to save Pareto front plots (default: current directory)",
    )
    parser.add_argument(
        "--detailed-routing",
        action="store_true",
        help="Use detailed routing when the loaded library exposes it",
    )
    parser.add_argument(
        "--gradient", action="store_true", help="Enable gradient refinement"
    )
    parser.add_argument(
        "--repair", action="store_true", help="Enable ML repair loop"
    )
    parser.add_argument(
        "--max-repair", type=int, default=5,
        help="Max repair iterations (default: 5)",
    )
    parser.add_argument("--pdk-root", default=None, help="PDK root directory")
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Verbose logging"
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    config = SpoutConfig(
        pdk=args.pdk,
        use_ml=args.ml,
        use_gradient=args.gradient,
        use_moead_placement=args.moead,
        use_detailed_routing=args.detailed_routing,
        use_repair=args.repair,
        max_repair_iterations=args.max_repair,
        pdk_root=args.pdk_root,
        dump_pareto=args.pareto,
        pareto_dir=args.pareto_dir,
    )

    result = run_pipeline(args.netlist, config, output_path=args.output)

    print(f"\n{'='*60}")
    print(f"Pipeline {'PASSED' if result.success else 'FAILED'}")
    print(f"{'='*60}")
    print(f"  GDSII:           {result.gds_path}")
    print(f"  DRC violations:  {result.drc_violations}")
    print(f"  LVS clean:       {result.lvs_clean}")
    print(f"  Devices:         {result.num_devices}")
    print(f"  Nets:            {result.num_nets}")
    print(f"  Routes:          {result.num_routes}")
    print(f"  Placement cost:  {result.placement_cost:.4f}")
    print(f"  Repair iters:    {result.repair_iterations}")
    if result.pex_parasitic_caps or result.pex_parasitic_res:
        print(f"  Parasitic caps:  {result.pex_parasitic_caps}")
        print(f"  Parasitic res:   {result.pex_parasitic_res}")
        if result.pex_assessment:
            a = result.pex_assessment
            print(f"  PEX quality:     {a.rating.upper()}"
                  f"  (R: {a.total_res_ohm:.2f} Ohm, C: {a.total_cap_ff:.3f} fF)")
            for note in a.notes:
                print(f"                   - {note}")
    else:
        print("  PEX:             no parasitics extracted")
    print(f"  Total time:      {result.timings.total:.2f}s")
    if result.error:
        print(f"  Error:           {result.error}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
