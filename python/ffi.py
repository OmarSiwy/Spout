"""
Spout2 FFI — ctypes bindings to libspout.so.

Every exported C-ABI function from ``src/lib.zig`` is declared here with
full ``argtypes`` / ``restype`` annotations.  Array data is shared
zero-copy between Zig and Python via ``Span`` structs (pointer + length)
that are mapped directly onto NumPy arrays.

Usage::

    ffi = SpoutFFI()                          # loads zig-out/lib/libspout.so
    handle = ffi.init_layout(backend=0, pdk=0)
    rc = ffi.parse_netlist(handle, "circuit.spice")
    positions = ffi.get_device_positions(handle)  # zero-copy np.ndarray
    ffi.destroy(handle)
"""

from __future__ import annotations

import ctypes
import os
from pathlib import Path
from typing import Optional

import numpy as np

# ---------------------------------------------------------------------------
# Span struct — mirrors the Zig ``Span(T)`` extern struct.
# All ``spout_get_*`` functions return one of these.
# ---------------------------------------------------------------------------


class Span(ctypes.Structure):
    """Generic (ptr, len) pair returned by the Zig C ABI."""

    _fields_ = [
        ("ptr", ctypes.c_void_p),
        ("len", ctypes.c_size_t),
    ]


# ---------------------------------------------------------------------------
# SpoutFFI class
# ---------------------------------------------------------------------------


