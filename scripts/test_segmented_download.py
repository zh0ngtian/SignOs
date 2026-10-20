#!/usr/bin/env python3
"""Exercise production Range transfer, persistence and cancellation over real HTTP."""
import pathlib
import subprocess
import tempfile

from download_test_server import DownloadFixtureServer

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ["DownloadCheckpoint.swift", "DownloadTransferFailure.swift", "DownloadTransferStore.swift",
        "HTTPRangeTransfer.swift", "DownloadTransferLimiter.swift", "SegmentedDownloadEngine.swift"]


def main():
    with tempfile.TemporaryDirectory(prefix="signos-range-regression-") as directory:
        output = pathlib.Path(directory)
        binary = output / "SegmentedDownloadRegression"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
                        *[str(ROOT / "Feather/Backend/Download" / name) for name in CORE],
                        str(ROOT / "Tests/SegmentedDownloadRegression.swift"), "-o", str(binary)], check=True)
        server = DownloadFixtureServer().start()
        try:
            subprocess.run([str(binary), server.url, str(output / "transfers")], check=True, timeout=120)
            print("HTTP fixture verified parallel Range requests, cancellation and resumed byte intervals.")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
