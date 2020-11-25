//
//  Deque.swift
//
//  Copyright © 2020 Lily Ballard.
//  Licensed under Apache License v2.0 with Runtime Library Exception
//
//  See https://github.com/lilyball/swift-deque/blob/main/LICENSE.txt for license information.
//

// See the doc comment on _DequeHeader for layout details.

/// A collection which supports efficient mutation at the front and back.
///
/// `Deque` is a random-access collection similar to `Array`, but it's backed by a growable ring
/// buffer and supports efficient insertion and removal at the front and back.
public struct Deque<Element>: RandomAccessCollection, MutableCollection {
    public typealias Index = DequeIndex
    
    /// The total number of elements that the deque can contain without allocating new storage.
    @inlinable
    public var capacity: Int {
        return _storage.header.capacity
    }
    
    @inlinable
    public var underestimatedCount: Int {
        return count
    }
    
    @inlinable
    public var count: Int {
        return _storage.header.count
    }
    
    @inlinable
    public var isEmpty: Bool {
        return _storage.header.headSpan.isEmpty
    }
    
    @inlinable
    public var startIndex: Index {
        return _storage.header.startIndex
    }
    
    @inlinable
    public var endIndex: Index {
        return _storage.header.endIndex
    }
    
    /// The indices that are valid for subscripting the collection, in ascending order.
    ///
    /// Iterating over the `indices` does not keep a strong reference to the `Deque`, which allows
    /// for index-preserving mutations without triggering copy-on-write behavior.
    ///
    /// ```swift
    /// var deque = Deque(1...5)
    /// for idx in deque.indices {
    ///     deque[idx] += 10
    /// }
    /// ```
    @inlinable
    public var indices: Indices {
        let header = _storage.header
        return Indices(header: header, startIndex: header.startIndex, endIndex: header.endIndex)
    }
    
    @inlinable
    public func makeIterator() -> Iterator {
        return Iterator(_buffer: self)
    }
    
    /// Creates a new, empty deque.
    ///
    /// This is equivalent to initializing with an empty array literal.
    @inlinable
    public init() {
        // Start off empty so creating new deques is cheap
        _storage = ManagedBufferPointer(unsafeBufferObject: _DequeEmptyStorage.shared)
    }
    
    /// Creates a deque containing the elements of a sequence.
    ///
    /// - Parameter elements: The sequence of elements to turn into a deque.
    @inlinable
    public init<S: Sequence>(_ elements: S) where S.Element == Element {
        if let other = elements as? Deque<Element> {
            // If it's a deque, just share the storage.
            _storage = other._storage
            return
        }
        let initialCount = elements.underestimatedCount
        if initialCount > 0 {
            _storage = _Storage.create(minimumCapacity: initialCount)
            // fast-path the initial elements, we don't need to check capacity on them
            let iter = _storage.withUnsafeMutablePointers({ (headerPtr, elemPtr) -> S.Iterator in
                let buf = UnsafeMutableBufferPointer(start: elemPtr, count: headerPtr.pointee.capacity)
                let (iter, count) = buf.initialize(from: elements)
                headerPtr.pointee.headSpan = 0..<count
                return iter
            })
            // Push any remaining elements on
            append(contentsOf: IteratorSequence(iter))
        } else {
            // Start empty
            _storage = ManagedBufferPointer(unsafeBufferObject: _DequeEmptyStorage.shared)
            // Push any elements on if the sequence is non-empty
            append(contentsOf: elements)
        }
    }
    
