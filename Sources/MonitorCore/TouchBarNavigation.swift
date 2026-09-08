import Foundation

/// Navigation lives on the Touch Bar: overview -> step list -> step content.
public struct TouchBarNavigation {
    public enum Mode: String { case overview, steps, content }
    public private(set) var mode: Mode = .overview
    public private(set) var taskID: String?
    public private(set) var steps: [ExecutionStep] = []
    public private(set) var start = 0
    public private(set) var followsLatest = true
    public private(set) var selectedID: String?
    public let pageSize = 3
    public init() {}
    public var visible: [ExecutionStep] { Array(steps.dropFirst(start).prefix(pageSize)) }
    public var selected: ExecutionStep? { steps.first { $0.id == selectedID } }
    public var canPrevious: Bool { start > 0 }
    public var canNext: Bool { start + pageSize < steps.count }
    public mutating func enter(taskID: String) {
        self = TouchBarNavigation(); self.taskID = taskID; mode = .steps
    }
    public mutating func update(_ items: [ExecutionStep]) {
        let anchor = visible.first?.id
        steps = items
        if followsLatest { start = max(0, steps.count - pageSize) }
        else if let anchor, let index = steps.firstIndex(where: { $0.id == anchor }) { start = index }
        else { start = min(start, max(0, steps.count - pageSize)) }
        if mode == .content && selected == nil { mode = .steps; selectedID = nil }
    }
    public mutating func previous() { followsLatest = false; start = max(0, start - pageSize) }
    public mutating func next() {
        start = min(max(0, steps.count - pageSize), start + pageSize)
        followsLatest = !canNext
    }
    public mutating func latest() { mode = .steps; selectedID = nil; followsLatest = true; start = max(0, steps.count - pageSize) }
    public mutating func open(_ id: String) {
        guard steps.contains(where: { $0.id == id }) else { return }
        selectedID = id; mode = .content; followsLatest = false
    }
    public mutating func back() {
        if mode == .content { mode = .steps; selectedID = nil }
        else { self = TouchBarNavigation() }
    }
}
