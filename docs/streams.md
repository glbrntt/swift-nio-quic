# The table-based stream design

In short: every stream of a connection lives in one table, each in its own
slot. The stack sets flags on slots and once per tick the connection hands the
flagged streams to a consumer.

Nothing in a stack callback reaches the application. This is a structural
decision which avoids application code re-entering SwiftNetwork.

## Layer 1: storage

Storage (`PagedBuffer`) is a list of page pointers. A page is one allocation of
contiguous slots, never moved and never freed until the store dies, so **a
resolved slot pointer stays valid across arbitrary application code**.

`Page` defines the geometry of the pages. Page capacities double —
1, 2, 4, 8, 16, 32 — then stay at 64. A connection with one stream pays for one
slot, not a page. This matters because the transport state held in the slot for
a stream is currently several hundred bytes and most connections use at most a
few streams at a time.

`QUICStreamSlots` holds a paged buffer and owns the index space on top of
it. Inserting a value into the store returns a `QUICStreamHandle` for accessing
a value in the store.

A slot holds the value itself, not an `Optional<Value>` to avoid optional
unwrapping on the hot-path. Whether a slot is occupied lives in the slot's
`QUICStreamSlotRecord` instead (held by `QUICStreamSlots`). It also
records the current generation of the slot.

When accessing a value from the store via a handle the record is consulted
first: the slot at the given index must be occupied and match the generation
from the handle for the store to provide access. This is what allows slots to
safely be reused (as an application may incorrectly hold onto a handle after a
stream has closed).

## Layer 2: what's in a slot

There are two separate stores for each slot. One stores the state for the
transport side, and the other holds per-stream state defined by the application.
The two stores share an indexing space, i.e. the handle retrieved from
inserting into `QUICStreamSlots` provides the index for looking up the
application state for the corresponding stream in `QUICStreamConsumerStates`.

```
slot index ──┬─→ QUICStreamSlots           → QUICStreamTransportState
             └─→ QUICStreamConsumerStates  → Consumer.StreamState?
```

`QUICStreamTransportState` contains transport state, like the event flags
('readable', 'closed', 'reset' etc.), the `SwiftNetwork` event manager, and
`QUICStreamCore` which is the only thing that calls *out* into SwiftNetwork per
stream.

The stores are separate for a few reasons:

1. **Generic metadata.** The slot is deliberately not generic over the
   consumer. In a stack callback `Consumer` isn't known statically, so the
   code is unspecialized; a nested generic field would mean instantiating
   metadata before computing any field offset.
2. **Different occupancy rules.** A slot in the slot store exists only while
   it is occupied. Its cell in the state store is always initialized, to
   `nil`, and is legitimately `nil` while the slot is live (the stream opens
   before the application knows about it).

## Layer 3: the table

`QUICStreamTable` holds both stores, a deque of handles to visit, an ID to
handle dictionary (`QUICStreamIDDictionary`), connection-level events, and
whether there is any pending output.

- `markReady(handle:events:)` checks the handle is valid (valid index,
  generation matches that stored in the slot record for the index), unions
  the flags, and enqueues the handle to visit only if the flags were
  previously empty (so a stream is in the ready list at most once).
- `drain(into:)` is what turns the queue of streams to visit into a call to
  `processStreams` on the consumer (i.e. how an application visits each stream).
  It's also responsible for calling into the consumer to create its application
  state for a new inbound stream (outbound streams are created with their
  application state).

## Layer 4: the API

An application implements a `QUICStreamConsumer`: which includes
`makeStreamState(_:)` (create the state for a new inbound stream) and
`processStreams(_:)` to which they are provided an iterator for the ready
streams.

### Example

```swift
struct EchoConsumer: QUICStreamConsumer {
    struct StreamState {
        var bytesEchoed = 0
    }

    mutating func makeStreamState(_ stream: inout QUICStream<Self>) -> StreamState {
        StreamState()
    }

    mutating func processStreams(_ streams: inout QUICStreamIterator<Self>) {
        while var visit = streams.next() {
            let events = visit.events
            visit.withStream { stream, state in
                var buffer = ByteBuffer()
                var endOfStream = false

                if events.contains(.readable) {
                    readLoop: while true {
                        switch stream.read(maxBytes: 4096, into: &buffer) {
                        case .read(let count) where count > 0:
                            continue

                        case .read, .nothingAvailable:
                            break readLoop

                        case .endOfStream:
                            endOfStream = true
                            break readLoop
                        }
                    }
                }

                let fin = endOfStream && stream.isSendOpen

                if buffer.readableBytes > 0 || fin {
                    state.bytesEchoed &+= buffer.readableBytes
                    stream.write(buffer)
                    try? stream.flush(fin: fin)
                }
            }
        }
    }
}
```

Opening a stream out-of-band goes through the `QUICConnectionStreams`
(this will likely be provided to the channel initializer or held elsewhere):

```swift
let handle = connectionStreams.withStreams { streams -> QUICStreamHandle? in
    let handle = try? streams.open(
        .clientInitiatedBidirectional,
        state: EchoConsumer.StreamState()
    )

    guard let handle else { return nil }  // failed to open stream

    streams.withStream(handle: handle) { stream, _ in
        stream.write(ByteBuffer(string: "Hello, World!"))
        try? stream.flush(fin: true)
    }

    return handle
}
```

Any response would be read in `processStreams` like in the example above.
