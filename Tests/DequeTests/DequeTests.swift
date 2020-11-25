//
//  DequeTests.swift
//
//  Copyright © 2020 Lily Ballard.
//  Licensed under Apache License v2.0 with Runtime Library Exception
//
//  See https://github.com/lilyball/swift-deque/blob/main/LICENSE.txt for license information.
//

import XCTest
@testable import Deque

// We need to test Codable but I'm not aware of any coder/decoder in the stdlib outside of the
// Foundation overlay.
#if canImport(Foundation)
import class Foundation.JSONEncoder
import class Foundation.JSONDecoder
#endif

// All tests in this suite use `IntClass` as the element type. This lets us validate Deque's
// initialization/deinitialization logic, as every element that is initialized must be deinitialized
// exactly once. This asserts that we aren't overreleasing or leaking anything.
final class DequeTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let initialIntClassCounter = IntClass.counter
        addTeardownBlock {
            let finalIntClassCounter = IntClass.counter
            XCTAssertEqual(finalIntClassCounter, initialIntClassCounter, "number of living IntClass objects")
        }
    }
    
    // MARK: -
    
    func testEmptyBufferStorage() {
        // An empty deque does not have unique storage
        var buf1 = Deque<IntClass>()
        XCTAssertFalse(buf1._storage.isUniqueReference(), "empty buffer storage is unique")
        
        // Empty deques should share the same storage
        let buf2 = Deque<IntClass>()
        XCTAssertEqual(buf1._storage, buf2._storage, "buffer storage pointers")
        
        // Buffers created from empty sequences as well
        let buf3 = Deque<IntClass>(Array([]))
        XCTAssertEqual(buf1._storage, buf3._storage, "buffer storage pointers")
        
        // Also buffers created from empty array literals
        let buf4: Deque<IntClass> = []
        XCTAssertEqual(buf1._storage, buf4._storage, "buffer storage pointers")
        
        // Buffers of different types should also have the same storage
        // We need to look at the buffer identifiers though as we can't compare otherwise
        let buf5 = Deque<String>()
        XCTAssertEqual(buf1.bufferIdentifier, buf5.bufferIdentifier, "buffer storage identifiers")
    }
    
    func testInitWithSequence() {
        XCTContext.runActivity(named: "Initializing with Array") { (_) in
            var buf = Deque<IntClass>([])
            XCTAssert(buf.isEmpty, "buffer is empty")
            XCTAssertEqual(buf.capacity, 0, "capacity")
            buf = Deque([1,2,3])
            assertElementsEqual(buf, [1,2,3])
            // init with a sequence whose size isn't known up front
            buf = Deque((1...10).lazy.filter({ $0.isMultiple(of: 2) }))
            assertElementsEqual(buf, [2,4,6,8,10])
        }
        
        XCTContext.runActivity(named: "Initializing with Deque") { (_) in
            let buf = Deque<IntClass>(0..<5)
            let buf2 = Deque(buf)
            // They should share the same storage pointer.
            XCTAssertEqual(buf._storage, buf2._storage, "buffer storage")
        }
    }
    
    func testCopyToArray() {
        var buf = Deque<IntClass>([1,2,3])
        XCTAssertEqual(Array(buf), [1,2,3])
        
        // copy a noncontiguous one too
        buf.reserveCapacity(5)
        buf.prepend(0)
        XCTAssertEqual(Array(buf), [0,1,2,3])
        
        // also an empty one
        buf = []
        XCTAssertEqual(Array(buf), [])
        // and an empty one with capacity
        buf.reserveCapacity(10)
        XCTAssertEqual(Array(buf), [])
        
        // Normally, Array(buf) will invoke our _copyContents. It doesn't do this if we're empty
        // though, but we'd like to validate that _copyContents works when empty. We'll do that by
        // using the other public API for invoking it, which is
        // UnsafeMutableBufferPointer.initialize(from:).
        let heapBuffer = UnsafeMutableBufferPointer<IntClass>.allocate(capacity: 5)
        defer { heapBuffer.deallocate() }
        buf = [] // test using shared empty storage
        var (iter, idx) = heapBuffer.initialize(from: buf)
        XCTAssertNil(iter.next(), "iter.next()")
        XCTAssertEqual(idx, heapBuffer.startIndex)
        buf.reserveCapacity(10) // test again with some capacity
        (iter, idx) = heapBuffer.initialize(from: buf)
        XCTAssertNil(iter.next(), "iter.next()")
        XCTAssertEqual(idx, heapBuffer.startIndex)
    }
    
    func testReserveCapacity() {
        var buf = Deque<IntClass>()
        XCTAssertEqual(buf.capacity, 0, "capacity")
        buf.reserveCapacity(10)
        // The system is allowed to give us extra capacity, but any extra should be small.
        XCTAssert((10..<20).contains(buf.capacity), "capacity is in 10..<20")
        buf.reserveCapacity(30)
        XCTAssert((30..<40).contains(buf.capacity), "capacity is in 30..<40")
        var prevCapacity = buf.capacity
        buf.reserveCapacity(10)
        XCTAssertEqual(buf.capacity, prevCapacity, "capacity when reserving with a smaller amount")
        // If the buffer isn't unique, it should obey the shrink call
        let buf2 = buf
        buf.reserveCapacity(10)
        XCTAssert((10..<20).contains(buf.capacity), "capacity is in 10..<20")
        XCTAssertEqual(buf2.capacity, prevCapacity, "capacity of buffer copy")
        
        // reserveCapacity preserves existing contents
        prevCapacity = buf.capacity
        buf.append(contentsOf: [1,2,3])
        XCTAssertEqual(buf.capacity, prevCapacity, "capacity after appending")
        buf.reserveCapacity(30)
        XCTAssert((30..<40).contains(buf.capacity), "capacity is in 30..<40")
        assertElementsEqual(buf, [1,2,3], "buffer contents")
        
        // reserveCapacity preserves contents that wrap around too
        let ary: [IntClass] = [0,1,2,3,4,5]
        buf = Deque(ary.dropFirst())
        buf.reserveCapacity(ary.count)
        let oldIdent = buf.bufferIdentifier
        buf.prepend(ary[0])
        XCTAssertEqual(buf.bufferIdentifier, oldIdent, "buffer storage pointer") // ensure we didn't reallocate
        assertElementsEqual(buf, ary, "buffer contents")
        // At this point the buffer should have both a head and a tail
        XCTAssertFalse(buf.hasContiguousStorage, "buffer should have noncontiguous storage")
        XCTAssert(buf.capacity < 30, "capacity < 30")
        buf.reserveCapacity(30)
        assertElementsEqual(buf, ary, "buffer contents")
    }
    
    func testWithContiguousStorageIfAvailable() {
        var buf = Deque<IntClass>()
        XCTAssertNotNil(buf.withContiguousStorageIfAvailable({ (ptr) -> Void in
            XCTAssertEqual(ptr.count, 0, "contiguous storage count")
        }), "contiguous storage existence")
        
        buf.append(contentsOf: [1,2,3])
        XCTAssertNotNil(buf.withContiguousStorageIfAvailable({ (ptr) -> Void in
            assertElementsEqual(ptr, [1,2,3], "contiguous storage contents")
        }), "contiguous storage existence")
        
        buf.reserveCapacity(4)
        buf.prepend(0)
        XCTAssertNil(buf.withContiguousStorageIfAvailable({ _ in () }), "contiguous storage existence")
        
        // During this method, mutations to the buffer should trigger CoW
        buf = [1,2,3]
        XCTAssertNotNil(buf.withContiguousStorageIfAvailable({ (ptr) -> Void in
            XCTAssertEqual(ptr[0], 1, "contiguous storage first element")
            buf[buf.startIndex] = 2
            XCTAssertEqual(ptr[0], 1, "contiguous storage first element")
        }), "contiguous storage existence")
    }
    
    func testWithContiguousMutableStorageIfAvailable() {
        var buf = Deque<IntClass>()
        XCTAssertNotNil(buf.withContiguousMutableStorageIfAvailable({ (ptr) -> Void in
            XCTAssertEqual(ptr.count, 0, "contiguous storage count")
        }), "contiguous storage existence")
        
        buf.append(contentsOf: [1,2,3])
        XCTAssertNotNil(buf.withContiguousMutableStorageIfAvailable({ (ptr) -> Void in
            assertElementsEqual(ptr, [1,2,3], "contiguous storage contents")
            ptr.assign(repeating: 42)
        }), "contiguous storage existence")
        assertElementsEqual(buf, [42,42,42], "buffer contents")
        
        buf.reserveCapacity(4)
        buf.prepend(0)
        XCTAssertNil(buf.withContiguousMutableStorageIfAvailable({ _ in () }), "contiguous storage existence")
        
        // Touching the deque during withContiguousMutableStorageIfAvailable should not break
        // anything. The compiler tries to enforce memory exclusivity so we need to be a little
        // tricky to get past it.
        buf = [1,2,3]
        withUnsafeMutablePointer(to: &buf) { (bufPtr) in
            XCTAssertNotNil(bufPtr.pointee.withContiguousMutableStorageIfAvailable({ (ptr) -> Void in
                assertElementsEqual(ptr, [1,2,3], "contiguous storage contents")
                assertElementsEqual(bufPtr.pointee, [], "buffer contents")
                bufPtr.pointee.append(4)
                assertElementsEqual(bufPtr.pointee, [4], "buffer contents")
                for i in ptr.indices {
                    ptr[i] += 10
                }
                assertElementsEqual(ptr, [11,12,13], "contiguous storage contents")
            }), "contiguous storage existence")
        }
        assertElementsEqual(buf, [11,12,13], "buffer contents")
    }
    
    func testIsEmpty() {
        var buf = Deque<IntClass>()
        XCTAssertTrue(buf.isEmpty, "isEmpty")
        buf.append(1)
        XCTAssertFalse(buf.isEmpty, "isEmpty")
        buf.removeFirst()
        XCTAssertTrue(buf.isEmpty, "isEmpty")
    }
    
    func testUnderestimatedCountAndCount() {
        var buf = Deque<IntClass>()
        XCTAssertEqual(buf.count, 0, "count")
        XCTAssertEqual(buf.underestimatedCount, 0, "underestimatedCount")
        
        buf.append(contentsOf: [1,2,3,4,5])
        XCTAssertEqual(buf.count, 5, "count")
        XCTAssertEqual(buf.underestimatedCount, 5, "underestimatedCount")
        
        buf.reserveCapacity(10)
        XCTAssertEqual(buf.count, 5, "count")
        XCTAssertEqual(buf.underestimatedCount, 5, "underestimatedCount")
        
        buf.prepend(0)
        buf.prepend(-1)
        XCTAssertFalse(buf.hasContiguousStorage, "buffer should have noncontiguous storage")
        XCTAssertEqual(buf.count, 7, "count")
        XCTAssertEqual(buf.underestimatedCount, 7, "underestimatedCount")
    }
    
    func testIndexTraversals() {
        let emptyDeque = Deque<IntClass>()
        let oneElemDeque: Deque<IntClass> = [42]
        let dequeWithCapacity = with(Deque<IntClass>([42]), { $0.reserveCapacity(10) })
        let dequeWithLeadingCapacity = with(Deque<IntClass>(1...7), { $0.removeFirst(2) })
        let dequeWithTail = with(Deque<IntClass>(1...5), { (buf) in
            buf.reserveCapacity(10)
            let oldIdent = buf.bufferIdentifier
            buf.prepend(6)
            buf.prepend(7)
            XCTAssertEqual(buf.bufferIdentifier, oldIdent, "buffer storage pointer") // ensure we didn't reallocate
            XCTAssertFalse(buf.hasContiguousStorage, "buffer should have noncontiguous storage")
        })
        let dequeWithTailNoGap = with(Deque<IntClass>(1...5), { (buf) in
            buf.reserveCapacity(10)
            let oldIdent = buf.bufferIdentifier
            for i: IntClass in 6...10 { buf.prepend(i) } // avoid prepend(contentsOf:) to keep test setup simpler
            XCTAssertEqual(buf.bufferIdentifier, oldIdent, "buffer storage pointer") // ensure we didn't reallocate
            XCTAssertFalse(buf.hasContiguousStorage, "buffer should have noncontiguous storage")
            XCTAssertEqual(buf.count, buf.capacity, "buffer count should equal capacity")
        })
        
        func runTests(_ deque: Deque<IntClass>, line: UInt = #line) {
            func validate<C: RandomAccessCollection>(_ collection: C, line: UInt) {
                validateIndexTraversals(collection, line: line)
                // validateIndexTraversals doesn't test all index methods. In particular, for every
                // nonmutating/mutating pair (such as index(before:) and formIndex(before:)) it only
                // picks one of them. Add a few tests of our own to ensure coverage.
                if !collection.isEmpty {
                    var idx = collection.startIndex
                    collection.formIndex(after: &idx)
                    XCTAssertEqual(idx, collection.index(after: collection.startIndex), "formIndex(after:) vs index(after:)", line: line)
                    idx = collection.endIndex
                    collection.formIndex(before: &idx)
                    XCTAssertEqual(idx, collection.index(before: collection.endIndex), "formIndex(before:) vs index(before:)", line: line)
                    // formIndex(_:offsetBy:) is not actually part of the protocol (it's an
                    // extension) so we can skip it.
                }
            }
            validate(deque, line: line)
            validate(deque.indices, line: line)
        }
        
        runTests(emptyDeque)
        runTests(oneElemDeque)
        runTests(dequeWithCapacity)
        runTests(dequeWithLeadingCapacity)
        runTests(dequeWithTail)
        runTests(dequeWithTailNoGap)
    }
    
    func testAppendReallocation() {
        XCTContext.runActivity(named: "Appending past capacity") { (_) in
            func test(offsetHead: Bool) {
                var deque = Deque<IntClass>()
                deque.reserveCapacity(5)
                let cap = deque.capacity // reserveCapacity may give us some extra space
                let oldIdent = deque.bufferIdentifier
                if offsetHead {
                    for _ in 0..<3 { deque.append(0) }
                    deque.removeFirst(2)
                    XCTAssertEqual(deque._storage.header.headSpan.lowerBound, 2, "buffer storage headSpan.lowerBound")
                } else {
                    deque.append(0)
                    XCTAssertEqual(deque._storage.header.headSpan.lowerBound, 0, "buffer storage headSpan.lowerBound")
                }
                for i in 1..<IntClass(cap) {
                    deque.append(i)
                }
                XCTAssertEqual(deque.capacity, cap, "capacity")
                XCTAssertEqual(deque.count, cap, "count")
                XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                deque.append(IntClass(cap+1))
                XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                XCTAssertEqual(deque.count, cap+1, "count")
                XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                XCTAssertEqual(deque._storage.header.headSpan.lowerBound, 0, "buffer storage headSpan.lowerBound") // it's linearized
            }
            XCTContext.runActivity(named: "With linear buffer") { (_) in
                test(offsetHead: false)
            }
            XCTContext.runActivity(named: "With split buffer") { (_) in
                test(offsetHead: true)
            }
        }
        
        XCTContext.runActivity(named: "Appending with head/tail gap") { (_) in
            var deque = Deque<IntClass>()
            deque.reserveCapacity(5)
            let cap = deque.capacity // reserveCapacity may give us some extra space
            let oldIdent = deque.bufferIdentifier
            for i in 0..<IntClass(cap) {
                deque.append(i)
            }
            XCTAssertEqual(deque.capacity, cap, "capacity")
            XCTAssertEqual(deque.count, cap, "count")
            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
            for i in 0..<cap {
                let x = deque.removeFirst()
                deque.append(x)
                XCTAssertEqual(deque.capacity, cap, "capacity - iteration \(i)")
                XCTAssertEqual(deque.count, cap, "count - iteration \(i)")
                XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer - iteration \(i)")
            }
        }
    }
    
    func testPrependReallocation() {
        XCTContext.runActivity(named: "Prepending past capacity") { (_) in
            var deque = Deque<IntClass>()
            deque.reserveCapacity(5)
            let cap = deque.capacity // reserveCapacity may give us some extra space
            let oldIdent = deque.bufferIdentifier
            for i in 0..<IntClass(cap) {
                deque.prepend(i)
            }
            XCTAssertEqual(deque.capacity, cap, "capacity")
            XCTAssertEqual(deque.count, cap, "count")
            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
            deque.prepend(IntClass(cap+1))
            XCTAssertGreaterThan(deque.capacity, cap, "capacity")
            XCTAssertEqual(deque.count, cap+1, "count")
            XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
        }
        
        XCTContext.runActivity(named: "Prepending with head/tail gap") { (_) in
            var deque = Deque<IntClass>()
            deque.reserveCapacity(5)
            let cap = deque.capacity // reserveCapacity may give us some extra space
            let oldIdent = deque.bufferIdentifier
            for i in 0..<IntClass(cap) {
                deque.prepend(i)
            }
            XCTAssertEqual(deque.capacity, cap, "capacity")
            XCTAssertEqual(deque.count, cap, "count")
            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
            for i in 0..<cap {
                let x = deque.removeLast()
                deque.prepend(x)
                XCTAssertEqual(deque.capacity, cap, "capacity - iteration \(i)")
                XCTAssertEqual(deque.count, cap, "count - iteration \(i)")
                XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer - iteration \(i)")
            }
        }
    }
    
    func testAppendContentsOfReallocation() {
        func makeDeque(gap: Int, minCount: Int = 5) -> (Deque<IntClass>, capacity: Int, bufferIdentifier: ObjectIdentifier) {
            var deque = Deque<IntClass>()
            deque.reserveCapacity(minCount+gap)
            let cap = deque.capacity // reserveCapacity may give us some extra space
            let count = cap-gap
            let oldIdent = deque.bufferIdentifier
            for i in 0..<IntClass(count) { deque.append(i) } // avoid append(contentsOf:) to keep test setup simpler
            XCTAssertEqual(deque.capacity, cap, "capacity")
            XCTAssertEqual(deque.count, count, "count")
            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
            return (deque, cap, oldIdent)
        }
        
        XCTContext.runActivity(named: "Appending when at capacity") { (_) in
            XCTContext.runActivity(named: "Appending a known-sized sequence") { (_) in
                XCTContext.runActivity(named: "Appending a non-empty sequence past capacity") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 0)
                    deque.append(contentsOf: [1,2])
                    XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap+2, "count")
                    XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
                
                XCTContext.runActivity(named: "Appending an empty sequence") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 0)
                    deque.append(contentsOf: EmptyCollection())
                    XCTAssertEqual(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap, "count")
                    XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
            }
            
            XCTContext.runActivity(named: "Appending an unknown-sized sequence") { (_) in
                XCTContext.runActivity(named: "Appending a non-empty sequence past capacity") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 0)
                    deque.append(contentsOf: UnknownLengthSequence([1,2]))
                    XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap+2, "count")
                    XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
                
                XCTContext.runActivity(named: "Appending an empty sequence") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 0)
                    deque.append(contentsOf: UnknownLengthSequence(EmptyCollection()))
                    XCTAssertEqual(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap, "count")
                    XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
            }
        }
        
        XCTContext.runActivity(named: "Appending with remaining capacity") { (_) in
            XCTContext.runActivity(named: "Appending a known-sized sequence") { (_) in
                XCTContext.runActivity(named: "Appending a sequence past capacity") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 3)
                    deque.append(contentsOf: 0..<5)
                    XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap+2, "count")
                    XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
                
                XCTContext.runActivity(named: "Appending a sequence equal to remaining capacity") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 3)
                    deque.append(contentsOf: 0..<3)
                    XCTAssertEqual(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap, "count")
                    XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
            }
            
            XCTContext.runActivity(named: "Appending an unknown-sized sequence") { (_) in
                XCTContext.runActivity(named: "Appending a sequence past capacity") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 3)
                    deque.append(contentsOf: UnknownLengthSequence(0..<5))
                    XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap+2, "count")
                    XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
                
                XCTContext.runActivity(named: "Appending a sequence equal to remaining capacity") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 3)
                    deque.append(contentsOf: UnknownLengthSequence(0..<3))
                    XCTAssertEqual(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap, "count")
                    XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
            }
        }
        
        XCTContext.runActivity(named: "Appending with head/tail gap") { (_) in
            // This will put a gap in every possible location and then fill the gap. This exercises
            // conditions such as when the gap is anchored to the start of the buffer, or when the
            // gap is split across the start/end of the buffer.
            var (deque, cap, oldIdent) = makeDeque(gap: 0, minCount: 5)
            for pos in 0..<(cap-1) { // (cap-1) because otherwise our final position is equivalent to pos=0
                let gapSize = 3
                func resetDeque() {
                    deque.removeAll(keepingCapacity: true)
                    // Place the head span at position `pos`.
                    // Note: We're avoiding the use of append(contentsOf:) here because this is testing append(contentsOf:)
                    // and we don't want any bugs in that method to affect the test setup.
                    for i in 0..<IntClass(pos) { deque.append(i) } // filler to be removed to create the gap
                    deque.append(0) // first element to keep
                    deque.removeFirst(pos) // clear the filler
                    for i in 1..<IntClass(cap-gapSize) { deque.append(i) } // remaining elements
                    XCTAssertEqual(deque._storage.header.headSpan.lowerBound, pos, "header span lower bound")
                    XCTAssertEqual(deque.capacity, cap, "capacity - head position \(pos)")
                    XCTAssertEqual(deque.count, cap-gapSize, "count - head position \(pos)")
                    XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer - head position \(pos)")
                }
                
                XCTContext.runActivity(named: "Using head position \(pos)") { (_) in
                    func fill(leavingGapOf remainder: Int) {
                        XCTContext.runActivity(named: "Filling with known-sized collection") { (_) in
                            resetDeque()
                            deque.append(contentsOf: 10..<(10+gapSize-remainder)) // fill the gap
                            XCTAssertEqual(deque.capacity, cap, "capacity - head position \(pos)")
                            XCTAssertEqual(deque.count, cap-remainder, "count - head position \(pos)")
                            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer - head position \(pos)")
                        }
                        
                        XCTContext.runActivity(named: "Filling with unknown-sized collection") { (_) in
                            resetDeque()
                            deque.append(contentsOf: UnknownLengthSequence(10..<(10+gapSize-remainder)))
                            XCTAssertEqual(deque.capacity, cap, "capacity - head position \(pos)")
                            XCTAssertEqual(deque.count, cap-remainder, "count - head position \(pos)")
                            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer - head position \(pos)")
                        }
                        
                        XCTContext.runActivity(named: "Filling with partially-sized collection") { (_) in
                            resetDeque()
                            deque.append(contentsOf: UnknownLengthSequence(10..<(10+gapSize-remainder), underestimatedCount: 1))
                            XCTAssertEqual(deque.capacity, cap, "capacity - head position \(pos)")
                            XCTAssertEqual(deque.count, cap-remainder, "count - head position \(pos)")
                            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer - head position \(pos)")
                        }
                    }
                    XCTContext.runActivity(named: "Filling entire gap") { (_) in
                        fill(leavingGapOf: 0)
                    }
                    XCTContext.runActivity(named: "Filling most of the gap") { (_) in
                        fill(leavingGapOf: 1)
                    }
                }
            }
        }
    }
    
    func testPrependContentsOfReallocation() {
        func makeDeque(gap: Int, minCount: Int = 5, putGapAtEnd: Bool = true) -> (Deque<IntClass>, capacity: Int, bufferIdentifier: ObjectIdentifier) {
            var deque = Deque<IntClass>()
            deque.reserveCapacity(minCount+gap)
            let cap = deque.capacity // reserveCapacity may give us some extra space
            let count = cap-gap
            let oldIdent = deque.bufferIdentifier
            if putGapAtEnd {
                for i in 0..<IntClass(count) { deque.append(i) } // avoid append(contentsOf:) to keep test setup simpler
            } else {
                for _ in 0..<gap { deque.append(0) }
                for i in 0..<IntClass(count) { deque.append(i) }
                deque.removeFirst(gap)
                XCTAssertEqual(deque._storage.header.headSpan, gap..<cap, "storage headSpan")
            }
            XCTAssertEqual(deque.capacity, cap, "capacity")
            XCTAssertEqual(deque.count, count, "count")
            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
            return (deque, cap, oldIdent)
        }
        
        XCTContext.runActivity(named: "Prepending when at capacity") { (_) in
            XCTContext.runActivity(named: "Prepending a known-sized sequence") { (_) in
                XCTContext.runActivity(named: "Prepending a non-empty sequence past capacity") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 0)
                    deque.prepend(contentsOf: [-2,-1])
                    XCTAssertEqual(Array(deque), Array(-2..<IntClass(cap)), "buffer elements")
                    XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap+2, "count")
                    XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
                
                XCTContext.runActivity(named: "Prepending an empty sequence") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 0)
                    deque.prepend(contentsOf: EmptyCollection())
                    XCTAssertEqual(Array(deque), Array(0..<IntClass(cap)), "buffer elements")
                    XCTAssertEqual(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap, "count")
                    XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
            }
            
            XCTContext.runActivity(named: "Prepending an unknown-sized sequence") { (_) in
                XCTContext.runActivity(named: "Prepending a non-empty sequence past capacity") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 0)
                    deque.prepend(contentsOf: UnknownLengthSequence([-2,-1]))
                    XCTAssertEqual(Array(deque), Array(-2..<IntClass(cap)), "buffer elements")
                    XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap+2, "count")
                    XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
                
                XCTContext.runActivity(named: "Prepending an empty sequence") { (_) in
                    var (deque, cap, oldIdent) = makeDeque(gap: 0)
                    deque.prepend(contentsOf: UnknownLengthSequence(EmptyCollection()))
                    XCTAssertEqual(Array(deque), Array(0..<IntClass(cap)), "buffer elements")
                    XCTAssertEqual(deque.capacity, cap, "capacity")
                    XCTAssertEqual(deque.count, cap, "count")
                    XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                }
            }
        }
        
        XCTContext.runActivity(named: "Prepending with remaining capacity") { (_) in
            for putGapAtEnd in [false, true] {
                let _makeDeque = { makeDeque(gap: $0, putGapAtEnd: putGapAtEnd) }
                XCTContext.runActivity(named: "With the gap at the \(putGapAtEnd ? "end" : "start")") { (_) in
                    let makeDeque = _makeDeque
                    XCTContext.runActivity(named: "Prepending a known-sized sequence") { (_) in
                        XCTContext.runActivity(named: "Prepending a sequence past capacity") { (_) in
                            var (deque, cap, oldIdent) = makeDeque(3)
                            deque.prepend(contentsOf: -5..<0)
                            XCTAssertEqual(Array(deque), Array(-5..<IntClass(cap-3)), "buffer elements")
                            XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                            XCTAssertEqual(deque.count, cap+2, "count")
                            XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                        }
                        
                        XCTContext.runActivity(named: "Prepending a sequence equal to remaining capacity") { (_) in
                            var (deque, cap, oldIdent) = makeDeque(3)
                            deque.prepend(contentsOf: -3..<0)
                            XCTAssertEqual(Array(deque), Array(-3..<IntClass(cap-3)), "buffer elements")
                            XCTAssertEqual(deque.capacity, cap, "capacity")
                            XCTAssertEqual(deque.count, cap, "count")
                            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                        }
                    }
                    
                    XCTContext.runActivity(named: "Prepending an unknown-sized sequence") { (_) in
                        XCTContext.runActivity(named: "Prepending a sequence past capacity") { (_) in
                            var (deque, cap, oldIdent) = makeDeque(3)
                            deque.prepend(contentsOf: UnknownLengthSequence(-5..<0))
                            XCTAssertEqual(Array(deque), Array(-5..<IntClass(cap-3)), "buffer elements")
                            XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                            XCTAssertEqual(deque.count, cap+2, "count")
                            XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                        }
                        
                        XCTContext.runActivity(named: "Prepending a sequence equal to remaining capacity") { (_) in
                            var (deque, cap, _) = makeDeque(3)
                            deque.prepend(contentsOf: UnknownLengthSequence(-3..<0))
                            XCTAssertEqual(Array(deque), Array(-3..<IntClass(cap-3)), "buffer elements")
                            XCTAssertEqual(deque.capacity, cap, "capacity")
                            XCTAssertEqual(deque.count, cap, "count")
                            // Note: Skipping the buffer identifier comparison. Currently we will create a
                            // new buffer, because we prepending into the available space and shuffling that
                            // around is too complicated when we don't know what size we're prepending, but
                            // using a new buffer isn't in our API contract.
                        }
                    }
            
                    XCTContext.runActivity(named: "Prepending a partially-sized sequence") { (_) in
                        XCTContext.runActivity(named: "Prepending a sequence past capacity") { (_) in
                            var (deque, cap, oldIdent) = makeDeque(3)
                            deque.prepend(contentsOf: UnknownLengthSequence(-5..<0, underestimatedCount: 1))
                            XCTAssertEqual(Array(deque), Array(-5..<IntClass(cap-3)), "buffer elements")
                            XCTAssertGreaterThan(deque.capacity, cap, "capacity")
                            XCTAssertEqual(deque.count, cap+2, "count")
                            XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer")
                        }
                        
                        XCTContext.runActivity(named: "Prepending a sequence equal to remaining capacity") { (_) in
                            var (deque, cap, _) = makeDeque(3)
                            deque.prepend(contentsOf: UnknownLengthSequence(-3..<0, underestimatedCount: 1))
                            XCTAssertEqual(Array(deque), Array(-3..<IntClass(cap-3)), "buffer elements")
                            XCTAssertEqual(deque.capacity, cap, "capacity")
                            XCTAssertEqual(deque.count, cap, "count")
                            // Note: Skipping the buffer identifier comparison. Currently we will create a
                            // new buffer, because we prepending into the available space and shuffling that
                            // around is too complicated when we don't know what size we're prepending, but
                            // using a new buffer isn't in our API contract.
                        }
                    }
                }
            }
        }
        
        XCTContext.runActivity(named: "Prepending with head/tail gap") { (_) in
            // This will put a gap in every possible location and then fill the gap. This exercises
            // conditions such as when the gap is anchored to the start of the buffer, or when the
            // gap is split across the start/end of the buffer.
            var (deque, cap, oldIdent) = makeDeque(gap: 0, minCount: 5)
            for pos in 0..<(cap-1) { // (cap-1) because otherwise our final position is equivalent to pos=0
                deque.removeAll(keepingCapacity: true)
                // Place the head span at position `pos`.
                // Note: We're avoiding the use of append(contentsOf:) here because that's a
                // much more complicated implementation than individual appending and I want to
                // keep this test setup simple.
                for i in 0..<IntClass(pos) { deque.append(i) } // filler to be removed to create the gap
                deque.append(0) // first element to keep
                deque.removeFirst(pos) // clear the filler
                let gapSize = 3
                for i in 1..<IntClass(cap-gapSize) { deque.append(i) } // remaining elements
                XCTAssertEqual(deque._storage.header.headSpan.lowerBound, pos, "header span lower bound")
                XCTAssertEqual(deque.capacity, cap, "capacity - head position \(pos)")
                XCTAssertEqual(deque.count, cap-gapSize, "count - head position \(pos)")
                XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer - head position \(pos)")
                
                deque.prepend(contentsOf: IntClass(-gapSize)..<0) // fill the gap
                XCTAssertEqual(Array(deque), Array(IntClass(-gapSize)..<IntClass(cap-gapSize)))
                XCTAssertEqual(deque.capacity, cap, "capacity - head position \(pos)")
                XCTAssertEqual(deque.count, cap, "count - head position \(pos)")
                XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage pointer - head position \(pos)")
            }
        }
    }
    
    // Appending or prepending to an empty buffer should result in contiguous storage.
    func testAppendPrependContiguous() {
        func assertNoReallocation(of buffer: inout Deque<IntClass>, with block: (inout Deque<IntClass>) -> Void) {
            let oldIdent = buffer.bufferIdentifier
            block(&buffer)
            XCTAssertEqual(buffer.bufferIdentifier, oldIdent, "buffer storage identifier")
        }
        
        var deque: Deque<IntClass> = []
        deque.reserveCapacity(10)
        assertNoReallocation(of: &deque) { (deque) in
            for i: IntClass in 0..<10 { deque.append(i) }
        }
        XCTAssert(deque.hasContiguousStorage, "buffer has contiguous storage")
        assertElementsEqual(deque, 0..<10)
        
        deque = []
        deque.reserveCapacity(10)
        assertNoReallocation(of: &deque) { (deque) in
            for i: IntClass in 0..<10 { deque.prepend(i) }
        }
        XCTAssert(deque.hasContiguousStorage, "buffer has contiguous storage")
        assertElementsEqual(deque, (0..<10).reversed())
        
        deque = []
        deque.reserveCapacity(10)
        assertNoReallocation(of: &deque) { (deque) in
            deque.append(contentsOf: 0..<5)
            deque.append(contentsOf: 5..<10)
        }
        XCTAssert(deque.hasContiguousStorage, "buffer has contiguous storage")
        assertElementsEqual(deque, 0..<10)
        
        // Note: we can't make this guarantee for prepend(contentsOf:) because that complicates
        // things too much. If we wanted to specialize for BidirectionalCollection then we could do
        // it easier, but we aren't doing that for now. So for the time being prepend(contentsOf:)
        // on an empty buffer acts like append(contentsOf:) instead and aligns the new elements to
        // the beginning of storage, so multiple calls to prepend(contentsOf:) will result in split
        // storage unless it has to reallocate. We can stil validate that a single call remains
        // contiguous though.
        deque = []
        deque.reserveCapacity(10)
        assertNoReallocation(of: &deque) { (deque) in
            deque.prepend(contentsOf: 0..<5)
        }
        XCTAssert(deque.hasContiguousStorage, "buffer has contiguous storage")
        assertElementsEqual(deque, 0..<5)
    }
    
    func testCopyOnWrite() {
        /// Shadows *deque* and asserts that the shadow was not modified across the call to
        /// *block*.
        func withShadow(of deque: inout Deque<IntClass>, _ block: (inout Deque<IntClass>) throws -> Void) rethrows {
            let shadow = deque
            let orig = (elements: Array(shadow), header: shadow._storage.header)
            let oldIdent = deque.bufferIdentifier
            try block(&deque)
            XCTAssertEqual(shadow.bufferIdentifier, oldIdent, "shadow storage")
            XCTAssertEqual(Array(shadow), orig.elements, "shadow elements")
            XCTAssertEqual(shadow._storage.header.capacity, orig.header.capacity, "shadow header capacity")
            XCTAssertEqual(shadow._storage.header.headSpan, orig.header.headSpan, "shadow header headSpan")
            XCTAssertEqual(shadow._storage.header.tailCount, orig.header.tailCount, "shadow header tailCount")
        }
        
        // Provides a deque with elements 0..<5 and a capacity of at least 10. Maintains a second
        // reference to the buffer, validates that the second reference isn't modified, and that the
        // buffer given to the function has its backing store modified.
        func assertCopies<C>(expected: C, _ f: (inout Deque<IntClass>) throws -> Void) rethrows
        where C: Collection, C.Element == IntClass
        {
            let origElements: [IntClass] = Array(0..<5)
            var deque = Deque<IntClass>(origElements)
            deque.reserveCapacity(10)
            XCTAssertEqual(Array(deque), origElements, "buffer elements")
            let oldIdent = deque.bufferIdentifier
            try withShadow(of: &deque, f)
            XCTAssertNotEqual(deque.bufferIdentifier, oldIdent, "buffer storage")
            XCTAssertEqual(Array(deque), Array(expected), "buffer elements")
        }
        
        assertCopies(expected: 0..<5, { $0.reserveCapacity($0.capacity+1) })
        assertCopies(expected: [10,1,2,3,4], { $0[$0.startIndex] = 10 })
        assertCopies(expected: 0..<6) { $0.append(5) }
        assertCopies(expected: -1..<5) { $0.prepend(-1) }
        assertCopies(expected: 0..<8) { $0.append(contentsOf: 5..<8) }
        assertCopies(expected: -3..<5) { $0.prepend(contentsOf: -3..<0) }
        assertCopies(expected: 1..<5) { XCTAssertEqual($0.removeFirst(), 0) }
        assertCopies(expected: 0..<4) { XCTAssertEqual($0.removeLast(), 4) }
        assertCopies(expected: 2..<5) { $0.removeFirst(2) }
        assertCopies(expected: 0..<3) { $0.removeLast(2) }
        assertCopies(expected: EmptyCollection()) { $0.removeAll(keepingCapacity: true) }
        assertCopies(expected: EmptyCollection()) { $0.removeAll(keepingCapacity: false) }
        assertCopies(expected: 0..<5) { XCTAssert($0.withContiguousMutableStorageIfAvailable({ _ in }) != nil, "does not have contiguous mutable storage") }
        
        // The following shouldn't copy since the buffer is empty
        do {
            var deque = Deque<IntClass>()
            let oldIdent = deque.bufferIdentifier
            withShadow(of: &deque) { (deque) in
                XCTAssertNil(deque.popFirst(), "popFirst")
                XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage")
                XCTAssertNil(deque.popLast(), "popLast")
                XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage")
                XCTAssertEqual(Array(deque), [], "buffer elements")
            }
        }
        
        // The following shouldn't copy because it's noncontiguous
        do {
            var deque = Deque<IntClass>()
            deque.reserveCapacity(3)
            for i: IntClass in 1...2 { deque.append(i) } // avoid append(contentsOf:) since it's a more complicated code path
            deque.prepend(0)
            // We should now have split storage
            XCTAssertGreaterThan(deque._storage.header.tailCount, 0, "buffer storage tail count")
            let oldIdent = deque.bufferIdentifier
            withShadow(of: &deque) { (deque) in
                XCTAssert(deque.withContiguousMutableStorageIfAvailable({ _ in }) == nil, "unexpected contiguous mutable storage")
            }
            XCTAssertEqual(deque.bufferIdentifier, oldIdent, "buffer storage")
        }
    }
    
    // Ensure that various mutation operations don't invalidate indices.
    func testIndexValidityPastMutation() {
        func runTests<C: Collection>(_ contents: C, minimumExtraCapacity: Int, _ block: (inout Deque<IntClass>) -> Void)
        where C.Element == IntClass
        {
            func runActivities(with buffer: inout Deque<IntClass>) {
                XCTContext.runActivity(named: "With CoW") { (_) in
                    let shadow = buffer
                    block(&buffer)
                    buffer = shadow // restore original contents
                }
                XCTContext.runActivity(named: "Uniquely owned") { (_) in
                    XCTAssertTrue(buffer._storage.isUniqueReference(), "storage is uniquely owned")
                    block(&buffer)
                }
            }
            XCTContext.runActivity(named: "Linear buffer aligned to front") { (_) in
                var buffer = Deque(contents)
                buffer.reserveCapacity(contents.count + minimumExtraCapacity)
                XCTAssertEqual(buffer._storage.header.headSpan.lowerBound, 0, "storage headSpan.lowerBound")
                XCTAssertEqual(buffer._storage.header.tailCount, 0, "storage tailCount")
                runActivities(with: &buffer)
            }
            XCTContext.runActivity(named: "Linear buffer aligned to end") { (_) in
                var buffer: Deque<IntClass> = []
                buffer.reserveCapacity(contents.count + minimumExtraCapacity)
                buffer.append(contentsOf: 0..<IntClass(buffer.capacity - contents.count))
                buffer.append(contentsOf: contents)
                buffer.removeFirst(buffer.count - contents.count)
                XCTAssertGreaterThan(buffer._storage.header.headSpan.lowerBound, 0, "storage headSpan.lowerBound")
                XCTAssertEqual(buffer._storage.header.tailCount, 0, "storage tailCount")
                runActivities(with: &buffer)
            }
            XCTContext.runActivity(named: "Buffer with head/tail split") { (_) in
                var buffer: Deque<IntClass> = []
                buffer.reserveCapacity(contents.count + minimumExtraCapacity)
                let pivot = contents.count / 2
                buffer.append(contentsOf: 0..<IntClass(buffer.capacity - pivot))
                buffer.append(contentsOf: contents.prefix(pivot))
                buffer.removeFirst(buffer.capacity - pivot)
                buffer.append(contentsOf: contents.dropFirst(pivot))
                XCTAssertGreaterThan(buffer._storage.header.tailCount, 0, "storage tailCount")
                runActivities(with: &buffer)
            }
        }
        func validateIndexes(after mutation: (inout Deque<IntClass>) -> Void) {
            runTests(0..<5, minimumExtraCapacity: 10) { (buffer) in
                let (startIndex, endIndex) = (buffer.startIndex, buffer.endIndex)
                mutation(&buffer)
                XCTAssertEqual(buffer.startIndex, startIndex, "startIndex after mutation")
                XCTAssertEqual(buffer.endIndex, endIndex, "endIndex after mutation")
            }
        }
        
        validateIndexes { $0.reserveCapacity($0.capacity) }
        validateIndexes { $0[$0.startIndex] += 10 }
        validateIndexes { $0.withContiguousMutableStorageIfAvailable({ _ in }) }
    }
    
    func testSubscript() {
        func assertSubscriptValues<S>(buffer: Deque<IntClass>, expected: S) where S: Sequence, S.Element == IntClass {
            var idx = buffer.startIndex
            for (i, value) in expected.enumerated() {
                XCTAssertEqual(buffer[idx], value, "subscript[\(i)]")
                buffer.formIndex(after: &idx)
            }
            XCTAssertEqual(idx, buffer.endIndex)
        }
        func mutateSubscripts(for buffer: inout Deque<IntClass>, with f: (inout IntClass) -> Void) {
            var idx = buffer.startIndex
            while idx != buffer.endIndex {
                f(&buffer[idx])
                buffer.formIndex(after: &idx)
            }
        }
        
        // Linear buffer
        var buffer = Deque<IntClass>(10..<15)
        assertSubscriptValues(buffer: buffer, expected: 10..<15)
        var oldIdent = buffer.bufferIdentifier
        mutateSubscripts(for: &buffer, with: { $0 += 10 })
        assertSubscriptValues(buffer: buffer, expected: 20..<25)
        XCTAssertEqual(buffer.bufferIdentifier, oldIdent, "buffer identifier")
        
        // Buffer with a tail
        buffer = Deque<IntClass>(10..<15)
        buffer.reserveCapacity(10)
        for i: IntClass in (7..<10).reversed() { buffer.prepend(i) }
        XCTAssertGreaterThan(buffer._storage.header.tailCount, 0, "storage tailCount")
        assertSubscriptValues(buffer: buffer, expected: 7..<15)
        oldIdent = buffer.bufferIdentifier
        mutateSubscripts(for: &buffer, with: { $0 += 10 })
        assertSubscriptValues(buffer: buffer, expected: 17..<25)
        XCTAssertEqual(buffer.bufferIdentifier, oldIdent, "buffer identifier")
        
        // Head-only buffer with a pre-head gap.
        buffer = Deque<IntClass>(10..<15)
        buffer.reserveCapacity(10)
        for i: IntClass in (7..<10).reversed() { buffer.prepend(i) }
        buffer.removeLast(5)
        XCTAssertEqual(buffer._storage.header.tailCount, 0, "storage tailCount")
        XCTAssertGreaterThan(buffer._storage.header.headSpan.lowerBound, 0, "storage headSpan.lowerBound")
        assertSubscriptValues(buffer: buffer, expected: 7..<10)
        oldIdent = buffer.bufferIdentifier
        mutateSubscripts(for: &buffer, with: { $0 += 10 })
        assertSubscriptValues(buffer: buffer, expected: 17..<20)
        XCTAssertEqual(buffer.bufferIdentifier, oldIdent, "buffer identifier")
    }
    
    func testEquatableAndHashable() {
        func runTests(with buffer: Deque<IntClass>) {
            // We want to compare with a contiguous Deque. To do that we'll round-trip through
            // Array first to linearize it.
            let linearBuffer = Deque(Array(buffer))
            XCTAssertEqual(linearBuffer._storage.header.headSpan.lowerBound, 0, "linear storage headSpan.lowerBound")
            XCTAssertEqual(linearBuffer._storage.header.tailCount, 0, "linear storage tailCount")
            // Check the linear buffer
            XCTAssertEqual(buffer, linearBuffer)
            XCTAssertEqual(buffer.hashValue, linearBuffer.hashValue, "hashValue")
            // Check variant: buffer with extra element
            let addOneBuffer = with(linearBuffer, { $0.append(42) })
            XCTAssertNotEqual(buffer, addOneBuffer)
            XCTAssertNotEqual(buffer.hashValue, addOneBuffer.hashValue, "hashValue")
            // Check variant: buffer without last element
            if !buffer.isEmpty {
                let dropLastBuffer = with(linearBuffer, { $0.removeLast() })
                XCTAssertNotEqual(buffer, dropLastBuffer)
                XCTAssertNotEqual(buffer.hashValue, dropLastBuffer.hashValue, "hashValue")
            }
            // Check variant: buffer rotated by one
            if !buffer.allSatisfy({ [first=buffer.first] in $0 == first }) {
                let rotatedBuffer = with(linearBuffer, { $0.append($0.removeFirst()) })
                XCTAssertNotEqual(buffer, rotatedBuffer)
                XCTAssertNotEqual(buffer.hashValue, rotatedBuffer.hashValue, "hashValue")
            }
            // Check variant: buffer with first element incremented
            if !buffer.isEmpty {
                let incrementedBuffer = with(linearBuffer, { $0[$0.startIndex] += 1 })
                XCTAssertNotEqual(buffer, incrementedBuffer)
                XCTAssertNotEqual(buffer.hashValue, incrementedBuffer.hashValue, "hashValue")
            }
        }
        
        XCTContext.runActivity(named: "Empty at capacity") { (_) in
            runTests(with: [])
        }
        XCTContext.runActivity(named: "Empty with capacity") { (_) in
            runTests(with: with([]) { $0.reserveCapacity(10) })
        }
        XCTContext.runActivity(named: "Contiguous at capacity") { (_) in
            runTests(with: with([]) {
                $0.reserveCapacity(10)
                for i in 0..<IntClass($0.capacity) { $0.append(i) }
                XCTAssertEqual($0.count, $0.capacity, "count == capacity")
            })
        }
        XCTContext.runActivity(named: "Contiguous with tail space") { (_) in
            runTests(with: with([]) {
                $0.reserveCapacity(10)
                for i: IntClass in 0..<5 { $0.append(i) }
                XCTAssertLessThan($0.count, $0.capacity, "count < capacity")
                XCTAssertEqual($0._storage.header.headSpan.lowerBound, 0, "storage headSpan.lowerBound")
            })
        }
        XCTContext.runActivity(named: "Contiguous with head space") { (_) in
            runTests(with: with([]) {
                $0.reserveCapacity(10)
                let headSpace = $0.capacity - 5
                for _ in 0..<headSpace { $0.append(0) }
                for i: IntClass in 0..<5 { $0.append(i) }
                $0.removeFirst(headSpace)
                XCTAssertLessThan($0.count, $0.capacity, "count < capacity")
                XCTAssertGreaterThan($0._storage.header.headSpan.lowerBound, 0, "storage headSpan.lowerBound")
                XCTAssertEqual($0._storage.header.tailCount, 0, "storage tailCount")
            })
        }
        XCTContext.runActivity(named: "Head/tail at capacity") { (_) in
            runTests(with: with([]) {
                $0.reserveCapacity(10)
                for i in 5..<IntClass($0.capacity) { $0.append(i) } // tail
                for i: IntClass in (0..<5).reversed() { $0.prepend(i) } // head
                XCTAssertEqual($0.count, $0.capacity, "count == capacity")
                XCTAssertEqual($0._storage.header.tailCount, 5, "storage tailCount")
            })
        }
        XCTContext.runActivity(named: "Head/tail with gap") { (_) in
            runTests(with: with([]) {
                $0.reserveCapacity(10)
                for i: IntClass in 4..<8 { $0.append(i) } // tail
                for i: IntClass in (0..<4).reversed() { $0.prepend(i) } // head
                XCTAssertLessThan($0.count, $0.capacity, "count < capacity")
                XCTAssertGreaterThan($0._storage.header.tailCount, 0, "storage tailCount")
                XCTAssertGreaterThan($0._storage.header.headSpan.lowerBound, $0._storage.header.tailCount, "storage headSpan.lowerBound > tailCount")
            })
        }
    }
    
    // Ensure that we can modify elements at subscripts without taking extra retains (which would
    // force copies of CoW elements).
    func testSubscriptModify() {
        struct Elt {
            mutating func validateUniquelyOwned() {
                XCTAssert(isKnownUniquelyReferenced(&_storage), "isKnownUniquelyReferenced")
            }
            class Storage {}
            var _storage = Storage()
        }
        var deque = Deque([Elt()])
        deque[deque.startIndex].validateUniquelyOwned()
    }
    
    func testInitUnsafeInitializedCapacity() {
        func assertLinear<C: Collection>(_ buffer: Deque<IntClass>, withContents contents: C) where C.Element == IntClass {
            assertElementsEqual(buffer, contents, "buffer contents")
            XCTAssertEqual(buffer._storage.header.headSpan.lowerBound, 0, "storage headSpan.lowerBound")
            XCTAssertEqual(buffer._storage.header.tailCount, 0, "storage tailCount")
        }
        
        // Asking for a buffer of size 0 should give us the shared empty buffer. It will call our
        // initializer anyway.
        let expectation = XCTestExpectation(description: "initializer invoked")
        XCTAssertEqual(Deque<IntClass>(unsafeUninitializedCapacity: 0, initializingWith: { (buffer, initializedCount) in
            XCTAssertEqual(buffer.count, 0, "buffer count")
            XCTAssertEqual(initializedCount, 0, "default initializedCount")
            expectation.fulfill()
        })._storage, Deque<IntClass>()._storage, "storage pointers")
        wait(for: [expectation], timeout: 0)
        
        assertLinear(Deque(unsafeUninitializedCapacity: 1, initializingWith: { (buffer, initializedCount) in
            XCTAssertEqual(buffer.count, 1, "buffer count")
            XCTAssertEqual(initializedCount, 0, "default initializedCount")
            buffer.baseAddress!.initialize(to: 42)
            initializedCount = 1
        }), withContents: [42])
        assertLinear(Deque(unsafeUninitializedCapacity: 2, initializingWith: { (buffer, initializedCount) in
            XCTAssertEqual(buffer.count, 2, "buffer count")
            XCTAssertEqual(initializedCount, 0, "default initializedCount")
            buffer.baseAddress!.initialize(to: 42)
            initializedCount = 1
        }), withContents: [42])
        assertLinear(Deque(unsafeUninitializedCapacity: 2, initializingWith: { (buffer, initializedCount) in
            XCTAssertEqual(buffer.count, 2, "buffer count")
            XCTAssertEqual(initializedCount, 0, "default initializedCount")
            _ = buffer.initialize(from: [42,84])
            initializedCount = 2
        }), withContents: [42,84])
        assertLinear(Deque(unsafeUninitializedCapacity: 17, initializingWith: { (buffer, initializedCount) in
            XCTAssertEqual(buffer.count, 17, "buffer count")
            XCTAssertEqual(initializedCount, 0, "default initializedCount")
            _ = buffer.initialize(from: 0..<5)
            initializedCount = 5
        }), withContents: 0..<5)
        
        // Throwing an error during buffer creation shouldn't leak any initialized objects. Test
        // throwing here, the leak check is already done for all tests (see `setUpWithError()`).
        struct Err: Error {}
        XCTAssertThrowsError(try Deque<IntClass>(unsafeUninitializedCapacity: 5, initializingWith: { (buffer, initializedCount) in
            _ = buffer.initialize(from: 0..<3)
            initializedCount = 3
            throw Err()
        })) { (error) in
            XCTAssert(error is Err, "expected Err, got \(error)")
        }
    }
    
    func testMutationViaIndicesType() {
        // Mutating the array in a loop with `indices` should not trigger CoW behavior.
        var deque: Deque<IntClass> = [1,2,3]
        var oldIdent = deque.bufferIdentifier
        for idx in deque.indices {
            deque[idx] += 10
        }
        XCTAssertEqual(deque.bufferIdentifier, oldIdent, "storage identifier")
        assertElementsEqual(deque, [11,12,13], "buffer contents")
        
        // Also test subranges of indices
        for idx in deque.indices.dropFirst() {
            deque[idx] += 10
        }
        XCTAssertEqual(deque.bufferIdentifier, oldIdent, "storage identifier")
        assertElementsEqual(deque, [11,22,23], "buffer contents")
        
        // Also test a noncontiguous buffer, just in case
        deque.reserveCapacity(10)
        deque.prepend(1)
        deque.prepend(0)
        oldIdent = deque.bufferIdentifier
        for idx in deque.indices {
            deque[idx] += 1
        }
        XCTAssertEqual(deque.bufferIdentifier, oldIdent, "storage identifier")
        assertElementsEqual(deque, [1,2,12,23,24], "buffer contents")
    }
    
    func testPopFirstLast() {
        var deque: Deque<IntClass> = []
        
        // empty
        XCTAssertNil(deque.popFirst())
        XCTAssertNil(deque.popLast())
        
        // head-only storage
        deque.reserveCapacity(10)
        for i: IntClass in 0..<3 { deque.append(i) }
        XCTAssertEqual(deque.popFirst(), 0)
        XCTAssertEqual(deque.popLast(), 2)
        XCTAssertEqual(deque.popFirst(), 1)
        XCTAssert(deque.isEmpty)
        
        // split storage
        deque = []
        deque.reserveCapacity(10)
        for i: IntClass in 2..<4 { deque.append(i) } // tail
        for i: IntClass in (0..<2).reversed() { deque.prepend(i) } // head
        XCTAssertEqual(deque._storage.header.tailCount, 2, "storage tailCount")
        XCTAssertEqual(deque.popFirst(), 0)
        XCTAssertEqual(deque.popLast(), 3)
        XCTAssertEqual(deque.popFirst(), 1)
        // We should have reverted to head-only storage now
        XCTAssertEqual(deque._storage.header.tailCount, 0, "storage tailCount")
        XCTAssertEqual(deque._storage.header.headSpan, 0..<1, "storage headSpan")
        XCTAssertEqual(deque.popFirst(), 2)
        XCTAssertEqual(deque._storage.header.headSpan, 0..<0, "storage headSpan")
    }
    
    func testRemoveFirstN() {
        var deque: Deque<IntClass> = []
        
        // empty
        deque.removeFirst(0) // should not crash
        XCTAssert(deque.isEmpty)
        
        // head-only storage
        deque.reserveCapacity(10)
        for i: IntClass in 0..<5 { deque.append(i) }
        assertElementsEqual(deque, 0..<5, "test setup")
        deque.removeFirst(0)
        assertElementsEqual(deque, 0..<5, "nothing removed")
        deque.removeFirst(3)
        assertElementsEqual(deque, 3..<5, "first 3 removed")
        deque.removeFirst(2)
        assertElementsEqual(deque, [], "remainder removed")
        
        // split storage
        deque = []
        deque.reserveCapacity(10)
        for i: IntClass in 4..<8 { deque.append(i) } // tail
        for i: IntClass in (0..<4).reversed() { deque.prepend(i) } // head
        XCTAssertEqual(deque._storage.header.tailCount, 4, "storage tailCount")
        assertElementsEqual(deque, 0..<8, "test setup")
        deque.removeFirst(2)
        assertElementsEqual(deque, 2..<8, "first 2 removed")
        XCTAssertEqual(deque._storage.header.tailCount, 4, "storage tailCount") // tail should be unaffected
        deque.removeFirst(2) // remove the rest of the head
        assertElementsEqual(deque, 4..<8, "rest of head removed")
        XCTAssertEqual(deque._storage.header.tailCount, 0, "storage tailCount") // tail should have turned into head
        for i: IntClass in (2..<4).reversed() { deque.prepend(i) } // restore the head/tail split
        XCTAssertEqual(deque._storage.header.tailCount, 4, "storage tailCount")
        deque.removeFirst(4) // remove head and part of tail
        assertElementsEqual(deque, 6..<8)
        XCTAssertEqual(deque._storage.header.tailCount, 0, "storage tailCount") // tail is once again the head
        for i: IntClass in (0..<6).reversed() { deque.prepend(i) } // restore the head/tail split
        XCTAssertEqual(deque._storage.header.tailCount, 4, "storage tailCount")
        assertElementsEqual(deque, 0..<8)
        deque.removeFirst(8) // clear everything
        assertElementsEqual(deque, [])
        XCTAssertEqual(deque._storage.header.headSpan, 0..<0, "storage headSpan")
    }
    
    func testRemoveLastN() {
        var deque: Deque<IntClass> = []
        
        // empty
        deque.removeLast(0) // should not crash
        XCTAssert(deque.isEmpty)
        
        // head-only storage
        deque.reserveCapacity(10)
        for i: IntClass in 0..<5 { deque.append(i) }
        assertElementsEqual(deque, 0..<5, "test setup")
        deque.removeLast(0)
        assertElementsEqual(deque, 0..<5, "nothing removed")
        deque.removeLast(3)
        assertElementsEqual(deque, 0..<2, "last 3 removed")
        deque.removeLast(2)
        assertElementsEqual(deque, [], "remainder removed")
        
        // split storage
        deque = []
        deque.reserveCapacity(10)
        for i: IntClass in 4..<8 { deque.append(i) } // tail
        for i: IntClass in (0..<4).reversed() { deque.prepend(i) } // head
        XCTAssertEqual(deque._storage.header.tailCount, 4, "storage tailCount")
        assertElementsEqual(deque, 0..<8, "test setup")
        deque.removeLast(2)
        assertElementsEqual(deque, 0..<6, "last 2 removed")
        XCTAssertEqual(deque._storage.header.tailCount, 2, "storage tailCount")
        deque.removeLast(2) // remove the rest of the tail
        assertElementsEqual(deque, 0..<4, "rest of tail removed")
        XCTAssertEqual(deque._storage.header.tailCount, 0, "storage tailCount")
        for i: IntClass in 4..<6 { deque.append(i) } // restore the head/tail split
        XCTAssertEqual(deque._storage.header.tailCount, 2, "storage tailCount")
        deque.removeLast(4) // remove tail and part of head
        assertElementsEqual(deque, 0..<2)
        XCTAssertEqual(deque._storage.header.tailCount, 0, "storage tailCount")
        for i: IntClass in 2..<8 { deque.append(i) } // restore the head/tail split
        XCTAssertEqual(deque._storage.header.tailCount, 4, "storage tailCount")
        assertElementsEqual(deque, 0..<8)
        deque.removeLast(8) // clear everything
        assertElementsEqual(deque, [])
        XCTAssertEqual(deque._storage.header.headSpan, 0..<0, "storage headSpan")
    }
    
    func testCodable() throws {
        #if canImport(Foundation)
        // Deque and Array should have the same encoded representation
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for ary: [Int] in [[], [1], [1,2,3]] {
            XCTAssertNoThrow(try {
                let deque = try decoder.decode(Deque<Int>.self, from: encoder.encode(ary))
                assertElementsEqual(deque, ary)
            }())
            XCTAssertNoThrow(try {
                let deque = Deque(ary)
                let ary2 = try decoder.decode(Array<Int>.self, from: encoder.encode(deque))
                XCTAssertEqual(ary2, ary)
                assertElementsEqual(ary2, deque) // for good measure
            }())
        }
        #else
        throw XCTSkip("This test requires Foundation")
        #endif
    }
    
    func testDescription() {
        XCTAssertEqual("\(Deque<IntClass>())", "[]")
        XCTAssertEqual("\(Deque<IntClass>([1]))", "[1]")
        XCTAssertEqual("\(Deque<IntClass>([1,2]))", "[1, 2]")
        XCTAssertEqual("\(Deque(["test"]))", "[\"test\"]")
    }
    
    func testDebugDescription() {
        // Our debugDescription prints as "Deque" instead of "Deque.Deque" because the latter seems
        // redundant.
        XCTAssertEqual(String(reflecting: Deque<IntClass>()), "Deque([])")
        XCTAssertEqual(String(reflecting: Deque<IntClass>([1])), "Deque([1])")
        XCTAssertEqual(String(reflecting: Deque<IntClass>([1,2])), "Deque([1, 2])")
        XCTAssertEqual(String(reflecting: Deque(["test"])), "Deque([\"test\"])")
    }
    
    func testMirror() {
        let mirror = Mirror(reflecting: Deque([1,2,3]))
        XCTAssertEqual(mirror.children.map({ $0.label }), [nil, nil, nil], "children labels")
        XCTAssertEqual(mirror.children.map({ $0.value as? Int }), [1,2,3], "children values")
        assertElementsEqual(mirror.children, [(label: String?.none, value: 1), (nil, 2), (nil, 3)], by: { ($0.label, $0.value as? Int) == ($1.label, $1.value) })
    }
    
    static var allTests = [
        ("testEmptyBufferStorage", testEmptyBufferStorage),
        ("testInitWithSequence", testInitWithSequence),
        ("testCopyToArray", testCopyToArray),
        ("testReserveCapacity", testReserveCapacity),
        ("testWithContiguousStorageIfAvailable", testWithContiguousStorageIfAvailable),
        ("testWithContiguousMutableStorageIfAvailable", testWithContiguousMutableStorageIfAvailable),
        ("testIsEmpty", testIsEmpty),
        ("testUnderestimatedCountAndCount", testUnderestimatedCountAndCount),
        ("testIndexTraversals", testIndexTraversals),
        ("testAppendReallocation", testAppendReallocation),
        ("testPrependReallocation", testPrependReallocation),
        ("testAppendContentsOfReallocation", testAppendContentsOfReallocation),
        ("testPrependContentsOfReallocation", testPrependContentsOfReallocation),
        ("testAppendPrependContiguous", testAppendPrependContiguous),
        ("testCopyOnWrite", testCopyOnWrite),
        ("testIndexValidityPastMutation", testIndexValidityPastMutation),
        ("testSubscript", testSubscript),
        ("testEquatableAndHashable", testEquatableAndHashable),
        ("testSubscriptModify", testSubscriptModify),
        ("testInitUnsafeInitializedCapacity", testInitUnsafeInitializedCapacity),
        ("testMutationViaIndicesType", testMutationViaIndicesType),
        ("testCodable", testCodable),
        ("testDescription", testDescription),
        ("testDebugDescription", testDebugDescription),
        ("testMirror", testMirror),
    ]
}