    /// Creates a deque with the specified capacity, then calls the given closure with a buffer
    /// covering the deque's uninitialized memory.
    ///
    /// Inside the closure, set the `initializedCount` parameter to the number of elements that are
    /// initialized by the closure. The memory in the range `buffer[0..<initializedCount]` must be
    /// initialized at the end of the closure's execution, and the memory in the range
    /// `buffer[initializedCount...]` must be uninitialized. This postcondition must hold even if
    /// the `initializer` closure throws an error.
    ///
    /// - Note: While the resulting deque may have a capacity larger than the requested amount, the
    ///   buffer passed to the closure will cover exactly the requested number of elements.
    ///
    /// - Parameter unsafeUninitializedCapacity: The number of elements to allocate space for in the
    ///   new deque.
    /// - Parameter initializer: A closure that initializes elements and sets the count of the new
    ///   deque.
    /// - Parameter buffer: A buffer covering uninitialized memory with room for the specified
    ///   number of elements.
    /// - Parameter initializedCount: The count of initialized elements in the deque, which begins
    ///   as zero. Set `initializedCount` to the number of elements you initialize.
    @inlinable
    public init(
        unsafeUninitializedCapacity: Int,
        initializingWith initializer: (
            _ buffer: inout UnsafeMutableBufferPointer<Element>,
            _ initializedCount: inout Int
        ) throws -> Void
    ) rethrows {
        if unsafeUninitializedCapacity > 0 {
            _storage = _Storage.create(minimumCapacity: unsafeUninitializedCapacity)
        } else {
            _storage = ManagedBufferPointer(unsafeBufferObject: _DequeEmptyStorage.shared)
        }
        try _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
            var buffer = UnsafeMutableBufferPointer(start: elemPtr, count: unsafeUninitializedCapacity)
            var initializedCount = 0
            defer {
                // Update our header spans even if the block throws an error.
                precondition(initializedCount <= unsafeUninitializedCapacity, "Initialized count set to greater than specified capacity.")
                precondition(buffer.baseAddress == elemPtr, "Can't reassign buffer in Deque(unsafeUninitializedCapacity:initializingWith:)")
                headerPtr.pointee.headSpan = 0..<initializedCount
            }
            try initializer(&buffer, &initializedCount)
        }
    }
    
    @inlinable
    public subscript(position: Index) -> Element {
        _read {
            let (offset, isTail) = (position._offset, position._rawValue >= Index._tailFlag)
            precondition(isTail ? (0..<_storage.header.tailCount).contains(offset) : _storage.header.headSpan.contains(offset), "Index out of range")
            yield _storage[_unsafeElementAt: offset]
        }
        _modify {
            let (offset, isTail) = (position._offset, position._rawValue >= Index._tailFlag)
            precondition(isTail ? (0..<_storage.header.tailCount).contains(offset) : _storage.header.headSpan.contains(offset), "Index out of range")
            _makeUniqueWithCurrentCapacity()
            yield &_storage[_unsafeElementAt: offset]
        }
    }
    
    @inlinable
    public func formIndex(after i: inout Index) {
        _storage.header.formIndex(after: &i)
    }
    
    @inlinable
    public func index(after i: Index) -> Index {
        return _storage.header.index(after: i)
    }
    
    @inlinable
    public func formIndex(before i: inout Index) {
        _storage.header.formIndex(before: &i)
    }
    
    @inlinable
    public func index(before i: Index) -> Index {
        return _storage.header.index(before: i)
    }
    
    // Note: formIndex(_:offsetBy:) is not actually declared in any collection protocol, it's
    // instead provided as an extension using index(_:offsetBy:), so we can skip it.
    
    @inlinable
    public func index(_ i: Index, offsetBy distance: Int) -> Index {
        return _storage.header.index(i, offsetBy: distance)
    }
    
    @inlinable
    public func distance(from start: Index, to end: Index) -> Int {
        return _storage.header.distance(from: start, to: end)
    }
    
    /// Reserves enough space to store the specified number of elements.
    ///
    /// If you are adding a known number of elements to a deque, use this method to avoid multiple
    /// reallocations. This method ensures that the deque has unique, mutable storage, with space
    /// allocated for at least the requested number of elements.
    ///
    /// For performance reasons, the size of the newly allocated storage might be greater than the
    /// requested capacity. Use the deque's `capacity` property to determine the size of the new
    /// storage.
    ///
    /// - Parameter minimumCapacity: The requested number of elements to store.
    ///
    /// - Note: Calling this method may invalidate any existing indices for use with this collection
    ///   if the storage is reallocated and `minimumCapacity` is not identical to the current
    ///   capacity.
    /// - Complexity: O(*n*), where *n* is the number of elements in the deque.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        // Always ensure storage is unique regardless of requested capacity
        if !_hasUniqueStorage(withMinimumCapacity: minimumCapacity) {
            _forceUnique(withMinimumCapacity: minimumCapacity)
        }
    }
    
    /// Adds a new element at the end of the deque.
    ///
    /// - Parameter newElement: The element to append to the deque.
    ///
    /// - Note: Calling this method may invalidate any existing indices for use with this collection
    ///   if the storage reallocates to increase capacity. If this method invalidates indices the
    ///   `startIndex` value will change.
    /// - Complexity: O(1) on average, over many calls to `append(_:)` on the same deque.
    @inlinable
    public mutating func append(_ newElement: Element) {
        if !_hasUniqueStorage(withMinimumCapacity: count + 1) {
            _forceUnique(withMinimumCapacity: capacity > count ? capacity : _growDequeCapacity(capacity))
        }
        _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
            if headerPtr.pointee.headSpan.upperBound < headerPtr.pointee.capacity {
                // Append to head
                (elemPtr + headerPtr.pointee.headSpan.upperBound).initialize(to: newElement)
                headerPtr.pointee.headSpan = headerPtr.pointee.headSpan.lowerBound..<(headerPtr.pointee.headSpan.upperBound + 1)
            } else {
                // Append to tail
                (elemPtr + headerPtr.pointee.tailCount).initialize(to: newElement)
                headerPtr.pointee.tailCount += 1
            }
        }
    }
    
    /// Adds the elements of a sequence to the end of the deque.
    ///
    /// - Parameter newElements: The elements to append to the deque.
    ///
    /// - Note: Calling this method may invalidate any existing indices for use with this collection
    ///   if the storage reallocates to increase capacity. If this method invalidates indices the
    ///   `startIndex` value will change.
    /// - Complexity: O(*m*) on average, where *m* is the length of `newElements`, over many calls
    ///   to `append(contentsOf:)` on the same deque.
    @inlinable
    public mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Element {
        let newElementCount = newElements.underestimatedCount
        let iter: S.Iterator?
        
        if newElementCount == 0 && capacity == count {
            // Don't force a copy for a non-unique receiver until we've confirmed we actually have
            // elements
            iter = newElements.makeIterator()
        } else {
            _reserveCapacityForAppend(newElementCount: newElementCount)
            
            iter = _storage.withUnsafeMutablePointers({ (headerPtr, elemPtr) -> S.Iterator? in
                if headerPtr.pointee.headSpan.upperBound < headerPtr.pointee.capacity {
                    // Copy into the head
                    let buf = UnsafeMutableBufferPointer(start: elemPtr + headerPtr.pointee.headSpan.upperBound,
                                                         count: headerPtr.pointee.capacity - headerPtr.pointee.headSpan.upperBound)
                    var (iter, count): (S.Iterator, Int)
                    if buf.count >= newElementCount {
                        (iter, count) = buf.initialize(from: newElements)
                    } else {
                        // initialize(from:) requires that the buffer have enough space for the
                        // source's underestimatedElements. Since it doesn't, we'll have to copy by
                        // hand. I wish we could just initialize from
                        // `newElements.prefix(buf.count)` but that will give us the wrong iterator
                        // type. So we'll just do this by hand.
                        iter = newElements.makeIterator()
                        count = 0
                        var ptr = buf.baseAddress!
                        while count < buf.count, let elt = iter.next() {
                            ptr.initialize(to: elt)
                            ptr += 1
                            count += 1
                        }
                    }
                    headerPtr.pointee.headSpan = headerPtr.pointee.headSpan.lowerBound..<(headerPtr.pointee.headSpan.upperBound + count)
                    guard count == buf.count else {
                        // We exhausted the elements
                        return nil
                    }
                    
                    // Copy into the tail
                    // Note: We can't use tailBuf.initialize(from: IteratorSequence(iter)) as that gives
                    // us the wrong iterator type. IteratorSequence doesn't have an optimized
                    // _copyContents anyway though so we can just loop ourselves.
                    let tailCapacity = headerPtr.pointee.headSpan.lowerBound
                    guard tailCapacity > 0 else {
                        // No room in the tail for elements. Fall back to slow path
                        return iter
                    }
                    var ptr = elemPtr
                    for _ in 0..<tailCapacity {
                        guard let x = iter.next() else { break }
                        ptr.initialize(to: x)
                        ptr += 1
                    }
                    let tailCount = ptr - elemPtr
                    headerPtr.pointee.tailCount = tailCount
                    return tailCount == tailCapacity
                        ? iter
                        : nil // we exhausted the elements
                } else {
                    // Copy into the tail
                    let buf = UnsafeMutableBufferPointer(start: elemPtr + headerPtr.pointee.tailCount,
                                                         count: headerPtr.pointee.headSpan.lowerBound - headerPtr.pointee.tailCount)
                    let (iter, count) = buf.initialize(from: newElements)
                    headerPtr.pointee.tailCount += count
                    return count == buf.count
                        ? iter
                        : nil // we exhausted the elements
                }
            })
        }
        
        if var iter = iter {
            // There may be elements left. Try appending them now
            assert(capacity == count) // we shouldn't hit this if we had any space left
            var nextItem = iter.next()
            while nextItem != nil {
                // Grow the array
                _reserveCapacityForAppend(newElementCount: 1)
                // Fill up the new space
                _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
                    assert(headerPtr.pointee.headSpan.lowerBound == 0) // new copies should be linearized since we grew capacity
                    let capacity = headerPtr.pointee.capacity
                    var newCount = headerPtr.pointee.headSpan.upperBound
                    while let next = nextItem, newCount < capacity {
                        (elemPtr + newCount).initialize(to: next)
                        newCount += 1
                        nextItem = iter.next()
                    }
                    headerPtr.pointee.headSpan = 0..<newCount
                }
            }
        }
    }
    
    /// Adds a new element at the front of the deque.
    ///
    /// - Parameter newElement: The element to prepend to the deque.
    ///
    /// - Note: Calling this method may invalidate any existing indices for use with this collection
    ///   if the storage reallocates to increase capacity or if the storage transitions from
    ///   contiguous to noncontiguous. If this method invalidates indices the `endIndex` value will
    ///   change.
    /// - Complexity: O(1) on average, over many calls to `prepend(_:)` on the same deque.
    @inlinable
    public mutating func prepend(_ newElement: Element) {
        if !_hasUniqueStorage(withMinimumCapacity: count + 1) {
            _forceUnique(withMinimumCapacity: capacity > count ? capacity : _growDequeCapacity(capacity))
        }
        _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
            if headerPtr.pointee.headSpan.lowerBound == 0 {
                // Wrap around to the end of the buffer
                let offset = headerPtr.pointee.capacity - 1
                (elemPtr + offset).initialize(to: newElement)
                headerPtr.pointee.tailCount = headerPtr.pointee.headSpan.count
                headerPtr.pointee.headSpan = offset..<(offset+1)
            } else {
                // There's space before the head
                let newHead = headerPtr.pointee.headSpan.lowerBound - 1
                (elemPtr + newHead).initialize(to: newElement)
                headerPtr.pointee.headSpan = newHead..<headerPtr.pointee.headSpan.upperBound
            }
        }
    }
    
    /// Adds the elements of a sequence to the beginning of the deque.
    ///
    /// - Parameter newElements: The elements to prepend to the deque.
    ///
    /// - Note: Calling this method may invalidate any existing indices for use with this collection
    ///   if the storage reallocates to increase capacity or if the storage transitions from
    ///   contiguous to noncontiguous. If this method invalidates indices the `endIndex` value will
    ///   change.
    /// - Complexity: O(*m*) on average, where *m* is the length of `newElements`, over many calls
    ///   to `prepend(contentsOf:)` on the same deque.
    @inlinable
    public mutating func prepend<S: Sequence>(contentsOf newElements: S) where S.Element == Element {
        guard !isEmpty else {
            // If we're empty, fall back to the append path as it's simpler.
            append(contentsOf: newElements)
            return
        }
        
        let newElementCount = newElements.underestimatedCount
        let data: (iter: S.Iterator, newStorage: _Storage.Manager)?
        
        // We're going to try and fill our existing space if possible. If we can't do that, we'll
        // allocate new storage, fill that with the new elements, then append our current contents
        // after that.
        
        if newElementCount > 0 && _hasUniqueStorage(withMinimumCapacity: count + newElementCount) {
            // We have enough space for the stated count of newElements. Let's fill that and hope it
            // has no more elements. If it does, we'll have to switch tactics.
            data = _storage.withUnsafeMutablePointers({ (headerPtr, elemPtr) -> (iter: S.Iterator, newStorage: _Storage.Manager)? in
                // We have enough storage for the new elements. There are three scenarios:
                // 1. We only have a head, and there's enough space before the head for the elements.
                // 2. We only have a head, but there's not enough space so we need to create a tail.
                // 3. We already have a tail, at which point all the space must be between the tail and head.
                // In cases 1 and 3, we can simply extend the head backwards. Case 2 turns our current head
                // into the tail and places any remaining elements into the new head.
                var iter: S.Iterator
                /// The number of elements prefixed onto the current head span.
                let headPrefix: Int
                if headerPtr.pointee.headSpan.lowerBound >= newElementCount {
                    // Copy into the head
                    headPrefix = newElementCount
                    let buf = UnsafeMutableBufferPointer(start: elemPtr + (headerPtr.pointee.headSpan.lowerBound - headPrefix),
                                                         count: newElementCount)
                    let count: Int
                    (iter, count) = buf.initialize(from: newElements)
                    precondition(count == newElementCount, "newElements.underestimatedCount was an overestimate")
                } else {
                    // We must only have head storage at the moment.
                    assert(headerPtr.pointee.tailCount == 0)
                    headPrefix = headerPtr.pointee.headSpan.lowerBound
                    if headPrefix == 0 {
                        // All of our space is at the end of the storage. We can copy there, it will
                        // be our new head.
                        let buf = UnsafeMutableBufferPointer(start: elemPtr + (headerPtr.pointee.capacity - newElementCount),
                                                             count: newElementCount)
                        let count: Int
                        (iter, count) = buf.initialize(from: newElements)
                        precondition(count == newElementCount, "newElements.underestimatedCount was an overestimate")
                    } else {
                        // Our gap must be split. We'll have to iterate manually
                        iter = newElements.makeIterator()
                        // We're splitting into head/tail, so the new head is at the end of the storage.
                        let newHeadSize = newElementCount - headPrefix
                        var ptr = elemPtr + (headerPtr.pointee.capacity - newHeadSize)
                        for _ in 0..<newHeadSize {
                            guard let x = iter.next() else { preconditionFailure("newElements.underestimatedCount was an overestimate") }
                            ptr.initialize(to: x)
                            ptr += 1
                        }
                        // And the new tail is at the start
                        ptr = elemPtr
                        for _ in 0..<headPrefix {
                            guard let x = iter.next() else { preconditionFailure("newElements.underestimatedCount was an overestimate") }
                            ptr.initialize(to: x)
                            ptr += 1
                        }
                    }
                }
                /// Elements appended to the end of storage, to be used as the new head.
                let newTrailingHeadSize = newElementCount - headPrefix
                // If iter still has any elements, we need to bail and move what we just prepended
                // into a new storage. It's possible we still have space before what we just
                // prepended, but we don't want end up shifting all the data back and forth in our
                // storage just in case it all fits.
                if let x = iter.next() {
                    // Fall back to the new storage approach.
                    let newStorage = _Storage.create(minimumCapacity: Swift.max(count + newElementCount + 1, _growDequeCapacity(capacity)))
                    newStorage.withUnsafeMutablePointers { (newHeaderPtr, newElemPtr) in
                        // Move any head elements placed at the end of storage
                        newElemPtr.moveInitialize(from: elemPtr + (headerPtr.pointee.capacity - newTrailingHeadSize),
                                                  count: newTrailingHeadSize)
                        // And any head elements prefixed to the head span
                        (newElemPtr + newTrailingHeadSize)
                            .moveInitialize(from: elemPtr + (headerPtr.pointee.headSpan.lowerBound - headPrefix), count: headPrefix)
                        // And append the one element we popped off the iterator
                        (newElemPtr + newElementCount).initialize(to: x)
                        // Set the header
                        newHeaderPtr.pointee.headSpan = 0..<(newElementCount + 1)
                    }
                    return (iter, newStorage)
                } else if newTrailingHeadSize > 0 {
                    // We split our storage into head and tail
                    headerPtr.pointee.tailCount = headerPtr.pointee.headSpan.upperBound
                    headerPtr.pointee.headSpan = (headerPtr.pointee.capacity - newTrailingHeadSize)..<headerPtr.pointee.capacity
                    return nil
                } else {
                    // All new elements fit before our existing head span
                    headerPtr.pointee.headSpan = (headerPtr.pointee.headSpan.lowerBound - headPrefix)..<headerPtr.pointee.headSpan.upperBound
                    return nil
                }
            })
        } else {
            // Either we need new storage, or newElementCount is zero. In the latter case, we don't
            // know how much space we need so we need to use the new storage approach regardless.
            var iter = newElements.makeIterator()
            // Let's make sure we're actually prepending anything at all, otherwise we can bail.
            guard let x = iter.next() else { return }
            let newStorage = _Storage.create(minimumCapacity: Swift.max(count + newElementCount + 1, _growDequeCapacity(capacity)))
            newStorage.withUnsafeMutablePointers { (newHeaderPtr, newElemPtr) in
                // Initialize it with the one element we just took from the iterator.
                newElemPtr.initialize(to: x)
                newHeaderPtr.pointee.headSpan = 0..<1
            }
            data = (iter, newStorage)
        }
        
        if var (iter, storage) = data {
            // First thing, we're going to swap our current storage out for the new one.
            // This lets us use our normal methods for growing storage as needed.
            swap(&storage, &_storage)
            let storageIsUnique = storage.isUniqueReference()
            
            // Now we'll try to append the rest of the elements from the iterator.
            var nextItem = iter.next()
            while nextItem != nil {
                // Grow the array
                _reserveCapacityForAppend(newElementCount: 1)
                // Fill up the new space
                _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
                    assert(headerPtr.pointee.headSpan.lowerBound == 0) // new copies should be linearized
                    let capacity = headerPtr.pointee.capacity
                    var newCount = headerPtr.pointee.headSpan.upperBound
                    while let next = nextItem, newCount < capacity {
                        (elemPtr + newCount).initialize(to: next)
                        newCount += 1
                        nextItem = iter.next()
                    }
                    headerPtr.pointee.headSpan = 0..<newCount
                }
            }
            
            // And now we'll append our original storage.
            storage.withUnsafeMutablePointers { (oldHeaderPtr, oldElemPtr) in
                _reserveCapacityForAppend(newElementCount: oldHeaderPtr.pointee.count)
                _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
                    var ptr = elemPtr + headerPtr.pointee.headSpan.upperBound
                    let (oldHeadPtr, oldHeadCount) = (oldElemPtr + oldHeaderPtr.pointee.headSpan.lowerBound,
                                                      oldHeaderPtr.pointee.headSpan.count)
                    if storageIsUnique {
                        ptr.moveInitialize(from: oldHeadPtr, count: oldHeadCount)
                        ptr += oldHeadCount
                        ptr.moveInitialize(from: oldElemPtr, count: oldHeaderPtr.pointee.tailCount)
                        oldHeaderPtr.pointee.headSpan = 0..<0
                        oldHeaderPtr.pointee.tailCount = 0
                    } else {
                        ptr.initialize(from: oldHeadPtr, count: oldHeadCount)
                        ptr += oldHeadCount
                        ptr.initialize(from: oldElemPtr, count: oldHeaderPtr.pointee.tailCount)
                    }
                    headerPtr.pointee.headSpan = 0..<(ptr - elemPtr)
                }
            }
        }
    }
    
    /// Removes and returns the first element of the deque.
    ///
    /// - Returns: The first element of the deque if the collection is not empty; otherwise, `nil`.
    ///
    /// - Note: Calling this method may invalidate any existing indices for use with this collection
    ///   if the storage transitions from noncontiguous to contiguous. If this method invalidates
    ///   indices the `endIndex` value will change.
    /// - Complexity: O(1)
    @inlinable
    public mutating func popFirst() -> Element? {
        guard !isEmpty else { return nil }
        _makeUniqueWithCurrentCapacity()
        return _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
            let elem = (elemPtr + headerPtr.pointee.headSpan.lowerBound).move()
            headerPtr.pointee.headSpan = headerPtr.pointee.headSpan.dropFirst()
            if headerPtr.pointee.headSpan.isEmpty {
                // The tail is now the head
                headerPtr.pointee.headSpan = 0..<headerPtr.pointee.tailCount
                headerPtr.pointee.tailCount = 0
            }
            return elem
        }
    }
    
    /// Removes and returns the last element of the deque.
    ///
    /// - Returns: The last element of the deque if the collection is not empty; otherwise, `nil`.
    ///
    /// - Note: This method preserves existing indices. `endIndex` after the mutation may not be
    ///   equal to the index of the popped element.
    /// - Complexity: O(1)
    @inlinable
    public mutating func popLast() -> Element? {
        guard !isEmpty else { return nil }
        _makeUniqueWithCurrentCapacity()
        return _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
            if headerPtr.pointee.tailCount > 0 {
                headerPtr.pointee.tailCount -= 1
                return (elemPtr + headerPtr.pointee.tailCount).move()
            } else {
                headerPtr.pointee.headSpan = headerPtr.pointee.headSpan.dropLast()
                return (elemPtr + headerPtr.pointee.headSpan.upperBound).move()
            }
        }
    }
    
    /// Removes and returns the first element of the collection.
    ///
    /// - Note: Calling this method may invalidate any existing indices for use with this collection
    ///   if the storage transitions from noncontiguous to contiguous. If this method invalidates
    ///   indices the `endIndex` value will change.
    /// - Requires: The collection must not be empty.
    /// - Returns: The removed element.
    /// - Complexity: O(1)
    @discardableResult
    @inlinable
    public mutating func removeFirst() -> Element {
        let elem = popFirst()
        precondition(elem != nil, "Can't remove element from empty deque") // better error message
        return elem!
    }
    
    /// Removes and returns the last element of the collection.
    ///
    /// - Note: This method preserves existing indices. `endIndex` after the mutation may not be
    ///   equal to the index of the removed element.
    /// - Requires: The collection must not be empty.
    /// - Returns: The removed element.
    /// - Complexity: O(1)
    @discardableResult
    @inlinable
    public mutating func removeLast() -> Element {
        let elem = popLast()
        precondition(elem != nil, "Can't remove element from empty deque") // better error message
        return elem!
    }
    
    /// Removes the specified number of elements from the beginning of the deque.
    ///
    /// - Note: Calling this method may invalidate any existing indices for use with this collection
    ///   if the storage transitions from noncontiguous to contiguous. If this method invalidates
    ///   indices the `endIndex` value will change.
    /// - Parameter k: The number of elements to remove from the collection. k must be greater than
    ///   or equal to zero and must not exceed the number of elements in the collection.
    /// - Complexity: O(*k*), where *k* is the specified number of elements.
    @inlinable
    public mutating func removeFirst(_ k: Int) {
        precondition(count >= k, "Can't remove more items from a collection than it has")
        precondition(k >= 0, "Number of elements to remove should be non-negative")
        _makeUniqueWithCurrentCapacity()
        _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
            let headToRemove = Swift.min(k, headerPtr.pointee.headSpan.count)
            (elemPtr + headerPtr.pointee.headSpan.lowerBound).deinitialize(count: headToRemove)
            let tailToRemove = k - headToRemove
            if tailToRemove > 0 {
                elemPtr.deinitialize(count: tailToRemove)
                // Rest of tail is now the head
                headerPtr.pointee.headSpan =
                    tailToRemove < headerPtr.pointee.tailCount
                    ? tailToRemove..<headerPtr.pointee.tailCount
                    : 0..<0
                headerPtr.pointee.tailCount = 0
            } else {
                headerPtr.pointee.headSpan = headerPtr.pointee.headSpan.dropFirst(headToRemove)
                if headerPtr.pointee.headSpan.isEmpty {
                    // Tail is now the head
                    headerPtr.pointee.headSpan = 0..<headerPtr.pointee.tailCount
                    headerPtr.pointee.tailCount = 0
                }
            }
        }
    }
    
    /// Removes the specified number of elements from the end of the collection.
    ///
    /// - Note: This method preserves existing indices. `endIndex` after the mutation may not be
    ///   equal to the index of any removed element.
    /// - Parameter k: The number of elements to remove from the collection. k must be greater than
    ///   or equal to zero and must not exceed the number of elements in the collection.
    /// - Complexity: O(*k*), where *k* is the specified number of elements.
    @inlinable
    public mutating func removeLast(_ k: Int) {
        precondition(count >= k, "Can't remove more items from a collection than it has")
        precondition(k >= 0, "Number of elements to remove should be non-negative")
        _makeUniqueWithCurrentCapacity()
        _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
            let tailToRemove = Swift.min(k, headerPtr.pointee.tailCount)
            (elemPtr + (headerPtr.pointee.tailCount - tailToRemove)).deinitialize(count: tailToRemove)
            headerPtr.pointee.tailCount -= tailToRemove
            let headToRemove = k - tailToRemove
            if headToRemove > 0 {
                (elemPtr + (headerPtr.pointee.headSpan.upperBound - headToRemove))
                    .deinitialize(count: headToRemove)
                headerPtr.pointee.headSpan = headerPtr.pointee.headSpan.dropLast(headToRemove)
                if headerPtr.pointee.headSpan.isEmpty {
                    headerPtr.pointee.headSpan = 0..<0
                }
            }
        }
    }
    
    /// Removes all elements from the collection.
    ///
    /// Calling this method may invalidate any existing indices for use with this collection.
    ///
    /// - Parameter keepCapacity: Pass `true` to request that the collection avoid releasing its
    ///   storage. Retaining the collection's storage can be a useful optimization when you're
    ///   planning to grow the collection again. The default value is `false`.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    @inlinable
    public mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
        // TODO: Delete this when we conform to RangeReplaceableCollection, the default implementation is fine
        if !(keepCapacity && _storage.isUniqueReference()) {
            self = Self()
        } else {
            _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
                elemPtr.deinitialize(count: headerPtr.pointee.tailCount)
                headerPtr.pointee.tailCount = 0
                (elemPtr + headerPtr.pointee.headSpan.lowerBound)
                    .deinitialize(count: headerPtr.pointee.headSpan.count)
                headerPtr.pointee.headSpan = 0..<0
            }
        }
    }
    
    // TODO: Support RangeReplaceableCollection as well
    // If we do this, we can probably get rid of some of the existing mutating functions as they'll
    // have default implementations based on `replaceSubrange(_:with:)`.
    
    /// Call `body(p)`, where p is a pointer to the deque's contiguous storage, if it exists. If the
    /// deque doesn't have contiguous storage, `body` is not called and `nil` is returned.
    @inlinable
    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R? {
        return try _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) -> R? in
            guard headerPtr.pointee.tailCount == 0 else { return nil }
            let buf = UnsafeBufferPointer(start: elemPtr + headerPtr.pointee.headSpan.lowerBound,
                                          count: headerPtr.pointee.headSpan.count)
            return try(body(buf))
        }
    }
    
    /// Call `body(p)`, where p is a pointer to the deque’s mutable contiguous storage, if it
    /// exists. If the deque doesn't have contiguous storage, `body` is not called and `nil` is
    /// returned.
    @inlinable
    public mutating func withContiguousMutableStorageIfAvailable<R>(_ body: (inout UnsafeMutableBufferPointer<Element>) throws -> R) rethrows -> R? {
        guard _storage.header.tailCount == 0 else { return nil }
        _makeUniqueWithCurrentCapacity()
        // Swap out the storage with an empty one for the duration of this call. This way accesses
        // to the deque from within `body` can't invalidate our storage pointer or our bounds.
        var temp = Deque()
        (temp, self) = (self, temp)
        defer { (temp, self) = (self, temp) }
        return try temp._storage.withUnsafeMutablePointers { (headerPtr, elemPtr) -> R in
            let start = elemPtr + headerPtr.pointee.headSpan.lowerBound
            let count = headerPtr.pointee.headSpan.count
            var buf = UnsafeMutableBufferPointer(start: start, count: count)
            defer {
                precondition(buf.baseAddress == start && buf.count == count,
                             "Deque withContiguousMutableStorageIfAvailable: replacing the buffer is not allowed")
            }
            return try(body(&buf))
        }
    }
    
    // This is one of those semi-private implementation hacks in the stdlib that enables efficient
    // copying of collections, even through type-erased wrappers. The `__consuming` annotation I'm
    // mildly nervous about, since it's the internal name of an in-progress feature on ownership,
    // but it's also how Sequence declares this method so we're copying it here. If a future version
    // of the compiler complains then it should be safe to remove.
    @inlinable
    public __consuming func _copyContents(
        initializing buffer: UnsafeMutableBufferPointer<Element>
    ) -> (Iterator, UnsafeMutableBufferPointer<Element>.Index) {
        guard !isEmpty else { return (makeIterator(), buffer.startIndex) }
        
        // A precondition of this method is that `buffer` must have space for at least our
        // `underestimatedCount` (which is also our exact count).
        guard let ptr = buffer.baseAddress else { preconditionFailure("Attempt to copy contents into nil buffer pointer") }
        precondition(count <= buffer.count, "Insufficient space allocated to copy deque contents")
        _storage.withUnsafeMutablePointers { (headerPtr, elemPtr) in
            // Copy the head
            ptr.initialize(from: elemPtr + headerPtr.pointee.headSpan.lowerBound,
                           count: headerPtr.pointee.headSpan.count)
            // Copy the tail
            (ptr + headerPtr.pointee.headSpan.count)
                .initialize(from: elemPtr, count: headerPtr.pointee.tailCount)
        }
        var iter = Iterator(_buffer: self)
        iter._index = iter._endIndex
        return (iter, buffer.index(buffer.startIndex, offsetBy: count))
    }
    
    public struct Iterator: IteratorProtocol {
        @inlinable
        internal init(_buffer deque: Deque) {
            _buffer = deque
            _index = deque.startIndex
            _endIndex = deque.endIndex
        }
        
        @usableFromInline
        internal let _buffer: Deque
        @usableFromInline
        internal var _index: Index
        @usableFromInline
        internal let _endIndex: Index
        
        @inlinable
        public mutating func next() -> Element? {
            guard _index != _endIndex else { return nil }
            defer { _buffer.formIndex(after: &_index) }
            // Skip the precondition in _buffer.subscript, we know the index is valid
            return _buffer._storage.withUnsafeMutablePointerToElements({ $0[_index._offset] })
        }
    }
    
    /// A collection of indices for `Deque`.
    ///
    /// - Note: This type exists to allow for iteration of a `Deque` without triggering
    ///   copy-on-write behavior for index-preserving mutations performed during iteration (such as
    ///   subscript mutation).
    public struct Indices: RandomAccessCollection {
        public typealias Index = Deque<Element>.Index
        
        public let startIndex: Index
        public let endIndex: Index
        
        @inlinable
        public func formIndex(after i: inout Index) {
            _header.formIndex(after: &i)
        }
        
        @inlinable
        public func index(after i: Index) -> Index {
            return _header.index(after: i)
        }
        
        @inlinable
        public func formIndex(before i: inout Index) {
            _header.formIndex(before: &i)
        }
        
        @inlinable
        public func index(before i: Index) -> Index {
            return _header.index(before: i)
        }
        
        @inlinable
        public func index(_ i: Index, offsetBy distance: Int) -> Index {
            return _header.index(i, offsetBy: distance)
        }
        
        @inlinable
        public func distance(from start: Index, to end: Index) -> Int {
            return _header.distance(from: start, to: end)
        }
        
        @inlinable
        public subscript(position: Index) -> Index {
            return position
        }
        
        @inlinable
        public subscript(bounds: Range<Index>) -> Indices {
            return Self(header: _header, startIndex: bounds.lowerBound, endIndex: bounds.upperBound)
        }
        
        @usableFromInline
        internal let _header: _DequeHeader
        
        @inlinable
        internal init(header: _DequeHeader, startIndex: Index, endIndex: Index) {
            _header = header
            self.startIndex = startIndex
            self.endIndex = endIndex
        }
    }
    
    // MARK: - Private
    
    @usableFromInline
    internal var _storage: ManagedBufferPointer<_DequeHeader, Element>
    
    // Note: This is mutating in order to avoid making _storage non-unique from a temporary.
    @inlinable
    internal mutating func _hasUniqueStorage(withMinimumCapacity minimumCapacity: Int) -> Bool {
        return _storage.isUniqueReference() && capacity >= minimumCapacity
    }
    
    /// Ensures `_storage` is uniquely-owned.
    ///
    /// If it's not uniquely-owned this copies storage into a new buffer with the same capacity.
    ///
    /// - Important: This method preserves the existing layout when creating new storage, in order
    ///   to avoid invalidating indices.
    @inlinable
    internal mutating func _makeUniqueWithCurrentCapacity() {
        guard !_storage.isUniqueReference() else { return }
        _forceUnique(withMinimumCapacity: capacity)
    }
    
    /// Copies _storage into a new buffer with the given minimum capacity.
    ///
    /// - Important: This method preserves the existing layout when creating new storage if and only
    ///   if the new storage has the same capacity as the old one. If the new capacity is different,
    ///   the new storage is linearized and the first element is placed at offset zero.
    @inlinable
    internal mutating func _forceUnique(withMinimumCapacity minimumCapacity: Int) {
        let requestedCapacity = Swift.max(minimumCapacity, count)
        let isUnique = _storage.isUniqueReference()
        if requestedCapacity == capacity {
            // Preserve layout
            let newStorage = _Storage.create(exactCapacity: requestedCapacity)
            _storage.withUnsafeMutablePointers { (oldHeaderPtr, oldElemPtr) in
                newStorage.withUnsafeMutablePointers { (newHeaderPtr, newElemPtr) in
                    // Update header
                    newHeaderPtr.pointee.headSpan = oldHeaderPtr.pointee.headSpan
                    newHeaderPtr.pointee.tailCount = oldHeaderPtr.pointee.tailCount
                    // Copy the elements.
                    // We don't need to support moving here, we shouldn't be called if we're unique
                    // and already have the right capacity.
                    // Copy tail
                    newElemPtr.initialize(from: oldElemPtr, count: oldHeaderPtr.pointee.tailCount)
                    // Copy head
                    let headOffset = oldHeaderPtr.pointee.headSpan.lowerBound
                    (newElemPtr + headOffset).initialize(from: oldElemPtr + headOffset,
                                                         count: oldHeaderPtr.pointee.headSpan.count)
                }
            }
            _storage = newStorage
        } else {
            // Linearize the new buffer
            let newStorage = _Storage.create(minimumCapacity: requestedCapacity)
            _storage.withUnsafeMutablePointers { (oldHeaderPtr, oldElemPtr) in
                newStorage.withUnsafeMutablePointers { (newHeaderPtr, newElemPtr) in
                    // Update header
                    newHeaderPtr.pointee.headSpan = 0..<oldHeaderPtr.pointee.count
                    // Move/copy the elements
                    if isUnique {
                        // Move head
                        newElemPtr.moveInitialize(from: oldElemPtr + oldHeaderPtr.pointee.headSpan.lowerBound,
                                                  count: oldHeaderPtr.pointee.headSpan.count)
                        // Move tail
                        (newElemPtr + oldHeaderPtr.pointee.headSpan.count)
                            .moveInitialize(from: oldElemPtr, count: oldHeaderPtr.pointee.tailCount)
                        // Clean up old header
                        oldHeaderPtr.pointee.headSpan = 0..<0
                        oldHeaderPtr.pointee.tailCount = 0
                    } else {
                        // Copy head
                        newElemPtr.initialize(from: oldElemPtr + oldHeaderPtr.pointee.headSpan.lowerBound,
                                              count: oldHeaderPtr.pointee.headSpan.count)
                        // Copy tail
                        (newElemPtr + oldHeaderPtr.pointee.headSpan.count)
                            .initialize(from: oldElemPtr, count: oldHeaderPtr.pointee.tailCount)
                    }
                }
            }
            _storage = newStorage
        }
    }
    
    @inlinable
    internal mutating func _reserveCapacityForAppend(newElementCount: Int) {
        // This is the same logic Array uses when appending sequences
        let oldCount = count
        let oldCapacity = capacity
        let newCount = oldCount + newElementCount
        
        reserveCapacity(
            newCount > oldCapacity
                ? Swift.max(newCount, _growDequeCapacity(oldCapacity))
                : newCount)
    }
    
    @usableFromInline
    internal final class _Storage {
        @usableFromInline
        typealias Manager = ManagedBufferPointer<_DequeHeader, Element>
        
        @inlinable
        class func create(minimumCapacity: Int) -> Manager {
            return Manager(bufferClass: self, minimumCapacity: minimumCapacity) { (buffer, numAllocated) in
                _DequeHeader(capacity: numAllocated(buffer), headSpan: 0..<0, tailCount: 0)
            }
        }
        
        @inlinable
        class func create(exactCapacity: Int) -> Manager {
            return Manager(bufferClass: self, minimumCapacity: exactCapacity) { (buffer, numAllocated) in
                assert(numAllocated(buffer) >= exactCapacity)
                return _DequeHeader(capacity: exactCapacity, headSpan: 0..<0, tailCount: 0)
            }
        }
        
        @inlinable
        deinit {
            let ptr = Manager(unsafeBufferObject: self)
            ptr.withUnsafeMutablePointers { (headerPtr, elemPtr) in
                // Deinitialize tail
                elemPtr.deinitialize(count: headerPtr.pointee.tailCount)
                // Deinitialize head
                (elemPtr + headerPtr.pointee.headSpan.lowerBound).deinitialize(count: headerPtr.pointee.headSpan.count)
            }
        }
    }
}

