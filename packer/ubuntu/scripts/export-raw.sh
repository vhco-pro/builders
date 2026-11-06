#!/usr/bin/env bash
set -euo pipefail

[[ "${BUILD_OUTPUT_RAW:-false}" == true ]] || exit 0
: "${BUILD_QEMU_IMAGE:?Set BUILD_QEMU_IMAGE to the qcow2 artifact}"
command -v qemu-img >/dev/null
raw_image="${BUILD_QEMU_IMAGE%.qcow2}.raw"
[[ "$raw_image" != "$BUILD_QEMU_IMAGE" && ! -e "$raw_image" ]] || {
    printf '%s\n' 'Refusing to overwrite the raw output or convert an unexpected input path.' >&2
    exit 1
}
qemu-img convert -f qcow2 -O raw "$BUILD_QEMU_IMAGE" "$raw_image"
