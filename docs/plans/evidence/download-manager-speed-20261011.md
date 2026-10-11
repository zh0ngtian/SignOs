# Download manager regression and speed measurements — 2026-10-11

## Change and simulator validation

Repeated `startDownload` calls previously replaced a running task without canceling it.
The manager now retains running/canceling tasks, resumes suspended tasks in place,
and leaves completed transfers awaiting import alone. Resume data is consumed once.
The download is registered before its task starts. The source detail speed sampler
is retained with SwiftUI state and reset when a different download is observed.

`python3 scripts/test_download_manager_simulator.py 240244F5-0BEC-4553-A346-32F7D5AD34FC`
passed on iPhone 17 Pro, iOS 26.5. The harness compiles production
`DownloadManager.swift`, substitutes import/background integrations, and uses a
counting, throttled local HTTP server. It verifies eight repeated calls retain the
same task and progressing byte count, suspended/canceling/completed task handling,
cancellation, and the existing distinction between manual/source import intent.
Before the intent-separation test, the server observed exactly one slow transfer
and one completed transfer. The temporary test app is uninstalled after the run.

The full SignOs Debug app also built, installed and launched in this simulator.
For local simulator builds, `DEPLOYMENT_LOCATION=NO` avoids the project's
`_build/Applications` deployment symlink. OneViewPhase regression passed (6 checks).
No physical-device installation was attempted for this change.

## Complete IPA downloads

Asset: CodexMobile v0.2.151, 3,761,966 bytes. Original address:
https://github.com/zh0ngtian/codex-mobile/releases/download/v0.2.151/CodexMobile-v0.2.151-unsigned.ipa

The same production manager performed each transfer, with a fresh session per
sample. Each pair alternated original GitHub URL and its freshly resolved asset
URL. All responses were HTTP 200 and delivered the full expected file size.
Final host: `release-assets.githubusercontent.com`. Signed URLs were not retained.
Signing/import/UI work was excluded from the measured transfer time.

| Run | Route | Total seconds | MB/s (decimal) |
| --- | --- | ---: | ---: |
| 1 | GitHub Release | 7.366 | 0.511 |
| 2 | Resolved asset | 10.381 | 0.362 |
| 3 | GitHub Release | 22.238 | 0.169 |
| 4 | Resolved asset | 2.996 | 1.256 |
| 5 | GitHub Release | 4.425 | 0.850 |
| 6 | Resolved asset | 13.794 | 0.273 |
| 7 | GitHub Release | 4.842 | 0.777 |
| 8 | Resolved asset | 3.880 | 0.969 |

URLSession metrics from runs 5–8 reported HTTP/2 and no explicit proxy connection.
This flag does not rule out transparent routing/proxy software. Run 5's GitHub
transaction took about 0.720 seconds to first byte; the asset transaction took
1.634 seconds to first byte and 2.057 seconds to transfer its body. Run 6, without
redirection, took 0.514 seconds to first byte and 13.274 seconds for the body.
Run 7's GitHub transaction took 0.565 seconds to first byte; the asset transaction
took 0.928 seconds to first byte and 3.344 seconds for the body. Run 8 took
0.958 seconds to first byte and 2.912 seconds for the body.

A sequential Mac curl control delivered the same 3,761,966 bytes in 30.741 seconds
(0.122 MB/s), with 0.754 seconds in redirection, 1.583 seconds to first byte, one
redirect, and remote IP `198.18.1.58`. This is consistent with the earlier local
benchmark's address; it is not evidence of a proxy-free path.

## Interpretation and remaining limits

There is no stable speed advantage from bypassing the GitHub redirect in these
samples. Transfer-time variability dominates the small redirect cost; the
resolved CDN address can also be slow. Keep the durable GitHub release URL in
sources rather than persisting expiring signed addresses. HTTP/2 is already used.
These measurements do not justify a new proxy or range-parallel downloader for
this 3.76 MB asset.

Preventing duplicate live tasks removes a concrete cause of wasted bandwidth and
lost progress tracking when repeated requests occur. This test does not establish
that the user's earlier 17–21 KB/s event triggered that bug, nor quantify a
before/after speedup. The current simulator tests did not reproduce that low rate.
The speed sampler fix corrects view-state lifetime, not network throughput.

The simulator uses the Mac network path. The user's report that iPhone Safari is
fast remains useful but does not identify the exact reason SignOs was slower on
that phone. A physical-device app/Safari comparison under the same route and time
would still be needed to attribute that difference to routing or per-app behavior.