class SpoutFFI:
    """Python wrapper around every C-ABI function exported by libspout.so."""

    def __init__(self, lib_path: Optional[str] = None) -> None:
        if lib_path is None:
            lib_path = self._find_library()
        self.lib = ctypes.CDLL(lib_path)
        self._supports_moead_placement = False
        self._supports_detailed_routing = False
        self._setup_signatures()

    @staticmethod
    def _bind_optional_symbol(lib, name: str, argtypes, restype) -> bool:
        """Bind an optional C symbol if the shared library exposes it."""
        try:
            func = getattr(lib, name)
        except AttributeError:
            return False

        func.argtypes = argtypes
        func.restype = restype
        return True

    @staticmethod
    def _find_project_root() -> Optional[Path]:
        """Walk up from this file to find the project root (contains build.zig)."""
        current = Path(__file__).resolve().parent
        for _ in range(10):  # don't walk up forever
            if (current / "build.zig").exists():
                return current
            parent = current.parent
            if parent == current:
                break
            current = parent
        return None

    @staticmethod
    def _find_library() -> str:
        """Locate libspout.so by searching multiple candidate paths."""
        candidates: list[Path] = []

        # 0. Environment override (highest priority)
        env = os.environ.get("SPOUT_LIB_PATH")
        if env:
            candidates.append(Path(env))

        # 1. Bundled alongside this Python file (pip-installed or copied)
        candidates.append(
            Path(__file__).resolve().parent / "libspout.so",
        )

        # 2. Zig build output relative to the project root.
        #    Find root by walking up to the directory containing build.zig.
        project_root = SpoutFFI._find_project_root()
        if project_root is not None:
            candidates.append(project_root / "zig-out" / "lib" / "libspout.so")

        # 3. Fallback: assume python/spout/ffi.py is two levels under root.
        candidates.append(
            Path(__file__).resolve().parent.parent.parent
            / "zig-out" / "lib" / "libspout.so",
        )

        for p in candidates:
            if p.exists():
                return str(p)

        raise FileNotFoundError(
            f"Cannot find libspout.so. Searched:\n"
            + "\n".join(f"  - {c}" for c in candidates)
            + "\nRun `zig build` in the project root, or set SPOUT_LIB_PATH."
        )

    # ------------------------------------------------------------------
    # Signature declarations
    # ------------------------------------------------------------------

    def _setup_signatures(self) -> None:
        """Declare ``argtypes`` and ``restype`` for every exported symbol."""

        lib = self.lib

        # ── 5.1 Lifecycle ─────────────────────────────────────────────
        lib.spout_init_layout.argtypes = [ctypes.c_uint8, ctypes.c_uint8]
        lib.spout_init_layout.restype = ctypes.c_void_p

        lib.spout_destroy.argtypes = [ctypes.c_void_p]
        lib.spout_destroy.restype = None

        lib.spout_load_pdk_from_file.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_load_pdk_from_file.restype = ctypes.c_int32

        # ── 5.2 Netlist parsing ───────────────────────────────────────
        lib.spout_parse_netlist.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_parse_netlist.restype = ctypes.c_int32

        lib.spout_get_num_devices.argtypes = [ctypes.c_void_p]
        lib.spout_get_num_devices.restype = ctypes.c_uint32

        lib.spout_get_num_nets.argtypes = [ctypes.c_void_p]
        lib.spout_get_num_nets.restype = ctypes.c_uint32

        lib.spout_get_num_pins.argtypes = [ctypes.c_void_p]
        lib.spout_get_num_pins.restype = ctypes.c_uint32

        lib.spout_get_device_positions.argtypes = [ctypes.c_void_p]
        lib.spout_get_device_positions.restype = Span

        lib.spout_get_device_types.argtypes = [ctypes.c_void_p]
        lib.spout_get_device_types.restype = Span

        lib.spout_get_device_params.argtypes = [ctypes.c_void_p]
        lib.spout_get_device_params.restype = Span

        lib.spout_get_net_fanout.argtypes = [ctypes.c_void_p]
        lib.spout_get_net_fanout.restype = Span

        lib.spout_get_pin_device.argtypes = [ctypes.c_void_p]
        lib.spout_get_pin_device.restype = Span

        lib.spout_get_pin_net.argtypes = [ctypes.c_void_p]
        lib.spout_get_pin_net.restype = Span

        lib.spout_get_pin_terminal.argtypes = [ctypes.c_void_p]
        lib.spout_get_pin_terminal.restype = Span

        # ── 5.3 Constraint extraction ────────────────────────────────
        lib.spout_extract_constraints.argtypes = [ctypes.c_void_p]
        lib.spout_extract_constraints.restype = ctypes.c_int32

        lib.spout_get_constraints.argtypes = [ctypes.c_void_p]
        lib.spout_get_constraints.restype = Span

        lib.spout_set_constraints_from_ml.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_set_constraints_from_ml.restype = ctypes.c_int32

        lib.spout_add_constraints_from_ml.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_add_constraints_from_ml.restype = ctypes.c_int32

        # ── 5.3.1 Macro / unit-cell ──────────────────────────────────
        lib.spout_detect_macros.argtypes = [ctypes.c_void_p]
        lib.spout_detect_macros.restype = ctypes.c_int32

        lib.spout_get_macro_template_count.argtypes = [ctypes.c_void_p]
        lib.spout_get_macro_template_count.restype = ctypes.c_uint32

        lib.spout_get_macro_instance_count.argtypes = [ctypes.c_void_p]
        lib.spout_get_macro_instance_count.restype = ctypes.c_uint32

        lib.spout_get_macro_device_inst.argtypes = [ctypes.c_void_p]
        lib.spout_get_macro_device_inst.restype = Span

        lib.spout_get_macro_device_local.argtypes = [ctypes.c_void_p]
        lib.spout_get_macro_device_local.restype = Span

        lib.spout_get_macro_instance_template_ids.argtypes = [ctypes.c_void_p]
        lib.spout_get_macro_instance_template_ids.restype = Span

        lib.spout_get_macro_instance_positions.argtypes = [ctypes.c_void_p]
        lib.spout_get_macro_instance_positions.restype = Span

        # ── 5.4 ML array write-back ──────────────────────────────────
        lib.spout_set_device_embeddings.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_float),
            ctypes.c_size_t,
        ]
        lib.spout_set_device_embeddings.restype = ctypes.c_int32

        lib.spout_set_net_embeddings.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_float),
            ctypes.c_size_t,
        ]
        lib.spout_set_net_embeddings.restype = ctypes.c_int32

        lib.spout_set_predicted_cap.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_float),
            ctypes.c_size_t,
        ]
        lib.spout_set_predicted_cap.restype = ctypes.c_int32

        # ── 5.5 Placement ────────────────────────────────────────────
        lib.spout_run_sa_placement.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_run_sa_placement.restype = ctypes.c_int32

        lib.spout_run_sa_hierarchical.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_run_sa_hierarchical.restype = ctypes.c_int32

        self._supports_moead_placement = self._bind_optional_symbol(
            lib,
            "spout_run_moead_placement",
            [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t],
            ctypes.c_int32,
        )

        self._bind_optional_symbol(
            lib,
            "spout_get_pareto_size",
            [ctypes.c_void_p],
            ctypes.c_uint32,
        )

        self._bind_optional_symbol(
            lib,
            "spout_get_pareto_objectives",
            [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_size_t],
            ctypes.c_uint32,
        )

        lib.spout_get_placement_cost.argtypes = [ctypes.c_void_p]
        lib.spout_get_placement_cost.restype = ctypes.c_float

        lib.spout_run_gradient_refinement.argtypes = [
            ctypes.c_void_p,
            ctypes.c_float,
            ctypes.c_uint32,
        ]
        lib.spout_run_gradient_refinement.restype = ctypes.c_int32

        # ── 5.6 Routing ──────────────────────────────────────────────
        lib.spout_run_routing.argtypes = [ctypes.c_void_p]
        lib.spout_run_routing.restype = ctypes.c_int32

        self._supports_detailed_routing = self._bind_optional_symbol(
            lib,
            "spout_run_detailed_routing",
            [ctypes.c_void_p],
            ctypes.c_int32,
        )

        lib.spout_get_route_segments.argtypes = [ctypes.c_void_p]
        lib.spout_get_route_segments.restype = Span

        lib.spout_get_num_routes.argtypes = [ctypes.c_void_p]
        lib.spout_get_num_routes.restype = ctypes.c_uint32

        lib.spout_get_layout_connectivity.argtypes = [ctypes.c_void_p]
        lib.spout_get_layout_connectivity.restype = Span

        # ── 5.10 Export ───────────────────────────────────────────────
        lib.spout_export_gdsii.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_export_gdsii.restype = ctypes.c_int32

        lib.spout_export_gdsii_named.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_export_gdsii_named.restype = ctypes.c_int32

        # Characterize: DRC
        lib.spout_run_drc.argtypes = [ctypes.c_void_p]
        lib.spout_run_drc.restype = ctypes.c_int32

        lib.spout_get_num_violations.argtypes = [ctypes.c_void_p]
        lib.spout_get_num_violations.restype = ctypes.c_uint32

        # Characterize: LVS
        lib.spout_run_lvs.argtypes = [ctypes.c_void_p]
        lib.spout_run_lvs.restype = ctypes.c_int32

        lib.spout_get_lvs_match.argtypes = [ctypes.c_void_p]
        lib.spout_get_lvs_match.restype = ctypes.c_bool

        lib.spout_get_lvs_mismatch_count.argtypes = [ctypes.c_void_p]
        lib.spout_get_lvs_mismatch_count.restype = ctypes.c_uint32

        # Characterize: ext2spice
        lib.spout_ext2spice.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
        ]
        lib.spout_ext2spice.restype = ctypes.c_int32

        # Characterize: PEX
        lib.spout_run_pex.argtypes = [ctypes.c_void_p]
        lib.spout_run_pex.restype = ctypes.c_int32

        lib.spout_get_pex_totals.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_float),
            ctypes.POINTER(ctypes.c_float),
        ]
        lib.spout_get_pex_totals.restype = ctypes.c_int32

    # ------------------------------------------------------------------
    # Lifecycle helpers
    # ------------------------------------------------------------------

    def init_layout(self, backend: int = 0, pdk: int = 0) -> ctypes.c_void_p:
        """Create a new SpoutContext.  Returns an opaque handle."""
        handle = self.lib.spout_init_layout(backend, pdk)
        if handle is None or handle == 0:
            raise RuntimeError("spout_init_layout returned a null handle")
        return handle

    def destroy(self, handle: ctypes.c_void_p) -> None:
        """Free all memory associated with *handle*."""
        self.lib.spout_destroy(handle)

    def load_pdk_from_file(self, handle: ctypes.c_void_p, path: str) -> int:
        """Replace the PDK config by loading a JSON file at *path*.

        Call this right after :meth:`init_layout` to use a cloned PDK or any
        custom JSON.  Raises ``RuntimeError`` on file-not-found or parse error.

        Example::

            handle = ffi.init_layout(backend=0, pdk=0)
            ffi.load_pdk_from_file(handle, "/path/to/my_pdk.json")
        """
        path_bytes = path.encode("utf-8")
        rc = self.lib.spout_load_pdk_from_file(handle, path_bytes, len(path_bytes))
        if rc != 0:
            raise RuntimeError(
                f"spout_load_pdk_from_file failed (code {rc}) for path: {path!r}"
            )
        return rc

    # ------------------------------------------------------------------
    # Netlist parsing
    # ------------------------------------------------------------------

    def parse_netlist(self, handle: ctypes.c_void_p, path: str) -> int:
        """Parse a SPICE netlist file.  Returns 0 on success."""
        path_bytes = path.encode("utf-8")
        rc = self.lib.spout_parse_netlist(handle, path_bytes, len(path_bytes))
        if rc != 0:
            raise RuntimeError(f"spout_parse_netlist failed with code {rc}")
        return rc

    def get_num_devices(self, handle: ctypes.c_void_p) -> int:
        """Return the number of devices parsed from the netlist."""
        return self.lib.spout_get_num_devices(handle)

    def get_num_nets(self, handle: ctypes.c_void_p) -> int:
        """Return the number of nets parsed from the netlist."""
        return self.lib.spout_get_num_nets(handle)

    def get_num_pins(self, handle: ctypes.c_void_p) -> int:
        """Return the total number of pins (device-net connections)."""
        return self.lib.spout_get_num_pins(handle)

    # ------------------------------------------------------------------
    # Zero-copy array getters
    # ------------------------------------------------------------------

    @staticmethod
    def _span_to_array(
        span: Span,
        count: int,
        ctype,
        dtype: np.dtype,
        cols: int = 1,
    ) -> np.ndarray:
        """Convert a ``Span`` to a NumPy array (zero-copy when possible).

        Parameters
        ----------
        span : Span
            The (ptr, len) pair from the Zig side.
        count : int
            Number of logical rows.
        ctype
            ctypes element type (e.g. ``ctypes.c_float``).
        dtype : np.dtype
            NumPy dtype matching *ctype*.
        cols : int
            Number of columns per row.  When > 1 the result is 2-D.
        """
        total = count * cols
        if span.ptr is None or span.ptr == 0 or total == 0:
            shape = (0, cols) if cols > 1 else (0,)
            return np.empty(shape, dtype=dtype)

        arr_ptr = ctypes.cast(span.ptr, ctypes.POINTER(ctype * total))
        arr = np.ctypeslib.as_array(arr_ptr.contents)
        arr = arr.view(dtype)
        if cols > 1:
            arr = arr.reshape(count, cols)
        return arr

    def get_device_positions(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Zero-copy view of device positions — shape ``(N, 2)``, float32."""
        n = self.get_num_devices(handle)
        span = self.lib.spout_get_device_positions(handle)
        return self._span_to_array(span, n, ctypes.c_float, np.float32, cols=2)

    def get_device_types(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Device type enum values — shape ``(N,)``, uint8."""
        n = self.get_num_devices(handle)
        span = self.lib.spout_get_device_types(handle)
        return self._span_to_array(span, n, ctypes.c_uint8, np.uint8)

    def get_device_params(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Device parameters — shape ``(N, 5)``, float32.

        Column order: w, l, fingers_as_f32, mult_as_f32, value.
        Note: The Zig ``DeviceParams`` extern struct packs ``fingers``
        and ``mult`` as u16 between the f32 fields; the raw view here
        re-interprets them as f32 for simplicity.  Use
        :meth:`get_device_params_structured` for accurate typed access.
        """
        n = self.get_num_devices(handle)
        span = self.lib.spout_get_device_params(handle)
        return self._span_to_array(span, n, ctypes.c_float, np.float32, cols=5)

    # DeviceParams dtype: mirrors the Zig extern struct { f32, f32, u16, u16, f32 }.
    _DEVICE_PARAMS_DTYPE = np.dtype([
        ("w", np.float32),
        ("l", np.float32),
        ("fingers", np.uint16),
        ("mult", np.uint16),
        ("value", np.float32),
    ])

    def get_device_params_structured(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Device parameters with proper dtypes for the u16 fields.

        Returns a structured NumPy array with fields ``w``, ``l``,
        ``fingers``, ``mult``, ``value``.
        """
        n = self.get_num_devices(handle)
        span = self.lib.spout_get_device_params(handle)
        dt = self._DEVICE_PARAMS_DTYPE
        if span.ptr is None or span.ptr == 0 or n == 0:
            return np.empty(0, dtype=dt)

        buf = (ctypes.c_char * (n * dt.itemsize)).from_address(span.ptr)
        return np.frombuffer(buf, dtype=dt)

    def get_net_fanout(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Per-net fanout — shape ``(M,)``, uint16."""
        n = self.get_num_nets(handle)
        span = self.lib.spout_get_net_fanout(handle)
        return self._span_to_array(span, n, ctypes.c_uint16, np.uint16)

    def get_pin_device(self, handle: ctypes.c_void_p) -> np.ndarray:
        """DeviceIdx for each pin — shape ``(P,)``, uint32."""
        n = self.get_num_pins(handle)
        span = self.lib.spout_get_pin_device(handle)
        return self._span_to_array(span, n, ctypes.c_uint32, np.uint32)

    def get_pin_net(self, handle: ctypes.c_void_p) -> np.ndarray:
        """NetIdx for each pin — shape ``(P,)``, uint32."""
        n = self.get_num_pins(handle)
        span = self.lib.spout_get_pin_net(handle)
        return self._span_to_array(span, n, ctypes.c_uint32, np.uint32)

    def get_pin_terminal(self, handle: ctypes.c_void_p) -> np.ndarray:
        """TerminalType for each pin — shape ``(P,)``, uint8."""
        n = self.get_num_pins(handle)
        span = self.lib.spout_get_pin_terminal(handle)
        return self._span_to_array(span, n, ctypes.c_uint8, np.uint8)

    # ------------------------------------------------------------------
    # Constraint extraction
    # ------------------------------------------------------------------

    def extract_constraints(self, handle: ctypes.c_void_p) -> int:
        """Run rule-based constraint extraction.  Returns 0 on success."""
        rc = self.lib.spout_extract_constraints(handle)
        if rc != 0:
            raise RuntimeError(f"spout_extract_constraints failed with code {rc}")
        return rc

    def get_constraints(self, handle: ctypes.c_void_p) -> bytes:
        """Return the serialised constraint buffer as ``bytes``."""
        span = self.lib.spout_get_constraints(handle)
        if span.ptr is None or span.ptr == 0 or span.len == 0:
            return b""
        buf = (ctypes.c_char * span.len).from_address(span.ptr)
        return bytes(buf)

    def set_constraints_from_ml(
        self, handle: ctypes.c_void_p, data: bytes
    ) -> int:
        """Write ML-predicted constraints into the engine."""
        rc = self.lib.spout_set_constraints_from_ml(handle, data, len(data))
        if rc != 0:
            raise RuntimeError(
                f"spout_set_constraints_from_ml failed with code {rc}"
            )
        return rc

    def add_constraints_from_ml(
        self, handle: ctypes.c_void_p, data: bytes
    ) -> int:
        """Append ML-predicted constraints, merging with existing Zig constraints."""
        rc = self.lib.spout_add_constraints_from_ml(handle, data, len(data))
        if rc != 0:
            raise RuntimeError(
                f"spout_add_constraints_from_ml failed with code {rc}"
            )
        return rc

    # ------------------------------------------------------------------
    # Macro / unit-cell read-back
    # ------------------------------------------------------------------

    def detect_macros(self, handle: ctypes.c_void_p) -> int:
        """Explicitly re-run macro detection. Also runs automatically after parse."""
        rc = self.lib.spout_detect_macros(handle)
        if rc != 0:
            raise RuntimeError(f"spout_detect_macros failed with code {rc}")
        return rc

    def get_macro_template_count(self, handle: ctypes.c_void_p) -> int:
        """Number of detected macro templates."""
        return int(self.lib.spout_get_macro_template_count(handle))

    def get_macro_instance_count(self, handle: ctypes.c_void_p) -> int:
        """Number of detected macro instances."""
        return int(self.lib.spout_get_macro_instance_count(handle))

    def get_macro_device_inst(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Per-device instance index — shape ``(N,)``, int32. -1 if not in a macro."""
        n = self.get_num_devices(handle)
        span = self.lib.spout_get_macro_device_inst(handle)
        return self._span_to_array(span, n, ctypes.c_int32, np.int32)

    def get_macro_device_local(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Per-device local index within its template — shape ``(N,)``, uint32."""
        n = self.get_num_devices(handle)
        span = self.lib.spout_get_macro_device_local(handle)
        return self._span_to_array(span, n, ctypes.c_uint32, np.uint32)

    def get_macro_instance_template_ids(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Template ID for each instance — shape ``(M,)``, uint32."""
        n = self.get_macro_instance_count(handle)
        span = self.lib.spout_get_macro_instance_template_ids(handle)
        return self._span_to_array(span, n, ctypes.c_uint32, np.uint32)

    def get_macro_instance_positions(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Instance positions — shape ``(M, 2)``, float32."""
        n = self.get_macro_instance_count(handle)
        span = self.lib.spout_get_macro_instance_positions(handle)
        return self._span_to_array(span, n, ctypes.c_float, np.float32, cols=2)

    def run_sa_hierarchical(
        self, handle: ctypes.c_void_p, config: bytes = b""
    ) -> None:
        """Two-phase hierarchical SA placement (unit-cell then super-device)."""
        rc = self.lib.spout_run_sa_hierarchical(handle, config, len(config))
        if rc != 0:
            raise RuntimeError(f"spout_run_sa_hierarchical failed with code {rc}")

    # ------------------------------------------------------------------
    # ML array write-back
    # ------------------------------------------------------------------

    def set_device_embeddings(
        self, handle: ctypes.c_void_p, embeddings: np.ndarray
    ) -> int:
        """Write device GNN embeddings (N x 64, float32) into Zig memory."""
        embeddings = np.ascontiguousarray(embeddings, dtype=np.float32)
        ptr = embeddings.ctypes.data_as(ctypes.POINTER(ctypes.c_float))
        rc = self.lib.spout_set_device_embeddings(handle, ptr, embeddings.size)
        if rc != 0:
            raise RuntimeError(
                f"spout_set_device_embeddings failed with code {rc}"
            )
        return rc

    def set_net_embeddings(
        self, handle: ctypes.c_void_p, embeddings: np.ndarray
    ) -> int:
        """Write net GNN embeddings (M x 64, float32) into Zig memory."""
        embeddings = np.ascontiguousarray(embeddings, dtype=np.float32)
        ptr = embeddings.ctypes.data_as(ctypes.POINTER(ctypes.c_float))
        rc = self.lib.spout_set_net_embeddings(handle, ptr, embeddings.size)
        if rc != 0:
            raise RuntimeError(
                f"spout_set_net_embeddings failed with code {rc}"
            )
        return rc

    def set_predicted_cap(
        self, handle: ctypes.c_void_p, caps: np.ndarray
    ) -> int:
        """Write ParaGraph predicted capacitances (N, float32) into Zig memory."""
        caps = np.ascontiguousarray(caps, dtype=np.float32)
        ptr = caps.ctypes.data_as(ctypes.POINTER(ctypes.c_float))
        rc = self.lib.spout_set_predicted_cap(handle, ptr, caps.size)
        if rc != 0:
            raise RuntimeError(f"spout_set_predicted_cap failed with code {rc}")
        return rc

    # ------------------------------------------------------------------
    # Placement
    # ------------------------------------------------------------------

    def run_sa_placement(
        self, handle: ctypes.c_void_p, config_json: bytes
    ) -> int:
        """Run simulated-annealing placement.  Returns 0 on success."""
        rc = self.lib.spout_run_sa_placement(
            handle, config_json, len(config_json)
        )
        if rc != 0:
            raise RuntimeError(f"spout_run_sa_placement failed with code {rc}")
        return rc

    @property
    def supports_moead_placement(self) -> bool:
        """True when the loaded shared library exposes MOEA/D placement."""
        return self._supports_moead_placement

    def run_moead_placement(
        self, handle: ctypes.c_void_p, config_json: bytes
    ) -> int:
        """Run MOEA/D placement when the optional entrypoint is available."""
        if not self._supports_moead_placement:
            raise AttributeError(
                "spout_run_moead_placement is not available in this library"
            )

        rc = self.lib.spout_run_moead_placement(
            handle, config_json, len(config_json)
        )
        if rc != 0:
            raise RuntimeError(
                f"spout_run_moead_placement failed with code {rc}"
            )
        return rc

    def get_pareto_size(self, handle: ctypes.c_void_p) -> int:
        """Return number of Pareto-optimal solutions from the last MOEA/D run."""
        if not hasattr(self.lib, "spout_get_pareto_size"):
            return 0
        return int(self.lib.spout_get_pareto_size(handle))

    def get_pareto_objectives(self, handle: ctypes.c_void_p) -> "np.ndarray":
        """Return (N, 3) float32 array of [hpwl, area, constraint] per Pareto solution."""
        import numpy as np

        n = self.get_pareto_size(handle)
        if n == 0:
            return np.empty((0, 3), dtype=np.float32)
        buf = (ctypes.c_float * (n * 3))()
        written = self.lib.spout_get_pareto_objectives(handle, buf, n * 3)
        arr = np.frombuffer(buf, dtype=np.float32, count=int(written))
        return arr.reshape(-1, 3).copy()

    def get_placement_cost(self, handle: ctypes.c_void_p) -> float:
        """Return the final placement cost scalar."""
        return float(self.lib.spout_get_placement_cost(handle))

    def run_gradient_refinement(
        self,
        handle: ctypes.c_void_p,
        learning_rate: float = 0.001,
        steps: int = 200,
    ) -> int:
        """Run gradient-based placement refinement.  Returns 0 on success."""
        rc = self.lib.spout_run_gradient_refinement(handle, learning_rate, steps)
        if rc != 0:
            raise RuntimeError(
                f"spout_run_gradient_refinement failed with code {rc}"
            )
        return rc

    # ------------------------------------------------------------------
    # Routing
    # ------------------------------------------------------------------

    def run_routing(self, handle: ctypes.c_void_p) -> int:
        """Run two-phase routing.  Returns 0 on success."""
        rc = self.lib.spout_run_routing(handle)
        if rc != 0:
            raise RuntimeError(f"spout_run_routing failed with code {rc}")
        return rc

    @property
    def supports_detailed_routing(self) -> bool:
        """True when the loaded shared library exposes detailed routing."""
        return self._supports_detailed_routing

    def run_detailed_routing(self, handle: ctypes.c_void_p) -> int:
        """Run the detailed routing flow when the optional entrypoint exists."""
        if not self._supports_detailed_routing:
            raise AttributeError(
                "spout_run_detailed_routing is not available in this library"
            )

        rc = self.lib.spout_run_detailed_routing(handle)
        if rc != 0:
            raise RuntimeError(
                f"spout_run_detailed_routing failed with code {rc}"
            )
        return rc

    def get_num_routes(self, handle: ctypes.c_void_p) -> int:
        """Return the number of route segments after routing."""
        return self.lib.spout_get_num_routes(handle)

    def get_route_segments(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Flattened route-segment data — shape ``(R, 7)``, float32.

        Columns: layer (as f32), x1, y1, x2, y2, width, net_idx (as f32).
        """
        n = self.get_num_routes(handle)
        span = self.lib.spout_get_route_segments(handle)
        return self._span_to_array(span, n, ctypes.c_float, np.float32, cols=7)

    def get_layout_connectivity(self, handle: ctypes.c_void_p) -> np.ndarray:
        """Per-pin connected-component IDs from physical route connectivity.

        Returns shape ``(P,)``, uint32.  Pins with the same value are
        electrically connected through metal in the layout.
        """
        n = self.get_num_pins(handle)
        span = self.lib.spout_get_layout_connectivity(handle)
        return self._span_to_array(span, n, ctypes.c_uint32, np.uint32)

    # ------------------------------------------------------------------
    # Export
    # ------------------------------------------------------------------

    def export_gdsii(self, handle: ctypes.c_void_p, path: str, cell_name: str = "") -> int:
        """Export the current layout state to a GDSII file.

        Parameters
        ----------
        handle : ctypes.c_void_p
            Opaque SpoutContext handle.
        path : str
            Output GDSII file path.
        cell_name : str
            Top cell name.  When empty, the Zig side derives the name from
            *path* (strips directory prefix and ``.gds`` extension).
        """
        path_bytes = path.encode("utf-8")
        if cell_name:
            name_bytes = cell_name.encode("utf-8")
            rc = self.lib.spout_export_gdsii_named(
                handle, path_bytes, len(path_bytes),
                name_bytes, len(name_bytes),
            )
        else:
            rc = self.lib.spout_export_gdsii(handle, path_bytes, len(path_bytes))
        if rc != 0:
            raise RuntimeError(f"spout_export_gdsii failed with code {rc}")
        return rc

    # ------------------------------------------------------------------
    # DRC / LVS / PEX stubs
    # (in-engine implementations not yet available; degrade gracefully)
    # ------------------------------------------------------------------

    def run_drc(self, handle: ctypes.c_void_p) -> int:
        """Run in-engine DRC on current route segments."""
        rc = self.lib.spout_run_drc(handle)
        if rc not in (0, -2):  # -2 = no routes yet (not an error for callers)
            raise RuntimeError(f"spout_run_drc failed with code {rc}")
        return rc

    def get_num_violations(self, handle: ctypes.c_void_p) -> int:
        """Return the number of DRC violations from the last spout_run_drc call."""
        return int(self.lib.spout_get_num_violations(handle))

    def get_drc_violations(self, handle: ctypes.c_void_p) -> list:
        """Return DRC violation count as a one-element list for compatibility."""
        return [self.get_num_violations(handle)]

    def run_lvs(self, handle: ctypes.c_void_p) -> int:
        """Run in-engine LVS: device-list check + net-coverage check."""
        rc = self.lib.spout_run_lvs(handle)
        if rc != 0:
            raise RuntimeError(f"spout_run_lvs failed with code {rc}")
        return rc

    def get_lvs_match(self, handle: ctypes.c_void_p) -> bool:
        """Return True if LVS passes (all devices and nets match)."""
        return bool(self.lib.spout_get_lvs_match(handle))

    def get_lvs_mismatch_count(self, handle: ctypes.c_void_p) -> int:
        """Return total mismatch count (net mismatches + unmatched devices)."""
        return int(self.lib.spout_get_lvs_mismatch_count(handle))

    def ext2spice(self, handle: ctypes.c_void_p, path: str) -> int:
        """Write a SPICE netlist using Spout's in-engine ext2spice.

        Uses the parsed schematic's device list, net names, subcircuit ports,
        and model names to produce a .spice file at the given path.
        """
        path_bytes = path.encode("utf-8")
        rc = self.lib.spout_ext2spice(handle, path_bytes, len(path_bytes))
        if rc != 0:
            raise RuntimeError(f"spout_ext2spice failed with code {rc}")
        return rc

    def run_pex(self, handle: ctypes.c_void_p) -> int:
        """Run in-engine PEX on current route segments."""
        rc = self.lib.spout_run_pex(handle)
        if rc not in (0, -2):  # -2 = no routes yet
            raise RuntimeError(f"spout_run_pex failed with code {rc}")
        return rc

    def get_pex_result(self, handle: ctypes.c_void_p) -> dict:
        """Return PEX aggregate totals: num_caps, num_res, total_cap_ff, total_res_ohm."""
        num_res = ctypes.c_uint32(0)
        num_cap = ctypes.c_uint32(0)
        total_res = ctypes.c_float(0.0)
        total_cap = ctypes.c_float(0.0)
        rc = self.lib.spout_get_pex_totals(
            handle,
            ctypes.byref(num_res),
            ctypes.byref(num_cap),
            ctypes.byref(total_res),
            ctypes.byref(total_cap),
        )
        if rc != 0:
            return {"num_caps": 0, "num_res": 0, "total_cap_ff": 0.0, "total_res_ohm": 0.0}
        return {
            "num_caps": int(num_cap.value),
            "num_res": int(num_res.value),
            "total_cap_ff": float(total_cap.value),
            "total_res_ohm": float(total_res.value),
        }

    # ------------------------------------------------------------------
    # Convenience: retrieve all arrays in one call
    # ------------------------------------------------------------------

    def get_all_arrays(self, handle: ctypes.c_void_p) -> dict:
        """Return a dict of all live array views (zero-copy).

        Useful for feeding data to ML models.
        """
        return {
            "device_positions": self.get_device_positions(handle),
            "device_types": self.get_device_types(handle),
            "device_params": self.get_device_params(handle),
            "net_fanout": self.get_net_fanout(handle),
            "pin_device": self.get_pin_device(handle),
            "pin_net": self.get_pin_net(handle),
            "pin_terminal": self.get_pin_terminal(handle),
            "num_devices": self.get_num_devices(handle),
            "num_nets": self.get_num_nets(handle),
            "num_pins": self.get_num_pins(handle),
        }