// Note: This index is just one word in size. We can do this because the stdlib uses Int everywhere,
// and yet these offsets must be non-negative, so the high bit is available for our own use.
public struct DequeIndex: Comparable, CustomStringConvertible, CustomDebugStringConvertible {
    @inlinable
    public static func < (lhs: DequeIndex, rhs: DequeIndex) -> Bool {
        return lhs._rawValue < rhs._rawValue
    }
    
    /// The offset into element storage, along with a head or tail flag.
    ///
    /// The high bit is the flag. `1` means this represents the tail, `0` is the head. The remainder
    /// is the offset directly into element storage. The flag exists to allow the index to be
    /// comparable, and the use of the high bit instead of the low bit makes the comparison trivial.
    @usableFromInline
    internal var _rawValue: UInt
    
    /// The offset into element storage.
    ///
    /// - Important: This offset must never be assumed to be equal to the distance from the start
    ///   index. Even for head-only storage, the head section may not be anchored to the beginning
    ///   of the storage.
    @inlinable
    internal var _offset: Int { Int(bitPattern: _rawValue & ~Self._tailFlag) }
    
    @inlinable
    internal static var _tailFlag: UInt { UInt(bitPattern: Int.min) } // Int.min is just the high bit set
    
    @inlinable
    internal init(_rawValue value: UInt) {
        _rawValue = value
    }
    
