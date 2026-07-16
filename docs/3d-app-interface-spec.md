# 3D App Family: Interface Specification

Resolver, trays, and the binding between them. Companion to the UX benchmark and HIG brief. This is the build-facing document: it defines the shared selection taxonomy, the selection-to-tool resolver, both tray components, and the selection-sync layer that connects all of them.

Scope note. The operation and step tables below are populated for a representative direct-plus-parametric solid and mesh modelling member. They illustrate the pattern, they are not a claim about any one app. Each family member registers its own operation and step descriptors against the same resolver and the same tray components. Lighter members can omit the right tray entirely (see Part 3).

How the parts connect:

```
   Canvas pick ─┐
   Items tray ──┼──publish──▶  SelectionModel  ──signature──▶  Resolver ──▶ Tool strip
   History tray─┘                    │
                                     └──highlight + scroll──▶  Canvas, Items tray, History tray
```

One `SelectionModel` is the single source of truth. The resolver reads its signature to produce tools. The trays and canvas read it to highlight. All three surfaces can write to it. Part 4 specifies the contract.

---

## Part 0. Shared vocabulary

### 0.1 Entity types

The taxonomy is extensible per family member. Baseline:

- **Document scope:** Project, Workspace (Modeling, Visualization, Drawing), Drawing, RenderScene.
- **Containers:** Folder, Component (a named group of bodies and sketches that can be instanced).
- **Geometry:** Body (BREP solid or sheet), Surface, Mesh (polygon), Curve, PointCloud.
- **Construction:** Plane, Axis, Point.
- **Reference:** Image.
- **Sub-entities (selectable parts of geometry):** Face, Edge, Vertex for BREP; MeshFace, MeshEdge, MeshVertex for mesh; SketchCurve, SketchPoint, SketchConstraint for sketches.

### 0.2 Selection states

The resolver and the trays both key off the same five states:

1. **Empty.** Nothing selected.
2. **Single.** One entity of type T.
3. **Homogeneous multi.** N entities, all type T.
4. **Heterogeneous multi.** Mixed types.
5. **Related multi.** A homogeneous or mixed set carrying a relationship flag that unlocks specific operations (two faces on different bodies, two closed profiles, an edge loop, coplanar faces).

### 0.3 Selection signature

The signature is the hashable summary the resolver consumes:

- `counts`: map of EntityType to count.
- `relationships`: flags such as `sameBody`, `differentBodies`, `coplanar`, `closedProfile`, `edgeLoop`, `sharesPlane`.
- `workspace` and `mode`: gate which operations are valid at all.

Determinism rule: the same signature always yields the same resolved tool set. This is what lets muscle memory form across the family.

---

## Part 1. Selection-to-tool resolver

### 1.1 What it is

A pure function. Given a selection signature and a context (workspace, mode, registered operations), it returns an ordered tool set: a primary operation that may auto-activate, a visible suggested strip, and an overflow set reachable through More or the command palette.

It is data-driven. Operations are not hardcoded per selection. Each operation declares a predicate over the signature, and the resolver evaluates all registered operations against the current selection, filters to the applicable ones, ranks them, and picks a default. Adding a tool means registering a descriptor, not editing the resolver.

### 1.2 Operation descriptor

```swift
struct OperationDescriptor {
    let id: OperationID
    let label: String
    let icon: SymbolName
    let group: OperationGroup           // create, sketch, modify, transform, boolean, pattern, annotate
    let accepts: (SelectionSignature) -> Bool   // applicability predicate
    let rank: Int                       // static priority, lower is higher
    let activation: Activation          // .autoGizmo(GizmoKind) | .openTool | .immediate
    let producesHistoryStep: Bool
    let workspaces: Set<Workspace>
    let modes: Set<EditMode>
}

struct ResolvedToolSet {
    let primary: OperationDescriptor?   // may auto-activate per its `activation`
    let visible: [OperationDescriptor]  // surfaced strip, count capped per device
    let overflow: [OperationDescriptor] // behind More, and palette-filtered to selection
}

func resolve(_ s: SelectionSignature, registry: [OperationDescriptor]) -> ResolvedToolSet
```

### 1.3 Ranking

Applied in order:

1. **Workspace and mode gate.** Drop anything not valid in the current workspace or mode.
2. **Applicability.** Keep operations whose `accepts(signature)` is true.
3. **Specificity.** An operation that exactly matches the selection type ranks above a general one. Fillet on a selected edge outranks Delete.
4. **Static rank.** Designer-assigned priority within group.
5. **Recency, capped.** Optional. May reorder the overflow only. The visible strip stays stable for a given signature so the layout never feels arbitrary. Do not let frequency churn the top slots.

### 1.4 Activation

