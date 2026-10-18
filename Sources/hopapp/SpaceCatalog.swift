import CoreGraphics
import Foundation
import Darwin

final class SpaceCatalog {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias WindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    // Keep the framework loaded for the lifetime of the resolved function pointers.
    private static let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private let connection: Connection?
    private let displays: Displays?
    private let currentSpace: CurrentSpace?
    private let windowSpaces: WindowSpaces?

    init() {
        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            guard let framework = Self.framework, let symbol = dlsym(framework, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        connection = resolve("SLSMainConnectionID", as: Connection.self)
        displays = resolve("SLSCopyManagedDisplays", as: Displays.self)
        currentSpace = resolve("SLSManagedDisplayGetCurrentSpace", as: CurrentSpace.self)
        windowSpaces = resolve("SLSCopySpacesForWindows", as: WindowSpaces.self)
    }

    func visibleSpaces() -> Set<UInt64>? {
        guard let connection, let displays, let currentSpace,
              let values = displays(connection())?.takeRetainedValue() as? [String], !values.isEmpty else { return nil }
        var spaces = Set<UInt64>()
        for display in values {
            let space = currentSpace(connection(), display as CFString)
            guard space != 0 else { return nil }
            spaces.insert(space)
        }
        return spaces
    }

    func spaces(for window: CGWindowID) -> Set<UInt64>? {
        guard let connection, let windowSpaces,
              let values = windowSpaces(connection(), 0x7, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber], !values.isEmpty else { return nil }
        let spaces = Set(values.map(\.uint64Value))
        return spaces.contains(0) ? nil : spaces
    }

    func isOnVisibleSpace(_ window: CGWindowID, visibleSpaces: Set<UInt64>?) -> Bool? {
        Self.isOnVisibleSpace(windowSpaces: spaces(for: window), visibleSpaces: visibleSpaces)
    }

    static func isOnVisibleSpace(windowSpaces: Set<UInt64>?, visibleSpaces: Set<UInt64>?) -> Bool? {
        guard let visibleSpaces, !visibleSpaces.isEmpty, !visibleSpaces.contains(0),
              let windowSpaces, !windowSpaces.isEmpty, !windowSpaces.contains(0) else { return nil }
        return !windowSpaces.isDisjoint(with: visibleSpaces)
    }
}