    public var description: String {
        if _rawValue >= Self._tailFlag {
            return "\(Self.self)(tailOffset: \(_offset))"
        } else {
            return "\(Self.self)(headOffset: \(_offset))"
        }
    }
    
    public var debugDescription: String {
        if _rawValue >= Self._tailFlag {
            return "\(String(reflecting: Self.self))(tailOffset: \(_offset))"
        } else {
            return "\(String(reflecting: Self.self))(headOffset: \(_offset))"
        }
    }
}

// MARK: -

extension Deque: Equatable where Element: Equatable {
    @inlinable
    public static func == (lhs: Deque, rhs: Deque) -> Bool {
        let lhsCount = lhs.count
        guard lhsCount == rhs.count else { return false }
        // Test referential equality
        if lhsCount == 0 || lhs._storage == rhs._storage { return true }
        return zip(lhs, rhs).allSatisfy(==)
    }
}

extension Deque: Hashable where Element: Hashable {
    @inlinable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for elt in self {
            hasher.combine(elt)
        }
    }
}

extension Deque: CustomStringConvertible {
    @inlinable
    public var description: String {
        // The Swift stdlib actually has a handy function that does exactly this, but it's internal.
        // Oh well. We can replicate its logic.
        var result = "["
        var first = true
        for item in self {
            if first {
                first = false
            } else {
                result += ", "
            }
            debugPrint(item, terminator: "", to: &result)
        }
        result += "]"
        return result
    }
}

