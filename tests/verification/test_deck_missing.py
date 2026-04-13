"""
DeckNotFoundError must be raised eagerly with a helpful message when
PDK_ROOT points at a directory that does not contain the expected deck.

This test deliberately does NOT require ``klayout``: the error should
surface before any klayout import is attempted.
"""

from __future__ import annotations

from pathlib import Path

import pytest


def test_bad_pdk_root_raises_deck_not_found(tmp_path: Path, monkeypatch):
    from python.spout.config import SpoutConfig
    from python.verification import run_drc
    from python.verification.errors import DeckNotFoundError

    bogus_root = tmp_path / "no_such_pdk"
    bogus_root.mkdir()
    monkeypatch.setenv("PDK_ROOT", str(bogus_root))

    pdk = SpoutConfig(pdk="sky130", pdk_root=str(bogus_root))
    fake_gds = tmp_path / "empty.gds"
    fake_gds.write_bytes(b"")

    with pytest.raises(DeckNotFoundError) as exc_info:
        run_drc(fake_gds, pdk)

    assert "DRC" in str(exc_info.value)
    assert str(bogus_root) in str(exc_info.value)


def test_unknown_pdk_raises_deck_not_found():
    from python.verification.decks import resolve_deck_paths
    from python.verification.errors import DeckNotFoundError

    with pytest.raises(DeckNotFoundError) as exc_info:
        resolve_deck_paths("not_a_real_pdk", None)

    assert "not_a_real_pdk" in str(exc_info.value)
