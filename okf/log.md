---
type: log
title: Change log
description: Dated entries for durable changes to the bundle
timestamp: 2026-09-16
---

## 2026-09-16: Fix Metal toolchain 27 build failure (issue #120)

Added Metal toolchain installation step to CI workflow (`.github/workflows/tests.yml`) to address build failures on macOS 27 / Xcode 27 where the Metal toolchain is not installed by default.

The build fails with:
```
error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain
```

The fix runs `xcodebuild -downloadComponent MetalToolchain` as a CI step before `swift build`.

Build and all 217 tests pass on macOS 27 (Xcode 27) after this change.