// MARK: -

private extension Deque {
    var hasContiguousStorage: Bool {
        return withContiguousStorageIfAvailable({ _ in () }) != nil
    }
    
    var bufferIdentifier: ObjectIdentifier {
        return ObjectIdentifier(_storage.buffer)
    }
}

private struct UnknownLengthSequence<Base: Sequence>: Sequence {
    var base: Base
    var underestimatedCount: Int
    init(_ base: Base, underestimatedCount: Int = 0) {
        self.base = base
        self.underestimatedCount = underestimatedCount
    }
    
    func makeIterator() -> Base.Iterator {
        return base.makeIterator()
    }
}

private func with<T>(_ value: T, _ block: (inout T) throws -> Void) rethrows -> T {
    var value = value
    try block(&value)
    return value
}

// TestUtilities.swift has XCTAssertElementsEqual but it doesn't synthesize a message.
// We're going to ignore that and just do this ourselves.
private func assertElementsEqual<C1: Collection, C2: Collection>(
    _ c1: C1, _ c2: C2,
    by areEquivalent: (C1.Element, C2.Element) throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    func colDesc<C: Collection>(_ col: C) -> String {
        // We can't assume all collections have an appropriate description
        return "[\(col.lazy.map({ "\($0)" }).joined(separator: ","))]"
    }
    func msg() -> String {
        let str = message()
        return str.isEmpty ? str : " - \(str)"
    }
    XCTAssert(try c1.elementsEqual(c2, by: areEquivalent), "\(colDesc(c1)) is not equal to \(colDesc(c2))\(msg())",
              file: file, line: line)
}

