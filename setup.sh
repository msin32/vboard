#!/usr/bin/env bash
if [[ $(command -v g++ make python sdl2-config) ]]; then
  echo "Installing..."
else
  echo "ERROR: ensure g++, make, python, sdl2 installed"
fi

set -euo pipefail
# folder to extract tools: YosysHQ OSS CAD Suite = yosys (+ghdl and slang plugins), nextpnr, IceStorm, verilator, GHDL, GTKWave, iverilog, cocotb, etc.
TOOLS="${TOOLS_DIR:-$(pwd)/tools}"

if [ ! -d "$TOOLS/oss-cad-suite" ]; then
  # Resolve the newest release
  tag=$(curl -sIL -o /dev/null -w '%{url_effective}' \
        https://github.com/YosysHQ/oss-cad-suite-build/releases/latest | sed 's#.*/tag/##')
  html=$(curl -sL "https://github.com/YosysHQ/oss-cad-suite-build/releases/expanded_assets/$tag")
  path=$(grep -o '/YosysHQ/[^"]*linux-x64-[0-9]*\.tgz' <<<"$html" | sed -n '1p')
  [ -n "$path" ] || { echo "could not find a linux-x64 asset for release $tag" >&2; exit 1; }
  echo "Downloading OSS CAD Suite $tag (~750 MB) ..."
  mkdir -p "$TOOLS"
  [ -n "${DRY_RUN:-}" ] && { echo "would fetch https://github.com$path"; exit 0; }
  curl -L --fail "https://github.com$path" | tar xz -C "$TOOLS"
fi

cat <<EOF

Done. Put the tools on your PATH (add to ~/.bashrc / ~/.zshrc to make it permanent):

    source $TOOLS/oss-cad-suite/environment          # fish: source $TOOLS/oss-cad-suite/environment.fish

Then:  cd examples/sv_vga && make run
EOF
