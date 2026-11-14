#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p dist work
swift build -c release --product WebinarNihongo
binary_dir=$(swift build -c release --show-bin-path)
app="dist/RTranslate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/WebinarNihongo" "$app/Contents/MacOS/WebinarNihongo"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ "${1:-}" == "--with-mlx" || "${1:-}" == "--personal" ]]; then
    runtime_source=$(work/mlx-venv/bin/python -c 'import sys; print(sys.base_prefix)')
    runtime="$app/Contents/Resources/Python"
    if [[ ! -d "$runtime" ]]; then
        ditto "$runtime_source" "$runtime"
        ditto work/mlx-venv/lib/python3.13/site-packages "$runtime/lib/python3.13/site-packages"
    fi
    cp scripts/plamo_worker.py "$app/Contents/Resources/plamo_worker.py"
    cp scripts/voicevox_worker.py "$app/Contents/Resources/voicevox_worker.py"
    if [[ -d work/mlx-venv/lib/python3.13/site-packages/voicevox_core ]]; then
        ditto work/mlx-venv/lib/python3.13/site-packages/voicevox_core "$runtime/lib/python3.13/site-packages/voicevox_core"
        for metadata in work/mlx-venv/lib/python3.13/site-packages/voicevox_core-*.dist-info; do
            ditto "$metadata" "$runtime/lib/python3.13/site-packages/${metadata:t}"
        done
    fi
    ditto Resources/VOICEVOX-LICENSE "$app/Contents/Resources/VOICEVOX-LICENSE"
    ditto Resources/PLaMo-LICENSE "$app/Contents/Resources/PLaMo-LICENSE"
    codesign --force --deep --sign - "$runtime/bin/python3.13"
fi
if [[ "${1:-}" == "--personal" ]]; then
    assets="$app/Contents/Resources/Models"
    mkdir -p "$assets"
    # Only authored/public model files belong in the app, never Hub cache metadata.
    python3 scripts/check_bundled_assets.py "$app"
    cp docs/AIR_INSTALL.md "$app/Contents/Resources/AIR_INSTALL.md"
    cp docs/V01_RELEASE.md "$app/Contents/Resources/V01_RELEASE.md"
fi
python3 scripts/apply_branding.py "$app"
codesign --force --deep --sign - "$app"
codesign --verify --strict "$app"
echo "Built: $PWD/$app"