private func assertElementsEqual<C1: Collection, C2: Collection>(
    _ c1: C1, _ c2: C2,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) where C1.Element == C2.Element, C1.Element: Equatable {
    assertElementsEqual(c1, c2, by: ==, message(), file: file, line: line)
}

/// A class type that acts like an integer.
///
/// This exists to test Deque's initialization/deinitialization of memory.
private final class IntClass: ExpressibleByIntegerLiteral, Comparable, Hashable, Strideable, CustomStringConvertible, Codable {
    typealias Stride = Int
    
    // Note: Our tests are single-threaded so we don't need to worry about synchronization here.
    static var counter: UInt = 0
    
    let value: Int
    
    init(_ value: Int) {
        self.value = value
        Self.counter += 1
    }
    
    required convenience init(integerLiteral value: IntegerLiteralType) {
        self.init(value)
    }
    
    deinit {
        Self.counter -= 1
    }
    
    static func == (lhs: IntClass, rhs: IntClass) -> Bool {
        return lhs.value == rhs.value
    }
    
    static func < (lhs: IntClass, rhs: IntClass) -> Bool {
        return lhs.value < rhs.value
    }
    
    static func + (lhs: IntClass, rhs: Int) -> IntClass {
        return IntClass(lhs.value + rhs)
    }
    
    static func - (lhs: IntClass, rhs: Int) -> IntClass {
        return IntClass(lhs.value - rhs)
    }
    
    static func += (lhs: inout IntClass, rhs: Int) {
        lhs = IntClass(lhs.value + rhs)
    }
    
    static func -= (lhs: inout IntClass, rhs: Int) {
        lhs = IntClass(lhs.value - rhs)
    }
    
    func advanced(by n: Int) -> IntClass {
        return IntClass(value + n)
    }
    
    func distance(to other: IntClass) -> Int {
        return other.value - value
    }
    
    func isMultiple(of other: IntClass) -> Bool {
        return value.isMultiple(of: other.value)
    }
    
    var description: String {
        return "\(value)"
    }
    
    func hash(into hasher: inout Hasher) {
        value.hash(into: &hasher)
    }
    
    init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Int.self)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
