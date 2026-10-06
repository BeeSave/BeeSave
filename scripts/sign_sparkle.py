"""Sign Sparkle's nested code before its framework, preserving helper entitlements."""
import argparse
import subprocess
from pathlib import Path


def sign_framework(framework, identity):
    if not identity or identity == "-":
        raise ValueError("An Apple certificate is required; ad-hoc is not enabled for BeeSave.")
    if framework.name != "Sparkle.framework" or not framework.is_dir():
        raise ValueError("Expected Sparkle.framework")
    code = []
    for path in framework.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in {".app", ".xpc", ".framework"}:
            code.append(path)
        elif path.is_file():
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic in {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}:
                code.append(path)
    code.append(framework)
    for path in sorted(code, key=lambda p: len(p.parts), reverse=True):
        subprocess.run(["codesign", "--force", "--sign", identity, "--options", "runtime",
                        "--timestamp=none", "--preserve-metadata=entitlements", str(path)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(framework)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("framework", type=Path)
    parser.add_argument("identity")
    args = parser.parse_args()
    sign_framework(args.framework, args.identity)