- `.autoGizmo`: the primary operation activates immediately and draws its gizmo on the geometry. Commit by tapping empty space, cancel by Escape, back gesture, or two-finger tap.
- `.openTool`: surfaces the tool but waits for explicit tap.
- `.immediate`: one-shot, no gizmo (Delete, Hide).

Only assign `.autoGizmo` where the default is unambiguous and reversible, so selecting never destroys or commits without intent.

### 1.5 Reference resolution table

Visible strip capped at roughly 5 on iPhone, 7 on iPad, more on Mac. Everything else falls to overflow. Auto-activating primaries marked with a dot.

| Selection | Primary (• auto) | Visible suggested | Overflow / palette |
| --- | --- | --- | --- |
| Empty (Modeling) | none | Sketch, Primitive, Import | Plane, Axis, Image, Paste |
| Vertex (1) | none | Move, Chamfer vertex, Measure | Coincident, Delete |
| Edge (1) | • Fillet/Chamfer (drag) | Fillet, Chamfer, Move edge, Split edge | Measure, Select loop, Delete |
| Edges (N) | • Fillet (drag) | Fillet, Chamfer, Bridge | Variable fillet, Delete, Measure |
| Edge loop | none | Fillet loop, Offset, Bridge | Convert to sketch, Delete |
| Face (1) | • Push/Pull (gizmo) | Offset, Move face, Sketch on face, Delete face | Draft, Replace, Split, Extract surface |
| Faces (N, same body) | • Push/Pull | Offset, Shell (remove these), Combine | Draft, Delete, Measure |
| Faces (2, different bodies) | none | Align, Replace face | Measure gap, Match orientation |
| Coplanar faces | none | Merge, Sketch on, Offset | Extract, Delete |
| Body (1, BREP) | • Move/Rotate (gizmo) | Scale, Copy, Shell, Material, Sketch on | Mirror, Split, Convert to mesh, Export |
| Bodies (N) | none | Union, Subtract, Intersect, Align | Pattern, Group to component, Move |
| Sketch (1) | • Extrude (drag) | Extrude, Revolve, Edit sketch, Offset | Sweep, Project, Thicken |
| Sketches (2+) | none | Loft, Sweep (profile + path) | Boundary surface, Align |
| Sketch curve | none | Trim, Extend, Offset, Constrain | Fillet 2D, Split, Convert |
| Mesh body (1) | • Move/Rotate | Remesh, Decimate, Smooth, Convert to BREP | Scale, Mirror, Material, Export |
| Mesh faces (N) | none | Extrude, Inset, Subdivide, Delete | Bridge, Flip normals |
| Plane | none | Sketch on, Mirror about, Section view | Offset plane, Reorient, Delete |
| Axis | none | Revolve about, Circular pattern, Measure | Reorient, Delete |
| Point | none | Move, Place primitive, Measure | Constrain, Delete |
| Image | none | Reposition, Set opacity, Lock | Calibrate scale, Trace, Delete |
| Heterogeneous mix | none | Move, Group, Hide, Delete | Measure, Align, Export selection |

The heterogeneous row is the floor: when types are mixed, fall back to the intersection of universally applicable operations. Never show an operation that would silently act on only part of the selection.

---

## Part 2. Left tray: structure

The left tray answers "what is in this model". Two stacked components: the workspace switcher and the items browser. It is a selection surface, not a read-only list.

### 2.1 Workspace switcher

- Segmented control or compact list: Modeling, Visualization, Drawing.
- Switching changes the canvas purpose, the valid operation set (via the resolver workspace gate), and which trays are relevant. Drawing hides the right history tray and shows sheet structure instead.
- Doubles as CRUD for the workspace's documents: add, rename, duplicate, delete drawings or render scenes.
- State: `activeWorkspace`, persisted per project.

### 2.2 Items browser

- **Hierarchy:** Folder and Component containers nest Bodies, Sketches, Construction geometry, Meshes, Images. Disclosure chevrons expand containers.
- **Row anatomy:** type icon, name (inline editable on double-tap or F2), visibility toggle (eyeball), optional lock, trailing context affordance.
- **Filter bar:** All Items dropdown filters to one type. Text search within the project.
- **Multi-select:** tap, shift-tap range, cmd or ctrl tap to add. The resulting set publishes to `SelectionModel` and drives the resolver, identical to a canvas pick.
- **Drag:** reorder within a container, drag into folders, drag out.
- **Overflow (three dots):** Show Hidden Items, Expand all, Collapse all, Sort by name or type or creation order.
- **Reveal in Items:** a canvas context-menu command that scrolls the tray to the picked entity and flashes its row.

### 2.3 States

Collapsed to an icon rail, expanded, width-adjustable. Empty state with a create prompt. Filtered state. Search-active state. Multi-select state. Drag-reorder state with valid and invalid drop targets.

