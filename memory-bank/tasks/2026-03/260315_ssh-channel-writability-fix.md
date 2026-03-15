# 260315_ssh-channel-writability-fix

## Objective
Fix terminal input freezing after period of use caused by missing parent channel writability propagation in NIOSSH.

## Outcome
- Terminal input no longer freezes when the TCP socket experiences transient backpressure
- SSH child channels now correctly track parent writability changes

## Root Cause
`SSHChildChannel.parentChannelWritabilityChanged(newValue:)` existed but was never called. When the NIO parent channel became temporarily unwritable due to network backpressure, child channels were never notified. Input writes queued in `pendingWritesFromChannel` and `deliverPendingWrites()` stayed blocked because it checks `parentIsWritable` — which was stale.

## Files Modified
- `Packages/swift-nio-ssh/Sources/NIOSSH/NIOSSHHandler.swift` — Added `channelWritabilityChanged` override that propagates to multiplexer and fires downstream
- `Packages/swift-nio-ssh/Sources/NIOSSH/Child Channels/SSHChannelMultiplexer.swift` — Added `parentChannelWritabilityChanged(_:)` method to propagate to all child channels

## Patterns Applied
- NIO ChannelHandler lifecycle event propagation pattern (fire event downstream after handling)
