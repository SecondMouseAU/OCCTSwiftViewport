---
type: policy
title: Code style
description: Swift naming/API shape follows the Swift API Design Guidelines, formatting follows Google's Swift Style Guide via swift-format; docs/ is the single source of truth for design rationale, not a second copy of it. Rolled out gradually via an exemption manifest, not a big-bang sweep.
tags: [policy, style, swift, docs, agents]
timestamp: 2026-08-12
---

# Code style

**Naming and API shape** follow the
[Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) as-is.

**Swift formatting** follows [Google's Swift Style Guide](https://google.github.io/swift/),
enforced by `swift-format` (`.swift-format`: 100-column limit, 4-space indent, the ecosystem's
one deliberate divergence from Google's own 2-space default, chosen to avoid a repo-wide reformat
diff with no readability gain).

**No first-party C++ bridge exists in this repo.** `OCCTSwiftViewport` is a pure Metal/SwiftUI
viewport library with no OCCT dependency (see `okf/index.md`), so unlike `OCCTSwift`'s
`OCCTBridge` layer, there's no `clang-format` half to this policy here.

**SwiftLint is scoped to `orphaned_doc_comment` only** (`.swiftlint.yml`, `only_rules`, not the
default set). SwiftLint's defaults duplicate `swift-format`'s formatting opinions (can disagree
with them on the same line) and separately add a large code-quality/complexity surface
(`identifier_name`, `cyclomatic_complexity`, `function_body_length`, `nesting`, ...) that overlaps
[code-structure](code-structure.md) rather than this policy; a file that needs a structural pass
runs one as its own scoped initiative, not as a side effect of a style-lint gate.
`orphaned_doc_comment` catches something `swift-format` has no equivalent for, and found one real
finding on rollout day: a 63-line module-overview doc comment in `OCCTSwiftViewport.swift`
(possibly a deliberate DocC landing-page convention rather than a bug, since the file is named
after the module) not attached to any single declaration. Tracked as
[#96](https://github.com/SecondMouseAU/OCCTSwiftViewport/issues/96) rather than resolved inline,
since either fix (attaching it to a declaration, or trimming it toward `docs/` per this policy's
own single-source-of-truth rule below) is a real documentation-structure decision, not a
mechanical move. The file is named in `.swiftlint.yml`'s `excluded:` list until #96 lands.

**Doc comments stay terse.** A `///` comment is a single-sentence summary plus only the
`Parameter`/`Returns`/`Throws` tags that add something the summary doesn't already say. Design
rationale, extended examples, and issue cross-references belong in `docs/`, not duplicated in
source: `docs/` is the single source of truth for *why* and *how*, per
[GitLab's documentation style guide](https://docs.gitlab.com/development/documentation/styleguide/)
("share the link to the documentation instead of rephrasing the information").

## Gradual rollout: the exemption manifest, not a big-bang sweep

Unlike the ecosystem's pilot repo (`OCCTSwiftScripts`, small enough to sweep into full compliance
in one PR), this repo measured 1,503 pre-existing `swift-format` diagnostics across
`Sources/OCCTSwiftViewport` (52 files) on rollout day, so it uses the same gradual approach
`OCCTSwift` established:

- `scripts/style-manifest-swift.txt` lists every file that existed at rollout. A listed file is
  exempt from `swift-format` until touched.
- **If you touch a listed file, you fix it and remove it from the manifest in the same PR.**
  `scripts/check-style-manifest.py` (copied verbatim from `OCCTSwift`, including its fix for a
  seeding-vs-growing bug found via testing against real git history) enforces this mechanically:
  a manifest file appearing in a PR's diff while still listed at `HEAD` fails the build.
- The manifest only shrinks. A new file is never grandfathered onto it; new code complies from
  creation, checked by the same `swift-format`/SwiftLint steps running unconditionally against
  anything not already listed.

Why: the ecosystem-wide proposal and evidence live in
[`ecosystem` docs/code-style-policy-proposal-2026-08.md](https://github.com/SecondMouseAU/ecosystem/blob/main/docs/code-style-policy-proposal-2026-08.md).
Rollout sequencing (the OCCTMCP cluster, then `OCCTSwiftMesh`/`OCCTSwiftViewport`) is in that
document's §4. Filed and tracked as
[OCCTSwiftViewport#95](https://github.com/SecondMouseAU/OCCTSwiftViewport/issues/95).

Ecosystem standard: see
[OKF-STANDARD.md](https://github.com/SecondMouseAU/ecosystem/blob/main/OKF-STANDARD.md).
