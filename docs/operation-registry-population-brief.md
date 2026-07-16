# Operation Registry: Population Brief

A brief for a Claude Code session. The goal is to populate the operation registry that feeds the selection-to-tool resolver. This document tells you how to do it. It does not contain the registry itself, that is the output of the session.

Read first: `3d-app-interface-spec.md`, Part 1 (the resolver and the `OperationDescriptor` shape) and Part 1.5 (the reference resolution table). That table is the specification and the test oracle for this work.

---

## 1. What you are building, and what you are not

Building: a set of `OperationDescriptor` values, one per distinct operation, plus a small reusable predicate library and a test suite. The descriptors are pure data the resolver consumes.

Not building: the resolver function itself (exists), the trays, the gizmos, the geometry operations they trigger. This is the data layer and its tests only.

Output of the session:

- A composable predicate library (`SelectionPredicates`).
- One descriptor per operation, grouped into files by `OperationGroup`.
- A registry assembler that collects descriptors, and a per-member composition point.
- A snapshot test suite that runs the resolver against every signature in Part 1.5 and asserts the result.

---

## 2. The key move: invert the table

Do not transcribe Part 1.5 row by row. Each row is a selection signature, but an operation (Fillet, Move, Offset) appears across many rows. If you write per-row you will duplicate operations and the ranking will drift.

Instead:

1. Enumerate the distinct operations across the whole table. Fillet, Chamfer, Move, Offset, Push/Pull, Extrude, Revolve, Boolean union, and so on.
2. For each operation, write one descriptor whose `accepts` predicate is true for exactly the signatures where that operation should appear, and whose `rank` places it correctly within those rows.
3. Verify by running the resolver against each signature in the table and checking the surfaced set matches. The table is the oracle, the descriptors are the implementation, the tests close the loop.

This inversion is the whole job. One operation, one predicate, one rank, validated against many rows.

---

## 3. The predicate library

Write `accepts` predicates as compositions of small named builders, not ad-hoc closures. This keeps them readable, reusable, and testable. Build at least:

- `empty` : nothing selected.
- `single(_ type: EntityType)` : exactly one of a type.
- `homogeneous(_ type: EntityType, min: Int = 2)` : N of one type.
- `count(_ type: EntityType, _ range: ClosedRange<Int>)` : bounded count.
- `relationship(_ flag: RelationshipFlag)` : a relationship flag is set (`differentBodies`, `coplanar`, `closedProfile`, `edgeLoop`, `sharesPlane`).
- `anyOf(_ predicates:)`, `allOf(_ predicates:)`, `not(_ predicate:)` : combinators.

Then operation predicates read declaratively, for example:

- Fillet accepts `anyOf(single(.edge), homogeneous(.edge), relationship(.edgeLoop))`.
- Replace face accepts `allOf(count(.face, 2...2), relationship(.differentBodies))`.
- Loft accepts `homogeneous(.sketch, min: 2)`.

Predicates read the `SelectionSignature` only (counts, relationships, workspace, mode). They never touch live geometry. This is what keeps the resolver pure and the tests fast.

---

## 4. Filling each descriptor field

| Field | How to fill it |
| --- | --- |
| `id` | Stable identifier, reverse-dotted, lower case, never reused: `modify.fillet`, `transform.move`, `boolean.subtract`. The id is permanent, the label is not. |
| `label` | Short, sentence case, Australian English. The on-screen name. |
| `icon` | SF Symbol name. Pick from the system set first, fall back to a custom symbol only where none fits. Keep one icon per operation across all members. |
| `group` | One of: create, sketch, modify, transform, boolean, pattern, annotate. Drives banding (see rank). |
| `accepts` | A predicate from the library in section 3. |
| `rank` | See section 5. |
| `activation` | See section 6. |
| `producesHistoryStep` | True if the operation mutates geometry and should appear in the right tray. False for view, selection, measure, and hide operations. Operations that consume sub-entities reference BRepGraph node IDs in their history inputs (spec Part 5.1). |
| `workspaces` | The set where the operation is valid. Modeling for most, Drawing for annotate and dimension, Visualization for material and appearance. |
| `modes` | Gate by edit mode where the member has modes (a sculpt mode exposes brush operations, a parametric mode exposes feature operations). Default to all modes if the member is single-mode. |