extension Deque: CustomDebugStringConvertible {
    @inlinable
    public var debugDescription: String {
        return "Deque(\(description))"
    }
}

extension Deque: CustomReflectable {
    @inlinable
    public var customMirror: Mirror {
        return Mirror(self, unlabeledChildren: self, displayStyle: .collection)
    }
}

extension Deque: ExpressibleByArrayLiteral {
    @inlinable
    public init(arrayLiteral elements: Element...) {
        // Empty array literals are super common, so let's add a minor optimization.
        if elements.isEmpty {
            self.init()
        } else {
            self.init(elements)
        }
    }
}

extension Deque: Encodable where Element: Encodable {
    @inlinable
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for elt in self {
            try container.encode(elt)
        }
    }
}

extension Deque: Decodable where Element: Decodable {
    @inlinable
    public init(from decoder: Decoder) throws {
        self.init()
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            append(try container.decode(Element.self))
        }
    }
}

// MARK: - Private

/// - Postcondition: Returned value is greater than `capacity`.
@inlinable
internal func _growDequeCapacity(_ capacity: Int) -> Int {
    return Swift.max(1, capacity * 2)
}

/// The header for the deque storage.
///
/// The deque is backed by a single contiguous buffer of elements. This buffer is broken down into 4
/// sections, which look like:
///
///     |--tail--|--uninitialized--|--head--|--uninitialized--|
///
/// Each of these sections may be empty, but all of them put together equal the capacity. If the
/// tail is non-empty, head must be non-empty and the second uninitialized block must be empty. This
/// means there's really 2 patterns in practice:
///
///     |--uninitialized--|--head--|--uninitialized--|
///     |--tail--|--uninitialized--|--head--|
///
/// The restriction against having tail-only storage is important to ensure index stability for
/// appends.
///
/// - Important: In the case where we have a head and no tail, the head may be preceded by
///   uninitialized memory. Code manipulating indices must not assume that the offset of a head-only
///   storage element is the same as its index.
@usableFromInline
internal struct _DequeHeader {
    @usableFromInline
    var capacity: Int
    @inlinable
    var count: Int { headSpan.count + tailCount }
    
