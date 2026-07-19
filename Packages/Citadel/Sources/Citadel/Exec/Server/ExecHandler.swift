//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOPosix
import NIOSSH

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Bionic
#endif

enum SSHServerError: Error {
    case invalidCommand
    case invalidDataType
    case invalidChannelType
    case alreadyListening
    case notListening
}

final class ExecHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    
    private struct State: Sendable {
        var context: ExecCommandContext?
        var pipeChannel: Channel?
    }

    let delegate: ExecDelegate?
    private let state = NIOLockedValueBox(State())
    
    init(delegate: ExecDelegate?, username: String?) {
        self.delegate = delegate
        self.username = username
    }
    
    let username: String?
    
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            channel.pipeline.fireErrorCaught(error)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        let channel = context.channel
        let commandContext = state.withLockedValue { state in
            let commandContext = state.context
            state.context = nil
            state.pipeChannel = nil
            return commandContext
        }
        Task {
            do {
                try await commandContext?.terminate()
            } catch {
                channel.pipeline.fireErrorCaught(error)
            }
        }
        context.fireChannelInactive()
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as SSHChannelRequestEvent.ExecRequest:
            if let delegate = delegate {
                self.exec(event, delegate: delegate, channel: context.channel)
            } else if event.wantReply {
                let channel = context.channel
                channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        case let event as SSHChannelRequestEvent.EnvironmentRequest:
            if let delegate = delegate {
                let channel = context.channel
                Task {
                    do {
                        try await delegate.setEnvironmentValue(event.value, forKey: event.name)
                    } catch {
                        channel.pipeline.fireErrorCaught(error)
                    }
                }
            }
        case ChannelEvent.inputClosed:
            let channel = context.channel
            let commandContext = state.withLockedValue(\.context)
            Task {
                do {
                    try await commandContext?.inputClosed()
                } catch {
                    channel.pipeline.fireErrorCaught(error)
                }
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
    
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
    
    private func exec(_ event: SSHChannelRequestEvent.ExecRequest, delegate: ExecDelegate, channel: Channel) {
        let successPromise = channel.eventLoop.makePromise(of: Int.self)
        let handler = ExecOutputHandler(username: username) { code in
            successPromise.succeed(code)
        } onFailure: { _ in
            if event.wantReply {
                channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { _ in
                    channel.close(promise: nil)
                }
            } else {
                channel.close(promise: nil)
            }
        }
        
        let (ours, theirs) = GlueHandler.matchedPair(eventLoop: channel.eventLoop)
        
        // Ok, great, we've sorted stdout and stdin. For stderr we need a different strategy: we just park a thread for this.
        let stderrHandle = handler.stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { stderrHandle in
            do {
                guard let data = try stderrHandle.readToEnd() else {
                    stderrHandle.readabilityHandler = nil
                    return
                }
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeContiguousBytes(data)
                channel.write(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer)), promise: nil)
            } catch {
                channel.close(promise: nil)
            }
        }
        
        let addHandler: EventLoopFuture<Void>
        do {
            try channel.pipeline.syncOperations.addHandler(ours)
            addHandler = channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            addHandler = channel.eventLoop.makeFailedFuture(error)
        }

        addHandler.flatMap {
            NIOPipeBootstrap(group: channel.eventLoop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { pipeChannel in
                    do {
                        try pipeChannel.pipeline.syncOperations.addHandlers(SSHInboundChannelDataWrapper(), theirs)
                        return pipeChannel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return pipeChannel.eventLoop.makeFailedFuture(error)
                    }
                }.takingOwnershipOfDescriptors(
                    input: dup(handler.stdoutPipe.fileHandleForReading.fileDescriptor),
                    output: dup(handler.stdinPipe.fileHandleForWriting.fileDescriptor)
                )
        }.flatMap { pipeChannel -> EventLoopFuture<Channel> in
            self.state.withLockedValue { $0.pipeChannel = pipeChannel }
            let start = channel.eventLoop.makePromise(of: Void.self)
            start.completeWithTask {
                do {
                    let commandContext = try await delegate.start(
                        command: event.command,
                        outputHandler: handler
                    )
                    self.state.withLockedValue { $0.context = commandContext }
                } catch {
                    try await pipeChannel.close(mode: .all)
                }
            }
            
            return start.futureResult.flatMap {
                if event.wantReply {
                    return channel.triggerUserOutboundEvent(ChannelSuccessEvent()).map {
                        pipeChannel
                    }
                } else {
                    return channel.eventLoop.makeSucceededFuture(pipeChannel)
                }
            }
        }.flatMap { pipeChannel in
            successPromise.futureResult.flatMap { code in
                channel.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ExitStatus(exitStatus: code)
                ).flatMap {
                    pipeChannel.close(mode: .all)
                }
            }
        }.whenComplete { result in
            switch result {
            case .success:
                handler.onExit?(ExecExitContext())
                channel.close(promise: nil)
            case .failure:
                if event.wantReply {
                    channel.triggerUserOutboundEvent(ChannelFailureEvent()).whenComplete { _ in
                        channel.close(promise: nil)
                    }
                } else {
                    channel.close(promise: nil)
                }
            }
        }
    }
}
