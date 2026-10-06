"""Test Sparkle loading with an Apple certificate and Library Validation enabled."""
import argparse
import plistlib
import subprocess
import tempfile
from pathlib import Path
from sign_sparkle import sign_framework

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("framework", type=Path)
parser.add_argument("identity")
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="BeeSaveSparkleCertificate-"))
app = root / "CertificateProbe.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Frameworks").mkdir()
source = root / "probe.c"
source.write_text('''#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *framework = dlopen(argv[1], RTLD_NOW);
    if (!framework) { fprintf(stderr, "SPARKLE_LOAD_FAILED: %s\\n", dlerror()); return 1; }
    puts("SPARKLE_LOAD_OK");
    dlclose(framework);
    return 0;
}
''')
binary = contents / "MacOS" / "Probe"
subprocess.run(["xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=26.0", str(source), "-o", str(binary)], check=True)
info = dict(CFBundleExecutable="Probe", CFBundleIdentifier="com.beesave.update-probe", CFBundleName="BeeSave signing probe",
            CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="1.0", LSMinimumSystemVersion="26.0")
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
framework = contents / "Frameworks" / "Sparkle.framework"
subprocess.run(["ditto", str(args.framework), str(framework)], check=True)
sign_framework(framework, args.identity)
entitlements = Path(__file__).resolve().parent.parent / "App/BeeSave.entitlements"
assert not plistlib.loads(entitlements.read_bytes()).get("com.apple.security.cs.disable-library-validation", False)
subprocess.run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", "--timestamp=none",
                "--entitlements", str(entitlements), str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
result = subprocess.run([str(binary), str(framework / "Sparkle")], capture_output=True, text=True)
log = "exit=" + str(result.returncode) + "\n" + result.stdout + result.stderr
(root / "probe.log").write_text(log)
print(log, end="")
print("Evidence: " + str(root))
raise SystemExit(result.returncode)