    /// The range of indices that comprise the head of the buffer.
    @usableFromInline
    var headSpan: Range<Int>
    /// The count of elements from the beginning of the buffer that comprise the tail.
    ///
    /// The tail range is `0..<tailCount`.
    @usableFromInline
    var tailCount: Int
    
    @inlinable
    init(capacity: Int, headSpan: Range<Int>, tailCount: Int) {
        self.capacity = capacity
        self.headSpan = headSpan
        self.tailCount = tailCount
    }
    
    // MARK: Indexing Operations
    
    // Indexing operations are exposed here so they can be used from both `Deque` and
    // `Deque.Indices`.
    
    @usableFromInline
    typealias Index = DequeIndex
    
    @inlinable
    var startIndex: Index {
        return Index(_rawValue: UInt(bitPattern: headSpan.lowerBound))
    }
    
    @inlinable
    var endIndex: Index {
        // Return the greatest valid index + 1, such that we can easily subtract 1 from this to get
        // the previous index.
        return tailCount > 0
            ? Index(_rawValue: UInt(bitPattern: tailCount) | Index._tailFlag)
            : Index(_rawValue: UInt(bitPattern: headSpan.upperBound))
    }
    
    @inlinable
    func formIndex(after i: inout Index) {
        i._rawValue += 1
        if i._rawValue == UInt(bitPattern: capacity) && tailCount > 0 {
            // Wrap around
            i._rawValue = 0 | Index._tailFlag
        }
    }
    
