/// How a body's authored per-element colours (`vertexColors`, `edgeColors`) are interpreted.
public enum AuthoredColorSpace: Sendable, Hashable, CaseIterable {
    /// Display (sRGB-encoded) values, drawn as given. The default.
    case sRGB
    /// Linear-light values; converted to display encoding when drawn.
    case linear
}