### 2.4 Per-entity exposure

| Entity | Row shows | Inline | Context menu | Notes |
| --- | --- | --- | --- | --- |
| Folder | name, child count, chevron | visibility (cascades), rename | New subfolder, Ungroup, Delete | Visibility cascades to children |
| Component | name, chevron, instance badge | isolate, visibility | Dissolve, Make unique, Rename | Instanced edits propagate |
| Body (BREP) | name, solid/sheet icon, eyeball, lock | rename, hide | Isolate, Move to folder, Copy, Material, Delete | Selecting feeds resolver Body row |
| Mesh | name, poly-count badge, eyeball | rename, hide | Remesh, Decimate, Convert to BREP, Delete | Poly count is a health signal |
| Sketch | name, eyeball | edit sketch, hide | Used by (jumps to history steps), Delete | Used-by links to the right tray |
| Plane / Axis / Point | name, eyeball | rename | Sketch on (plane), Reorient, Delete | Hidden by default, toggle to show |
| Image | name, eyeball, opacity inline | reposition, lock | Calibrate scale, Trace, Delete | Opacity edits are non-destructive |
| Drawing (Drawing ws) | name, sheet size | open, rename | Duplicate, Delete | Lives in the Drawing workspace list |
| RenderScene (Visualization) | name, thumbnail | open | Duplicate, Delete | Appearance state, not geometry |

---

## Part 3. Right tray: process and history

The right tray answers "how it was built". It is the construction graph: an ordered timeline of feature steps that produced the geometry. It is the part graph made directly editable.

Optional by design. Closed, the app is in pure direct-modelling mode. Open, it is parametric. The state persists per project. Family members with no construction sequence (a mesh viewer, a measurement tool) omit the right tray entirely, and the architecture treats it as a module, not a fixture. When present it behaves identically across the family.

### 3.1 Step card

- **Collapsed:** type icon, name (inline editable, defaults to a generic like `fillet034` and should be renamed), status indicator (ok, warning, error, suppressed), drag handle.
- **Expanded:** the feature's parameters, editable in place. The card is the editor, so there is no separate properties dialog. Below the parameters, the inputs it consumes (links to the entities, selectable) and the outputs it produces.
- **Parameter edits propagate.** Change an upstream value and downstream steps rebuild. Show a rebuild indicator while recomputing.

### 3.2 Graph editing

- **Reorder:** drag a step up or down. Order changes the result (move a cut above a shell and the wall shells around the cut). Validate against dependencies: a step cannot move before its inputs exist. Mark invalid drops, do not allow the drop.
- **Breakpoint:** insert via context menu, rolls the model back to that point and suppresses everything after it. Drag the breakpoint bar to move the rollback point. Edit upstream, then move the breakpoint down to reapply. Non-destructive time travel.
- **Suppress:** toggle a single step off without deleting it.
- **Diagnostics:** if a reorder or parameter change breaks a downstream step, flag the failing step, show the cause, and offer to revert the change.

### 3.3 Step context menu (three dots)

Rename, Edit, Suppress or Unsuppress, Insert breakpoint, Roll to here, Show dependencies, Delete.

### 3.4 States

Closed (direct mode), open, step-collapsed, step-expanded, rolled-back (breakpoint active), rebuilding, error. Reordering with valid and invalid drop indication.

### 3.5 Per-step exposure

| Step | Card (collapsed) | Editable params | Consumes | Produces |
| --- | --- | --- | --- | --- |
| Sketch | sketch icon, plane name | plane or face, edit-sketch | Plane or Face | Sketch curves |
| Extrude | direction arrow | distance, direction, taper, op (new/add/cut) | Sketch or Face | Body |
| Revolve | angle badge | angle, axis | Sketch + Axis | Body |
| Fillet | radius badge | radius, edge list | Edges | Modifies body |
| Chamfer | setback badge | setback, edges | Edges | Modifies body |
| Shell | thickness badge | thickness, removed faces | Body + Faces | Modifies body |
| Boolean | op icon | operation, operands | Bodies | Body |
| Pattern | count badge | count, spacing or angle, axis | Body + Axis | Bodies |
| Mirror | plane icon | plane | Body + Plane | Body |
| Loft / Sweep | profile count | profiles, path, guides | Sketches | Body |
| Transform | vector badge | translation, rotation | Body | Modifies body |
| Mesh op | type icon | target count or ratio | Mesh | Modifies mesh |

Appearance and material are deliberately not history steps. They are attributes attached to a body, set in Visualization, and they do not participate in the construction graph. This keeps the DAG geometric and the history readable.

---

## Part 4. Canvas-to-tree binding

