"""Run app coordination tests with a temporary UI_SMOKE model, without the user's container."""
import argparse
import plistlib
import subprocess
import tempfile
from pathlib import Path
root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('products', type=Path, help='UISmoke build products')
parser.add_argument('identity')
args = parser.parse_args()
workspace = Path(tempfile.mkdtemp(prefix='BeeSaveCoordinatorTests-'))
app = workspace / 'BeeSave.app'
binary = app / 'Contents/MacOS/CoordinatorTests'
binary.parent.mkdir(parents=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.mubudget.app',
    'CFBundleExecutable': 'CoordinatorTests', 'CFBundleVersion': '6', 'CFBundleShortVersionString': '1.2.0', 'CFBundlePackageType': 'APPL'}))
sources = sorted(path for path in (root / 'App').glob('*.swift') if path.name != 'BeeSaveApp.swift')
modulemap = args.products.parent.parent / 'Intermediates.noindex/GeneratedModuleMaps/CArgon2.modulemap'
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-target', 'arm64-apple-macos26.0', '-DDEBUG', '-DUI_SMOKE',
    '-Xcc', '-fmodule-map-file='+str(modulemap), '-Xcc', '-I'+str(root / 'Vendor/Argon2/include'),
    '-I', str(args.products), '-F', str(root / 'build/Sparkle'), '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
    *map(str, sources), str(root / 'Tests/AppUpdateCoordinatorTests/main.swift'),
    *[str(args.products / name) for name in ['BudgetCore.o', 'BudgetPresentation.o', 'CArgon2.o']], '-o', str(binary)], check=True)
subprocess.run(['ditto', str(root / 'build/Sparkle/Sparkle.framework'), str(app / 'Contents/Frameworks/Sparkle.framework')], check=True)
subprocess.run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp=none', str(app)], check=True)
subprocess.run([str(binary)], check=True)