---

## 5. Ranking convention

`rank` is an integer, lower is higher priority. Reserve a band per group so groups never interleave by accident:

- create 0 to 99
- sketch 100 to 199
- modify 200 to 299
- transform 300 to 399
- boolean 400 to 499
- pattern 500 to 599
- annotate 600 to 699

Within a band, seed the order from the left-to-right order of the visible column in Part 1.5. The operation that appears first in the visible list for its most specific selection gets the lowest rank in its band. The resolver applies specificity before rank (spec Part 1.3), so rank only breaks ties within equally specific operations. Do not try to encode specificity in rank, let the resolver do it.

---

## 6. Activation rules

From spec Part 1.4. Assign:

- `.autoGizmo(kind)` only to the primary operations of Body, Face, Edge, and Sketch selections, where the default is unambiguous and reversible. Body to move gizmo, Face to push-pull gizmo, Edge to fillet drag, Sketch to extrude drag.
- `.openTool` to everything else that opens an interaction.
- `.immediate` to one-shot operations with no gizmo: Delete, Hide, Isolate.

Never assign `.autoGizmo` to anything destructive or anything that commits without a clear undo.

---

## 7. File and assembly structure

```
OperationRegistry/
  Predicates/
    SelectionPredicates.swift      // section 3
  Descriptors/
    CreateOps.swift
    SketchOps.swift
    ModifyOps.swift
    TransformOps.swift
    BooleanOps.swift
    PatternOps.swift
    AnnotateOps.swift
  Registry.swift                   // collects all descriptors
  Members/
    <MemberName>Registry.swift     // composes the subset this member ships
  Tests/
    ResolverSnapshotTests.swift    // section 8
```

`Registry.swift` exposes the full descriptor set. Each member in `Members/` selects the subset it ships, by group or by id. A mesh-only member omits the BREP modify group, a viewer omits everything that produces history steps. The resolver is the same everywhere, only the registered set differs.

---

## 8. Tests: the table is the oracle

Write one snapshot test per row of Part 1.5. For each, build the selection signature, call `resolve(signature, registry: fullRegistry)`, and assert:

- `primary?.id` matches the expected primary, and its `activation` is `.autoGizmo` where the table marks the dot.
- `visible.map(\.id)` matches the expected visible set, in order, capped at the device count.
- Every expected overflow id is present in `overflow`.
- The heterogeneous-mix row returns only universally applicable operations, and nothing that would act on part of the selection.

These tests are the definition of correct. If a predicate is too broad an operation leaks into rows it should not, if too narrow it goes missing, and the snapshot catches both. Run them as you add each descriptor, not at the end.

Add a determinism test: resolve the same signature twice and assert identical output, so no recency or frequency logic ever reaches the visible strip (spec Part 1.3).

---

## 9. Order of work

1. Predicate library and its unit tests.
2. The snapshot test harness, with the Part 1.5 table encoded as expected values, all failing initially.
3. Descriptors group by group, create through annotate, running the snapshot suite after each group until its rows pass.
4. The registry assembler and one member composition.
5. The determinism test.

---

## 10. Definition of done

- Every distinct operation in Part 1.5 has exactly one descriptor.
- Every row of Part 1.5 passes its snapshot test.
- The determinism test passes.
- Predicates are library compositions, no ad-hoc closures.
- Ranks sit inside their group bands.
- `producesHistoryStep` is set correctly, and sub-entity-consuming operations are noted as referencing BRepGraph node IDs for the right-tray work that follows.
- At least one member composition exists and resolves a sensible subset.

---

## 11. Out of scope, for the avoidance of doubt

The resolver function, the tool strip view, both trays, the gizmos, and the geometry operations themselves. This session produces descriptors, predicates, an assembler, and tests. Nothing that touches live geometry or draws UI.
