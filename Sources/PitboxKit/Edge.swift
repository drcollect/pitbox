/// The screen edge the block sits at (alone) or the host's edge (docked). Its window side is the opposite one.
public enum Edge: String, Codable, Sendable, CaseIterable {
    case left, right
}
