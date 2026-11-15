# Security Review

Review scope: iLiDAR iOS client and Python capture server at commit `66cd476`.

This review did not modify application code. Findings are listed with recommended remediations for a follow-up implementation.

| # | Severity | File | Lines | Vulnerability | Confidence |
|---|----------|------|-------|---------------|------------|
| 1 | 🟡 MEDIUM | `Server/ios_driver.py` | 30, 169–209, 225–238 | No authentication; client chooses file name and type; existing files are overwritten | 8/10 |
| 2 | 🟡 MEDIUM | `Network/CocoaAsyncSocketHandler.m`; `Server/ios_driver.py` | 30–56, 68–75; 229–231 | Frames are sent over plain TCP and the app does not authenticate the server | 8/10 |
| 3 | ⚪ LOW | `Network/DataStorage.swift`; `iLiDAR/Views/ContentView.swift` | 24–39; 66–74, 388–407 | Auto-connect to hardcoded `10.129.164.22:5678`; quick-bar Transfer control is not gated on connection | 7/10 |
| 4 | ⚪ LOW | `Server/ios_driver.py` | 176, 182, 199 | Client-controlled file names are printed unescaped, enabling terminal escape injection | 7/10 |
| 5 | ⚪ LOW | `Server/requirements.txt`; `Server/read_depth_data.py` | 1–4; 92 | Outdated dependency floors; image loader accepts formats other than JPEG | 6/10 |
| 6 | ⚪ LOW | `iLiDAR/Info.plist` | 9–10 | `NSAllowsArbitraryLoads` disables App Transport Security app-wide | 8/10 |
| 7 | ⚪ LOW | `Podfile` | 6–7 | Unused AFNetworking 4.0.1 and ReactiveCocoa dependencies are linked | 8/10 |
| 8 | 🟡 MEDIUM | `Server/ios_driver.py` | 94–98, 137–156, 184, 236–238 | Unbounded packet buffering, incomplete-file state, and per-connection threads permit denial of service | 8/10 |

## Details and recommended fixes

### 1. Unauthenticated uploads and overwrite

The server listens on all interfaces. Any reachable client can upload files using a chosen name and data type. `basename` prevents directory traversal, but the selected extension is never used and opening with `wb` overwrites an existing file.

**Recommendation:** require an access token over TLS; allow only app-generated file-name characters; derive the extension from the packet type; create files exclusively (`xb`); optionally restrict listening and client IPs.

### 2. Cleartext, unauthenticated transport

The iOS client sends frames and calibration data over plain TCP and reports a successful connection immediately after TCP connects. A network-adjacent attacker can observe the stream or impersonate the server.

**Recommendation:** use TLS 1.2 or newer and authenticate the server with a pinned certificate fingerprint. Authenticate clients with a pairing token and mark the connection established only after the server accepts it.

### 3. Hardcoded auto-connect

`DataStorage` initiates a connection to `10.129.164.22:5678` on initialization, and that host is also seeded as “Lab Computer.” Frames are sent only when network transfer is enabled, but the quick-bar Transfer button is active while disconnected; a user can enable transfer without selecting a server.

**Recommendation:** remove startup auto-connect and seeded hosts, require explicit server selection and credentials, and disable transfer until connected.

### 4. Unescaped log output

An untrusted upload name is interpolated directly into terminal logs, allowing crafted control characters to rewrite or hide output.

**Recommendation:** log the name using a representation that escapes control characters, such as Python's `!r` formatting.

### 5. Dependency and image-format hardening

The declared minimum versions permit old dependency versions. The image reader lets Pillow sniff the format rather than requiring JPEG. Pillow versions before 10.0.1 are affected by CVE-2023-4863; the suggested floors below are based on known advisories, not a live OSV query.

**Recommendation:** verify current advisories with `pip-audit -r Server/requirements.txt`, raise dependency minimums based on that output, and open color images with `formats=["JPEG"]`.

### 6. App Transport Security disabled

`NSAllowsArbitraryLoads` relaxes App Transport Security for the entire app. The current network stream uses raw sockets, which ATS does not govern, so this is a low-risk hardening issue rather than a direct protection for that stream.

**Recommendation:** remove the setting unless an HTTP feature has a documented need for it.

### 7. Unused pods

The Podfile links AFNetworking and ReactiveCocoa, but the application source has no imports or usage of either.

**Recommendation:** remove both dependencies and update the tutorial's Podfile sample.

### 8. Server resource exhaustion

The packet header permits payload sizes up to 4 GiB, and the server grows an immutable `bytes` buffer as data arrives. Invalid UTF-8 headers return without clearing the buffer. Incomplete files remain in per-client state, and the accept loop creates an unbounded thread for every connection. A local check showed that buffering 32 MiB this way took about 47 seconds.

**Recommendation:** enforce packet, per-file, and per-connection buffer limits; reject malformed headers and close the connection; use a mutable buffer; expire incomplete transfers; limit concurrent clients and add timeouts.

## Verification limitations

- The OSV advisory lookup was blocked twice. The dependency vulnerability status and proposed floors have not been independently verified; run `pip-audit` locally.
- The attempted comparison of vendored CocoaAsyncSocket code with upstream tag 7.6.5 was blocked. The vendored source integrity remains unverified; compare `Pods/CocoaAsyncSocket/Source` to that upstream tag.
- No application fixes or tests were applied as part of this review.
