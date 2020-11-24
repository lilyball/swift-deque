//: A basic demonstration of usage of `Deque`.
import Deque
//: Like `Array`, a brand new empty `Deque` does not heap allocate until an element is inserted or capacity is reserved.
var deque = Deque<Int>() // no heap allocation
//: `Deque` supports creation from sequences. Creating a `Deque` from another `Deque` shares the same backing storage until such time as one copy is mutated.
deque = Deque(1..<5)
assert(deque.elementsEqual(1..<5))
//: `Deque` supports creation from array literals.
deque = [1,2,3]
//: `Deque` can be efficiently mutated at the front and back. Such mutation will be O(1) as long as the `Deque` is uniquely owned and has sufficient capacity for insertions (just like `Array` when inserting at the back).
deque.reserveCapacity(10)

// None of these mutations exceed capacity. Insertions/removals of one element will be O(1),
// insertions/removals of *n* elements will be O(*n*).
deque.append(4)
deque.prepend(0)
deque.removeLast()
deque.removeFirst()
deque.append(contentsOf: 10..<13)
deque.prepend(contentsOf: [42, 84])
deque.removeFirst(2)
deque.removeLast(3)
//: Like the standard library collections, `Deque` is copy-on-write (CoW). And like `Array`, any copies made in order to ensure uniqueness retain the capacity.
let dequeCopy = deque

assert(dequeCopy == deque)
deque.append(42)
assert(dequeCopy != deque)
assert(deque.capacity == dequeCopy.capacity)
//: Unlike `Array`, `Deque` does not use integers as indices. However it attempts to preserve index validity as much as possible. To that end, all reallocations due to CoW behavior preserve the existing layout (and therefore indices), appends that don't grow the capacity preserve indices, and prepends that don't grow the capacity or transition from contiguous to noncontiguous storage preserve indices. Admittedly there's no good way right now to determine up front whether a prepend will transition from contiguous to noncontiguous storage, but if you start with an empty storage and exclusively prepend, it will remain contiguous. the whole time.
//:
//: If you're not sure whether a given operation preserves indices, you can save the `startIndex` or `endIndex` (whichever shouldn't move) before the operation and compare it to the same index after the operation. If `append` reallocates the storage but `startIndex` does not change, all other indices are still valid. And if `endIndex` remains the same after `prepend` or `removeFirst()` then the storage did not transition between contiguous and non-contiguous, nor did it reallocate for new capacity.
deque = Deque(0..<5)
deque.reserveCapacity(10)
let lastIdx = deque.index(before: deque.endIndex)
deque.removeFirst() // it was contiguous before and remains contiguous now
assert(deque[lastIdx] == 4) // lastIdx is still valid
deque.prepend(0) // still contiguous
assert(deque[lastIdx] == 4) // lastIdx is still valid
let oldEndIndex = deque.endIndex
deque.prepend(42) // this changes to non-contiguous storage
assert(deque.endIndex != oldEndIndex) // indexes are invalidated
