{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };
  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
    }:
    {
      devShells.x86_64-linux.default =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          zig = zig-overlay.packages.x86_64-linux."0.15.2";

          volare = pkgs.python312Packages.buildPythonPackage rec {
            pname = "volare";
            version = "0.20.6";
            pyproject = true;

            src = pkgs.fetchPypi {
              inherit pname version;
              hash = "sha256-ouvZuKgd4UTbw1LqtxZw5+Sz5HEycjh0eadZNVaeB2o=";
            };

            build-system = [ pkgs.python312Packages.poetry-core ];

            dependencies = with pkgs.python312Packages; [
              click
              httpx
              pcpp
              pyyaml
              rich
              zstandard
            ];

            # rich 14 in nixpkgs exceeds volare's <14 pin but is compatible
            pythonRelaxDeps = [ "rich" ];

            # volare has no test suite in the sdist
            doCheck = false;
          };

          python = pkgs.python312.withPackages (ps: [
            ps.numpy
            ps.torch
            ps.torch-geometric
            ps.onnx
            ps.onnxruntime
            ps.pytest
            volare
          ]);
        in
        pkgs.mkShell {
          buildInputs = [
            zig
            python
            pkgs.magic-vlsi
            pkgs.klayout
            pkgs.ngspice # SPICE simulation
          ];
          LD_LIBRARY_PATH = "${pkgs.stdenv.cc.cc.lib}/lib";
          shellHook = ''
            # Strip Python 3.13 site-packages paths that netgen/klayout inject.
            # Our interpreter is 3.12; mixing cpython-313 C extensions crashes numpy.
            if [ -n "$PYTHONPATH" ]; then
              PYTHONPATH=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -v 'python3\.13' | paste -sd ':' -)
            fi

            # Make the Python package importable without pip install
            export PYTHONPATH="$PWD/python''${PYTHONPATH:+:$PYTHONPATH}"

            # Create a wrapper so the "spout" CLI entry point works without pip install
            spout() { python -c "import sys; sys.argv = ['spout'] + sys.argv[1:]; from spout.main import main; main()" "$@"; }
            export -f spout

            # PDK setup
            export PDK_ROOT="''${PDK_ROOT:-$HOME/.volare}"
            export PDK=sky130A

            if [ ! -d "$PDK_ROOT/$PDK" ]; then
              echo ""
              echo "  sky130 PDK not found at $PDK_ROOT/$PDK"
              echo "  Installing via volare..."
              volare enable --pdk sky130 || echo "  Failed — run manually: volare enable --pdk sky130"
              echo ""
            fi
          '';
        };
    };
}
