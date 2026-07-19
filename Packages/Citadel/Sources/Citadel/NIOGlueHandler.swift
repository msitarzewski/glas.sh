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

import NIOCore

final class GlueHandler: Sendable {
    private struct State {
        var partner: GlueHandler?
        var context: ChannelHandlerContext?
        var pendingRead = false
    }

    private let state: NIOLoopBoundBox<State>

    private init(eventLoop: EventLoop) {
        self.state = NIOLoopBoundBox(State(), eventLoop: eventLoop)
    }
}

extension GlueHandler {
    static func matchedPair(eventLoop: EventLoop) -> (GlueHandler, GlueHandler) {
        let first = GlueHandler(eventLoop: eventLoop)
        let second = GlueHandler(eventLoop: eventLoop)
        
        first.state.value.partner = second
        second.state.value.partner = first
        
        return (first, second)
    }
}

extension GlueHandler {
    private func partnerWrite(_ data: NIOAny) {
        state.value.context?.write(data, promise: nil)
    }
    
    private func partnerFlush() {
        state.value.context?.flush()
    }
    
    private func partnerWriteEOF() {
        state.value.context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        state.value.context?.close(promise: nil)
    }
    
    private func partnerBecameWritable() {
        if state.value.pendingRead {
            state.value.pendingRead = false
            state.value.context?.read()
        }
    }
    
    private var partnerWritable: Bool {
        state.value.context?.channel.isWritable ?? false
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny
    
    func handlerAdded(context: ChannelHandlerContext) {
        state.value.context = context
        
        // It's possible our partner asked if we were writable, before, and we couldn't answer.
        // Consider updating it.
        if context.channel.isWritable {
            state.value.partner?.partnerBecameWritable()
        }
    }
    
    func handlerRemoved(context: ChannelHandlerContext) {
        state.value.context = nil
        state.value.partner = nil
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        state.value.partner?.partnerWrite(data)
    }
    
    func channelReadComplete(context: ChannelHandlerContext) {
        state.value.partner?.partnerFlush()
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        state.value.partner?.partnerCloseFull()
    }
    
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // We have read EOF.
            state.value.partner?.partnerWriteEOF()
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.value.partner?.partnerCloseFull()
    }
    
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            state.value.partner?.partnerBecameWritable()
        }
    }
    
    func read(context: ChannelHandlerContext) {
        if let partner = state.value.partner, partner.partnerWritable {
            context.read()
        } else {
            state.value.pendingRead = true
        }
    }
}
