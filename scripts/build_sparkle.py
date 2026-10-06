"""Fetch, verify, patch, build and sign the locked Sparkle framework for Xcode."""
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path
from sign_sparkle import sign_framework

root = Path(__file__).resolve().parent.parent
vendor = root / 'Vendor/Sparkle'
lock = json.loads((vendor / 'lock.json').read_text())
workspace = root / 'build/Sparkle'
workspace.mkdir(parents=True, exist_ok=True)
runtime = Path(tempfile.gettempdir()) / ('BeeSaveSparkle-' + hashlib.sha256(str(root).encode()).hexdigest()[:12])
runtime.mkdir(parents=True, exist_ok=True)
identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or os.environ.get('CODE_SIGN_IDENTITY')
if not identity or identity == '-':
    raise SystemExit('Select your Apple Development certificate before building BeeSave.')
with (workspace / 'build.lock').open('w') as guard:
    fcntl.flock(guard, fcntl.LOCK_EX)
    inputs = b''.join((vendor / name).read_bytes() for name in ['lock.json', 'network.patch', 'package.patch', 'BeeSaveDownloadPolicy.h', 'BeeSavePackagePolicy.h', 'LICENSE'])
    inputs += Path(__file__).read_bytes() + (root / 'scripts/sign_sparkle.py').read_bytes()
    inputs += subprocess.check_output(['xcodebuild', '-version']) + identity.encode()
    fingerprint = hashlib.sha256(inputs).hexdigest()
    framework = workspace / 'Sparkle.framework'
    stamp = workspace / 'fingerprint'
    if stamp.exists() and stamp.read_text() == fingerprint and framework.exists():
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(framework)], check=True)
        raise SystemExit(0)
    archive = workspace / 'source.tar.gz'
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != lock['sourceSHA256']:
        partial = workspace / 'source.tar.gz.partial'
        subprocess.run(['curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
                        '--connect-timeout', '15', '--max-time', '300', lock['sourceURL'], '-o', str(partial)], check=True)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != lock['sourceSHA256']:
            partial.unlink()
            raise SystemExit('Sparkle source checksum mismatch.')
        partial.replace(archive)
    source = runtime / 'source'
    if source.exists(): shutil.rmtree(source)
    source.mkdir()
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            parts = Path(member.name).parts[1:]
            if not parts: continue
            if member.isdev() or any(part in {'..', '/'} for part in parts):
                raise SystemExit('Unsafe Sparkle archive member.')
            member.name = str(Path(*parts))
            if member.issym() or member.islnk():
                if Path(member.linkname).is_absolute() or '..' in Path(member.linkname).parts:
                    raise SystemExit('Unsafe Sparkle archive link.')
            package.extract(member, source)
    subprocess.run(['patch', '-p1', '-i', str(vendor / 'network.patch')], cwd=source, check=True)
    subprocess.run(['patch', '-p1', '-i', str(vendor / 'package.patch')], cwd=source, check=True)
    shutil.copy2(vendor / 'BeeSaveDownloadPolicy.h', source / 'Downloader/BeeSaveDownloadPolicy.h')
    shutil.copy2(vendor / 'BeeSavePackagePolicy.h', source / 'Sparkle/BeeSavePackagePolicy.h')
    # Compile with local signatures, then sign every nested component with the
    # host identity. SDK build settings never weaken the host's Library Validation.
    sdkBuild = runtime / 'DerivedData'
    # Do not inherit the host target's Xcode build-service/environment settings.
    # A nested invocation otherwise uses host tool paths and may crash its service.
    env = {key: value for key, value in os.environ.items() if key in {
        'PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR',
        'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY'}}
    with (workspace / 'build.log').open('w') as log:
        subprocess.run(['xcodebuild', '-project', str(source / 'Sparkle.xcodeproj'), '-scheme', 'Sparkle',
                        '-configuration', 'Release', '-derivedDataPath', str(sdkBuild), 'ARCHS=arm64',
                        'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO',
                        'SPARKLE_EMBED_DOWNLOADER_XPC_SERVICE=0', 'build'], stdout=log, stderr=subprocess.STDOUT,
                        env=env, check=True)
    stage = runtime / 'Signed/Sparkle.framework'
    if stage.parent.exists(): shutil.rmtree(stage.parent)
    stage.parent.mkdir()
    subprocess.run(['ditto', str(sdkBuild / 'Build/Products/Release/Sparkle.framework'), str(stage)], check=True)
    shutil.copy2(vendor / 'LICENSE', stage / 'Versions/B/Resources/BeeSaveSparkleLICENSE')
    sign_framework(stage, identity)
    if framework.is_symlink(): framework.unlink()
    elif framework.exists(): shutil.rmtree(framework)
    framework.symlink_to(stage, target_is_directory=True)
    stamp.write_text(fingerprint)
