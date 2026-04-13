"""Generate a layout SPICE netlist from Spout's routed connectivity.

After Spout routes a circuit, this module extracts the physical connectivity
(which pins are actually connected through metal) and writes a SPICE netlist
representing the layout.  This layout SPICE can then be fed to NETGEN alongside
the schematic SPICE for LVS comparison.
"""
from __future__ import annotations

import re
from collections import defaultdict
from pathlib import Path

import numpy as np


# TerminalType enum values (must match src/core/types.zig)
_GATE = 0
_DRAIN = 1
_SOURCE = 2
_BODY = 3

# MOSFET SPICE line order: Mname drain gate source body model ...
# Maps SPICE position (0-based after device name) to TerminalType.
_MOSFET_SPICE_POS_TO_TERMINAL = [_DRAIN, _GATE, _SOURCE, _BODY]


def parse_spice_subckt(path: Path) -> dict:
    """Parse a SPICE netlist to extract subcircuit structure.

    Returns a dict with:
      name      — subcircuit name (str)
      ports     — ordered port names (list[str])
      globals   — global net declarations (list[str])
      devices   — per-device dicts with keys: name, prefix, nets, model, params_str
    """
    globals_: list[str] = []
    subckt_name = ""
    ports: list[str] = []
    devices: list[dict] = []

    with open(path) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("*"):
                continue

            low = stripped.lower()
            if low.startswith(".global"):
                globals_.extend(stripped.split()[1:])
            elif low.startswith(".subckt"):
                parts = stripped.split()
                subckt_name = parts[1]
                ports = parts[2:]
            elif low.startswith(".ends"):
                pass
            elif not low.startswith("."):
                parts = stripped.split()
                name = parts[0]
                prefix = name[0].upper()

                if prefix == "M":
                    # MOSFET: Mname drain gate source body model [params...]
                    nets = parts[1:5]
                    model = parts[5] if len(parts) > 5 else ""
                    params_str = " ".join(parts[6:])
                elif prefix in ("R", "C"):
                    nets = parts[1:3]
                    model = parts[3] if len(parts) > 3 else ""
                    params_str = " ".join(parts[4:])
                elif prefix == "X":
                    # Subcircuit instance: Xname n1 n2 ... subckt_name [params]
                    # Last non-param token is the subcircuit name
                    param_start = len(parts)
                    for idx in range(2, len(parts)):
                        if "=" in parts[idx]:
                            param_start = idx
                            break
                    nets = parts[1 : param_start - 1]
                    model = parts[param_start - 1] if param_start > 1 else ""
                    params_str = " ".join(parts[param_start:])
                else:
                    nets = parts[1:]
                    model = ""
                    params_str = ""

                devices.append(
                    {
                        "name": name,
                        "prefix": prefix,
                        "nets": nets,
                        "model": model,
                        "params_str": params_str,
                    }
                )

    return {
        "name": subckt_name,
        "ports": ports,
        "globals": globals_,
        "devices": devices,
    }


