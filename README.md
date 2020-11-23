# Deque

This package provides `Deque`, a random-access collection similar to `Array` but backed by a growable ring buffer and offering efficient insertion and removal at the front and back.

## Adding Deque as a dependency

To use `Deque` in a SwiftPM project, add the following line to the dependencies in your `Package.swift` file:

```swift
.package(url: "https://github.com/lilyball/Deque.swift", from: "0.0.1"),
```

Because `Deque` is still pre-1.0, source-stability is only guaranteed within minor versions. If you don't want potentially source-breaking package updates, use this dependency specification instead:

```swift
.package(url: "https://github.com/lilyball/Deque.swift", .upToNextMinor(from: "0.0.1")),
```

Finally, include `"Deque"` as a dependency for your target:

```swift
let package = Package(
    // name, etc…
    dependencies: [
        .package(url: "https://github.com/lilyball/Deque.swift", .upToNextMinor(from: "0.0.1")),
    ],
    targets: [
        .target(name: "<target name>", dependencies: [
            .product(name: "Deque", package: "Deque.swift")
        ]),
        // other targets…
    ]
)
```