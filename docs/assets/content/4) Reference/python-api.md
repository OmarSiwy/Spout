# Python API Reference

All public API is exposed via `python/` and accessible after `import spout`.

## `spout.Netlist`

```python
nl = spout.Netlist()
nl.add_device(device: Device) -> DeviceRef
nl.add_net(net: Net) -> NetRef
nl.connect(device: DeviceRef, pin: str, net: NetRef)
```

## `spout.Device`

```python
Device(
    kind: str,       # "nmos" | "pmos" | "res" | "cap" | ...
    name: str,
    **params         # w, l, nf, m, ...
)
```

## `spout.Net`

```python
Net(name: str, net_class: str = "signal")
# net_class: "signal" | "power" | "analog" | "matched" | "clock"
```

## `spout.PlaceConstraints`

```python
pc = PlaceConstraints()
pc.match_pair(a: DeviceRef, b: DeviceRef)
pc.add_guard_ring(devices: list[DeviceRef], ring_type: str = "nwell")
pc.near(a: DeviceRef, b: DeviceRef, max_um: float = 10.0)
pc.fix(device: DeviceRef, x: float, y: float)
pc.align_row(devices: list[DeviceRef])
pc.symmetry_axis(devices: list[DeviceRef], axis: str = "x")
```

## `spout.RouteConstraints`

```python
rc = RouteConstraints()
rc.set_class(net: NetRef, cls: str)
rc.match_length(a: NetRef, b: NetRef)
rc.shield(net: NetRef, shield_net: NetRef = None)  # None → auto VSS
rc.min_width(net: NetRef, width_um: float)
```

## `spout.Flow`

```python
flow = Flow(pdk, netlist, place=None, route=None)
result = flow.run(stop_after: str = None)
# stop_after: "place" | "route" | "drc" | "pex"
```

## `spout.FlowResult`

```python
result.gds            # GDSLayout object — call .write(path)
result.spice          # SPICENetlist object — call .write(path)
result.drc_violations # list[DRCViolation]
result.lvs_match      # bool
result.pex            # PEXResult object
```

## `spout.pdk.load_pdk`

```python
from spout.pdk import load_pdk
pdk = load_pdk("pdks/sky130.json")
```

> [!NOTE]
> All length/width parameters are in **metres** (SI). Use `1e-6` for microns, `180e-9` for 180 nm.