def generate_layout_spice(
    schematic_path: Path,
    pin_device: np.ndarray,
    pin_terminal: np.ndarray,
    connectivity: np.ndarray,
    output_path: Path,
) -> Path:
    """Generate a layout SPICE netlist from route connectivity.

    Parameters
    ----------
    schematic_path
        Path to the schematic SPICE file (``*_lvs.spice``).
    pin_device
        Per-pin device index — shape ``(P,)``, uint32.
    pin_terminal
        Per-pin terminal type — shape ``(P,)``, uint8.
    connectivity
        Per-pin connected-component IDs — shape ``(P,)``, uint32.
        Pins with the same value are electrically connected in the layout.
    output_path
        Where to write the layout SPICE file.

    Returns
    -------
    Path
        The *output_path* (for convenience).
    """
    parsed = parse_spice_subckt(schematic_path)
    port_set = set(parsed["ports"])

    # Build device → {terminal_type → pin_index} mapping.
    dev_term_pin: dict[int, dict[int, int]] = defaultdict(dict)
    for pi in range(len(pin_device)):
        dev_term_pin[int(pin_device[pi])][int(pin_terminal[pi])] = pi

    # For each pin, determine its schematic net name from the parsed devices.
    # pin_schematic_net[pi] = net name string
    pin_schematic_net: dict[int, str] = {}
    for dev_idx, dev in enumerate(parsed["devices"]):
        if dev["prefix"] == "M":
            for spice_pos in range(min(4, len(dev["nets"]))):
                term_type = _MOSFET_SPICE_POS_TO_TERMINAL[spice_pos]
                pi = dev_term_pin.get(dev_idx, {}).get(term_type)
                if pi is not None:
                    pin_schematic_net[pi] = dev["nets"][spice_pos]
        else:
            # For non-MOSFET devices, map positionally.
            term_map = dev_term_pin.get(dev_idx, {})
            for term_type, pi in term_map.items():
                # Best-effort: use net at terminal index if available
                if term_type < len(dev["nets"]):
                    pin_schematic_net[pi] = dev["nets"][term_type]

    # Group pins by connected component.
    comp_pins: dict[int, list[int]] = defaultdict(list)
    for pi in range(len(connectivity)):
        comp_pins[int(connectivity[pi])].append(pi)

    # Assign a canonical net name to each component.
    comp_name: dict[int, str] = {}
    # Track how many components each schematic net appears in (for open detection).
    net_comp_ids: dict[str, list[int]] = defaultdict(list)

    for comp_id, pins in comp_pins.items():
        net_names_in_comp: list[str] = []
        for pi in pins:
            n = pin_schematic_net.get(pi)
            if n and n not in net_names_in_comp:
                net_names_in_comp.append(n)
        for n in net_names_in_comp:
            net_comp_ids[n].append(comp_id)

    # Pick canonical name: prefer port names, then first encountered.
    net_comp_counter: dict[str, int] = defaultdict(int)
    for comp_id, pins in comp_pins.items():
        net_names_in_comp: list[str] = []
        for pi in pins:
            n = pin_schematic_net.get(pi)
            if n and n not in net_names_in_comp:
                net_names_in_comp.append(n)

        if not net_names_in_comp:
            comp_name[comp_id] = f"__unconnected_{comp_id}"
            continue

        # Prefer port net, then first name.
        best = net_names_in_comp[0]
        for n in net_names_in_comp:
            if n in port_set:
                best = n
                break

        # Disambiguate opens: if this net spans multiple components.
        if len(net_comp_ids[best]) > 1:
            idx = net_comp_counter[best]
            net_comp_counter[best] += 1
            if idx > 0:
                best = f"{best}_open{idx}"

        comp_name[comp_id] = best

    # Build per-pin layout net name.
    pin_layout_net: dict[int, str] = {}
    for pi in range(len(connectivity)):
        pin_layout_net[pi] = comp_name.get(int(connectivity[pi]), f"__unk_{pi}")

    # Write the layout SPICE.
    with open(output_path, "w") as f:
        f.write(f"* Layout netlist extracted from Spout route connectivity\n")
        for g in parsed["globals"]:
            f.write(f".global {g}\n")
        f.write(f".subckt {parsed['name']} {' '.join(parsed['ports'])}\n")

        for dev_idx, dev in enumerate(parsed["devices"]):
            if dev["prefix"] == "M":
                layout_nets = []
                for spice_pos in range(4):
                    term_type = _MOSFET_SPICE_POS_TO_TERMINAL[spice_pos]
                    pi = dev_term_pin.get(dev_idx, {}).get(term_type)
                    if pi is not None:
                        layout_nets.append(pin_layout_net[pi])
                    else:
                        layout_nets.append(dev["nets"][spice_pos])
                line = f"{dev['name']} {' '.join(layout_nets)} {dev['model']}"
            else:
                # Non-MOSFET: substitute nets where possible.
                layout_nets = list(dev["nets"])
                term_map = dev_term_pin.get(dev_idx, {})
                for term_type, pi in term_map.items():
                    if term_type < len(layout_nets):
                        layout_nets[term_type] = pin_layout_net[pi]
                line = f"{dev['name']} {' '.join(layout_nets)} {dev['model']}"

            if dev["params_str"]:
                line += f" {dev['params_str']}"
            f.write(f"{line}\n")

        f.write(f".ends {parsed['name']}\n")

    return output_path
