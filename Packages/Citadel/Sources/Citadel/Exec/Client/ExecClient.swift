import Foundation
import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

final class ExecCommandCompletion: @unchecked Sendable {
    private let completed = NIOLockedValueBox(false)
    private let promise: EventLoopPromise<ByteBuffer>

    init(promise: EventLoopPromise<ByteBuffer>) {
        self.promise = promise
    }

    func succeed(_ value: ByteBuffer) {
        guard completed.withLockedValue({ completed in
            guard !completed else { return false }
            completed = true
            return true
        }) else { return }
        promise.succeed(value)
    }

    func fail(_ error: Error) {
        guard completed.withLockedValue({ completed in
            guard !completed else { return false }
            completed = true
            return true
        }) else { return }
        promise.fail(error)
    }
}

/// A channel handler that manages TTY (terminal) input/output for SSH command execution.
/// This handler processes both incoming and outgoing data through the SSH channel.
// NIO confines handler callbacks and mutable buffers to the channel event loop.
final class TTYHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    /// Maximum allowed size for command response data
    let maxResponseSize: Int
    /// Flag to indicate if input should be ignored (e.g., when response size exceeds limit)
    var isIgnoringInput = false
    /// Buffer to store the command's response data
    var response = ByteBuffer()
    /// Single-use completion shared with timeout and cancellation paths.
    let completion: ExecCommandCompletion
    /// Buffer to store error messages from stderr
    private var errorBuffer = ByteBuffer()
    /// Combined stdout and stderr bytes accepted so far.
    private var receivedByteCount = 0
    
    init(
        maxResponseSize: Int,
        completion: ExecCommandCompletion
    ) {
        self.maxResponseSize = max(0, maxResponseSize)
        self.completion = completion
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            channel.pipeline.fireErrorCaught(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            if status.exitStatus != 0 {
                completion.fail(SSHClient.CommandFailed(exitCode: status.exitStatus))
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if errorBuffer.readableBytes > 0 {
            completion.fail(TTYSTDError(message: errorBuffer))
        } else {
            completion.succeed(response)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(var bytes) = data.data, !isIgnoringInput else {
            return
        }
        
        switch data.type {
        case .channel, .stdErr:
            guard bytes.readableBytes <= maxResponseSize - receivedByteCount else {
                isIgnoringInput = true
                completion.fail(CitadelError.commandOutputTooLarge)
                context.close(promise: nil)
                return
            }
            receivedByteCount += bytes.readableBytes
            
            if data.type == .channel {
                response.writeBuffer(&bytes)
            } else {
                errorBuffer.writeBuffer(&bytes)
            }
        default:
            ()
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }
}

extension SSHClient {
    /// Executes a command on the remote SSH server and returns its output.
    ///
    /// This method establishes a new channel, executes the specified command, and collects
    /// its output. The command execution is handled asynchronously and includes timeout protection
    /// for channel creation, command execution, and task cancellation.
    ///
    /// - Parameters:
    ///   - command: The shell command to execute on the remote server
    ///   - maxResponseSize: Maximum allowed size for the command's output in bytes. 
    ///                     If exceeded, throws `CitadelError.commandOutputTooLarge`
    ///   - executionTimeout: Maximum time the remote command may run after its channel is created.
    ///
    /// - Returns: A ByteBuffer containing the command's output
    ///
    /// - Throws:
    ///   - `CitadelError.channelCreationFailed` if the channel cannot be created within 15 seconds
    ///   - `CitadelError.commandOutputTooLarge` if the response exceeds maxResponseSize
    ///   - `CitadelError.commandExecutionTimedOut` if execution exceeds executionTimeout
    ///   - `SSHClient.CommandFailed` if the command returns a non-zero exit status
    ///   - `TTYSTDError` if there was output to stderr
    public func executeCommand(
        _ command: String,
        maxResponseSize: Int = .max,
        executionTimeout: TimeAmount = .seconds(3_600)
    ) async throws -> ByteBuffer {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        let completion = ExecCommandCompletion(promise: promise)
        
        let channel: Channel
        
        do {
            channel = try await eventLoop.flatSubmit { [eventLoop, sshHandler = session.sshHandler] in
                let createChannel = eventLoop.makePromise(of: Channel.self)
                sshHandler.value.createChannel(createChannel) { channel, _ in
                    do {
                        try channel.pipeline.syncOperations.addHandler(
                            TTYHandler(
                                maxResponseSize: maxResponseSize,
                                completion: completion
                            )
                        )
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                
                let creationTimeout = eventLoop.scheduleTask(in: .seconds(15)) {
                    createChannel.fail(CitadelError.channelCreationFailed)
                }
                createChannel.futureResult.whenComplete { _ in
                    creationTimeout.cancel()
                }
                
                return createChannel.futureResult
            }.get()
        } catch {
            completion.fail(error)
            throw error
        }

        let executionTimeoutTask = channel.eventLoop.scheduleTask(in: executionTimeout) {
            completion.fail(CitadelError.commandExecutionTimedOut)
            channel.close(promise: nil)
        }
        defer { executionTimeoutTask.cancel() }
        
        // We need to exec a thing.
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        
        return try await withTaskCancellationHandler {
            try await eventLoop.flatSubmit {
                channel.triggerUserOutboundEvent(execRequest).whenFailure { [channel] error in
                    completion.fail(error)
                    channel.close(promise: nil)
                }

                return promise.futureResult
            }.get()
        } onCancel: {
            channel.eventLoop.execute {
                completion.fail(CancellationError())
                channel.close(promise: nil)
            }
        }
    }
}