    @inlinable
    func index(after i: Index) -> Index {
        var i = i
        formIndex(after: &i)
        return i
    }
    
    @inlinable
    func formIndex(before i: inout Index) {
        if i._rawValue == 0 | Index._tailFlag {
            // Wrap around
            i._rawValue = UInt(bitPattern: capacity - 1)
        } else {
            precondition(i._rawValue != 0, "Attempted to create invalid index") // report better error on underflow
            i._rawValue &-= 1
        }
    }
    
    @inlinable
    func index(before i: Index) -> Index {
        var i = i
        formIndex(before: &i)
        return i
    }
    
    @inlinable
    func index(_ i: Index, offsetBy distance: Int) -> Index {
        var rawValue = i._rawValue
        if distance > 0 {
            let wasHead = rawValue < Index._tailFlag
            rawValue += UInt(bitPattern: distance)
            if wasHead && rawValue >= UInt(bitPattern: capacity) && tailCount > 0 {
                // Wrap around
                rawValue = (rawValue &- UInt(bitPattern: capacity)) | Index._tailFlag
            }
        } else if distance < 0 {
            if rawValue >= Index._tailFlag {
                rawValue &+= UInt(bitPattern: distance) // equivalent to signed addition
                if rawValue < Index._tailFlag {
                    // We subtracted past the beginning of the tail
                    let result = UInt(bitPattern: capacity).subtractingReportingOverflow(Index._tailFlag &- rawValue)
                    precondition(!result.overflow, "Attempted to create invalid index") // Report better error on overflow
                    rawValue = result.partialValue
                }
            } else {
                let newValue = rawValue &+ UInt(bitPattern: distance) // equivalent to signed addition
                precondition(newValue < rawValue, "Attempted to create invalid index") // Report error on overflow
                rawValue = newValue
            }
        }
        return Index(_rawValue: rawValue)
    }
    