The selection-sync layer. This is the connective tissue between the resolver and the two trays, and the thing that makes the trays live surfaces rather than dead lists.

### 4.1 Single source of truth

```swift
@Observable
final class SelectionModel {
    private(set) var selection: Selection          // entities + sub-entities
    var signature: SelectionSignature { /* derived */ }

    func select(_ items: [EntityRef], from source: SelectionSource)
    func add(_ items: [EntityRef], from source: SelectionSource)
    func clear(from source: SelectionSource)
}

enum SelectionSource { case canvasPick, itemsTray, historyTray, command }
```

- The resolver subscribes to `signature` and recomputes `ResolvedToolSet` on every change.
- The Items tray subscribes: highlight and scroll-into-view the matching rows.
- The History tray subscribes: highlight the step that produced the selected geometry.
- The canvas subscribes: draw selection highlights and the primary gizmo.

### 4.2 Bidirectional flow

Selection can originate from any surface and every surface reflects it:

- **Canvas pick** to all trays: pick geometry, both trays highlight and scroll. This is Reveal in Items and Reveal in History happening automatically.
- **Items row tap** to canvas and history: selects the entity, canvas highlights, history highlights the creating step.
- **History step tap** to canvas and items: selects that step's output geometry.
- **Command or API** to all: a palette command or script can set selection, and all surfaces follow.

The `from source` parameter prevents feedback loops: a surface ignores change notifications it originated.

### 4.3 Hover preview

On pointer or Pencil hover over a tray row, preview-highlight the entity in the canvas without committing selection. Releases on hover-out. This gives fast scanning without disturbing the active selection or the resolved tool set.

### 4.4 SwiftUI mapping

- `SelectionModel` is `@Observable`, injected into the environment.
- The resolver is a pure function, recomputed in a derived property or a small view model observing `signature`.
- The tool strip, both trays, and the canvas overlay are views observing the model. No surface owns selection state, they all read and write the one model.

---

## Part 5. Handoff notes and open decisions

### 5.1 Persistent sub-entity identity: BRepGraph

The right tray's reorder, edit, and breakpoint behaviour all assume an edge or face keeps a stable identity across rebuilds: when an upstream parameter changes and the body recomputes, the fillet that referenced an edge has to find the same edge again. This is the topological naming problem, and it is handled at the kernel layer by OCCT 8's BRepGraph rather than left to the UI.

BRepGraph is a graph-based, mutation-aware representation of BRep topology, complementary to TopoDS_Shape, with roundtrip conversion to and from it. The facilities the tray depends on:

- **Typed node identifiers (BRepGraph_NodeId).** Stable handles for faces, edges and vertices. A history step stores node IDs for the geometry it consumes, not transient TopoDS pointers, so a reference survives recompute.
- **Mutation tracking and History.** The graph is mutation-aware and tracks history, so an edit propagates through dependents with identities preserved, which is exactly the propagation the right tray visualises.
- **Bidirectional traversal with O(1) reverse indices.** Edge-to-face and vertex-to-edge are direct lookups, which makes the canvas-to-tree binding (Part 4) and Show dependencies cheap.
- **EditorView and roundtrip to TopoDS_Shape.** Edits run against the graph, then convert back so the rest of the OCCT algorithm set still applies.

Implication for the tray: a step's Consumes references (Part 3.5) are BRepGraph node IDs. Show dependencies and reorder validation read the graph's parent and child explorers directly. Direct-mode-only members that never recompute can skip this, another reason the right tray is a module.

Note: BRepGraph shipped in OCCT 8.0 and its API is recent, so pin the version and treat class and method names as subject to minor change across point releases.

### 5.2 Open decisions

- **Direct edits in hybrid mode.** Do direct manipulations always create history steps, or can some be fast and ephemeral. Recommend: record them as steps so history stays complete, with a setting for users who want pure direct mode.
- **Resolver personalization.** How much recency reordering, if any. Recommend: overflow only, visible strip frozen per signature.
- **Reorder strictness.** How aggressively to block dependency-violating drops versus allowing them and flagging the break. Recommend: block hard violations, flag soft ones.
- **Gizmo defaults.** Which selections earn `.autoGizmo`. Recommend: only Body, Face, Edge, and Sketch primaries, where the default is unambiguous and reversible.
- **Tray presence per family member.** Confirm which members ship the right tray at all. Lighter tools take the left tray only.

### 5.3 What design receives from this

- The resolution table (Part 1.5) as the layout contract for the dynamic tool strip, per selection signature.
- Both per-type exposure tables (Parts 2.4 and 3.5) as the row and card content contracts.
- The state lists (Parts 2.3 and 3.4) as the screens to design.
- The binding contract (Part 4) as the interaction model the prototype must honour, so selecting anywhere highlights everywhere.
