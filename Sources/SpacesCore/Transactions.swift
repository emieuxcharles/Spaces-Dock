import Foundation
public func applyTransaction<P, S>(prepare: () throws -> P, snapshot: () throws -> S, mutate: (P) throws -> Void, persist: (P) throws -> Void, restore: (S) throws -> Void) throws -> P {
    let plan = try prepare()
    let before = try snapshot()
    do { try mutate(plan); try persist(plan) }
    catch {
        let failure = error
        do { try restore(before) }
        catch { throw LayoutError.invalid("Échec de l’application et de la restauration : \(error.localizedDescription)") }
        throw failure
    }
    return plan
}
public struct OperationGeneration {
    public private(set) var value: UInt64 = 0
    public init() {}
    public mutating func invalidate() { value &+= 1 }
    public func accepts(_ token: UInt64) -> Bool { value == token }
}
public struct MoveReport {
    public var lines: [String] = []
    public var failed = 0
    public var skipped = 0
    public var verified = 0
    public var hasFailures: Bool { failed > 0 }
    public init() {}
}
