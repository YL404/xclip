# Known issues (v1 Swift app)

Applies to the legacy Swift implementation in `Sources/`. The shipped v2 app is Go/MyGo; see
`README.md`.

SwiftUI platform pitfalls found while verifying the packaged app (screenshots + AppleScript), all
worked around; when touching the related code, do not reintroduce Button / .toolbar.

## 1. Buttons don't render inside a custom Layout container

A `Button` inside `FlowLayout` (Sources/XClipApp/FlowLayout.swift) lays out correctly but is never
drawn. Debug output confirmed the layout data is all correct (proposal.width=504, 13 chips,
correct child sizes and positions); swapping the `Button` for `Text` renders immediately — so this
is a SwiftUI platform limitation, not a data or coordinate problem.

Workaround: `TagChip` (Sources/XClipApp/TagChip.swift) is implemented as `Text + onTapGesture`,
with `.accessibilityAddTraits(.isButton)` so VoiceOver still reads button semantics.
Covers the tag chips in PostDetailView's "adjust tags" state and the card tag chips.
FilterBar's tag pills and the read-only tag row in PostDetailView live in system containers, are
unaffected, and keep real Buttons.

Addendum (macOS 26): in a system container, `.buttonStyle(.bordered)` combined with `.tint(.clear)`
also tints the button label — `Color.clear`. FilterBar's unselected pill once showed only a
floating count number, with the tag text fully invisible. Hand-drawn capsule buttons switched to
`.buttonStyle(.plain)` (see FilterPill in FilterBar); custom Layout containers still use `TagChip`.

## 2. The detail sheet's .toolbar doesn't render

With Edit / Delete placed in a `.toolbar` on PostDetailView, the entire toolbar inside the sheet
was invisible and its buttons unreachable.

Workaround: a `.safeAreaInset(edge: .bottom)` bar inside the content area holds the buttons;
TagManagementSheet's footer uses the same pattern.

Addendum: a `.sheet` is `NSWindow.beginSheet` system modality underneath — AppKit swallows all
mouse clicks that land on the parent window, so clicking outside the card cannot close the detail
view. Switched to an in-window "scrim + centered card" overlay (ContentView's `modalCard`);
clicking the scrim closes it. Child views (PostDetailView, TagManagementSheet) take an `onClose`
callback instead of `dismiss()`. Delete confirmation also moved to inline two-step confirmation in
the bottom bar, so a system NSAlert can't fight window events over "click-outside-to-close".

## 3. SwiftUI `VideoPlayer` links only `_AVKit_SwiftUI`, crashing on video open (`getSuperclassMetadata` SIGABRT)

PostDetailView used to use SwiftUI's `VideoPlayer(player:)`. When SwiftPM builds a macOS
executable, `VideoPlayer` only references generic symbols in
`/System/Library/Frameworks/_AVKit_SwiftUI.framework` and never references any Objective-C class
symbol from AVKit.framework, so the linker never links AVKit.framework into the binary
(`otool -L` shows `_AVKit_SwiftUI` but not `AVKit`).

Opening a video post at runtime: `_AVKit_SwiftUI` initializes the metadata of an internal
`NSViewRepresentable` wrapper class whose superclass is the ObjC class `AVPlayerView` from AVKit;
the framework isn't loaded, so `swift::getSuperclassMetadata` can't find the superclass and calls
`swift::fatalError` → `abort()` (SIGABRT), reproducibly (confirmed by the ips crash report).

Workaround: `NativeVideoPlayer` (Sources/XClipApp/PostDetailView.swift) wraps AppKit's native
`AVPlayerView` directly in an `NSViewRepresentable` (inline controls + fullscreen button).
Instantiating `AVPlayerView()` in that file emits a strong `_OBJC_CLASS_$_AVPlayerView` symbol
reference, forcing the linker to link AVKit.framework; the XClipApp target in Package.swift adds
`linkerSettings: [.linkedFramework("AVKit")]` as a belt-and-braces second line of defense.
Verify: `otool -L .build/debug/XClipApp | grep AVKit` should list both `_AVKit_SwiftUI.framework`
and `AVKit.framework`.

Addendum: `AVPlayerView`'s internal subviews eat scroll wheel events for video scrubbing, and also
swallow the outer ScrollView's scrolling. lldb disassembly confirmed two classes implement
`scrollWheel:`: `AVDesktopPlayerViewContentView` (internally via `_gestureController`) and the
bottom control bar's progress slider `AVScrollSliderView`.

The coordinate-check approach (`addLocalMonitorForEvents(.scrollWheel)` + `visibleRect`) can't plug
it: NSWindow does scroll-target latching for wheel gestures — during fast scrolling, some
`.changed` / momentum events bypass the coordinate check and land directly on the internal
subviews.

Root fix (`NonScrubbingPlayerView`, same file): the ObjC runtime swaps those two classes'
`scrollWheel:` implementations to "forward to `enclosingScrollView`" and `swipeWithEvent:` to an
empty implementation, and nils out `AVDesktopPlayerViewContentView`'s `_gestureController` on
layout / window entry. Semantically there is no scrubbing entry point anymore, no matter how fast
the scroll or where the mouse enters and leaves.

## Note: AppleScript automation only works against an installed app bundle

Running .build/debug/XClipApp straight from the terminal, the process has no bundle and macOS
gives it accessory activation policy; it cannot be activated / set frontmost, so sent keystrokes
and clicks all land in other windows. To script the UI, you must target the .app installed in
/Applications.
