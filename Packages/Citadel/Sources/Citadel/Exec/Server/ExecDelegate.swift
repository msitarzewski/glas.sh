import Foundation
import NIOConcurrencyHelpers

public protocol ExecCommandContext: Sendable {
    func terminate() async throws
    func inputClosed() async throws
}

extension ExecCommandContext {
    public func inputClosed() async throws { }
}

public struct ExecExitContext: Sendable {
    
}

public final class ExecOutputHandler: Sendable {
    public typealias ExitHandler = @Sendable (ExecExitContext) -> ()
    
    public let username: String?
    public let stdinPipe = Pipe()
    public let stdoutPipe = Pipe()
    public let stderrPipe = Pipe()
    
    private let _onExit = NIOLockedValueBox<ExitHandler?>(nil)
    var onExit: ExitHandler? {
        _onExit.withLockedValue { $0 }
    }
    let onSuccess: @Sendable (Int) -> ()
    let onFailure: @Sendable (Error) -> ()
    
    init(
        username: String?,
        onSuccess: @escaping @Sendable (Int) -> (),
        onFailure: @escaping @Sendable (Error) -> ()
    ) {
        self.username = username
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }
    
    public func succeed(exitCode: Int) {
        onSuccess(exitCode)
    }
    
    public func fail(_ error: Error) {
        onFailure(error)
    }
    
    public func onExit(_ handle: @escaping ExitHandler) {
        _onExit.withLockedValue { $0 = handle }
    }
}

public protocol ExecDelegate: AnyObject, Sendable {
    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext
    func setEnvironmentValue(_ value: String, forKey key: String) async throws
}
