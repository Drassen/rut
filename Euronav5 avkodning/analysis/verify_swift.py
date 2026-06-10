"""Compile Euronav5Encoder.swift + harness with swiftc and byte-verify the
Swift export against all reference sets. Run: python3 verify_swift.py"""
import subprocess, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
ENCODER = os.path.join(HERE, "../../Services/Export/Euronav5Encoder.swift")

import shutil
os.makedirs("/tmp/euronav5_h", exist_ok=True)
shutil.copy("swift_harness.swift", "/tmp/euronav5_h/main.swift")

r = subprocess.run(["swiftc", "-O", ENCODER, "/tmp/euronav5_h/main.swift",
                    "-o", "/tmp/euronav5_harness"], cwd=HERE)
if r.returncode:
    sys.exit("swiftc compilation failed")
sys.exit(subprocess.run(["/tmp/euronav5_harness"], cwd=HERE).returncode)