    @inlinable
    func distance(from start: Index, to end: Index) -> Int {
        func distanceFromStart(to idx: Index) -> Int {
            return idx._rawValue >= Index._tailFlag
                ? idx._offset + headSpan.count
                : idx._offset - headSpan.lowerBound
        }
        return distanceFromStart(to: end) - distanceFromStart(to: start)
    }
}

/// A singleton class used as the backing storage for empty deques of capacity zero.
///
/// This class allows all empty deques of capacity zero to share the same backing storage object,
/// meaning that a brand new `Deque()` performs no allocation.
@usableFromInline
internal final class _DequeEmptyStorage {
    @usableFromInline
    static var shared: _DequeEmptyStorage = {
        // Construct it using ManagedBufferPointer so we have our header
        let ptr = ManagedBufferPointer<_DequeHeader, ()>(bufferClass: _DequeEmptyStorage.self, minimumCapacity: 0) { (buffer, numAllocated) in
            // Ignore numAllocated. It should be zero, but if not we still want to record a zero
            // capacity.
            return _DequeHeader(capacity: 0, headSpan: 0..<0, tailCount: 0)
        }
        return ptr.buffer as! _DequeEmptyStorage
    }()
    
    private init() {}
    
    deinit {
        fatalError("_DequeEmptyStorage shouldn't ever deinit")
    }
}

internal extension ManagedBufferPointer {
    /// Accesses the element at an offset.
    ///
    /// This is equivalent to `buffer.withUnsafeMutablePointerToElements({ $0[offset] })` except it
    /// provides direct read/modify access.
    ///
    /// - Parameter offset: The offset of an initialized element to access. No bounds checking is
    ///   done on this offset.
    ///
    /// - Remark: The implementation of this violates the API contract of `ManagedBufferPointer` by
    ///   using its element pointer past the call to `withUnsafeMutablePointerToElements`. Based on
    ///   the implementation of `ManagedBufferPointer` this is safe to do so long as the buffer
    ///   itself lives past the usage of the pointer. In theory the stdlib could break this but that
    ///   seems rather unlikely as that would mean it would have to yield a pointer to temporary
    ///   storage, and that's contrary to the purpose of `ManagedBufferPointer`. This hack can be
    ///   removed if [SR-13876][] is fixed.
    ///
    /// [SR-13876]: https://bugs.swift.org/browse/SR-13876
    @inlinable
    subscript(_unsafeElementAt offset: Int) -> Element {
        _read {
            let ptr = withUnsafeMutablePointerToElements({ $0 })
            defer { _fixLifetime(self) } // I am unsure if this is necessary
            yield ptr[offset]
        }
        nonmutating _modify {
            let ptr = withUnsafeMutablePointerToElements({ $0 })
            defer { _fixLifetime(self) } // I am unsure if this is necessary
            yield &ptr[offset]
        }
    }
}
