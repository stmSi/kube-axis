#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/assets/ui_src"
DST_DIR="${ROOT_DIR}/assets/ui"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert is not installed" >&2
  exit 1
fi

mkdir -p "${DST_DIR}"

shopt -s nullglob
svgs=("${SRC_DIR}"/*.svg)

if [ "${#svgs[@]}" -eq 0 ]; then
  echo "error: no SVG files found in ${SRC_DIR}" >&2
  exit 1
fi

for svg in "${svgs[@]}"; do
  name="$(basename "${svg}" .svg)"
  png="${DST_DIR}/${name}.png"
  rsvg-convert "${svg}" -o "${png}"
  echo "exported ${png}"
done
