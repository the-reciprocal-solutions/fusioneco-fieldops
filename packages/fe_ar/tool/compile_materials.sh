#!/usr/bin/env bash
# Compiles the fe_ar Filament materials for every backend (OpenGL ES, Vulkan,
# Metal) and copies them to where each platform loads them from:
#   android/src/main/assets/fe_ar/<name>.filamat   (AssetManager)
#   ios/Assets/<name>.filamat                       (the pod's resource bundle)
#
# matc MUST be the same Filament version as the runtime, or the engine refuses
# the package ("material version mismatch"). Both platforms pin one version:
#   Android  SceneView's Filament (io.github.sceneview:arsceneview, see
#            android/build.gradle FE_AR_FILAMENT_VERSION)
#   iOS      the `Filament` pod in ios/fe_ar.podspec
# Get matc from that version's desktop release on GitHub
# (filament-v<VERSION>-mac.tgz or -linux.tgz, bin/matc).
#
# Usage: MATC=/path/to/matc tool/compile_materials.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
matc="${MATC:-matc}"
if ! command -v "$matc" >/dev/null 2>&1; then
  echo "matc not found. Set MATC=/path/to/matc (Filament desktop release, same version as the runtime)." >&2
  exit 1
fi

android_out="$here/android/src/main/assets/fe_ar"
ios_out="$here/ios/Assets"
mkdir -p "$android_out" "$ios_out"

for src in "$here"/materials/*.mat; do
  name="$(basename "$src" .mat)"
  out="$(mktemp -t "$name").filamat"
  "$matc" --api all --platform mobile -o "$out" "$src"
  # fe_camera_feed and fe_scan are iOS-only: SceneView draws the ARCore
  # camera and its own plane grid (the room-scan overlay) on Android.
  if [[ "$name" != "fe_camera_feed" && "$name" != "fe_scan" ]]; then
    cp "$out" "$android_out/$name.filamat"
  fi
  cp "$out" "$ios_out/$name.filamat"
  rm -f "$out"
  echo "compiled $name"
done
