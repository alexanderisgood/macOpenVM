# ADR 7: native Liquid Glass with a complete older-host fallback

Status: explicit user design requirement accepted, 2026-10-06; implementation
awaits strict-build and actual-GUI verification. This read-only API/design audit
ran no builds or apps and changed no system preferences. It adds no supported UI,
accessibility, performance or guest-workflow claim. The minimum host remains
macOS 14.

## Decision and scope

Use Apple's native Liquid Glass on macOS 26 and later for the host's controls and
navigation. Preserve functional native controls, semantic surfaces and equivalent
keyboard actions on macOS 14–25, where these Liquid Glass APIs do not exist. The
older-host path is a native fallback; ordinary vibrancy/material is not claimed
to be Liquid Glass.

Use standard SwiftUI/AppKit controls and native toolbar behavior first. Apply
custom glass only to a small, useful action/navigation layer. Keep explanatory
content, installation/hardware forms, errors and purely informational panels on
semantic content backgrounds. A passive status must not look like a tappable
control. Use original layout and terminology, not copied application artwork or
an imitation of another virtualization product.

This follows Apple's [adoption guide](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
and [materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials):
system controls adopt the newer appearance, and glass establishes the functional
layer above content. Avoid custom toolbar backgrounds or nested glass around a
button already styled by a native toolbar. Use accent color sparingly to identify
a primary action; never communicate capability/error/selection using color alone.

## Public API and availability boundary

The installed macOS 27 CLT SDK's public SwiftUI/SwiftUICore interfaces were read on
2026-10-06. They declare:

| API | Minimum macOS | Implementation consequence |
|---|---:|---|
| `glassEffect`, `Glass`, `GlassEffectContainer` | 26.0 | Gate every use with availability and keep older-host content equivalent. |
| `.glass`, `.glassProminent` button styles | 26.0 | Prefer the built-in styles for content-layer actions instead of manually drawing interactive glass. |
| `GlassButtonStyle.init(_ glass:)` | 26.1 | Do not accidentally raise a 26.0 path by using this customized initializer. |
| `accessibilityReduceTransparency`, `accessibilityReduceMotion`, `colorSchemeContrast` | 10.15 | Public environment observation works at the macOS 14 deployment floor. Values are read-only. |
| `toolbar(_:for:)`, `toolbarBackground(_:for:)` visibility overloads; `.windowToolbar` placement | 13.0 | The established visibility API can serve macOS 14. |
| `toolbarVisibility`, `toolbarBackgroundVisibility` names | 15.0 | Gate these newer spellings or retain the older public overloads. |

Primary documentation: [custom glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views),
[effect container](https://developer.apple.com/documentation/swiftui/glasseffectcontainer),
[Reduce Transparency](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency),
[Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion),
[contrast](https://developer.apple.com/documentation/swiftui/environmentvalues/colorschemecontrast),
[toolbar placement](https://developer.apple.com/documentation/swiftui/toolbarplacement/windowtoolbar)
and [toolbar background](https://developer.apple.com/documentation/swiftui/view/toolbarbackground(_:for:)).
API declarations and source availability do not prove runtime appearance or
compatibility on macOS 14. A successful minimum-deployment build on macOS 27 is
also insufficient for that claim.

## Bounded effects and accessibility

Use regular glass for the limited custom control layer. Avoid highly translucent
clear glass where variable text/form backgrounds require legibility. Apply the
effect after padding and appearance modifiers so its shape encloses the intended
control. When several custom effects are visible together, prefer a single
`GlassEffectContainer`; select spacing that does not unintentionally merge
separate controls at rest. The host workspace and creation view use one collector
around their layout to coordinate child effects; the collector applies no material
to the content itself. Only the small badges and native controls use glass while
form and content cards remain opaque. Never apply glassEffect to whole forms,
windows or guest surfaces. Limit simultaneous effects; benchmark any later animation or
large effect layer before claiming its cost is negligible.

Read system appearance/accessibility environment values and preserve their
meaning. With Reduce Transparency, custom backgrounds must become opaque. With
increased contrast, use strong semantic foreground/background/border separation;
a solid custom fallback is a conservative app policy, not a claim that native
glass lacks system adaptation. Retain readable focus, disabled and selected
states in light and dark appearances. Prefer full-opacity semantic window/control
colors for the custom solid fallback rather than fixed white/black or alpha fills.

Use no decorative morphing, scaling or looping animations in this slice. Native
controls retain their platform behavior. If custom transitions are added later,
Reduce Motion must select a restrained alternative and be tested. Standard
components adapt automatically, while app-defined colors/effects still need
inspection. Do not change the user's accessibility preferences or use underscored
writable environment properties to simulate them. An explicit app policy input
may test branch logic but cannot establish real preference observation or visual
accessibility.

## Guest pixels and native window chrome

A running guest keeps its actual framebuffer clear and unobscured: no glass,
blur/dimming overlay, status card, setup banner or permanent action toolbar on top
of guest pixels. Styling must not crop the guest taskbar, distort its aspect ratio
or substitute a lower backing-pixel resolution. Retain deliberate menu access to
Machine/View/Input and recovery controls. Input capture, focus and lifecycle
ownership rules remain independent of styling.

Keep AppKit's native titlebar, traffic-light controls, window ownership and
fullscreen transition behavior. Apple's `.windowToolbar` documentation states
that hiding that placement hides the entire titlebar, including title and
traffic-light controls. To remove custom toolbar content only, use the documented
`.automatic` placement and verify the result. Do not manually overwrite fullscreen
style masks or create another window to compensate for a chrome change. Native
fullscreen may hide/reveal native chrome according to system behavior; the guest
still satisfies the existing D5/D6 acceptance requirements.

## Manual acceptance cases and remaining evidence

| Case | Required observation |
|---|---|
| macOS 26+ normal appearance | Real packaged app shows native action/toolbar treatment; content remains distinct and legible. Verify actual button behavior, keyboard focus/default action, errors and narrow-window layout. No mock or screenshot alone proves a workflow. |
| macOS 14–25 fallback | Run the packaged app on an identified older host. Equivalent actions/forms, native chrome and readable solid surfaces work without unavailable API access. Until available, explicitly record this runtime test as unverified. |
| Light/dark and increased contrast | Inspect text, borders, status, disabled controls and focus with bright/dark surrounding content. Status and error meaning remains available without color. |
| Reduce Transparency | Observe the real environment change and opaque custom surfaces without loss of information or actions; restore preferences only under user-controlled testing. Policy injection alone is narrower evidence. |
| Reduce Motion | No app-defined decorative morph/scale/loop survives the setting; native controls, progress and focus remain usable. |
| Keyboard/VoiceOver | New/Open/Start, creation fields, validation errors and cancellation are discoverable and operable. Accessibility labels/actions expose semantics rather than material names. |
| Guest start/fullscreen/stop | Custom host toolbar/content disappears when appropriate; framebuffer/input geometry and taskbar remain intact; original owner and native chrome survive entry/exit, sheets, close guards and return to host UI. |
| Rendering cost | Check idle behavior and interaction hitches on a named host before any performance claim. More glass is not accepted merely because compilation succeeds. |

Record this requirement in the product specification and requirements ledger,
add a precise `UI-GLASS` feature-matrix row, and expand `UI-ACCESS`/A1 to include
Reduce Transparency. Initially mark the new capability planned; working code with
incomplete runtime/older-host/accessibility acceptance is experimental. Styling
does not promote installation, library, input, fullscreen or Windows support.
