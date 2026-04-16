# Quick Start

A minimal example: place and route a differential pair.

## 1. Define the netlist

```python
from spout import Netlist, Device, Net

nl = Netlist()

# Devices
m1 = nl.add_device(Device("nmos", "M1", w=2e-6, l=180e-9))
m2 = nl.add_device(Device("nmos", "M2", w=2e-6, l=180e-9))

# Nets
inp  = nl.add_net(Net("INP"))
inm  = nl.add_net(Net("INM"))
outp = nl.add_net(Net("OUTP"))
outm = nl.add_net(Net("OUTM"))
tail = nl.add_net(Net("TAIL"))
vss  = nl.add_net(Net("VSS"))

nl.connect(m1, "gate",   inp)
nl.connect(m1, "drain",  outp)
nl.connect(m1, "source", tail)
nl.connect(m2, "gate",   inm)
nl.connect(m2, "drain",  outm)
nl.connect(m2, "source", tail)
```

## 2. Set constraints

```python
from spout import PlaceConstraints, RouteConstraints

pc = PlaceConstraints()
pc.match_pair(m1, m2)           # common-centroid placement
pc.add_guard_ring([m1, m2])     # nwell guard ring

rc = RouteConstraints()
rc.set_class(inp,  "analog")
rc.set_class(inm,  "analog")
rc.match_length(outp, outm)     # matched routing
```

## 3. Run the flow

```python
from spout import Flow
from spout.pdk import load_pdk

pdk = load_pdk("pdks/sky130.json")

flow = Flow(pdk=pdk, netlist=nl, place=pc, route=rc)
result = flow.run()

result.gds.write("diffpair.gds")
result.spice.write("diffpair.pex.spice")
```

## 4. Check results

```python
print(f"DRC violations: {len(result.drc_violations)}")
print(f"LVS: {'PASS' if result.lvs_match else 'FAIL'}")
print(f"Parasitic caps: {result.pex.summary()}")
```

> [!TIP]
> Use `flow.run(stop_after="place")` to inspect placement before routing begins.

## Next steps

- [Router Architecture](/2) Router/overview) — understand how routing decisions are made
- [Python API Reference](/4) Reference/python-api) — full API documentation
- [PDK Config](/4) Reference/pdk-config) — how to add or modify PDK definitions
