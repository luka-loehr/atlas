# Apple Design Guidelines — Engineering Reference for Atlas (iOS 27 / Xcode 27)

Distilled from Apple's Human Interface Guidelines, Liquid Glass technology overviews and SwiftUI documentation as published on developer.apple.com on 2026-10-03. Written in our own words as a build reference for the Atlas iOS app (Photos, Drive, Settings). Anything not confirmed on Apple's site today is tagged `(unverified)`.

## Contents

1. Platform and SDK status
2. Design principles and Liquid Glass
3. Foundations
4. Components
5. Patterns
6. Atlas recipes
7. "Does this look Apple-made?" checklist and common mistakes
8. Appendix A (sources) and B (known gaps)

Conventions used below:

- `iOS 26+` / `iOS 27+` = minimum deployment version of the API, read from Apple's DocC data for that symbol on 2026-10-03.
- **Do / Don't** bullets are distilled rules, not quotes.
- `(unverified)` = from memory or inference; re-check before relying on it.
- Every section ends with `Source:` links. HIG page JSON for any page is at `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`; API JSON at `https://developer.apple.com/tutorials/data/documentation/swiftui/<path>.json`.

---

## 1. Platform and SDK status

### 1.1 Local toolchain (measured on this machine, 2026-10-03)

| Item | Value |
|---|---|
| `xcodebuild -version` | **Xcode 27.0**, build 27A266a |
| `xcrun --sdk iphoneos --show-sdk-version` | **iOS SDK 27.0** |
| Host | macOS 27.0.1 |

Consequence: everything marked `iOS 26+` and `iOS 27+` below compiles. Choose the deployment target deliberately:

- **Deployment target iOS 26** gives the full Liquid Glass API set (`glassEffect`, `GlassEffectContainer`, `Tab(role: .search)`, `tabBarMinimizeBehavior`, `tabViewBottomAccessory`, `ToolbarSpacer`, `scrollEdgeEffectStyle`, `safeAreaBar`, `backgroundExtensionEffect`, `ConcentricRectangle`, `.buttonStyle(.glass)`). iOS 27-only APIs then need `if #available(iOS 27, *)`.
- **Deployment target iOS 27** (recommended for a brand-new app in Oct 2026 whose only user base is the owner's devices) removes every availability check and lets you use the iOS 27 toolbar/tab APIs directly.

### 1.2 Current generation: iOS 27 / iPadOS 27 / Xcode 27

- **iOS 27** is the shipping OS (developer.apple.com/ios headlines "What's new in iOS 27"; release notes for iOS & iPadOS 27 are published). Xcode 27 is current (developer.apple.com/xcode/whats-new: "Xcode 27").
- **Design language** is still **Liquid Glass**, introduced with iOS 26 (June 2025) and refined, not replaced, in 27. Apple's design "What's new" log for June–Sept 2026 lists refinements (search-as-a-tab terminology, scroll edge effects, sidebar icon colors, menu item icons, app icons for Liquid Glass, Sheets button placement) rather than a new visual system.
- **New hardware**: **iPhone Duo**, the first folding iPhone (HIG page "Designing for iPhone Duo", added 2026-09-09), plus the iPhone 18 family (product bezels 2026-09-18). iPhone Duo has an outer display (wide and short) and an inner display, a center hinge, and puts **toolbars and tab bars on the vertical axis (screen side)** on the outer display and in landscape on the inner display.
- **Design tools**: Icon Composer 2 (layered Liquid Glass icons for iPhone, iPad, Mac, Watch), SF Symbols 8, iOS/iPadOS 27 UI Kit for Figma/Sketch.
- **HIG pages changed in 2026** that matter here: Design principles (reintroduced, June 2026), Searching + Search fields (search as a tab in iOS, new terminology), Tab bars (terminology/art), Scroll views (scroll edge effects), Menus (menu item icons), Sidebars (icon colors), App icons (Liquid Glass), Sheets (button placement, March 2026), Layout (Sept 2026), Branding (brand color, Sept 2026), Designing for iPhone Duo (new, Sept 2026).

### 1.3 iOS 27 SwiftUI changes relevant to Atlas

Verified in Apple's "SwiftUI updates" page (June + September 2026) and the iOS & iPadOS 27 release notes:

| Change | API | Min |
|---|---|---|
| Toolbar item keeps visible longer / overflows first | `.visibilityPriority(.high / .low)` on `ToolbarContent` | iOS 27 |
| Secondary actions always in overflow ("...") menu | `ToolbarOverflowMenu { }` inside `.toolbar`, or `.toolbarOverflowMenu { }` | iOS 27 |
| Item pinned to trailing edge of top bar | `ToolbarItem(placement: .topBarPinnedTrailing)` | iOS 27 |
| Nav bar / toolbar minimize on scroll | `.toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)` (replaces beta-era `toolbarMinimizeBehavior`) | iOS 27 |
| Separate trailing "prominent" tab | `Tab(role: .prominent)` (`TabRole.prominent`) | iOS 27 |
| Reorder by drag in any container | `.reorderable()` + `.reorderContainer(for:isEnabled:move:)` | iOS 27 |
| Swipe actions outside `List` (grids, stacks) | `.swipeActions(edge:allowsFullSwipe:content:onPresentationChanged:)` + `.swipeActionsContainer()` | iOS 27 |
| Alerts/dialogs from optional item or `Error` | `.alert(_:item:actions:)`, `.alert(error:actions:)`, `.confirmationDialog(_:item:titleVisibility:actions:)` — back-deploy to iOS 15 | iOS 15 (built with Xcode 27) |
| Sheet that fades in instead of sliding | `.navigationTransition(.crossFade)` on the presented content (`CrossFadeNavigationTransition`) | iOS 27 |
| `AsyncImage` HTTP caching + custom session | `.asyncImageURLSession(_:)`, `AsyncImage(request:...)` | iOS 27 |
| `@State` becomes a macro (initial value evaluated once) | build with Xcode 27; back-deploys to iOS 17 | — |
| `ContentBuilder` unifies result builders | `@ContentBuilder` | Xcode 27 |
| Status bar color scheme / visibility through toolbar API | `.toolbarColorScheme(_:for: .statusBar)`, `.toolbarVisibility(_:for: .statusBar)` | iOS 27 |
| Selectable `Text` gets real system selection UI | `.textSelection(.enabled)` | iOS 27 SDK |
| Tabs-semantics segmented picker | `.pickerStyle(.tabs)` (`TabsPickerStyle`) — VoiceOver reads "tabs" | iOS 27 |
| Text field border | `.textFieldStyle(.bordered)`, `.textInputBorderShape(_:)`; `.roundedBorder`/`.squareBorder` soft-deprecated | iOS 27 |
| Concentric radii for custom drawing | `GeometryProxy.concentricCornerRadii` | iOS 27 |
| Menu item subtitle | `LabeledContent` inside `Menu` maps value to subtitle | iOS 27 SDK |
| Menu item icons hidden by default on iPadOS menu bar | force with `.labelStyle(.titleAndIcon)` for object-like items | iPadOS 27 |
| `TabView` selection must point at a visible tab (else crash) | — | iOS 27 SDK |
| Gesture input kinds (touch / pencil / pointer) | `TapGesture`, `DragGesture`, `MagnifyGesture`, … new initializers with `GestureInputKinds` | iOS 27 |
| Documents | `ReadableDocument`/`WritableDocument`/`Document`; `FileDocument` deprecated | iOS 27 |
| iPhone Duo adaptivity | `ArrangementView` (split / overlay), `ReservedRegion`, `onHingeChange(isEnabled:_:)`, `\.toolbarVerticalEdge` env (`HorizontalEdge?`), `toolbarVerticalBehavior(_:)`, `axisBehavior(_:)`, `toolbarVerticalCompressionBehavior(_:)` | **iOS 27.1 beta** — NOT in the installed iOS 27.0 SDK; needs the Xcode 27.1 beta. Standard components adapt automatically without them |
| Controls reset inside sheets/popovers | `controlSize`, `buttonSizing`, `ButtonBorderShape`, `menuIndicatorVisibility` env values reset to default in sheets/popovers | iOS 27 SDK |

Other iOS 27 SDK requirements (UIKit release notes, also bind SwiftUI apps):

- **A launch screen is mandatory**: Info.plist must contain `UILaunchScreen` (SwiftUI apps: add an empty `UILaunchScreen` dictionary, optionally with `UIColorName`/`UIImageName`). Apps without one are rejected once App Store takes 27 SDK builds.
- **Scene-based life cycle is mandatory** for UIKit apps built with the iOS 27 SDK (SwiftUI `App` already is).
- iOS 26 shipped `UIDesignRequiresCompatibility` (Info.plist) to opt out of Liquid Glass. Atlas must **not** set it. Whether it still works under the 27 SDK: (unverified).

### 1.4 iOS 26 recap (the base the whole design builds on)

- Liquid Glass: a translucent, refracting material for the **functional layer** (bars, tab bars, sidebars, toolbars, sheets, popovers, menus, controls) floating above the **content layer**.
- Tab bar floats as a glass capsule above content, can minimize on scroll, can host a bottom accessory, search becomes its own trailing tab.
- Navigation bars are now "toolbars": items sit in glass capsules grouped by `ToolbarItemGroup`/`ToolbarSpacer`; prominent action tinted with accent color.
- Scroll edge effect replaces opaque bar backgrounds: content blurs/fades under bars.
- Sheets: bigger corner radius, half-height sheets are inset from screen edges and become more opaque when expanded; action sheets/confirmation dialogs originate from their source control.
- Lists/forms: taller rows, more padding, larger section corner radius, section headers no longer forced uppercase (use Title Case text yourself).
- Controls: rounder shapes concentric with the device, knob of sliders/toggles turns into glass while dragged, buttons morph into their menus/popovers, new extra-large control size.
- App icons: layered, built in Icon Composer, four appearances (default/light, dark, clear, tinted).

Source: https://developer.apple.com/design/whats-new/ · https://developer.apple.com/documentation/updates/swiftui · https://developer.apple.com/documentation/updates/uikit · https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes · https://developer.apple.com/ios/ · https://developer.apple.com/xcode/whats-new/ · https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo

---

## 2. Design principles and Liquid Glass

### 2.1 Apple's design principles (HIG, reintroduced June 2026)

Eight principles; use them as tie-breakers when two rules conflict.

| Principle | One-line meaning | What it means for Atlas |
|---|---|---|
| Purpose | Make the most important things great | Photos grid + viewer must be flawless before albums/people polish |
| Agency | Let people act their way, keep them informed, make mistakes recoverable | Trash instead of hard delete, undo, visible backup progress, no forced flows |
| Responsibility | Be transparent; collect only what you need; protect data | Explain every permission (Photos, Local Network, Face ID) in context |
| Familiarity | Reuse known concepts; be consistent; give clear feedback | Copy Photos.app and Files.app conventions instead of inventing |
| Flexibility | Design for everyone, every input, every size | Dynamic Type to AX5, VoiceOver, pointer/keyboard on iPad, iPhone Duo |
| Simplicity | Only what's needed, concise words, clear hierarchy | One primary action per screen; secondary actions go in menus |
| Craft | Care about every detail; iterate; keep current | Smooth 120 Hz scrolling, correct haptics, no placeholder copy |
| Delight | Right emotion, defining moments, not decoration | Zoom transition into a photo, satisfying selection haptics — no gratuitous animation |

Source: https://developer.apple.com/design/human-interface-guidelines/design-principles

### 2.2 The two layers

- **Content layer**: photos, file lists, settings rows, charts. Opaque or standard materials. **Never Liquid Glass.**
- **Functional (Liquid Glass) layer**: tab bar, toolbars/nav bars, sidebars, search field, sheets, popovers, menus, floating action bars. Floats above content; content scrolls underneath and shows through.
- Exception: transient controls in the content layer (slider knob, toggle knob) turn into glass **only while being touched**; the system does this for you.
- Keep a clean separation: navigation must look like navigation, content like content. Don't put glass cards in a feed, don't put glass behind list rows, don't make photo thumbnails glass.

Source: https://developer.apple.com/design/human-interface-guidelines/materials · https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass

### 2.3 Where glass goes / must not go

**Use system components first — they adopt glass automatically**: `TabView`, `NavigationStack`/`NavigationSplitView` bars, `.toolbar`, `.searchable`, `.sheet`, `.popover`, `Menu`, `confirmationDialog`, `Button` in toolbars, `Slider`, `Toggle`, `Picker(.segmented)`.

Custom glass (`glassEffect`) is allowed only for a few **important floating functional elements**. In Atlas that means:

- the multi-select action bar floating above the photo grid (if not done via the bottom toolbar),
- floating viewer controls over a full-screen photo (prefer `.clear` glass),
- the date scrubber thumb/label over the grid,
- a floating backup-status pill (prefer `tabViewBottomAccessory` instead).

**Never** apply glass to: list rows, grid cells, cards in scrolling content, full-screen backgrounds, section headers, charts, text blocks, or layered on top of other glass (no glass-on-glass).

Remove custom backgrounds from system bars: no `.toolbarBackground(.visible)` color fills, no `UINavigationBarAppearance` backgrounds, no custom blur views behind tab bars or toolbars, no visual-effect views inside popovers/sheets. They fight the glass and the scroll edge effect.

### 2.4 Variants and when to use which

| Variant | SwiftUI | Look | Use for |
|---|---|---|---|
| Regular | `Glass.regular` (default) | Blurs + adjusts luminosity of what's behind; adapts light/dark to content | Almost everything: bars, controls, anything with text, over mixed content |
| Clear | `Glass.clear` | Highly translucent | Controls floating over **media** (photo viewer, video). Add a **35% black dimming layer** behind them when the media is bright; skip it when media is dark or when AVKit controls bring their own dimming |
| Identity | `Glass.identity` | No effect (renders content as if no glass) | Toggling glass off conditionally without changing view structure (e.g. Reduce Transparency fallback, or "selected vs unselected") |
| `.tint(_:)` | `Glass.regular.tint(.accentColor)` | Stained glass | Only the **one** primary action / a status indicator; tint the background, not the label |
| `.interactive()` | `Glass.regular.interactive()` | Scales/bounces/shimmers on touch like system buttons | Custom glass that is tappable |

All `Glass` APIs: `iOS 26+` (`struct Glass`, `.regular`, `.clear`, `.identity`, `tint(_ color: Color?)`, `interactive(_ isEnabled: Bool = true)`).

### 2.5 Color on glass

- Glass has no color of its own; it picks up the content behind it. Small elements (tab bar, toolbar) flip between light and dark appearance automatically depending on content beneath; their symbols/text are monochrome by default.
- Larger glass surfaces (sidebars) are more opaque to stay legible.
- Apply color **sparingly**: one tinted primary action per bar (system does this for `.glassProminent` / `.borderedProminent` / confirm actions like Done). Don't tint multiple controls. Tint the **background** of the primary action, not its symbol.
- Over colorful content (photos!), keep toolbars/tab bar monochrome. Atlas's accent color should therefore be used for selection state and the single prominent action, not for every toolbar icon.
- Ensure the resting state of the screen has contrast; content may briefly scroll under controls, that's fine.
- Custom colors on glass need light, dark and increased-contrast variants (use an asset-catalog color with all four).

Source: https://developer.apple.com/design/human-interface-guidelines/color#Liquid-Glass-color

### 2.6 Layering, grouping and morphing

- Glass elements that sit near each other should be **rendered together** in a `GlassEffectContainer` (performance + they can blend/morph). Shapes closer than the container's `spacing` merge into one blob at rest; larger spacing = earlier merge during animations.
- Apply `.glassEffect` **last** (after padding, frame, font, foreground styles) — it captures the view's appearance.
- `glassEffectUnion(id:namespace:)` merges separate views into a single capsule even when they're not adjacent in one stack.
- `glassEffectID(_:in:)` + `withAnimation` makes glass shapes morph into each other when views appear/disappear (e.g. "Select" button morphing into the selection action bar).
- `glassEffectTransition(_:)`: `.matchedGeometry` (default inside container spacing), `.materialize` (fade content + animate material, for shapes farther apart than spacing), `.identity`.
- Don't stack glass on glass, don't crowd glass controls, use standard spacing.
- Limit how many glass effects are on screen at once — each costs GPU.

```swift
// iOS 26+
struct SelectionBar: View {
    @Namespace private var glass
    var isSelecting: Bool
    var count: Int

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                if isSelecting {
                    Button("Share", systemImage: "square.and.arrow.up") {}
                        .labelStyle(.iconOnly)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("share", in: glass)
                    Text(count == 0 ? "Select Items" : "\(count) Selected")
                        .font(.headline)
                        .padding(.horizontal, 20).frame(height: 48)
                        .glassEffect()
                        .glassEffectID("title", in: glass)
                    Button("Delete", systemImage: "trash", role: .destructive) {}
                        .labelStyle(.iconOnly)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("delete", in: glass)
                }
            }
        }
        .animation(.smooth, value: isSelecting)
    }
}
```

API facts (DocC, `iOS 26+`):

```swift
func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View // default shape: Capsule
struct GlassEffectContainer<Content: View>   // init(spacing: CGFloat? = nil, @ContentBuilder content: () -> Content)
func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
func glassEffectTransition(_ transition: GlassEffectTransition) -> some View // .matchedGeometry, .materialize, .identity
static var glass: GlassButtonStyle            // .buttonStyle(.glass)
static var glassProminent: GlassProminentButtonStyle // .buttonStyle(.glassProminent)
static func glass(_ glass: Glass) -> Self     // .buttonStyle(.glass(.clear))
```

Prefer `.buttonStyle(.glass)` / `.glassProminent` over hand-rolled `glassEffect` on buttons.

Source: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views · https://developer.apple.com/documentation/swiftui/glass · https://developer.apple.com/documentation/swiftui/glasseffectcontainer

### 2.7 Legibility and scroll edge effects

- With glass bars, content runs **edge to edge** under the bars; the **scroll edge effect** (blur + fade of content under a bar) keeps bar controls legible. System bars apply it automatically.
- Styles (`ScrollEdgeEffectStyle`, `iOS 26+`): `.automatic` (default; system chooses), `.hard` (nearly opaque linear boundary — use with many controls, text outside glass, or pinned headers), `.soft` (subtle blur). Hide with `.scrollEdgeEffectHidden(_:for:)`.
- Rules: prefer automatic; use the effect only where a scroll view is behind floating UI (it's not decoration); one effect per view/pane; in split views keep pane edge-effect heights consistent.
- Custom floating bars (Atlas selection bar, scrubber) must register as bars so the edge effect is computed for them: use `.safeAreaBar(edge:...)` instead of `.safeAreaInset` / `.overlay`. Two overloads (iOS 26+): `safeAreaBar(edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, content:)` for top/bottom bars and `safeAreaBar(edge: HorizontalEdge, alignment: VerticalAlignment = .center, ...)` for leading/trailing bars (e.g. the scrubber).
- Pinned section headers in the photo grid sit under the top bar: use `.scrollEdgeEffectStyle(.hard, for: .top)` so dates stay readable.

```swift
// iOS 26+
ScrollView { PhotoGrid() }
    .scrollEdgeEffectStyle(.hard, for: .top)
    .safeAreaBar(edge: .bottom) { SelectionBar(isSelecting: true, count: 3) }
```

Source: https://developer.apple.com/design/human-interface-guidelines/scroll-views#Scroll-edge-effects · https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle

### 2.8 Concentricity and shape

- Hardware corner radius drives everything: sheets, popovers, controls and windows nest **concentrically** (inner radius = outer radius − inset). Many controls became capsules/rounder.
- Use `ConcentricRectangle` (iOS 26+) for custom containers near the screen or inside a container shape; set `.containerShape(_:)` on your custom container so children can resolve concentric radii. Corner styles: `.concentric`, `.concentric(minimum:)`, `.fixed(_:)`; static convenience `.rect(corners:isUniform:)`.
- iOS 27: `GeometryProxy.concentricCornerRadii` / `concentricCornerRadii(in:)` returns `RectangleCornerRadii?` for custom drawing.
- Prefer `Capsule` for glass buttons/pills, `Circle` for single-symbol glass buttons, concentric rects for larger glass panels. Don't hard-code a 10pt radius on something sitting 8pt from a 55pt-radius screen corner.

```swift
// iOS 26+: a floating panel whose corners follow the device corners
VStack { BackupStatusDetails() }
    .padding(20)
    .background(.background, in: ConcentricRectangle(corners: .concentric(minimum: 20), isUniform: true)) // init(corners: Edge.Corner.Style, isUniform: Bool = false)
    .padding(8)
```

Source: https://developer.apple.com/documentation/swiftui/concentricrectangle · https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass

### 2.9 Navigation in the glass layer

- Make navigation hierarchy obvious and separate from content: tab bar for top-level areas, toolbars for actions on the current view.
- Tab bar can minimize on scroll (`.tabBarMinimizeBehavior(.onScrollDown)`, iPhone only) — Photos uses this.
- Search is a dedicated trailing tab (`Tab(role: .search)`); the system separates it from other tabs.
- `tabViewBottomAccessory` hosts persistent status above the tab bar (Music's mini player). Atlas: backup progress.
- On iPad, `.tabViewStyle(.sidebarAdaptable)` lets the tab bar become a sidebar.
- `backgroundExtensionEffect()` mirrors and blurs edge content under sidebars/inspectors (hero images on iPad). Use on at most one background view.
- Hide whole toolbar items, not their contents (an empty glass capsule is a bug).

### 2.10 Accessibility interactions with glass

- People can choose a preferred glass look (clearer vs tinted) in Settings, and Reduce Transparency / Increase Contrast / Reduce Motion modify glass and morphing. System components adapt automatically; **test every custom glass element** under each setting.
- Under Reduce Transparency, consider switching custom glass to `.identity` plus a solid background (`@Environment(\.accessibilityReduceTransparency)`).
- Provide an accessibility label for every icon-only glass button.

### 2.11 Performance

- Wrap multiple custom glass views in **one** `GlassEffectContainer`; don't create many containers.
- Keep simultaneous glass effects few; profile with Instruments (SwiftUI + Animation Hitches).
- `backgroundExtensionEffect()` duplicates the view: one instance only.

Source: https://developer.apple.com/documentation/technologyoverviews/liquid-glass · https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass · https://developer.apple.com/design/human-interface-guidelines/materials · https://developer.apple.com/design/human-interface-guidelines/motion

---

## 3. Foundations

### 3.1 Typography

**Rules**

- System font = **SF Pro** (variable, dynamic optical sizes; the system adjusts tracking per point size — don't add tracking yourself). Serif = **New York** (`.fontDesign(.serif)`), rounded (`.rounded`), monospaced (`.monospaced`; SF Mono). Never bundle SF/NY files; reach them through `Font.Design`.
- iOS default text size **17 pt**, minimum **11 pt** (applies to custom fonts too).
- Prefer Regular, Medium, Semibold, Bold. Avoid Ultralight/Thin/Light, especially small.
- Use as few typefaces as possible. Atlas: SF Pro only, plus `.monospacedDigit()` for live numbers (CPU %, sizes, counters) so they don't jitter.
- Use **text styles** (not fixed sizes) so Dynamic Type works. Create extra hierarchy with the bold/emphasized trait (`.bold()`), not by inventing sizes.
- Tight leading only for 1–2 lines in height-constrained rows; never for 3+ lines. Loose leading for long passages.
- When text grows: icons that carry meaning must grow too (SF Symbols do automatically); avoid truncation (aim to show as much at AX sizes as at the largest standard size); switch horizontal layouts to stacked layouts at accessibility sizes; reduce column count; keep the hierarchy order (primary stays on top).
- Not everything must scale: tab titles and other chrome needn't grow with content (the system handles its own bars).

**iOS/iPadOS Dynamic Type — default size ("Large")**

| Style | SwiftUI | Weight | Size pt | Leading pt | Emphasized weight |
|---|---|---|---|---|---|
| Large Title | `.largeTitle` | Regular | 34 | 41 | Bold |
| Title 1 | `.title` | Regular | 28 | 34 | Bold |
| Title 2 | `.title2` | Regular | 22 | 28 | Bold |
| Title 3 | `.title3` | Regular | 20 | 25 | Semibold |
| Headline | `.headline` | Semibold | 17 | 22 | Semibold |
| Body | `.body` | Regular | 17 | 22 | Semibold |
| Callout | `.callout` | Regular | 16 | 21 | Semibold |
| Subhead | `.subheadline` | Regular | 15 | 20 | Semibold |
| Footnote | `.footnote` | Regular | 13 | 18 | Semibold |
| Caption 1 | `.caption` | Regular | 12 | 16 | Semibold |
| Caption 2 | `.caption2` | Regular | 11 | 13 | Semibold |

(`Font.TextStyle` also has `.extraLargeTitle` / `.extraLargeTitle2` — visionOS-oriented; don't use on iPhone.)

**Size / leading in points across every Dynamic Type setting (iOS)**

| Style | xS | S | M | **L (default)** | xL | xxL | xxxL | AX1 | AX2 | AX3 | AX4 | AX5 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Large Title | 31/38 | 32/39 | 33/40 | **34/41** | 36/43 | 38/46 | 40/48 | 44/52 | 48/57 | 52/61 | 56/66 | 60/70 |
| Title 1 | 25/31 | 26/32 | 27/33 | **28/34** | 30/37 | 32/39 | 34/41 | 38/46 | 43/51 | 48/57 | 53/62 | 58/68 |
| Title 2 | 19/24 | 20/25 | 21/26 | **22/28** | 24/30 | 26/32 | 28/34 | 34/41 | 39/47 | 44/52 | 50/59 | 56/66 |
| Title 3 | 17/22 | 18/23 | 19/24 | **20/25** | 22/28 | 24/30 | 26/32 | 31/38 | 37/44 | 43/51 | 49/58 | 55/65 |
| Headline | 14/19 | 15/20 | 16/21 | **17/22** | 19/24 | 21/26 | 23/29 | 28/34 | 33/40 | 40/48 | 47/56 | 53/62 |
| Body | 14/19 | 15/20 | 16/21 | **17/22** | 19/24 | 21/26 | 23/29 | 28/34 | 33/40 | 40/48 | 47/56 | 53/62 |
| Callout | 13/18 | 14/19 | 15/20 | **16/21** | 18/23 | 20/25 | 22/28 | 26/32 | 32/39 | 38/46 | 44/52 | 51/60 |
| Subhead | 12/16 | 13/18 | 14/19 | **15/20** | 17/22 | 19/24 | 21/28 | 25/31 | 30/37 | 36/43 | 42/50 | 49/58 |
| Footnote | 12/16 | 12/16 | 12/16 | **13/18** | 15/20 | 17/22 | 19/24 | 23/29 | 27/33 | 33/40 | 38/46 | 44/52 |
| Caption 1 | 11/13 | 11/13 | 11/13 | **12/16** | 14/19 | 16/21 | 18/23 | 22/28 | 26/32 | 32/39 | 37/44 | 43/51 |
| Caption 2 | 11/13 | 11/13 | 11/13 | **11/13** | 13/18 | 15/20 | 17/22 | 20/25 | 24/30 | 29/35 | 34/41 | 40/48 |

Weights are the same at every size (Headline is Semibold, everything else Regular). Body grows 17 → 53 pt (≈312%) — layouts must survive that.

**SF Pro tracking (reference only — system applies it automatically)**: 11 pt +0.06, 12 pt 0, 13 pt −0.08, 14 pt −0.15, 15 pt −0.23, 16 pt −0.31, 17 pt −0.43 (points).

**SwiftUI**

```swift
Text("Recents").font(.largeTitle.bold())                 // emphasized variant
Text("1,284 Photos").font(.subheadline).foregroundStyle(.secondary)
Text("72%").font(.title2.weight(.semibold)).monospacedDigit()   // live values
Text("ATLAS").fontWidth(.expanded)                         // iOS 16+, Font.Width: .compressed .condensed .standard .expanded
Text("Note").fontDesign(.rounded)                          // iOS 16.1+
Text(caption).font(.callout).lineLimit(3).leading(.tight)  // Font.leading(_:) .tight/.standard/.loose

// Custom font that still scales with Dynamic Type
Text("Hero").font(.custom("Brand-Bold", size: 34, relativeTo: .largeTitle))

// Scale a non-text metric with Dynamic Type (iOS 14+)
@ScaledMetric(relativeTo: .body) private var rowIcon: CGFloat = 28

// Switch layout at accessibility sizes
@Environment(\.dynamicTypeSize) private var typeSize
var body: some View {
    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
    layout { Label("Storage", systemImage: "internaldrive"); Spacer(); Text("1.2 TB") }
}
// Or let SwiftUI choose the first layout that fits:
ViewThatFits { HStack { a; b }; VStack(alignment: .leading) { a; b } }

// Clamp only where unavoidable (e.g. a dense grid overlay label) — iOS 15+
Text(duration).font(.caption2).dynamicTypeSize(...DynamicTypeSize.accessibility1)
```

Source: https://developer.apple.com/design/human-interface-guidelines/typography

### 3.2 Color

**Rules**

- Use **semantic/system colors** via API; never hard-code their RGB (values change between releases and with settings).
- Every custom color needs **light, dark, increased-contrast light, increased-contrast dark** variants (asset catalog color set with "High Contrast" checked). Even a dark-only screen must provide both so Liquid Glass can adapt.
- Don't reuse one color for different meanings (e.g. accent for "tappable" and also for plain decorative text).
- Never convey information by color alone — add a symbol, shape or text (status dots on the server dashboard need an icon or label too).
- Apply the accent color sparingly: selection, the one primary action, links. On glass, see §2.5.
- Use system color pickers (`ColorPicker`) if users pick colors.
- Photos-heavy apps may adjust True Tone behavior (`UIWhitePointAdaptivityStyle` Info.plist: `photo` style) — consider for the viewer (unverified for SwiftUI-only apps; it's an Info.plist key).

**Background hierarchy (iOS)**

| Context | Primary (whole view) | Secondary (groups inside) | Tertiary (groups inside secondary) |
|---|---|---|---|
| Plain lists / custom screens | `systemBackground` | `secondarySystemBackground` | `tertiarySystemBackground` |
| Grouped lists / Settings-style forms | `systemGroupedBackground` | `secondarySystemGroupedBackground` (cells) | `tertiarySystemGroupedBackground` |

In SwiftUI: `Color(.systemGroupedBackground)`, `Color(.secondarySystemGroupedBackground)` etc. (UIColor bridges), or the ShapeStyles `.background`, `.background.secondary`, `.background.tertiary`. `Form`/`List(.insetGrouped)` already use the grouped set — don't paint them.

**Foreground (label) hierarchy**

| Role | UIKit | SwiftUI |
|---|---|---|
| Primary text | `label` | `.primary` / `.foregroundStyle(.primary)` |
| Secondary text (subtitles, metadata) | `secondaryLabel` | `.secondary` |
| Tertiary (disabled-looking hints) | `tertiaryLabel` | `.tertiary` |
| Quaternary (watermarks) | `quaternaryLabel` | `.quaternary` |
| Placeholder | `placeholderText` | `Color(.placeholderText)` |
| Separator (translucent) | `separator` | `Color(.separator)` / `Divider()` |
| Opaque separator | `opaqueSeparator` | `Color(.opaqueSeparator)` |
| Link | `link` | `Color(.link)` / `Link` / `.tint` |
| Fills (control backgrounds) | `systemFill` … `quaternarySystemFill` | `Color(.systemFill)`, or ShapeStyle `.fill` (iOS 17+) with `.fill.secondary` / `.fill.tertiary` |

Don't repurpose them (no separator color as text, no secondary label as a background).

**System colors (iOS 26/27 values, RGB 0–255; reference only)**

| Name | SwiftUI | Light | Dark | Inc. contrast light | Inc. contrast dark |
|---|---|---|---|---|---|
| Red | `.red` | 255,56,60 | 255,66,69 | 233,21,45 | 255,97,101 |
| Orange | `.orange` | 255,141,40 | 255,146,48 | 197,83,0 | 255,160,86 |
| Yellow | `.yellow` | 255,204,0 | 255,214,0 | 161,106,0 | 254,223,67 |
| Green | `.green` | 52,199,89 | 48,209,88 | 0,137,50 | 74,217,104 |
| Mint | `.mint` | 0,200,179 | 0,218,195 | 0,133,117 | 84,223,203 |
| Teal | `.teal` | 0,195,208 | 0,210,224 | 0,129,152 | 59,221,236 |
| Cyan | `.cyan` | 0,192,232 | 60,211,254 | 0,126,174 | 109,217,255 |
| Blue | `.blue` | 0,136,255 | 0,145,255 | 30,110,244 | 92,184,255 |
| Indigo | `.indigo` | 97,85,245 | 109,124,255 | 86,74,222 | 167,170,255 |
| Purple | `.purple` | 203,48,224 | 219,52,242 | 176,47,194 | 234,141,255 |
| Pink | `.pink` | 255,45,85 | 255,55,95 | 231,18,77 | 255,138,196 |
| Brown | `.brown` | 172,127,94 | 183,138,102 | 149,109,81 | 219,166,121 |

**System grays (UIKit)**

| Name | Light | Dark | IC light | IC dark |
|---|---|---|---|---|
| `systemGray` (= SwiftUI `.gray`) | 142,142,147 | 142,142,147 | 108,108,112 | 174,174,178 |
| `systemGray2` | 174,174,178 | 99,99,102 | 142,142,147 | 124,124,128 |
| `systemGray3` | 199,199,204 | 72,72,74 | 174,174,178 | 84,84,86 |
| `systemGray4` | 209,209,214 | 58,58,60 | 188,188,192 | 68,68,70 |
| `systemGray5` | 229,229,234 | 44,44,46 | 216,216,220 | 54,54,56 |
| `systemGray6` | 242,242,247 | 28,28,30 | 235,235,240 | 36,36,38 |

Atlas semantic mapping suggestion: healthy = `.green` + `checkmark.circle.fill`, degraded = `.orange` + `exclamationmark.triangle.fill`, down = `.red` + `xmark.octagon.fill`, CPU = `.blue`, GPU = `.purple`, RAM = `.teal`, disk = `.orange`, network = `.indigo` (chart series).

```swift
// Accent color: set "AccentColor" in the asset catalog (all 4 variants); override per subtree with .tint(_:)
List { ... }.tint(.blue)
Text("Up").foregroundStyle(.green)
Rectangle().fill(.background.secondary)          // hierarchical background ShapeStyle (iOS 17+)
Text(subtitle).foregroundStyle(.secondary)
@Environment(\.colorSchemeContrast) private var contrast   // .standard / .increased
```

Source: https://developer.apple.com/design/human-interface-guidelines/color

### 3.3 Dark Mode

- Support both appearances; **no in-app light/dark switch** (people expect the system setting, incl. Auto).
- Dark palette = dimmer backgrounds + brighter foregrounds; not a straight inversion. Semantic colors adapt automatically.
- Minimum contrast **4.5:1** in both appearances; check Dark Mode with Increase Contrast and Reduce Transparency, separately and together.
- Images with white backgrounds: darken slightly in Dark Mode so they don't glow (e.g. document thumbnails in Drive).
- A **permanently dark** appearance is acceptable for immersive media viewing — the full-screen photo/video viewer should force dark: `.preferredColorScheme(.dark)` on the viewer only, or a black background with `.toolbarColorScheme(.dark, for: .navigationBar)`.
- Use SF Symbols (adapt automatically); provide separate light/dark assets only where needed.
- Use system text views/fields so vibrancy and contrast are handled.

```swift
@Environment(\.colorScheme) private var scheme
PhotoViewer().background(.black).preferredColorScheme(.dark)   // viewer only
```

Source: https://developer.apple.com/design/human-interface-guidelines/dark-mode

### 3.4 Materials (standard, content layer)

- Liquid Glass = functional layer (see §2). **Standard materials** = structure inside the content layer.
- iOS standard materials, thinnest to thickest: `.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial` (default), `.thickMaterial` (plus `.ultraThickMaterial` in SwiftUI). Thicker = more contrast for fine text; thinner = more context.
- Pick by semantic purpose, not by the tint it seems to give.
- Put **vibrant** foreground on materials: in SwiftUI, `.foregroundStyle(.secondary)` etc. on top of a `Material` background automatically become vibrant. Don't use quaternary on thin/ultraThin (too little contrast).
- Atlas uses: date-pill labels over thumbnails (`.ultraThinMaterial` capsule — content layer, so not glass), video duration badges, face-thumbnail name labels.

```swift
Text("Today").font(.caption.weight(.semibold))
    .padding(.horizontal, 8).padding(.vertical, 4)
    .background(.ultraThinMaterial, in: .capsule)
    .foregroundStyle(.secondary)     // vibrant over material
```

Source: https://developer.apple.com/design/human-interface-guidelines/materials

### 3.5 Layout

**Rules**

- Most important content top and leading; align for scanning; indent to show subordination; group with space/containers/separators; progressive disclosure for secondary detail.
- **Differentiate controls from content with Liquid Glass + scroll edge effect, not with solid/semi-opaque bars behind controls.**
- Extend full-bleed content under sidebars/inspectors (`backgroundExtensionEffect()` if a sidebar would hide important parts).
- Lay out by **size class**, not device model or orientation. Handle every combination (iPhone portrait = compact width/regular height; most iPhone landscape = compact/compact; Pro Max/Plus landscape = regular width/compact height; iPad full screen = regular/regular; iPad windows can be anything; iPhone Duo outer = compact width, inner = regular width).
- Keep functionality identical across size classes; you may show more of it in more space (tab bar → sidebar).
- Respect **safe areas** (Dynamic Island, home indicator, bars) and **layout margins**; let backgrounds bleed (`.ignoresSafeArea()` on the background only, never on interactive content).
- Support text-size changes (stack instead of truncating).
- Preview the smallest and largest layouts first; use Device Hub (Xcode 27) to test sizes incl. iPhone Duo.
- iPad windows resize continuously (iPadOS 26+): support arbitrary sizes; use `NavigationSplitView` for fluid column reflow.

**Numbers**

| Item | Value |
|---|---|
| Default hit target | **44×44 pt** (minimum 28×28 pt) |
| Padding around bezeled elements | ~12 pt |
| Padding around bezel-less elements | ~24 pt |
| Standard layout margins (iPhone) | 16 pt compact, 20 pt regular width (unverified — not stated on current HIG page) |
| Default `List`/`Form` inset grouped corner radius | increased in iOS 26; don't hard-code (unverified exact) |

Device screen sizes: the HIG Layout page **no longer lists per-device dimensions** (Sept 2026 rewrite points to Apple Design Resources). Points from memory (unverified): iPhone 16e 390×844; iPhone 17 / 17 Pro 402×874; iPhone Air 420×912; iPhone 17 Pro Max 440×956. Don't design to these — use size classes and `containerRelativeFrame`/`GeometryReader`.

**iPhone Duo (iOS 27, new Sept 2026)**

- Two displays: **outer** (closed; wider and shorter than other iPhones) and **inner** (open; larger). Center hinge; poses: book-like partially folded, flat on a surface, standing on its edge.
- Treat outer as **compact width**, inner as **regular width**; don't design per pose — let layouts expand.
- On the outer display (and inner display in landscape) the system puts **toolbars, tab bars and navigation controls on the vertical axis** (screen side) to save height. Standard components do this automatically.
- Keep functionality and state identical across displays; optionally show one more hierarchy level on the inner display (Mail: list or message closed, both side by side open).
- **Reserved regions**: outer front camera (always; expands into Dynamic Island for Live Activities), inner camera (only while active — UI moves aside), folding region (only when partially folded; splits the inner display). Alerts, context menus, sheets and split views avoid them automatically; custom UI uses `ReservedRegion` (iOS 27.1 beta API).
- Grids: prefer an **even number of columns** so content divides cleanly at the fold. Atlas photo grid: on the inner display choose 6 or 8 columns rather than 5 or 7.
- Avoid extreme layout changes while folding — small adjustments only.
- `ArrangementView` (split / overlay arrangement of a primary + secondary view) adapts to size, orientation and the fold — consider it where you'd otherwise hand-build an `HStack`/`VStack` switch (iOS 27.1 beta).

```swift
@Environment(\.horizontalSizeClass) private var hSize
let columns = hSize == .regular ? 6 : 4                      // even column counts
LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) { ... }

// Size relative to the scroll container (iOS 17+)
Image(...).containerRelativeFrame(.horizontal, count: columns, spacing: 2)

// Read and use safe areas
GeometryReader { proxy in content.padding(.bottom, proxy.safeAreaInsets.bottom) }
someBackground.ignoresSafeArea()   // backgrounds only
```

Source: https://developer.apple.com/design/human-interface-guidelines/layout · https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo · https://developer.apple.com/design/human-interface-guidelines/accessibility (control sizes)

### 3.6 Designing for iPhone (platform traits)

- Medium high-res display; one- or two-handed use; viewing distance ~1–2 ft; both orientations.
- Short sessions (check backup status) and long sessions (browse photos) — support both.
- Limit on-screen controls; make secondary actions discoverable with minimal interaction (menus, context menus).
- Put frequent controls in the **middle/bottom** (reachability) — another reason Atlas puts selection actions in a bottom bar.
- Adapt to orientation, Dark Mode, Dynamic Type.
- Integrate system capabilities with permission instead of asking for data (Face ID, Photos, Share sheet).
- System features to consider: widgets, Home Screen quick actions, Spotlight, Shortcuts, activity views.

Source: https://developer.apple.com/design/human-interface-guidelines/designing-for-ios

### 3.7 Accessibility

**Numbers**

| Requirement | Value |
|---|---|
| Text enlargement to support | at least **200%** |
| iOS default / minimum text | 17 pt / 11 pt |
| Contrast, text ≤17 pt (all weights) | **4.5:1** |
| Contrast, text ≥18 pt or bold (any size) | **3:1** |
| Control size iOS default / minimum | **44×44 pt** / 28×28 pt |
| Spacing around bezeled controls | ~12 pt; bezel-less ~24 pt |

**Rules**

- Vision: support Dynamic Type through AX5; meet contrast (at least under Increase Contrast); prefer system colors; never color-only signals; VoiceOver labels for everything.
- Hearing: captions/subtitles for video (AVKit handles tracks); pair audio cues with haptics and visuals.
- Mobility: big targets, simple gestures, **on-screen alternative for every gesture** (pinch-to-change-grid-density needs a menu option too; swipe-to-delete needs Edit/Delete buttons), support Voice Control (visible labels = spoken names), Switch Control, Full Keyboard Access; don't override system keyboard shortcuts.
- Cognitive: consistent interactions, no auto-dismissing UI on timers, user-controlled media playback (no autoplay with sound), honor Dim Flashing Lights for video.
- **Reduce Motion**: tighten springs (less bounce), track gestures directly, avoid z-axis depth animations, replace x/y/z slides with fades, don't animate into/out of blur.
- Assistive Access (iOS 26 SwiftUI `AssistiveAccess` scene): identify core functions, one interaction per screen, double-confirm destructive actions. Optional for Atlas.
- Audit with Accessibility Inspector; declare Accessibility Nutrition Labels in App Store Connect.

**VoiceOver**

- Label every key element (system controls already are). Icon-only buttons need labels — `Button("Delete", systemImage: "trash")` + `.labelStyle(.iconOnly)` keeps the label for VoiceOver.
- Describe meaningful images (photos: use date/place/people as the label, e.g. "Photo, March 3 2026, Lisbon, with Ana"); hide decorative images (`Image(decorative:)` / `.accessibilityHidden(true)`).
- Charts: concise summary + per-point values; Swift Charts provides Audio Graphs automatically, add `.accessibilityLabel`/`.accessibilityValue` per mark.
- Headings for navigation (`.accessibilityAddTraits(.isHeader)`; section headers are headings automatically in `List`).
- Group related elements (`.accessibilityElement(children: .combine)` on a grid cell or row), set order (`.accessibilitySortPriority`), announce content changes (`AccessibilityNotification.Announcement("Upload complete").post()`).
- Support the rotor (`.accessibilityRotor`) for long content — e.g. jump between date sections in the photo grid.

```swift
PhotoCell(asset)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(asset.accessibilityDescription)        // "Video, 0:42, June 2 2026"
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction(named: "Favorite") { toggleFavorite(asset) }
    .accessibilityAction(named: "Delete") { delete(asset) }

@Environment(\.accessibilityReduceMotion) private var reduceMotion
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
@Environment(\.accessibilityDifferentiateWithoutColor) private var noColor
withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .bouncy) { expanded.toggle() }

Section("Server") { ... }    // headers are headings
Text("Storage").accessibilityAddTraits(.isHeader)

ScrollView { grid }
    .accessibilityRotor("Months") {
        ForEach(sections) { s in AccessibilityRotorEntry(s.title, id: s.id) }
    }
```

Source: https://developer.apple.com/design/human-interface-guidelines/accessibility · https://developer.apple.com/design/human-interface-guidelines/voiceover

### 3.8 SF Symbols

- Use SF Symbols for all interface icons (toolbars, tab bars, menus, list rows, swipe actions). SF Symbols 7 shipped with iOS 26; **SF Symbols 8** (beta June 2026) accompanies the 27 generation — newer symbols need the matching OS (check availability in the SF Symbols app).
- Don't use symbols (or look-alikes) in app icons or logos. Apple-product symbols can't be customized.
- **Rendering modes**: monochrome (one color), hierarchical (one color, opacity by layer — good default for depth), palette (one color per layer), multicolor (intrinsic colors, e.g. `trash.slash` red). Use system colors so modes adapt to Dark Mode/contrast.
- **Gradient** rendering (SF Symbols 7+, iOS 26+): smooth linear gradient from one color; best at large sizes: `.symbolColorRenderingMode(.gradient)` (`.flat` default).
- **Variable color**: show a changing quantity (signal, capacity, progress) — not depth. `Image(systemName: "wifi", variableValue: 0.6)` (iOS 16+). iOS 26 adds `.symbolVariableValueMode(.draw)` (draws path length) vs `.color` (layer on/off).
- **Weights**: 9 (ultralight…black) matched to SF text weights — match adjacent text weight. **Scales**: small, medium (default), large relative to cap height: `.imageScale(.large)`.
- **Variants**: outline (toolbars, lists, next to text), fill (tab bars, swipe actions, selected state), slash, enclosed (circle/square — legible at small sizes). Containers usually pick the variant (tab bar → fill, toolbar → outline); force with `.symbolVariant(.fill)`.
- **Animations** (all on any symbol): appear, disappear, bounce (action happened), scale (persistent emphasis), pulse (ongoing activity), variable color (cumulative/iterative, activity), replace (down-up = state change, up-up = forward progression, off-up = next state; **Magic Replace** is the default for related shapes), wiggle (call attention), breathe (living status e.g. recording/syncing), rotate (in-progress), **Draw On / Draw Off** (SF Symbols 7+, iOS 26+). Use sparingly, with a clear purpose, matching the app's tone. Respect Reduce Motion (system symbol effects do).
- Custom symbols: start from an exported template, match weight/detail, annotate layers, provide accessibility labels.

**Standard symbols for common actions (HIG table)**

| Action | Symbol | Action | Symbol |
|---|---|---|---|
| Cut | `scissors` | Copy | `document.on.document` |
| Paste | `document.on.clipboard` | Done / Save | `checkmark` |
| Cancel / Close | `xmark` | Delete | `trash` |
| Undo / Redo | `arrow.uturn.backward` / `arrow.uturn.forward` | Compose | `square.and.pencil` |
| Duplicate | `plus.square.on.square` | Rename | `pencil` |
| Move to / Folder | `folder` | Attach | `paperclip` |
| Add | `plus` | More | `ellipsis` |
| Select | `checkmark.circle` | Deselect | `xmark` |
| Search | `magnifyingglass` | Find | `text.page.badge.magnifyingglass` |
| Filter | `line.3.horizontal.decrease` | Share / Export | `square.and.arrow.up` |
| Print | `printer` | Account / User / Profile | `person.crop.circle` |
| Like / Dislike | `hand.thumbsup` / `hand.thumbsdown` | Archive | `archivebox` |
| Calendar | `calendar` | Alarm | `alarm` |

Atlas-specific picks (verify each in the SF Symbols app — unverified names are common, long-standing symbols): Photos tab `photo.on.rectangle`, Drive tab `folder`, Settings tab `gear`, favorite `heart`/`heart.fill`, albums `rectangle.stack`, people `person.2`, trash `trash`, backup `icloud.and.arrow.up` → prefer a non-iCloud symbol such as `arrow.up.circle` or `externaldrive.badge.checkmark` since Atlas is iCloud-independent, server `server.rack`, CPU `cpu`, memory `memorychip`, disk `internaldrive`, network `network`, power `power`, grid `square.grid.3x3`, list `list.bullet`, sort `arrow.up.arrow.down`, info `info.circle`, upload `square.and.arrow.up.on.square` (unverified), map `map`.

```swift
Image(systemName: "externaldrive.fill").symbolRenderingMode(.hierarchical).foregroundStyle(.blue)
Image(systemName: "server.rack").symbolRenderingMode(.palette).foregroundStyle(.green, .secondary)
Image(systemName: "wifi", variableValue: signal)                     // iOS 16+
Image(systemName: "heart").symbolVariant(isFavorite ? .fill : .none)
Image(systemName: "arrow.up.circle").symbolEffect(.pulse, isActive: isUploading)        // iOS 17+ indefinite
Image(systemName: "checkmark.circle").symbolEffect(.bounce, value: completedCount)     // discrete, on change
Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.rotate, isActive: syncing)   // iOS 18+
Image(systemName: isFavorite ? "heart.fill" : "heart").contentTransition(.symbolEffect(.replace))
Image(systemName: "checkmark").symbolEffect(.drawOn, isActive: done)                 // iOS 26+ (DrawOnSymbolEffect)
Image(systemName: "sun.max.fill").symbolColorRenderingMode(.gradient)                // iOS 26+
Label("Storage", systemImage: "internaldrive").imageScale(.large)
```

Source: https://developer.apple.com/design/human-interface-guidelines/sf-symbols · https://developer.apple.com/design/human-interface-guidelines/icons

### 3.9 Icons (interface glyphs)

- Simple, single-concept, familiar metaphors; consistent size, detail, stroke weight and perspective across the app; match weight with adjacent text.
- Optical centering for asymmetric custom icons (bake padding into the asset).
- No separate selected-state icon for system bars/buttons — the system handles it.
- Gender-neutral, culturally neutral imagery; text in icons only when essential (and localized).
- Custom icons as **PDF or SVG** vector assets ("Preserve Vector Data"), with accessibility labels.
- Don't depict Apple hardware (use SF Symbols' device symbols if needed).

Source: https://developer.apple.com/design/human-interface-guidelines/icons

### 3.10 App icon

| Item | iOS / iPadOS value |
|---|---|
| Canvas | **1024×1024 px**, square, unmasked layers (system applies the rounded-rect mask concentric with hardware) |
| Style | **Layered**: background layer + one or more foreground layers; system adds specular highlights, refraction, translucency, shadow, blur |
| Appearances | **Default (light), Dark, Clear light, Clear dark, Tinted light, Tinted dark** |
| Tool | **Icon Composer** (ships with Xcode; Icon Composer 2 beta, June 2026) → produces the `.icon` file you add to the Xcode project |
| Color spaces | sRGB, Gray Gamma 2.2, Display P3 |
| Smaller sizes | generated automatically by the system |

Rules:

- Simple, bold concept; filled overlapping shapes; vary layer opacity for depth (import opaque layers, set transparency in Icon Composer); crisp edges (no feathering).
- Background: solid or gradient defined in Icon Composer (no need to import).
- Vector layers (SVG/PDF), text converted to outlines; PNG only for raster/mesh gradients.
- **Don't** bake in highlights, shadows, bevels, blurs, glows — the system renders them.
- Keep core content centered (corner masking); check against the updated grid (Apple Design Resources).
- No text unless essential, no photos, no UI replicas, no Apple hardware.
- Keep features consistent across all appearances; dark variant derived from light, avoid overly bright imagery; colored backgrounds give best contrast in dark.
- Alternate icons (iOS) need their own dark/clear/tinted variants.
- Atlas idea (non-binding): a simple folded-map/globe glyph on a gradient background in two or three layers.

Source: https://developer.apple.com/design/human-interface-guidelines/app-icons · https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass#App-icons

### 3.11 Images

- iOS bitmap scale factors: **@2x and @3x**. Points are layout units; design at @1x and scale up.
- Formats: PNG (de-interlaced) for raster UI art; 8-bit palette PNG when full color isn't needed; **JPEG or HEIC for photos**; stereo HEIC for spatial photos; **PDF/SVG** for flat icons.
- Embed a color profile; test on real devices (P3 wide color on all current iPhones).
- Atlas: server thumbnails should be served at ≈ cell-size × screen scale (e.g. 3× a 130 pt cell ≈ 390 px) — don't decode full-size originals in the grid; use the original only in the viewer (zoom).

Source: https://developer.apple.com/design/human-interface-guidelines/images

### 3.12 Motion and animation

- Animate with purpose; never motion for its own sake. Motion must be **optional** — never the only carrier of information; pair with haptics/text.
- Feedback motion should follow the gesture realistically (dismiss in the direction you revealed). Keep feedback animations **brief and precise**.
- Don't add custom animation to very frequent interactions (system already animates standard ones).
- **Never block** on animations — let people interrupt/cancel (SwiftUI springs are interruptible and preserve velocity).
- Liquid Glass motion: glass reacts more strongly to direct touch than to trackpad; controls morph (button → menu, glass shapes merge). Use `glassEffectID` morphs, not custom scale/opacity hacks.
- Prefer animated SF Symbols for small status feedback.
- Reduce Motion: see §3.7.

**SwiftUI spring presets** (all `iOS 13+` in DocC due to back-deployment; standardized parameters since iOS 17):

| Preset | Signature | Use |
|---|---|---|
| `.smooth` | `smooth(duration: 0.5, extraBounce: 0)` | default for UI state changes, no bounce |
| `.snappy` | `snappy(duration: 0.5, extraBounce: 0)` | small, quick UI responses (toggling selection mode) |
| `.bouncy` | `bouncy(duration: 0.5, extraBounce: 0)` | playful emphasis (favorite heart) — sparingly |
| `.spring(duration:bounce:)` | `spring(duration: 0.5, bounce: 0.0, blendDuration: 0)` | custom; bounce 0 = critically damped, >0 bouncier, <0 overdamped |
| `.interactiveSpring` | — | gesture tracking (unverified current parameters) |

`withAnimation(.smooth) { ... }`, `.animation(.snappy, value: x)`, `withAnimation(_:completionCriteria:_:completion:)` for chaining (iOS 17+), `PhaseAnimator`/`KeyframeAnimator` (iOS 17+) for multi-step, `.contentTransition(.numericText())` for changing numbers (dashboard values), `.transition(.blurReplace)` (iOS 17+).

Source: https://developer.apple.com/design/human-interface-guidelines/motion · https://developer.apple.com/documentation/swiftui/animation

### 3.13 Haptics

- Standard controls (toggles, sliders, pickers, pull-to-refresh, context menus) already play haptics — don't double them.
- Use system patterns **only for their documented meaning**; keep a consistent cause → haptic mapping; complement visuals/audio; don't overuse; short haptics for discrete events; make haptics non-essential.
- UIKit categories: **notification** (success / warning / error outcomes), **impact** (light/medium/heavy/soft/rigid — physical collision/snap), **selection** (value changing step by step).
- SwiftUI `SensoryFeedback` (iOS 17+): `.success`, `.warning`, `.error`, `.selection`, `.impact`, `.impact(weight:intensity:)`, `.impact(flexibility:intensity:)`, `.increase`, `.decrease`, `.start`, `.stop`, `.alignment`, `.levelChange`, `.pathComplete`; iOS 26 adds `.press(_:)`, `.release(_:)`, `.selection(_:)` variants for control touch-down/up.

Atlas mapping:

| Event | Feedback |
|---|---|
| Enter selection mode / select a cell by drag | `.selection` |
| Pinch snaps to a new grid density | `.impact(weight: .light)` |
| Scrubber passes a month/year boundary | `.selection` |
| Backup/upload finished | `.success` |
| Delete moved to Trash | none (system/animation) or `.impact(weight: .medium)` |
| Server action failed / connection lost | `.error` |
| Power-off confirmed | `.warning` before, `.success` after |

```swift
.sensoryFeedback(.selection, trigger: selectedIDs.count)
.sensoryFeedback(.success, trigger: backup.completedRunID)
.sensoryFeedback(trigger: columns) { old, new in .impact(weight: .light) }   // conditional form (iOS 17+)
```

Source: https://developer.apple.com/design/human-interface-guidelines/playing-haptics · https://developer.apple.com/documentation/swiftui/sensoryfeedback

### 3.14 Writing

- Define a voice (Atlas: calm, precise, technical only where needed) and adjust tone per situation (errors: direct; success: brief).
- Be clear and concise; read it aloud; plain language; write for localization (no idioms, leave room for ~30–40% longer translations (unverified figure)).
- Most important info first; **action-oriented labels** — buttons say the verb ("Delete 12 Photos", "Back Up Now", "Restart Server"), not "OK"/"Yes".
- Build consistent language patterns; pick a capitalization style and apply everywhere. Apple uses **title case** for buttons, menu items, tab titles, nav titles and (since iOS 26) section headers; sentence case for descriptions/footers.
- Avoid unnecessary possessives ("Favorites", not "Your Favorites"; "Settings", not "My Settings").
- Empty states: say what goes here and the next step ("No Photos Yet — Turn on Backup to see your library here.").
- Errors: near the problem, no blame, say how to fix ("Can't reach atlas.local. Check that you're on your home network.").
- Settings labels: practical names; add a footer explanation when needed; link directly to the relevant setting instead of describing its location.
- Text fields: clear labels + placeholder hints for format.
- Multi-step flows: consistent step naming (Next / Back / Done).

Source: https://developer.apple.com/design/human-interface-guidelines/writing

### 3.15 Branding

- Brand voice in copy; accent color **judiciously** (minimize on controls; use for selection/primary action); custom font only if legible and Dynamic Type-compatible (Atlas: no custom font).
- Express brand through familiar components; branding **defers to content**; no logo sprinkled through screens; **launch screen is not a branding moment** (match the first screen, no logo splash).
- Don't use Apple trademarks in app name/images.

Source: https://developer.apple.com/design/human-interface-guidelines/branding

### 3.16 Privacy

- Ask only for what you need, **in context** (Photos access when the user turns on backup, not at first launch; Local Network when first discovering the server; Face ID when enabling App Lock).
- Purpose strings: active sentence stating what and why. Good: "Atlas backs up your photos and videos to your home server." Bad: "Access needed for a better experience." / "Turn on photo access."
- Optional pre-permission screen: explain, then **one button** that triggers the system alert; no other actions, no incentives, no fake alerts.
- Process on device where possible; keychain for tokens; never plaintext secrets; prefer passkeys / system auth over custom schemes.
- Info.plist keys Atlas needs: `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` (save to device), `NSLocalNetworkUsageDescription` (+ `NSBonjourServices` if using Bonjour), `NSFaceIDUsageDescription`, `NSCameraUsageDescription` only if capturing (unverified list completeness).
- Respect limited Photos library access (show a "Manage" affordance via `PHPhotoLibrary.shared().presentLimitedLibraryPicker(from:)` — UIKit).

Source: https://developer.apple.com/design/human-interface-guidelines/privacy

### 3.17 Right-to-left

- System components flip automatically; use leading/trailing, never left/right (`.padding(.leading)`, `HStack` auto-flips).
- Flip: back/forward chevrons, progress direction, ordered sequences (a timeline scrubber's ordering is vertical — fine), text-direction icons. Don't flip: photos, logos, real-world objects, clocks, media playback controls (unverified for media), the digits within a number.
- Align paragraphs by their own language; keep list alignment consistent.
- SF Symbols provide RTL and localized variants automatically.
- Test with the "Right-to-Left Pseudolanguage" scheme option.

```swift
Image(systemName: "chevron.forward")            // auto-flips; prefer over chevron.right
Image("customArrow").flipsForRightToLeftLayoutDirection(true)
```

Source: https://developer.apple.com/design/human-interface-guidelines/right-to-left

---

## 4. Components

Each entry: **Use** (when/when not) · **Rules** · **Metrics** (numbers Apple gives) · **SwiftUI**. Min iOS from DocC.

### 4.1 Tab bars

**Use**: navigate between top-level sections (Atlas: Photos, Drive, Settings + Search). Never for actions — actions go in toolbars.

**Rules**

- Tab bar must stay visible across sections; hide it only for modal views (full-screen viewer, sheets).
- Keep the number of tabs small; avoid the overflow "More" tab. If people can customize tabs (iPad), default to **five or fewer**.
- Never disable or hide a tab because its content is temporarily unavailable — show an empty/unavailable state inside it instead (Drive offline → `ContentUnavailableView`, tab stays).
- Every tab has a **label** (single word if possible) + SF Symbol (tab bars render the **fill** variant automatically — pass the outline name).
- Badges only for critical, actionable information (red oval with number or "!"). Atlas: maybe a badge on Settings when the server is unreachable; not for "new photos".
- If content is colorful (photos!), keep the tab bar **monochrome** — don't tint tab labels with brand color that clashes with content.
- iOS: tab bar **floats** on Liquid Glass at the bottom; content scrolls beneath it.
- **Minimize on scroll** is opt-in; minimized bar shrinks and an attached bottom accessory moves inline next to it. Tapping returns it.
- **Search tab** sits at the trailing end, visually separated (`Tab(role: .search)`). Two styles: **standard tab** (navigates to a search landing page with field at top — use when you want suggestions/discovery: Atlas Photos search with "People", "Places", "Recent searches") vs **button appearance** (keyboard comes up immediately — use for quick lookup).
- iOS 27: `Tab(role: .prominent)` places a tab in a separate trailing position (like search). Use for at most one special destination; Atlas doesn't need it.
- iPad: `.tabViewStyle(.sidebarAdaptable)` — tab bar at top that can turn into a sidebar; you choose which appears at launch.
- iPhone Duo: tab bar moves to the screen side on the outer display (automatic).
- iOS 27 SDK: `TabView` selection must point at a visible tab or it may crash.

**SwiftUI**

```swift
// iOS 18+ Tab API; Liquid Glass behaviors iOS 26+
enum AppTab: Hashable { case photos, drive, settings, search }

struct RootView: View {
    @State private var tab: AppTab = .photos
    @State private var searchText = ""

    var body: some View {
        TabView(selection: $tab) {
            Tab("Photos", systemImage: "photo.on.rectangle", value: AppTab.photos) {
                PhotosRoot()
            }
            Tab("Drive", systemImage: "folder", value: AppTab.drive) {
                DriveRoot()
            }
            Tab("Settings", systemImage: "gear", value: AppTab.settings) {
                SettingsRoot()
            }
            .badge(serverDown ? "!" : nil)                       // critical only
            Tab(value: AppTab.search, role: .search) {           // trailing, separated
                NavigationStack { SearchView(text: $searchText) }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)                  // iOS 26+, iPhone only
        .tabViewBottomAccessory { BackupAccessory() }           // iOS 26+
        .tabViewSearchActivation(.searchTabSelection)           // iOS 26+: selecting the tab activates search ("button" feel)
        .tabViewStyle(.sidebarAdaptable)                        // iOS 18+: iPad sidebar
    }
}

// Accessory adapts to placement (iOS 26+)
struct BackupAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View {
        switch placement {
        case .inline:   Label("Backing Up", systemImage: "arrow.up.circle").labelStyle(.iconOnly)  // next to minimized bar
        default:        HStack { ProgressView(value: 0.42); Text("1,203 left").font(.footnote).monospacedDigit() }.padding(.horizontal)
        }
    }
}
```

`TabBarMinimizeBehavior`: `.automatic`, `.never`, `.onScrollDown`, `.onScrollUp` (minimize only on iPhone). `TabViewBottomAccessoryPlacement`: `.inline`, `.expanded`. `TabSearchActivation`: `.automatic`, `.searchTabSelection`. Use `TabSection("Library") { Tab... }` for sidebar groups on iPad.

Bottom accessory rules (from Music's mini player pattern): persistent, glanceable, relevant across tabs; not for actions that belong to one screen. Backup progress qualifies **while a backup runs** — remove the accessory when idle rather than showing "Up to date" forever (design judgment).

Source: https://developer.apple.com/design/human-interface-guidelines/tab-bars · https://developer.apple.com/documentation/swiftui/tabbarminimizebehavior · https://developer.apple.com/documentation/swiftui/tabviewbottomaccessoryplacement

### 4.2 Toolbars (incl. navigation bars)

Apple merged "navigation bars" into **Toolbars**: top toolbar = title + navigation + actions; bottom toolbar = actions.

**Rules**

- Three content types: view title, navigation controls (Back, search), actions (buttons, menus).
- Don't overcrowd; prioritize the most likely actions; put the rest in a **More** (`ellipsis`) menu — but only if needed, and don't add a manual overflow menu where the system makes one.
- **Titles**: useful, not the app name, **under ~15 characters**. Large title by default on top-level iOS screens; it collapses to inline on scroll.
- Use the standard Back and Close buttons (don't build custom chevrons).
- Prefer **symbols without borders** for actions; text only when clearer (e.g. "Select", "Edit", "Done"). Don't place a text item next to a symbol item in one group (looks like one control).
- **One primary action**, trailing, styled prominent (system tints it with accent) — e.g. Done/Save. Not on destructive actions.
- **Groups**: leading (back, sidebar toggle, title), center, trailing (important items, inspector, search, More). Group by function/frequency; keep critical actions (Done/Close/Save) in their own group; **max ~3 groups**; consistent across platforms.
- Reduce custom backgrounds and tinted controls — let glass + scroll edge effect work; monochrome items over colorful content.
- Standard toolbar items get concentric corner radii automatically; custom controls in a bar should too.
- Hide the **item** (`.hidden()` on `ToolbarItem` content via `ToolbarContent.hidden(_:)`), not its view — otherwise an empty glass capsule remains.
- Consider hiding bars temporarily for distraction-free viewing (photo viewer: tap to toggle).
- iOS: only the essentials in the main area; large title for orientation.
- iOS 27: `visibilityPriority`, `ToolbarOverflowMenu`, `.topBarPinnedTrailing`, `toolbarMinimizationBehavior`.

**SwiftUI**

```swift
NavigationStack {
    PhotoGrid()
        .navigationTitle("Library")
        .navigationSubtitle("12,480 Photos")                 // iOS 26+
        .toolbarTitleDisplayMode(.large)                     // iOS 17+: .automatic .inline .inlineLarge .large
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") { SortPicker() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {    // shares one glass capsule
                Button("Select") { selecting.toggle() }      // text item — keep separate from symbols
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing) // iOS 26+: visual break between capsules
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") { MoreMenu() }
            }
        }
}

// Primary (prominent) action in a sheet
.toolbar {
    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }   // system styles it prominent (unverified that this alone tints it)
}
// Force prominence explicitly (iOS 26+)
ToolbarItem(placement: .confirmationAction) {
    Button("Done", systemImage: "checkmark") { dismiss() }.buttonStyle(.glassProminent)
}

// Bottom toolbar (selection actions in Photos/Drive)
.toolbar {
    ToolbarItemGroup(placement: .bottomBar) {
        ShareLink(items: selectedURLs) { Label("Share", systemImage: "square.and.arrow.up") }
        Spacer()
        Text("\(selection.count) Selected").font(.headline)
        Spacer()
        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
    }
}

// Opt an item out of the shared glass background (iOS 26+)
ToolbarItem(placement: .topBarTrailing) { AvatarButton() }.sharedBackgroundVisibility(.hidden)

// iOS 27 additions
.toolbar {
    ToolbarItem { Button("Share", systemImage: "square.and.arrow.up") {} }.visibilityPriority(.high)
    ToolbarItem { Button("Archive", systemImage: "archivebox") {} }.visibilityPriority(.low)
    ToolbarItem(placement: .topBarPinnedTrailing) { Button("Add", systemImage: "plus") {} }
    ToolbarOverflowMenu {                                       // always in the "..." menu
        Button("Rename", systemImage: "pencil") {}
        Button("Get Info", systemImage: "info.circle") {}
    }
}
.toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)   // iOS 27

// Hide/show bars (viewer)
.toolbarVisibility(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar, .tabBar)  // iOS 18+
```

`ToolbarItemVisibilityPriority`: `.automatic`, `.low`, `.high`, `init(lowerThan:)`, `init(higherThan:)`. `ToolbarMinimizationBehavior`: `.automatic` (nav bar minimizes by default when it hosts a `.toolbarPrincipal` searchable), `.never`, `.onScrollDown`, `.onScrollUp`.

Source: https://developer.apple.com/design/human-interface-guidelines/toolbars · https://developer.apple.com/documentation/swiftui/toolbarspacer · https://developer.apple.com/documentation/swiftui/toolbaritemvisibilitypriority · https://developer.apple.com/documentation/swiftui/toolbarminimizationbehavior

### 4.3 Search fields

**Rules**

- Placeholder text says what's searchable ("Photos, People, Places"; "Files and Folders").
- Search as you type; show recent searches before typing and suggestions while typing; most relevant results first.
- Filters: **scope bar** for clearly defined categories (default to the broadest scope) and **tokens** for common terms (pair tokens with suggestions so people discover them). iOS 27 SDK: scope bar sits inline on the same row as a centered search field.
- **Placement on iPhone**: (1) **as a tab** (app-wide search; Atlas) — standard tab style for discovery, button style for quick lookup; (2) **in a toolbar** — bottom if there's room (expanded field or button), top (as a button that expands) when bottom content must stay visible; (3) **inline** above the list it filters (Drive folder filter), optionally pinned to the top toolbar on scroll.
- When the field gets focus it slides up with the keyboard (system behavior; don't fight it).
- Search should feel like one place to find anything — avoid multiple competing search UIs (Atlas: one global search tab + in-folder filter in Drive is fine because scope is obvious).
- Respect privacy of search history; let people clear it.
- Spotlight: index content (Core Spotlight) so photos/files can be found system-wide (optional for Atlas).

**SwiftUI**

```swift
// Search inside the search tab (iOS 26+: the tab's NavigationStack hosts the field)
NavigationStack {
    SearchResults(query: query, scope: scope)
        .navigationTitle("Search")
}
.searchable(text: $query, tokens: $tokens, prompt: "Photos, People, Places") { token in
    Label(token.title, systemImage: token.symbol)
}
.searchSuggestions {
    ForEach(recent) { r in Text(r.text).searchCompletion(r.text) }
    ForEach(peopleMatches) { p in Label(p.name, systemImage: "person.crop.circle").searchCompletion(Token.person(p)) }
}
.searchScopes($scope) {
    Text("All").tag(Scope.all); Text("Photos").tag(Scope.photos); Text("Videos").tag(Scope.videos)
}
.onSubmit(of: .search) { runSearch() }

// Inline filter in a Drive folder
List(filtered) { FileRow(file: $0) }
    .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search in \(folder.name)")

// Search in a bottom toolbar rendered as a button until tapped (iOS 26+)
.searchable(text: $q).searchToolbarBehavior(.minimize)

// Programmatic focus (iOS 18+)
@FocusState private var searchFocused: Bool
.searchFocused($searchFocused)
// Present programmatically (iOS 17+)
.searchable(text: $q, isPresented: $isSearching)
```

`SearchFieldPlacement`: `.automatic`, `.navigationBarDrawer`, `.navigationBarDrawer(displayMode:)`, `.toolbar`, `.toolbarPrincipal`, `.sidebar`. `SearchToolbarBehavior`: `.automatic`, `.minimize`.

Source: https://developer.apple.com/design/human-interface-guidelines/search-fields · https://developer.apple.com/design/human-interface-guidelines/searching

### 4.4 Sidebars (iPad)

- Leading-edge navigation between areas/top-level collections (Drive folders, Photos albums on iPad).
- Floats on glass above content; extend rich content beneath it (`backgroundExtensionEffect`).
- Let people customize contents and hide the sidebar.
- **Max two levels of hierarchy**; deeper → three-column split view (sidebar | list | detail). Use disclosure groups for many items; short group labels.
- Familiar SF Symbols per item; sidebar icons default to accent color — only use other colors with clear purpose (June 2026 update).
- iPad: prefer a tab bar first (`.sidebarAdaptable` lets it become a sidebar). For sidebar-only, use `NavigationSplitView`.

```swift
NavigationSplitView {
    List(selection: $selection) {
        Section("Library") {
            Label("Photos", systemImage: "photo.on.rectangle").tag(Item.photos)
            Label("Favorites", systemImage: "heart").tag(Item.favorites)
        }
        Section("Albums") { ForEach(albums) { Label($0.name, systemImage: "rectangle.stack").tag(Item.album($0.id)) } }
    }
    .navigationTitle("Atlas")
} content: {
    AlbumGrid(item: selection)
} detail: {
    PhotoDetail(id: detailID)
}
.navigationSplitViewStyle(.balanced)
```

Source: https://developer.apple.com/design/human-interface-guidelines/sidebars

### 4.5 Split views

- iPad: two panes (Mail) or three (Keynote). Default primary ≈ **1/3 width**, secondary ≈ 2/3; half/half possible. Divider **1 pt**. Set sensible min/max column widths.
- One title above the split view, or above the primary when the secondary is a single main view.
- On iPhone (compact) and the iPhone Duo outer display, a split view **collapses to one stack** automatically; on the inner display it expands and adapts to the fold.
- Use `NavigationSplitView` (not hand-made HStacks) to get fluid resizing on iPad windows.

```swift
NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
    Sidebar()
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
} detail: {
    Detail()
}
.inspector(isPresented: $showInfo) { PhotoInfo() .inspectorColumnWidth(min: 280, ideal: 320, max: 400) } // iOS 17+
```

Source: https://developer.apple.com/design/human-interface-guidelines/split-views

### 4.6 Tab views (segmented page switching)

- A tab view (in-content tabs) switches between peer views inside one context — efficient (one tap vs a pop-up's two). On iOS, prefer a **segmented control** for this.
- iOS 27: `.pickerStyle(.tabs)` gives a segmented look with "tabs" semantics for VoiceOver — use when the picker switches views (e.g. Settings ▸ Server: "Overview | Services | Logs"), keep `.segmented` for value selection.

```swift
Picker("Section", selection: $section) {
    Text("Overview").tag(Section.overview)
    Text("Services").tag(Section.services)
    Text("Logs").tag(Section.logs)
}
.pickerStyle(.tabs)          // iOS 27; fall back to .segmented on 26
```

Source: https://developer.apple.com/design/human-interface-guidelines/tab-views · iOS 27 release notes (TabsPickerStyle)

### 4.7 Lists and tables

**Rules**

- Lists are for text-forward, scannable rows; succinct text, minimize truncation (wrap instead).
- Let people edit (reorder, delete) when it makes sense; iOS requires Edit mode for reorder/multi-delete (or swipe).
- Selection feedback: navigation rows highlight briefly and push; toggle rows show a checkmark.
- Row styles: leading image + title + subtitle + trailing detail/accessory — use `Label`, `LabeledContent`.
- Info button (`info.circle`) in a row only reveals more info about that row; don't add an alphabetical index to a table whose rows have trailing disclosure indicators.
- iOS 26: taller rows, more padding, larger section corner radius; **section headers are title case, not ALL CAPS** — write header text in Title Case.
- Swipe actions: match the top items of the row's context menu (same actions, same order).

**SwiftUI**

```swift
List(selection: $selectedFiles) {                         // multi-select in Edit mode
    Section {
        ForEach(files) { file in
            NavigationLink(value: file) { FileRow(file: file) }
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(file) }
                    Button("Move", systemImage: "folder") { move(file) }.tint(.indigo)
                }
                .swipeActions(edge: .leading) {
                    Button("Favorite", systemImage: "star") { toggleFav(file) }.tint(.yellow)
                }
        }
        .onDelete(perform: delete)
        .onMove(perform: move)
    } header: {
        Text("Recent Files")                                   // Title Case
    } footer: {
        Text("Files you opened in the last 7 days.")
    }
}
.listStyle(.insetGrouped)                                  // .plain for file browsers, .insetGrouped for settings-like
.environment(\.editMode, $editMode)
.listRowSeparator(.hidden, edges: .top)                    // per row, iOS 15+
.listSectionSpacing(.compact)                              // iOS 17+
.contentMargins(.horizontal, 16, for: .scrollContent)      // iOS 17+

struct FileRow: View {
    let file: DriveItem
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(2)
                Text("\(file.modified, format: .relative(presentation: .named)) · \(file.size, format: .byteCount(style: .file))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            FileThumbnail(file: file).frame(width: 40, height: 40)
        }
    }
}
```

iOS 27: `.swipeActions(edge:allowsFullSwipe:content:onPresentationChanged:)` + `.swipeActionsContainer()` bring swipe actions to `ScrollView`/`LazyVStack`/grids; `.reorderable()` on `ForEach` + `.reorderContainer(for:isEnabled:move:)` for drag-reorder outside `List`.

Source: https://developer.apple.com/design/human-interface-guidelines/lists-and-tables · https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass#Organization-and-layout

### 4.8 Collections (grids)

**Rules**

- Ideal for image-based content (photo grid, Drive grid view). Use a table instead for text.
- Prefer standard row/grid layouts; make items easy to tap (size ≥ 44 pt is easy in a photo grid).
- Defaults: tap to select/open, touch-and-hold for context menu/edit, swipe to scroll; add gestures only if needed (pinch to change density is an established Photos convention).
- Animate insertions, deletions, reorders (SwiftUI does with identity-stable `ForEach` + `withAnimation`).
- Be careful with dynamic layout changes — keep the item under the user's finger/focus anchored when density changes.

**SwiftUI**

```swift
ScrollView {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns),
              spacing: 2, pinnedViews: [.sectionHeaders]) {
        ForEach(sections) { section in
            Section {
                ForEach(section.assets) { asset in
                    Thumbnail(asset: asset)
                        .aspectRatio(1, contentMode: .fill)            // square cells
                        .clipped()
                        .contentShape(.rect)
                }
            } header: {
                SectionHeader(title: section.title)
            }
        }
    }
}
```

Use `LazyVGrid`/`LazyHGrid` (lazy, for large data) — never `Grid` (eager) for thousands of photos. See §6.1 for the full Atlas grid.

Source: https://developer.apple.com/design/human-interface-guidelines/collections

### 4.9 Labels, Disclosure, Boxes

- **Labels**: static, uneditable text; use the 4 label colors for hierarchy; `Text` for text, `Label` for symbol + text (adapts with `.labelStyle(.iconOnly/.titleOnly/.titleAndIcon)`). Make labels selectable when copying is useful (iOS 27 gives real selection UI for `.textSelection(.enabled)` — e.g. server IP, file path).
- **Disclosure controls**: disclosure triangle (expand/collapse lists/sections) vs disclosure button (more options in a view). **At most one disclosure button per view**.
- **Boxes** (`GroupBox`): visually group related info in the content layer; give it a title if helpful; don't nest deeply. Atlas: server-status cards could be `GroupBox` or `Section` in a `Form`.

```swift
LabeledContent("IP Address") { Text(server.ip).textSelection(.enabled).monospaced() }
DisclosureGroup("Advanced", isExpanded: $advanced) { Toggle("Verbose Logging", isOn: $verbose) }
Section("Services", isExpanded: $servicesExpanded) { ... }        // collapsible section, iOS 17+ (sidebar list style)
GroupBox("CPU") { CPUChart() }
```

Source: https://developer.apple.com/design/human-interface-guidelines/labels · https://developer.apple.com/design/human-interface-guidelines/disclosure-controls · https://developer.apple.com/design/human-interface-guidelines/boxes

### 4.10 Buttons

**Rules**

- Button = **style** (size, color, shape) + **content** (symbol and/or text) + **role** (normal, primary, cancel, destructive).
- Enough space around buttons; always a press state for custom buttons (use `ButtonStyle`, `configuration.isPressed`).
- Prominent style for the **most likely** action; **1–2 prominent buttons per view max**. Distinguish options with style, not size; same-size buttons signal a coherent set.
- Monochrome labels over colorful content.
- Familiar action = familiar symbol (`square.and.arrow.up` = share). Text labels: a few words, title case, start with a verb.
- Roles: primary gets accent color + Return key; destructive gets red; cancel is the safe exit. **Never give a destructive action the primary role.**
- iOS: show an activity indicator inside the button for actions that don't complete instantly.
- Liquid Glass: `.glass` (secondary glass), `.glassProminent` (tinted glass, primary). Controls are rounder; `.extraLarge` control size exists; `buttonSizing(.flexible/.fitted)` (iOS 26).
- iOS 27 SDK resets `controlSize`, `buttonSizing`, `ButtonBorderShape`, `menuIndicatorVisibility` inside sheets/popovers — set them inside the presented content.

**Styles (SwiftUI)**

| Style | Use |
|---|---|
| `.automatic` / `.plain` | inline/text buttons in content, rows |
| `.borderless` | toolbar-like icon buttons in content |
| `.bordered` | secondary actions in content |
| `.borderedProminent` | primary action in content (onboarding "Connect") |
| `.glass` (iOS 26+) | secondary action floating over content (viewer controls) |
| `.glassProminent` (iOS 26+) | primary floating action |
| `.glass(.clear)` (iOS 26+) | over photos/videos |

```swift
Button("Connect to Server") { connect() }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)                 // .mini .small .regular .large .extraLarge
    .buttonBorderShape(.capsule)         // .automatic .capsule .roundedRectangle(radius:) .circle

Button(role: .destructive) { emptyTrash() } label: { Label("Empty Trash", systemImage: "trash") }

Button { Task { await restart() } } label: {
    if isRestarting { ProgressView() } else { Text("Restart") }
}
.disabled(isRestarting)

Button("Favorite", systemImage: isFav ? "heart.fill" : "heart") { isFav.toggle() }
    .labelStyle(.iconOnly)
    .buttonStyle(.glass(.clear))         // over a photo
    .contentTransition(.symbolEffect(.replace))
    .sensoryFeedback(.selection, trigger: isFav)

HStack { Button("Cancel") {}; Button("Save") {} }.buttonSizing(.flexible)   // iOS 26+: equal-width
```

Source: https://developer.apple.com/design/human-interface-guidelines/buttons · https://developer.apple.com/documentation/swiftui/primitivebuttonstyle

### 4.11 Menus, pull-down and pop-up buttons

**Menu rules**

- Labels: verb phrases for actions (View, Close, Select), **title case**, no articles, ellipsis (…) when more input is needed ("Rename…", "Move…").
- Show unavailable items dimmed in regular menus (context menus hide them instead). A menu stays openable even if all items are disabled.
- Icons: use standard icons for standard actions (§3.8); **all items in a group have icons or none**; use icons sparingly to highlight key actions (June 2026). iPadOS 27 menu bar hides symbol images by default; object-like items keep icons via `.labelStyle(.titleAndIcon)`.
- Order: important/frequent first; group related items with separators (`Divider()`/`Section`); keep related commands together even if one is rare.
- Submenus: sparingly, **one level**, **≤ ~5 items**; create one when a term repeats in >2 items. Prefer submenus to indentation.
- Toggled items: a single item with changing label ("Show Map"/"Hide Map") or a checkmark for attributes in effect.
- iOS layouts: **small** (top row of 4 symbol-only items), **medium** (top row of 3 symbol + short label — use when there are 3 key actions, like Notes), **large** (default list). In SwiftUI a `ControlGroup` at the top of a `Menu` produces the top row.
- Buttons morph into their menus with Liquid Glass (system).

**Pull-down button** (menu of actions or options related to a button): ≥ 3 items to be worthwhile; 1–2 items → just use buttons/toggles. **Pop-up button** (choose one value from a list; shows current value): use `Picker` with `.menu` style.

```swift
Menu {
    ControlGroup {                                      // top row (medium layout)
        Button("Share", systemImage: "square.and.arrow.up") {}
        Button("Favorite", systemImage: "heart") {}
        Button("Delete", systemImage: "trash", role: .destructive) {}
    }
    .controlGroupStyle(.compactMenu)                    // iOS 16.4+: icon row; use .menu for a submenu (unverified exact rendering)
    Section {
        Button("Rename…", systemImage: "pencil") {}
        Button("Move…", systemImage: "folder") {}
        Button("Duplicate", systemImage: "plus.square.on.square") {}
    }
    Menu("Sort By", systemImage: "arrow.up.arrow.down") {        // one-level submenu
        Picker("Sort By", selection: $sort) {
            Text("Name").tag(Sort.name); Text("Date").tag(Sort.date); Text("Size").tag(Sort.size)
        }
    }
} label: {
    Label("More", systemImage: "ellipsis")
}
.menuOrder(.fixed)                                     // keep my order regardless of position (iOS 16+)

Picker("Grid Size", selection: $columns) {              // pop-up button
    Text("Small").tag(7); Text("Medium").tag(5); Text("Large").tag(3)
}.pickerStyle(.menu)

Menu("View") { LabeledContent("Items", value: "1,284") }   // iOS 27: value shows as subtitle
```

Source: https://developer.apple.com/design/human-interface-guidelines/menus · https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons · https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons

### 4.12 Context menus

**Rules**

- Item-specific, frequently needed commands — not advanced/rare ones. Keep short; **≤ ~3 groups**.
- Offer context menus **consistently** for the same kind of item everywhere (all photo cells, all file rows, album covers).
- Every context menu action must also exist in the main UI (toolbar/viewer/selection bar).
- **Hide** unavailable items (don't dim). Submenus one level deep.
- Most frequent items closest to where the finger is (menu may open above or below).
- Destructive items **last**, marked destructive (red). No keyboard shortcuts shown in context menus.
- Title only if it clarifies (e.g. "12 Photos" for a multi-item menu).
- Use standard icons.
- iOS: either a context menu **or** an edit menu for an item, not both. Provide a **preview** that clarifies the target (larger photo; file Quick Look thumbnail); make the preview's clipping shape match its content so the lift animation looks right. iPad: context menu on empty area to create objects (New Folder).
- Top context-menu items should match swipe actions for the same row.

```swift
Thumbnail(asset: asset)
    .contextMenu {
        Section {
            ShareLink(item: asset.transferable, preview: SharePreview(asset.title, image: asset.thumbnailImage))
            Button("Favorite", systemImage: asset.isFavorite ? "heart.slash" : "heart") { toggleFavorite(asset) }
            Button("Copy", systemImage: "document.on.document") { copy(asset) }
        }
        Section {
            Button("Add to Album…", systemImage: "rectangle.stack.badge.plus") { addToAlbum(asset) }
            Button("Show in All Photos", systemImage: "photo.on.rectangle") { reveal(asset) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { delete(asset) }   // last
    } preview: {
        AssetPreview(asset: asset)                // iOS 16+: contextMenu(menuItems:preview:)
            .frame(idealWidth: 320, idealHeight: 320 / asset.aspectRatio)
    }

// Multi-selection-aware (iOS 16+), e.g. in a List or grid with selection
.contextMenu(forSelectionType: DriveItem.ID.self) { ids in
    if ids.isEmpty { Button("New Folder", systemImage: "folder.badge.plus") { newFolder() } }
    else { Button("Delete \(ids.count) Items", systemImage: "trash", role: .destructive) { delete(ids) } }
} primaryAction: { ids in open(ids) }
```

Source: https://developer.apple.com/design/human-interface-guidelines/context-menus

### 4.13 Edit menus

- The system edit menu (Cut/Copy/Paste/Select/Look Up/Translate/Share) appears for selected text/content. Keep system order; add only a few custom, relevant actions; don't duplicate a context menu on the same item.
- SwiftUI text fields/editors provide it automatically; iOS 27 selectable `Text` gets the real selection UI.

Source: https://developer.apple.com/design/human-interface-guidelines/edit-menus

### 4.14 Activity views (share sheet)

- Use the system share sheet (`ShareLink`), don't build a custom one. Custom activities: short verb labels, symbol-like template images.
- Provide a good preview (title + image) for what's shared; share the **file/item**, not a URL to a private server the recipient can't reach (Atlas: export the original via `Transferable` file representation).

```swift
ShareLink(item: photoURL, preview: SharePreview("IMG_2041", image: Image(uiImage: thumb)))
ShareLink(items: selectedURLs) { Label("Share \(selectedURLs.count) Items", systemImage: "square.and.arrow.up") }

// Transferable for server-backed assets (downloads on demand)
struct RemotePhoto: Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { photo in
            SentTransferredFile(try await AtlasAPI.downloadOriginal(photo.id))
        }
    }
}
```

Source: https://developer.apple.com/design/human-interface-guidelines/activity-views

### 4.15 Image views

- Show photos at their aspect ratio; `scaledToFill` + clip in grids, `scaledToFit` in viewers. Provide accessibility labels for meaningful images.
- Don't put text on images without a dimming/legibility treatment.
- Animated sequences only for content (Live Photos via PhotosUI/PhotoKit views).

```swift
AsyncImage(url: thumbURL) { phase in
    switch phase {
    case .success(let image): image.resizable().scaledToFill()
    case .failure: Image(systemName: "photo").foregroundStyle(.tertiary)
    default: Color(.secondarySystemBackground)
    }
}
// iOS 27: HTTP-cached; inject an authenticated session for the Atlas server
.asyncImageURLSession(AtlasAPI.session)
```

For a large grid prefer your own thumbnail loader with memory + disk cache and request cancellation (`.task(id:)`) over `AsyncImage` (unverified performance claim; profile).

Source: https://developer.apple.com/design/human-interface-guidelines/image-views

### 4.16 Text views

- Multiline, scrollable, possibly editable text. Use `TextEditor` (iOS 26+ supports `AttributedString`); keep the default font unless needed; make read-only text selectable when useful (logs).
- Atlas: server log viewer → `ScrollView { Text(log).font(.footnote.monospaced()).textSelection(.enabled) }` with `defaultScrollAnchor(.bottom)`.

Source: https://developer.apple.com/design/human-interface-guidelines/text-views

### 4.17 Web views

- For web content inside the app (e.g. a server's web admin page); not a replacement for native UI. Provide back/forward/reload in a toolbar if navigation is possible.
- iOS 26: SwiftUI `WebView` + `WebPage` (WebKit for SwiftUI) (API names from Apple's SwiftUI updates page; exact module `WebKit` — unverified import details).
- Prefer `SFSafariViewController`-style presentation for external links (`openURL` opens Safari).

Source: https://developer.apple.com/design/human-interface-guidelines/web-views · https://developer.apple.com/documentation/updates/swiftui (June 2025)

### 4.18 Charts (component)

**Rules**

- Mark types: **bar** (compare categories / parts of a whole), **line** (change over time; slope = rate), **point** (individual values, correlations, outliers); combine marks for clarity (line + point for latest value; area under line for utilization).
- Axes: **fixed range** when bounds are meaningful (CPU/RAM/disk % → 0–100); dynamic when values vary widely (network throughput). Bar charts start at 0. Familiar tick sequences (0, 25, 50, 75, 100). Few grid lines.
- Descriptive content: title/subtitle that states the takeaway ("CPU 23% · last 5 min"); summarize the main message.
- Visual hierarchy: data most prominent; axes/grid subdued.
- Compact width: maximize plot width; full-width charts.
- Accessibility: Swift Charts gives Audio Graphs + per-mark elements by default; add labels with context, no subjective words ("rapidly"), unambiguous formats ("June 6", not "6/6"); describe meaning not color; hide redundant axis labels from VoiceOver.
- Interaction optional, never required for critical info; targets must be big enough; support keyboard/Switch Control navigation.
- Animate changes so they're noticed; align chart leading edge with surrounding content.
- Color: never sole differentiator; separate contiguous color areas (stacked bars need gaps).

```swift
import Charts

struct CPUChart: View {
    let samples: [Sample]          // struct Sample: Identifiable { id: Date; date: Date; value: Double }  value 0...1
    var body: some View {
        Chart(samples) { s in
            AreaMark(x: .value("Time", s.date), y: .value("CPU", s.value))
                .foregroundStyle(.blue.opacity(0.2).gradient)
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", s.date), y: .value("CPU", s.value))
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...1)                                   // fixed: percentage
        .chartYAxis {
            AxisMarks(values: [0, 0.5, 1]) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(d, format: .percent) } }
            }
        }
        .chartXAxis(.hidden)                                          // sparkline-like in a row
        .frame(height: 120)
        .accessibilityLabel("CPU usage, last 5 minutes")
        .accessibilityValue("Currently \(samples.last?.value ?? 0, format: .percent)")
    }
}
```

Swift Charts: `Chart`, `LineMark`, `AreaMark`, `BarMark`, `PointMark`, `RuleMark`, `RectangleMark`, `SectorMark` (iOS 17, pie/donut — good for storage breakdown), `chartXSelection(value:)` (iOS 17) for scrubbing. iOS 27 SDK: conditionals inside `Chart {}` with a deployment target < 27 warn and may crash — keep chart content unconditional or wrap with `if #available` outside the builder.

Source: https://developer.apple.com/design/human-interface-guidelines/charts · https://developer.apple.com/design/human-interface-guidelines/charting-data

### 4.19 Path controls

macOS-only component (file path breadcrumbs). On iOS, show location with the navigation stack (back button title + large title) or a `Menu` on the title listing ancestor folders (Files app pattern: long-press the back button shows the history menu automatically).

Source: https://developer.apple.com/design/human-interface-guidelines/path-controls

### 4.20 Sheets

**Use**: a scoped task tied to the current context (rename, add to album, upload options, photo info, connection editor). **Not** for complex/long flows — use full-screen modal (photo viewer, editing) or push navigation.

**Rules**

- iOS sheets can be **modal or nonmodal** (nonmodal: parent stays interactive, e.g. info panel while browsing — `presentationBackgroundInteraction`).
- Buttons: **Cancel/Close** dismisses without saving; **Done** completes/saves; **Back** goes to a previous step (never dismisses). Single-view sheet: **Cancel on the leading edge** of the top toolbar, **Done on the trailing edge** (March 2026 guidance). Always pair Done with Cancel (or Back). **Never show Cancel, Done and Back together.**
- One sheet at a time; if a sheet action needs another sheet, dismiss the first.
- Detents: **large** (full height) is automatic; **medium ≈ half height**. Add medium for progressive disclosure (info sheet); medium-only prevents full expansion. Include a **grabber** for resizable sheets (also a VoiceOver resize control).
- Support swipe-down to dismiss; if there are unsaved changes, confirm with an action sheet (`interactiveDismissDisabled` + confirmationDialog).
- iPad: prefer **form** or **page** sheet sizing.
- Liquid Glass: larger corner radius; **partial-height sheets are inset** from the screen edges with glass, content peeks around them; at full height they become more opaque. Check content near the rounder corners. Don't add your own background/visual-effect view — let the system glass show (only override with `presentationBackground` for a real reason).
- iOS 27: `.navigationTransition(.crossFade)` makes a sheet fade in over content; zoom transitions (`.zoom(sourceID:in:)`) from the source control are the iOS 18+ standard for "this sheet comes from that button/thumbnail".
- iOS 27 SDK: control-size/button-sizing environment values reset inside sheets.

```swift
.sheet(isPresented: $showInfo) {
    NavigationStack {
        PhotoInfoView(asset: asset)
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { showInfo = false } }
            }
    }
    .presentationDetents([.medium, .large], selection: $detent)     // iOS 16+
    .presentationDragIndicator(.visible)                            // grabber
    .presentationBackgroundInteraction(.enabled(upThrough: .medium)) // nonmodal at medium (iOS 16.4+)
    .presentationContentInteraction(.scrolls)                        // scroll before resizing (iOS 16.4+)
}

// Editing sheet with unsaved-changes protection
.sheet(isPresented: $editing) {
    NavigationStack {
        RenameForm(name: $draft)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { attemptDismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { commit() }.disabled(draft.isEmpty) }
            }
    }
    .interactiveDismissDisabled(hasChanges)
    .presentationSizing(.form)                                       // iPad, iOS 18+
}

// Zoom from source (iOS 18+)
@Namespace private var ns
Button { showUpload = true } label: { Image(systemName: "plus") }
    .matchedTransitionSource(id: "upload", in: ns)
.sheet(isPresented: $showUpload) { UploadOptions().navigationTransition(.zoom(sourceID: "upload", in: ns)) }
```

`PresentationDetent`: `.medium`, `.large`, `.fraction(_:)`, `.height(_:)`, custom `CustomPresentationDetent`.

Source: https://developer.apple.com/design/human-interface-guidelines/sheets · https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass#Windows-and-modals

### 4.21 Alerts

**Use**: critical info needing immediate attention or confirmation of an important action. **Not** for: pure information (use inline status), common undoable actions even if destructive (deleting a photo to Trash needs no alert), app launch.

**Rules**

- Title + optional message + **up to 3 buttons** (iOS can add a text field — only when input resolves the situation, e.g. password).
- Title: clear, specific, ≤2 lines; never "Error" or error codes. Message only if it adds value; complete sentences, sentence case. Don't explain the buttons.
- Buttons: 1–2 words describing the result, verbs ("Delete", "Restart", "Reconnect"); avoid "OK" except purely informational alerts. Likely button trailing (row) / top (stack). Default button never destructive.
- Destructive style for destructive actions people didn't deliberately choose; always include "Cancel" (exactly that word) with a destructive action. Single-button default alert: "Done", not "Cancel".
- Alternative cancel: Esc / ⌘. on keyboards, going Home.
- Use an **action sheet (confirmationDialog)**, not an alert, for choices about an action the person initiated.
- Avoid alerts that scroll (short text; test at AX sizes).

```swift
// iOS 15+ (back-deployed when built with Xcode 27): from an optional item / error
.alert(Text("Restart Server?"), item: $pendingRestart) { server in
    Button("Restart", role: .destructive) { restart(server) }
    Button("Cancel", role: .cancel) {}
}
.alert(error: $connectionError) { _ in            // E: LocalizedError — title = errorDescription
    Button("Try Again") { reconnect() }
    Button("Cancel", role: .cancel) {}
}

// Classic
.alert("Couldn't Connect", isPresented: $showError, presenting: lastError) { _ in
    Button("Try Again") { reconnect() }
    Button("Cancel", role: .cancel) {}
} message: { err in
    Text(err.localizedDescription)
}

// Text field in alert
.alert("New Album", isPresented: $newAlbum) {
    TextField("Name", text: $albumName)
    Button("Create") { create(albumName) }
    Button("Cancel", role: .cancel) {}
}
```

Source: https://developer.apple.com/design/human-interface-guidelines/alerts

### 4.22 Action sheets (confirmation dialogs)

- Choices related to an **intentional** action (e.g. "Delete 12 Photos" after tapping Delete; "Discard Changes" when swiping away an edited sheet).
- Use sparingly; short single-line title; message only if necessary.
- **≤ 4 buttons including Cancel** (so ≤3 choices). Destructive choices prominent, at the **top**; Cancel at the bottom (system places it).
- Avoid scrolling action sheets.
- Use an action sheet, not a menu, for choices about an action.
- Liquid Glass: **originates from the control that triggered it** (inline popover-like on iPhone too) and lets people keep interacting with other UI. Always attach `confirmationDialog` to the triggering button so the source is known.

```swift
Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
    .confirmationDialog("Delete \(selection.count) Photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("Delete from Server", role: .destructive) { deleteSelection() }   // moves to Trash for 30 days (example copy)
        Button("Cancel", role: .cancel) {}
    } message: {
        Text("Deleted items stay in Recently Deleted for 30 days.")
    }

// iOS 15+ item form (Xcode 27)
.confirmationDialog(Text("Power Off"), item: $powerTarget, titleVisibility: .visible) { target in
    Button("Shut Down \(target.name)", role: .destructive) { shutDown(target) }
}
```

Source: https://developer.apple.com/design/human-interface-guidelines/action-sheets

### 4.23 Popovers

- Small amount of info/functionality, transient; arrow points at the source and doesn't cover it; Close/Done only when it clarifies save vs discard; **auto-save** work in nonmodal popovers; one popover at a time, no cascades; nothing on top except alerts; switch popovers with one tap; size to content and animate size changes; never for warnings.
- **iOS: avoid popovers in compact width** — they become sheets automatically; on iPhone prefer a sheet (or force popover only for tiny content with `presentationCompactAdaptation(.popover)`).

```swift
Button("Filter", systemImage: "line.3.horizontal.decrease") { showFilter = true }
    .popover(isPresented: $showFilter, arrowEdge: .top) {
        FilterOptions()
            .frame(minWidth: 280)
            .presentationCompactAdaptation(.popover)     // iOS 16.4+: keep popover on iPhone for small content
    }
```

Source: https://developer.apple.com/design/human-interface-guidelines/popovers

### 4.24 Scroll views

- Support default gestures and keyboard scrolling; make scrollability apparent (partially visible content at edges; flash indicators).
- **No nested scroll views on the same axis.** Horizontal inside vertical is fine (album carousels).
- Paging when content is page-shaped (photo viewer) — show a page control only if counting pages helps, and then hide the scroll indicator on that axis.
- Auto-scroll only as much as needed to reveal selection/insertion point.
- Zoom: set sensible min/max scale (photo viewer 1×…~5× of fit size; don't zoom past pixel-level usefulness).
- Scroll edge effects: see §2.7.

```swift
ScrollView(.horizontal) {
    LazyHStack(spacing: 0) {
        ForEach(assets) { a in ZoomablePhoto(asset: a).containerRelativeFrame(.horizontal) }
    }
    .scrollTargetLayout()
}
.scrollTargetBehavior(.paging)                         // iOS 17+; .viewAligned for card carousels
.scrollPosition(id: $currentID)                        // iOS 17+
.scrollIndicators(.hidden)

// Observe geometry (iOS 18+): e.g. drive the date scrubber
.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in offset = y }
.onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
// Visibility of an item (iOS 18+): e.g. lazy-load or pause video
VideoCell().onScrollVisibilityChange(threshold: 0.5) { visible in visible ? play() : pause() }

// Programmatic scroll (iOS 18+)
@State private var position = ScrollPosition(edge: .top)
ScrollView { ... }.scrollPosition($position)
position.scrollTo(id: section.id, anchor: .top)
position.scrollTo(edge: .top)

.refreshable { await reload() }                        // pull to refresh
.scrollEdgeEffectStyle(.soft, for: .bottom)            // iOS 26+
.scrollEdgeEffectHidden(true, for: .top)               // iOS 26+ (e.g. viewer where content is full-bleed by design)
.scrollDismissesKeyboard(.interactively)               // forms with text fields
.defaultScrollAnchor(.bottom)                          // logs
```

Source: https://developer.apple.com/design/human-interface-guidelines/scroll-views

### 4.25 Page controls

- Ordered flat pages only; centered at the bottom; **≤ ~10 dots** (beyond that use another navigation); ≤2 indicator image types; don't color indicators.
- iOS: tap/scrub; don't animate each page during scrubbing; background style automatic (default), prominent (only if it's the primary navigation), minimal (position only, no scrubbing).
- Atlas: onboarding pages only. The photo viewer does **not** use a page control (thousands of items) — Photos.app uses a thumbnail strip instead.

```swift
TabView { ForEach(pages) { OnboardingPage(page: $0) } }
    .tabViewStyle(.page(indexDisplayMode: .always))
    .indexViewStyle(.page(backgroundDisplayMode: .interactive))
```

Source: https://developer.apple.com/design/human-interface-guidelines/page-controls

### 4.26 Windows (iPad)

- iPadOS 26+: window controls, continuous resizing down to a minimum, rounder window corners. Support **arbitrary sizes**; use `NavigationSplitView` for fluid columns; respect safe areas so window controls don't collide.
- Offer "Open in New Window" where it helps (photo or folder in a new window) — not as default behavior.
- SwiftUI: `WindowGroup(for: Asset.ID.self) { $id in ... }` + `@Environment(\.openWindow)`; `UIApplicationSupportsMultipleScenes` = YES.

Source: https://developer.apple.com/design/human-interface-guidelines/windows

### 4.27 Pickers and date pickers

- For medium-to-long value lists; short lists → menu/pull-down. Predictable, logical ordering. Show in context (inline/compact), don't navigate away just to pick.
- Date picker styles: **compact** (button showing value in accent color, opens a modal calendar — use when space is tight), **inline** (calendar or wheels), **wheels**, **automatic**. Modes: date, time, date+time, countdown (≤ 23 h 59 min; not in compact/inline).
- Reduce minute granularity when appropriate (e.g. 15-min steps for a backup schedule).

```swift
Picker("Upload Quality", selection: $quality) {
    Text("Original").tag(Quality.original)
    Text("High Efficiency").tag(Quality.heic)
}
.pickerStyle(.menu)          // .menu (pop-up), .segmented, .inline, .navigationLink, .wheel, .palette, .tabs (iOS 27)

DatePicker("Back Up At", selection: $time, displayedComponents: .hourAndMinute)
    .datePickerStyle(.compact)

Picker("Sort", selection: $sort) { ... }.pickerStyle(.navigationLink)   // pushes a list in Form (Settings pattern)
```

Source: https://developer.apple.com/design/human-interface-guidelines/pickers

### 4.28 Segmented controls

- Closely related, mutually exclusive choices affecting a view/state (Drive: "List | Grid" view mode; Photos: "Years | Months | All Photos" like Photos.app).
- Don't mix actions and selection in one control; **≤ ~5 segments on iPhone** (≤5–7 wide); equal widths; text **or** images, not both; similar content length; nouns, title case.
- iOS: good for switching closely related subviews (use `.tabs` style in iOS 27 when it switches views).
- Icon-only segments need accessibility labels.

```swift
Picker("View", selection: $mode) {
    Label("List", systemImage: "list.bullet").tag(Mode.list)
    Label("Grid", systemImage: "square.grid.2x2").tag(Mode.grid)
}
.pickerStyle(.segmented)
.labelStyle(.iconOnly)
.fixedSize()
```

Source: https://developer.apple.com/design/human-interface-guidelines/segmented-controls

### 4.29 Toggles

- Two opposing states that affect content/view state. Context must make clear what it controls.
- iOS: **switch style only inside list rows** (label = row text). Default **green** — change color only if necessary (accent). **Outside lists, use a toggle-style button** (changes appearance between states, e.g. filter button) — no explaining label.
- Liquid Glass: knob turns to glass while dragged (automatic).

```swift
Form {
    Toggle("Back Up Over Cellular", isOn: $cellular)
    Toggle(isOn: $wifiOnly) {
        Text("Wi-Fi Only")
        Text("Uploads pause when you leave Wi-Fi.")     // second Text = subtitle
    }
}
// Toggle-button outside lists
Toggle(isOn: $favoritesOnly) { Label("Favorites", systemImage: "heart") }
    .toggleStyle(.button)
```

Source: https://developer.apple.com/design/human-interface-guidelines/toggles

### 4.30 Sliders

- Continuous value between min (leading) and max (trailing); fill from min to thumb; optional min/max icons; customize only if it adds meaning; pair with text field/stepper for precise values.
- iOS 26+: **tick marks** automatically when you pass `step`; knob becomes glass while dragging.
- **Not for volume** — use the system volume view (MPVolumeView).

```swift
Slider(value: $thumbnailSize, in: 80...200, step: 40) {        // iOS 26: ticks appear with step
    Text("Thumbnail Size")
} minimumValueLabel: { Image(systemName: "square.grid.4x3.fill") }
  maximumValueLabel: { Image(systemName: "square.grid.2x2.fill") }
```

Source: https://developer.apple.com/design/human-interface-guidelines/sliders

### 4.31 Steppers

- Small incremental changes; must sit next to a visible value; pair with a text field when big jumps are likely.

```swift
Stepper("Keep Last \(versions) Versions", value: $versions, in: 1...20)
Stepper(value: $days, in: 1...90, step: 1) { LabeledContent("Trash Retention", value: "\(days) days") }
```

Source: https://developer.apple.com/design/human-interface-guidelines/steppers

### 4.32 Text fields

- Small amounts of text (name, address, server URL); larger → text view. Placeholder hint ("atlas.local or 192.168.1.10"). **Secure field** for passwords. Size field to expected text; even spacing; logical focus order; validate when it makes sense (inline, near the field); number formatters for numbers; correct **keyboard type** and content type.
- iOS: Clear button at trailing end; leading/trailing images or buttons for clarity (e.g. scan QR).
- iOS 27: `.textFieldStyle(.bordered)` + `.textInputBorderShape(_:)`; `.roundedBorder` soft-deprecated.

```swift
@FocusState private var focus: Field?
Form {
    TextField("Server Address", text: $address, prompt: Text("atlas.local or 192.168.1.10"))
        .textContentType(.URL)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.next)
        .focused($focus, equals: .address)
        .onSubmit { focus = .username }
    TextField("Username", text: $user).textContentType(.username).focused($focus, equals: .username)
    SecureField("Password", text: $password).textContentType(.password).submitLabel(.go).onSubmit(signIn)
}
TextField("Port", value: $port, format: .number.grouping(.never)).keyboardType(.numberPad)
```

Source: https://developer.apple.com/design/human-interface-guidelines/text-fields

### 4.33 Color wells

- Use the system `ColorPicker` when people choose colors (e.g. album accent, tag color). Atlas likely doesn't need it.

```swift
ColorPicker("Tag Color", selection: $tagColor, supportsOpacity: false)
```

Source: https://developer.apple.com/design/human-interface-guidelines/color-wells

### 4.34 Progress indicators and activity indicators

- **Determinate** when duration/amount is known (upload 340 of 1,203); **indeterminate** (spinner) only when unknown. Switch indeterminate → determinate as soon as you know; **never switch spinner ↔ bar** shapes.
- Be accurate; even out pacing (don't show 90% in 5 s and the last 10% in 5 min). Keep it moving — a stalled indicator reads as frozen.
- Add a precise description when helpful ("Uploading 340 of 1,203"), avoid vague "Loading…".
- Consistent location for progress (Atlas: tab bottom accessory + Settings ▸ Backup row).
- Let people cancel when it's safe; warn if cancelling loses progress.
- iOS **refresh control**: pull-to-refresh for immediate reload, but also refresh automatically; title only if it adds value.
- Button-embedded spinner for actions that take a moment.

```swift
ProgressView(value: Double(done), total: Double(total)) {
    Text("Backing Up")
} currentValueLabel: {
    Text("\(done) of \(total)").monospacedDigit()
}
ProgressView()                                         // indeterminate spinner
ProgressView().controlSize(.large)
ProgressView(timerInterval: start...end, countsDown: false)   // time-based
```

Source: https://developer.apple.com/design/human-interface-guidelines/progress-indicators

### 4.35 Gauges

- Show a value within a range, with optional min/max/current labels (VoiceOver reads visible labels; write succinct ones). Gradients can encode meaning (green → red for temperature).
- Styles available on **iOS**: `.linearCapacity`, `.accessoryLinear`, `.accessoryLinearCapacity`, `.accessoryCircular`, `.accessoryCircularCapacity` (all iOS 16+). `.circular` and `.linear` are **watchOS-only** in DocC.
- Atlas: disk usage → `.linearCapacity`; CPU temperature → `.accessoryCircular` with gradient; RAM → `.accessoryCircularCapacity`.

```swift
Gauge(value: usedTB, in: 0...totalTB) {
    Text("Storage")
} currentValueLabel: {
    Text("\(usedTB, format: .number.precision(.fractionLength(1))) TB")
} minimumValueLabel: { Text("0") } maximumValueLabel: { Text("\(Int(totalTB)) TB") }
.gaugeStyle(.linearCapacity)
.tint(usedTB / totalTB > 0.9 ? .red : .blue)

Gauge(value: tempC, in: 20...100) {
    Image(systemName: "thermometer.medium")
} currentValueLabel: { Text("\(Int(tempC))°") }
.gaugeStyle(.accessoryCircular)
.tint(Gradient(colors: [.green, .yellow, .orange, .red]))
```

Source: https://developer.apple.com/design/human-interface-guidelines/gauges

### 4.36 Rating indicators, activity rings

- Rating indicators: show (not edit) a rating with stars; macOS-centric. Atlas: not needed (favorites are binary hearts).
- Activity rings: reserved for Move/Exercise/Stand data — **never reuse the ring look** for server metrics.

Source: https://developer.apple.com/design/human-interface-guidelines/rating-indicators · https://developer.apple.com/design/human-interface-guidelines/activity-rings

### 4.37 Status bar

- Transparent by default; content under it must be obscured by the scroll edge effect/bars, never cut by text.
- Hide temporarily for full-screen media (viewer); **never hide permanently**.
- iOS 27: `.toolbarVisibility(.hidden, for: .statusBar)` / `.toolbarColorScheme(.dark, for: .statusBar)`; earlier: `.statusBarHidden(_:)`.

```swift
.statusBarHidden(chromeHidden)                                     // iOS 13+
if #available(iOS 27, *) { view.toolbarVisibility(chromeHidden ? .hidden : .automatic, for: .statusBar) }
```

Source: https://developer.apple.com/design/human-interface-guidelines/status-bars

### 4.T Technologies relevant to Atlas

#### 4.T1 Live Activities (backup / upload progress)

- For tasks with a **defined start and end**, short-to-medium duration (a large backup run or upload qualifies). Presentations: **compact** (Dynamic Island, one activity: leading + trailing), **minimal** (two activities), **expanded** (touch and hold), **Lock Screen** banner, **StandBy**; also Mac menu bar, Watch Smart Stack, CarPlay.
- Glanceable essentials only; no ads; no sensitive info (no photo previews on the Lock Screen by default); medium+ weight, large text; match app look in light and dark; logo mark without container.
- Lock Screen standard margin **14 pt**; Dynamic Island corner radius **44 pt**; concentric placement; dynamic height.
- Animations ≤ **2 s**; update only when content changes; alert only for essential updates; tap opens the relevant place in the app; simple actions only (Pause Backup).
- Offer an App Shortcut to start it; let people turn it off in the app; **end it immediately** when done (custom dismissal time OK).

```swift
// ActivityKit (iOS 16.1+). Attributes shared by app + widget extension.
struct BackupAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var done: Int; var total: Int; var paused: Bool }
    var serverName: String
}
// Start
let activity = try Activity.request(attributes: BackupAttributes(serverName: "Atlas"),
                                    content: .init(state: .init(done: 0, total: 1203, paused: false), staleDate: nil))
// Update / end
await activity.update(.init(state: .init(done: 340, total: 1203, paused: false), staleDate: nil))
await activity.end(nil, dismissalPolicy: .default)

// Widget extension
struct BackupLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BackupAttributes.self) { ctx in
            LockScreenBackupView(state: ctx.state)                      // Lock Screen
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "arrow.up.circle.fill") }
                DynamicIslandExpandedRegion(.trailing) { Text("\(ctx.state.done)/\(ctx.state.total)").monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: Double(ctx.state.done), total: Double(ctx.state.total)) }
            } compactLeading: { Image(systemName: "arrow.up.circle.fill") }
              compactTrailing: { Text("\(Int(Double(ctx.state.done) / Double(ctx.state.total) * 100))%").monospacedDigit() }
              minimal: { Image(systemName: "arrow.up.circle.fill") }
        }
    }
}
```

Source: https://developer.apple.com/design/human-interface-guidelines/live-activities

#### 4.T2 Widgets (optional)

- Small amount of timely, glanceable info (storage left, last backup time, "On This Day" photo). Home Screen, Today View, Lock Screen, StandBy; widgets can be tinted/accented (iOS 18+) and rendered as clear glass in iOS 26 (unverified exact naming: "clear"/"tinted" rendering modes) — test with `widgetRenderingMode`.
- Don't replicate the app; tap opens the matching view; keep content fresh via timelines; no sensitive photos on Lock Screen widgets.

Source: https://developer.apple.com/design/human-interface-guidelines/widgets

#### 4.T3 Notifications

- Timely, high-value, actionable: "Backup finished", "Server is offline", "Disk 95% full". Not marketing. Ask permission in context (after enabling backup), let people configure categories in Settings, group by thread. Use Time Sensitive only for real urgency (server down).

Source: https://developer.apple.com/design/human-interface-guidelines/notifications

#### 4.T4 Photos: PhotoKit, pickers, Live Photos, editing

- For **reading the whole device library** (backup) you need PhotoKit authorization (`PHPhotoLibrary.requestAuthorization(for: .readWrite)`), handle `.limited`. For **picking** a few items to upload, use `PhotosPicker` — it needs **no** permission (out-of-process).
- Show Live Photos with `PHLivePhotoView` (PhotosUI, UIKit-wrapped) and badge them (`livephoto` symbol); let people play by press-and-hold (system behavior).
- Editing: if offered, follow photo-editing guidance (non-destructive, Revert); Atlas likely only offers "Open in Photos"/"Edit a Copy" (unverified scope).

```swift
import PhotosUI
@State private var picks: [PhotosPickerItem] = []
PhotosPicker(selection: $picks, maxSelectionCount: 0, selectionBehavior: .ordered, matching: .any(of: [.images, .videos])) {
    Label("Upload from Photos", systemImage: "photo.badge.plus")
}
.onChange(of: picks) { _, items in Task { await upload(items) } }   // item.loadTransferable(type: Data.self) / a FileRepresentation type
```

Source: https://developer.apple.com/design/human-interface-guidelines/live-photos · https://developer.apple.com/design/human-interface-guidelines/photo-editing · https://developer.apple.com/documentation/photosui/photospicker

#### 4.T5 Playing video

- Use AVKit's player UI (`VideoPlayer` in SwiftUI or `AVPlayerViewController`) — familiar controls, PiP, AirPlay, captions, Dim Flashing Lights. Don't build custom transport controls over video unless necessary.
- Don't autoplay with sound; in the grid, muted silent previews only if the user opts in (design judgment).

```swift
import AVKit
VideoPlayer(player: player).ignoresSafeArea().onDisappear { player.pause() }
```

Source: https://developer.apple.com/design/human-interface-guidelines/playing-video

#### 4.T6 Maps (photo location in Info sheet, Places album)

```swift
import MapKit
Map(initialPosition: .region(MKCoordinateRegion(center: coord, latitudinalMeters: 2000, longitudinalMeters: 2000))) {
    Marker("Photo", systemImage: "photo", coordinate: coord)
}
.mapStyle(.standard(elevation: .realistic))
.frame(height: 180)
.clipShape(.rect(cornerRadius: 12))       // content-layer card; or ConcentricRectangle inside a sheet
.allowsHitTesting(false)                   // static preview; tap opens a full map
```

Source: https://developer.apple.com/design/human-interface-guidelines/maps

#### 4.T7 Face ID / app lock

- Offer optional "Require Face ID" in Settings; explain in `NSFaceIDUsageDescription`; always provide passcode fallback (`.deviceOwnerAuthentication`); never invent biometric UI; refer to "Face ID"/"Touch ID" by correct name based on `LAContext().biometryType`.

```swift
import LocalAuthentication
func unlock() async -> Bool {
    let ctx = LAContext()
    return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your Atlas library")) ?? false
}
```

Source: https://developer.apple.com/design/human-interface-guidelines/privacy#Protecting-data (unverified: dedicated biometrics HIG page not consulted)

#### 4.T8 Generative AI / natural-language search, App Intents

- Generative AI HIG: be transparent that results are generated/interpreted, let people refine results and give feedback (June 2026 update), handle uncertainty gracefully, keep people in control. For Atlas NL search ("dogs at the beach 2024"): show the interpreted query as tokens (date, place, person) people can edit/remove.
- App Intents / Siri: expose "Search Atlas Photos", "Start Backup", "Server Status" as App Shortcuts; iOS 27 app **schemas** (e.g. `.photos.asset`) connect content to Siri AI and Spotlight semantic index (release notes: existing `@AppEntity(schema: .photos.asset)` conformances may need new properties in the 27 SDK).

Source: https://developer.apple.com/design/human-interface-guidelines/generative-ai · https://developer.apple.com/design/human-interface-guidelines/app-shortcuts · https://developer.apple.com/ios/

#### 4.T9 iCloud

- Atlas is **iCloud-independent**: don't use iCloud wording, symbols (`icloud.*`) or imply Apple sync for server backup. Use "Backup", "Server", "Atlas" terminology and server/drive symbols.

Source: https://developer.apple.com/design/human-interface-guidelines/icloud

---

## 5. Patterns

### 5.1 Launching

- Launch **instantly**; people won't wait more than a couple of seconds.
- **Launch screen** (mandatory with the iOS 27 SDK — `UILaunchScreen` in Info.plist): nearly identical to the first screen (same background color, maybe empty bars); **no text, no logo/ads, no splash art**.
- Splash screen (if ever) belongs at the start of onboarding, not at every launch.
- **Restore state**: reopen the last tab, scroll position, folder, open viewer item (`@SceneStorage`).
- Launch in the device's current orientation.

```swift
// Info.plist (SwiftUI app):
// <key>UILaunchScreen</key><dict><key>UIColorName</key><string>LaunchBackground</string></dict>
@SceneStorage("selectedTab") private var tabRaw = AppTab.photos.rawValue
@SceneStorage("drivePath") private var drivePath = ""
```

Source: https://developer.apple.com/design/human-interface-guidelines/launching

### 5.2 Loading

- Show something immediately (cached thumbnails, skeleton/placeholder layout); never a blank screen.
- Load in the background and let people keep using other parts of the app.
- Communicate that loading happens and roughly how long (determinate when possible).
- Download large assets in the background (Background Assets / background `URLSession`).
- Atlas: cache the library index and thumbnails on device; open instantly from cache, then reconcile with the server; show a small inline status ("Updating…") instead of blocking.

```swift
LibraryGrid(items: cachedItems)
    .redacted(reason: isFirstLoad ? .placeholder : [])      // skeleton (iOS 14+)
    .task { await library.refresh() }                       // cancelled automatically on disappear
    .overlay {
        if library.items.isEmpty && library.isLoading { ProgressView("Loading Library") }
    }
```

Source: https://developer.apple.com/design/human-interface-guidelines/loading

### 5.3 Empty and unavailable states

- Every empty screen says what will appear and the next step (Writing guidance). Use the system `ContentUnavailableView`.
- No-results search uses `ContentUnavailableView.search` / `.search(text:)`.
- Offline: keep the tab, show cached content if any, otherwise an unavailable view with a retry action.

```swift
ContentUnavailableView {
    Label("No Photos Yet", systemImage: "photo.on.rectangle")
} description: {
    Text("Turn on Backup to see this iPhone's photos on your Atlas server.")
} actions: {
    Button("Turn On Backup") { enableBackup() }.buttonStyle(.borderedProminent)
}

ContentUnavailableView.search(text: query)                        // iOS 17+

ContentUnavailableView("Server Unreachable", systemImage: "wifi.exclamationmark",
                       description: Text("Atlas couldn't reach atlas.local. Check that you're on your home network."))
```

Source: https://developer.apple.com/documentation/swiftui/contentunavailableview · https://developer.apple.com/design/human-interface-guidelines/writing

### 5.4 Searching

See §4.3 for components. Pattern rules:

- If search is important, give it a primary position (Atlas: dedicated search tab).
- **One place** to search everything; clearly display the current scope (placeholder, scope bar, tokens, title).
- Recents before typing, suggestions while typing; protect search history privacy (clearable).
- Make content findable system-wide via Spotlight indexing (optional).
- Natural-language photo search: interpret the query into tokens (person, place, date, media type) the user can see and remove; show results progressively.

```swift
struct SearchView: View {
    @State private var query = ""
    @State private var tokens: [SearchToken] = []
    @State private var results: [Asset] = []
    var body: some View {
        Group {
            if query.isEmpty && tokens.isEmpty { SearchLanding() }           // recents, people, places, categories
            else if results.isEmpty { ContentUnavailableView.search(text: query) }
            else { ResultsGrid(results: results) }
        }
        .navigationTitle("Search")
        .searchable(text: $query, tokens: $tokens, prompt: "Photos, People, Places") { Label($0.title, systemImage: $0.symbol) }
        .task(id: SearchKey(query: query, tokens: tokens)) {               // debounced live search
            try? await Task.sleep(for: .milliseconds(250))
            results = (try? await AtlasAPI.search(query, tokens)) ?? []
        }
    }
}
```

Source: https://developer.apple.com/design/human-interface-guidelines/searching

### 5.5 Settings

- Good **defaults** for most people; **minimize the number of settings**.
- Make settings reachable where expected (in-app Settings tab; ⌘, on iPad with keyboard via `.keyboardShortcut(",", modifiers: .command)` on a button/command).
- Don't ask in Settings for information you can detect (server discovery via Bonjour, device name).
- Don't duplicate system settings (appearance, text size, notifications permission toggles) — link to them (`UIApplication.openSettingsURLString`, `openNotificationSettingsURLString`).
- General, rarely-changed settings in the Settings area; **task-specific options in context** (grid density in the Photos toolbar menu, sort in Drive's menu — not in Settings).
- Labels practical; footers explain consequences; destructive actions (Sign Out, Reset) at the bottom in their own section, red.
- Settings-app bundle (system Settings) only for the rarest options — Atlas: none.
- Match Apple's Settings look: `Form` (grouped), `Section` with title-case headers, `LabeledContent` for read-only values, `NavigationLink` rows with leading colored symbol tiles (optional), toggles in rows, `.pickerStyle(.navigationLink)` or `.menu` for choices.

```swift
Form {
    Section {
        NavigationLink { AccountView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(user.name).font(.title3.weight(.semibold))
                    Text(server.host).font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
        }
    }
    Section("Backup") {
        Toggle("Photo Backup", isOn: $backupOn)
        Picker("Upload Quality", selection: $quality) { Text("Original").tag(Quality.original); Text("Optimized").tag(Quality.optimized) }
        Toggle("Use Cellular Data", isOn: $cellular)
    } footer: {
        Text("Photos back up automatically when Atlas is open or charging on Wi-Fi.")
    }
    Section("Server") {
        NavigationLink { ServerStatusView() } label: { LabeledContent { StatusBadge(status) } label: { Label("Status", systemImage: "server.rack") } }
        LabeledContent("Version", value: server.version)
    }
    Section {
        Button("Sign Out", role: .destructive) { confirmSignOut = true }
    }
}
.navigationTitle("Settings")
```

Source: https://developer.apple.com/design/human-interface-guidelines/settings

### 5.6 Modality

- Modal only with a clear benefit: critical info, confirming/modifying the last action, a scoped task, or immersive/complex work.
- Keep modal tasks short; **don't build an app-within-the-app** (no deep hierarchies inside a modal; a short `NavigationStack` for a 2–3 step flow is fine).
- **Full-screen** modal for in-depth content or complex tasks (photo/video viewer, editor, onboarding).
- Always an obvious dismissal (Close/Cancel, swipe down). Confirm before discarding unsaved data on any dismissal path.
- Make the modal's task obvious (title). Dismiss one modal before presenting another.
- Component choice: **alert** (critical), **action sheet/confirmationDialog** (choices for an initiated action), **sheet** (scoped task), **popover** (iPad, small), **fullScreenCover** (immersive).

```swift
.fullScreenCover(item: $viewerItem) { item in
    PhotoViewer(start: item).navigationTransition(.zoom(sourceID: item.id, in: ns))   // iOS 18+
}
```

Source: https://developer.apple.com/design/human-interface-guidelines/modality

### 5.7 Feedback

- Match the delivery to significance: inline status for routine info, alert for critical/actionable, haptics + animation for confirmations.
- Make feedback accessible (visual + haptic + VoiceOver announcement).
- Integrate status near the item (upload badge on a cell, sync state on a file row).
- Warn **only** for unexpected, irreversible data loss (permanently deleting from Trash, server power off). Don't warn for expected, recoverable actions (move to Trash).
- Confirm completion of significant tasks (backup finished, upload done) — subtly (toast-like inline banner or Live Activity end state; no alert).
- When a command can't run, explain why and how to fix it.

```swift
// Inline transient confirmation (custom, content-layer, auto-dismiss is OK for non-essential info but keep it ≥ ~4 s and reachable via VoiceOver) — design judgment
AccessibilityNotification.Announcement("Upload complete").post()
```

Source: https://developer.apple.com/design/human-interface-guidelines/feedback

### 5.8 File management (Drive)

- If you need a custom file browser (Atlas Drive: server files), mirror Files/Finder concepts: folders, breadcrumbs via navigation stack, list/grid toggle, sort (Name, Date, Size, Kind), Recents, Favorites, Trash, file name + size + date metadata, file-type icons/thumbnails.
- **Auto-save**; never make people explicitly save unless they want "Save As"/export.
- Hide file extensions by default with an option to show them (Files has "Show All Filename Extensions") — consistent everywhere.
- **Quick Look** to preview files your app can't open natively; Quick Look generator for custom types (n/a).
- Document launcher (iOS 18+) is for document-based apps — not Drive.
- File provider extension: optional, lets the system Files app browse Atlas Drive (powerful integration; then the in-app Drive can stay simple). If built, show only appropriate files, let people choose destinations, don't add a second toolbar.
- Prefer system open/save UIs (`fileImporter`, `fileExporter`) for moving data between Atlas and device storage.

```swift
// Upload from Files
.fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
    if case .success(let urls) = result {
        Task { for url in urls where url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            try? await AtlasAPI.upload(url, to: folder)
        } }
    }
}
// Preview a downloaded file (iOS 14+), with paging over siblings
.quickLookPreview($previewURL, in: downloadedSiblingURLs)
// Export to device (iOS 17+, item: some Transferable)
.fileExporter(isPresented: $exporting, item: exportFile, contentTypes: [.data], defaultFilename: exportName) { result in handle(result) }
```

Source: https://developer.apple.com/design/human-interface-guidelines/file-management

### 5.9 Managing accounts (server sign-in)

- Require an account only when core functionality needs it (Atlas: yes — server login). Explain why briefly; delay sign-in until needed where possible (Atlas: first screen is "Connect to your server").
- Prefer **passkeys** (or Sign in with Apple if the server supports it); otherwise username/password with Password AutoFill (`textContentType(.username/.password)`), and offer biometric unlock at system level.
- Name the auth method accurately ("Sign In with Face ID"); only reference methods available on the device; **avoid an app-specific biometric opt-in setting** (HIG) — exception: an app-lock feature (protecting the library from someone holding the unlocked phone) is a distinct privacy feature (design judgment).
- Don't call account credentials a "passcode".
- If the app can create accounts, it must support **deleting** them in-app. Atlas: accounts are created on the server by its admin; if the app can create users, provide deletion (App Review requirement).
- Use `ASWebAuthenticationSession` for OAuth/OIDC flows against the server's identity provider.

```swift
import AuthenticationServices
@Environment(\.webAuthenticationSession) private var webAuth      // iOS 16.4+
let callback = try await webAuth.authenticate(using: authURL, callbackURLScheme: "atlas", preferredBrowserSession: .ephemeral)
```

Source: https://developer.apple.com/design/human-interface-guidelines/managing-accounts

### 5.10 Onboarding

- Ideally none: the app teaches itself. If needed: **fast, fun, optional**; teach through doing; prefer contextual tips (TipKit) over a long upfront tour.
- Prerequisite flows only for what's required (Atlas: connect to server → sign in → optional backup setup).
- No licensing text in onboarding; don't block on large downloads.
- Postpone nonessential setup; good defaults.
- Ask for permissions inside onboarding **only if needed to function** and with context (Photos access on the "Back Up This iPhone" step, with "Not Now").
- Ratings/purchases only after people experienced the app.

```swift
import TipKit
struct PinchTip: Tip {
    var title: Text { Text("Change Grid Size") }
    var message: Text? { Text("Pinch to see more or fewer photos.") }
    var image: Image? { Image(systemName: "hand.pinch") }
}
PhotoGrid().popoverTip(PinchTip())         // iOS 17+; call try? Tips.configure() at launch
```

Source: https://developer.apple.com/design/human-interface-guidelines/onboarding · https://developer.apple.com/design/human-interface-guidelines/offering-help

### 5.11 Going full screen (photo/video viewer)

- Full screen when immersion helps (viewer). Keep essential controls reachable without leaving full screen (share, favorite, info, delete via tap-to-show chrome).
- **Hide toolbars/navigation temporarily** (tap toggles chrome; it can also auto-hide when video plays).
- Let people choose when to exit (swipe down / Close); resume where they left off.
- iOS: consider **deferring system gestures** at screen edges only in games/drawing; for a photo viewer keep the home indicator auto-hide default.
- Status bar hidden while chrome is hidden; never permanently.

```swift
PhotoPager(...)
    .background(.black)
    .ignoresSafeArea()
    .toolbarVisibility(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)   // iOS 18+
    .statusBarHidden(chromeHidden)
    .persistentSystemOverlays(chromeHidden ? .hidden : .automatic)   // home indicator (iOS 16+)
    .onTapGesture { withAnimation(.smooth(duration: 0.25)) { chromeHidden.toggle() } }
// .defersSystemGestures(on: .bottom)  // games only (iOS 16+)
```

Source: https://developer.apple.com/design/human-interface-guidelines/going-full-screen

### 5.12 Drag and drop

- Support it broadly (iPad especially): drag photos into albums, files into folders, between Atlas and other apps (Files, Mail).
- Always provide an alternative (Move…/Add to Album… menu items).
- Move within the same container, copy across containers/apps. Support multi-item drags. Make drops undoable.
- Offer multiple representations, richest first (original file, then JPEG).
- Feedback: drag image after ~**3 pt** of movement; show valid destinations (highlight folder), animate failed drops back; auto-scroll destinations; progress for slow transfers; keep the selection after drop.
- iPadOS: multiple simultaneous drag sessions and adding items to an in-progress drag.

```swift
FileRow(file: file)
    .draggable(file)                                         // Transferable (iOS 16+)
FolderRow(folder: folder)
    .dropDestination(for: DriveItem.self) { items, _ in move(items, to: folder); return true }
        isTargeted: { targeted = $0 }
    .background(targeted ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
// Multi-item drags from a grid: .dragContainer(for: Asset.self, itemID: \.id, in: ns) { ids in payload(ids) } on the container
// + .draggable(containerItemID: asset.id, containerNamespace: ns) on each cell. DocC lists both as iOS 27.0
// (Apple's SwiftUI updates page files them under June 2025 — trust DocC availability)
// iOS 27: .reorderable() + .reorderContainer(for:isEnabled:move:) for in-place reordering (album order)
```

Source: https://developer.apple.com/design/human-interface-guidelines/drag-and-drop

### 5.13 Entering data

- Get data from the system when possible (device name, network, Bonjour-discovered server); offer choices over typing; support paste and drop; secure fields for secrets; **never prefill passwords**; validate dynamically; make required fields obvious and disable the continue button until satisfied.

Source: https://developer.apple.com/design/human-interface-guidelines/entering-data

### 5.14 Undo and redo

- Predictable, visible results (scroll to the affected item); unlimited-ish undo; batch revert where helpful; dedicated undo buttons only when necessary.
- iOS: don't redefine system undo gestures (three-finger swipe, shake); describe the operation briefly ("Undo Move" — system prefixes "Undo ").
- Atlas: undo for move/rename/delete-to-trash in Drive and for removing photos from an album.

```swift
@Environment(\.undoManager) private var undoManager
func move(_ items: [DriveItem], to dest: Folder) {
    let origin = items.map(\.parent)
    perform(move: items, to: dest)
    undoManager?.registerUndo(withTarget: store) { store in store.restore(items, to: origin) }
    undoManager?.setActionName("Move")
}
```

Source: https://developer.apple.com/design/human-interface-guidelines/undo-and-redo

### 5.15 Charting data (pattern)

- Chart only when it highlights something; keep it simple with details on demand; common chart types; descriptive titles/annotations; size matches detail; consistent styling across charts; continuity when several charts show the same data (same colors per metric).
- Atlas dashboard: one compact chart per metric (CPU, GPU, RAM, network) with the current value as headline text; tap for a detailed chart with time range picker (1h / 24h / 7d).

Source: https://developer.apple.com/design/human-interface-guidelines/charting-data

### 5.16 Collaboration and sharing, multitasking, offering help (brief)

- Share with `ShareLink`/share sheet; for shared albums use clear owner/participant language (if Atlas adds sharing).
- iPad multitasking: support all window sizes, multiple windows (open album/folder in new window), drag and drop between windows.
- Offering help: TipKit tips in context; no manual-style help screens.

Source: https://developer.apple.com/design/human-interface-guidelines/collaboration-and-sharing · https://developer.apple.com/design/human-interface-guidelines/multitasking · https://developer.apple.com/design/human-interface-guidelines/offering-help

---

## 5B. Inputs

### 5B.1 Gestures

| Gesture | Standard meaning | Atlas use |
|---|---|---|
| Tap | activate/select | open photo/file; select in selection mode |
| Swipe | reveal actions, dismiss, scroll | row swipe actions; swipe down to close viewer; horizontal paging in viewer |
| Drag | move element | drag-to-select across grid cells; drag-and-drop; scrubber |
| Touch and hold | reveal more (context menu) | context menu with preview |
| Double tap | zoom in / out | viewer zoom toggle |
| Zoom (pinch) | magnify | viewer zoom; grid density (Photos convention) |
| Rotate | rotate item | not used |

Rules: offer more than one way (menu alternatives for every gesture); behave as people expect; respond immediately and track the finger; show when a gesture isn't available. Custom gestures only if discoverable, easy, distinct, and never the only path; shortcut gestures supplement visible controls (Back button stays even though edge-swipe works); don't conflict with system edge gestures.

```swift
// Pinch to change grid density (iOS 17+ MagnifyGesture)
.gesture(MagnifyGesture().onEnded { value in
    let next = value.magnification > 1 ? max(columns - 1, 2) : min(columns + 1, 8)   // fewer columns when zooming in
    withAnimation(.snappy) { columns = next }
})
// Double tap to zoom in viewer
.onTapGesture(count: 2) { withAnimation(.smooth) { zoom = zoom > 1 ? 1 : 2.5 } }
// Long press handled by .contextMenu — don't add a separate LongPressGesture on the same view
// iOS 27: restrict input kinds, e.g. TapGesture(count: 2, inputKinds: ...) — see GestureInputKinds
```

Source: https://developer.apple.com/design/human-interface-guidelines/gestures

### 5B.2 Keyboards (hardware) and virtual keyboards

- iPad hardware keyboard: support standard shortcuts (⌘F search, ⌘N new folder, ⌘, settings, Delete, Space for Quick Look, arrow keys in grids), don't override system shortcuts; the system shows a shortcut overlay when holding ⌘.
- Virtual keyboard: correct keyboard type, return key label (`submitLabel`), content types for AutoFill, don't obscure the focused field (SwiftUI handles safe area), toolbar above keyboard for custom actions (`ToolbarItemGroup(placement: .keyboard)`).

```swift
Button("New Folder", systemImage: "folder.badge.plus", action: newFolder).keyboardShortcut("n", modifiers: [.command, .shift])
Button("Search", action: focusSearch).keyboardShortcut("f")
.toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focus = nil } } }
```

Source: https://developer.apple.com/design/human-interface-guidelines/keyboards · https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards

### 5B.3 Pointing devices (iPad)

- Pointer adapts to controls automatically (hover effects on buttons, bars). Add `.hoverEffect()` to custom tappable views (photo cells: `.hoverEffect(.lift)` or `.highlight`); support secondary click → context menu (automatic with `.contextMenu`); support drag-select with pointer; scroll with trackpad.

```swift
Thumbnail(asset).hoverEffect(.lift)          // iOS 13.4+
```

Source: https://developer.apple.com/design/human-interface-guidelines/pointing-devices

### 5B.4 Apple Pencil, Action button, Camera Control (brief)

- Pencil: not relevant beyond acting as a pointer/tap. Action button and Camera Control: expose an App Shortcut ("Start Backup") so people can map it; no special UI needed.

Source: https://developer.apple.com/design/human-interface-guidelines/apple-pencil-and-scribble · https://developer.apple.com/design/human-interface-guidelines/action-button · https://developer.apple.com/design/human-interface-guidelines/camera-control

---

## 6. Atlas recipes

Target: iOS 26+ (iOS 27 APIs marked). These are skeletons that follow the rules above — model/network types (`Asset`, `AtlasAPI`, …) are placeholders. They compile in principle; adjust names to the real model layer.

### 6.0 State and environment plumbing

```swift
import SwiftUI
import Observation

@Observable final class LibraryModel {            // iOS 17+
    var sections: [DaySection] = []
    var isLoading = false
    var columns = 4                                // pinch-controlled density
    var selection: Set<Asset.ID> = []
    var isSelecting = false
    func refresh() async { /* fetch index, merge into cache */ }
}

@Observable final class ServerModel {
    var status: ServerStatus = .unknown
    var cpu: [Sample] = []; var gpu: [Sample] = []; var ram: [Sample] = []; var net: [Sample] = []
    var services: [Service] = []
    func poll() async {                            // run from .task; cancels automatically
        while !Task.isCancelled {
            if let s = try? await AtlasAPI.metrics() { apply(s) }
            try? await Task.sleep(for: .seconds(2))
        }
    }
    func apply(_ s: Metrics) { /* append, trim to window */ }
}

extension EnvironmentValues {
    @Entry var atlasAPI: AtlasAPI = .live           // iOS 18 back-deployable macro; avoid class instances as defaults (Xcode 27 warns)
}

@main struct AtlasApp: App {
    @State private var library = LibraryModel()     // Xcode 27: @State macro evaluates initializer once
    @State private var server = ServerModel()
    @State private var backup = BackupModel()        // drives the tab accessory + Live Activity
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(server)
                .environment(backup)
        }
    }
}
```

### 6.1 App shell: tabs, search tab, minimize on scroll, backup accessory

```swift
enum AppTab: String, Hashable { case photos, drive, settings, search }

struct RootView: View {
    @SceneStorage("tab") private var tab: AppTab = .photos
    @Environment(BackupModel.self) private var backup

    var body: some View {
        TabView(selection: $tab) {
            Tab("Photos", systemImage: "photo.on.rectangle", value: .photos) { PhotosRoot() }
            Tab("Drive", systemImage: "folder", value: .drive) { DriveRoot() }
            Tab("Settings", systemImage: "gear", value: .settings) { SettingsRoot() }
            Tab(value: .search, role: .search) { NavigationStack { SearchView() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)        // Photos-like: bar shrinks while browsing
        .tabViewBottomAccessory {                     // shows only while a backup runs
            if backup.isRunning { BackupAccessory() }
        }
        .tabViewStyle(.sidebarAdaptable)              // iPad
    }
}
```

Notes: each tab owns its own `NavigationStack` (state preserved when switching tabs). Don't hide the tab bar except for full-screen/modal content or selection mode (see 6.4). If `tabViewBottomAccessory` with conditional content leaves an empty capsule on your OS version, apply the modifier conditionally instead (unverified behavior).

### 6.2 Photo grid with pinned date headers, pinch density, scrubber

Design rules applied: square thumbnails, 1–2 pt gutters, no glass on cells, headers pinned under a **hard** scroll edge effect, material date pills, monochrome bars over colorful content, pinch with haptic snap, VoiceOver rotor by month, even column counts on wide/folding layouts.

```swift
struct PhotosRoot: View {
    @Environment(LibraryModel.self) private var library
    @Namespace private var zoomNS
    @State private var path: [Asset.ID] = []

    var body: some View {
        NavigationStack(path: $path) {
            PhotoGrid(zoomNS: zoomNS, open: { path.append($0) })
                .navigationTitle("Library")
                .navigationSubtitle(library.subtitle)                 // "12,480 Photos · 1,024 Videos"
                .toolbar { PhotosToolbar() }
                .navigationDestination(for: Asset.ID.self) { id in
                    PhotoViewer(startID: id, zoomNS: zoomNS)
                        .navigationTransition(.zoom(sourceID: id, in: zoomNS))   // iOS 18+
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
        }
    }
}

struct PhotoGrid: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.horizontalSizeClass) private var hSize
    let zoomNS: Namespace.ID
    let open: (Asset.ID) -> Void
    @State private var position = ScrollPosition(idType: DaySection.ID.self)
    @State private var visibleSection: DaySection.ID?
    @State private var pinchBase: Int?

    private var columnCount: Int { hSize == .regular ? library.columns + 2 : library.columns }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount),
                      spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(library.sections) { section in
                    Section {
                        ForEach(section.assets) { asset in
                            GridCell(asset: asset, isSelected: library.selection.contains(asset.id),
                                     isSelecting: library.isSelecting)
                                .matchedTransitionSource(id: asset.id, in: zoomNS)       // iOS 18+
                                .onTapGesture { tap(asset) }
                                .contextMenu { AssetMenu(asset: asset) } preview: { AssetPreview(asset: asset) }
                        }
                    } header: {
                        SectionHeader(section: section)
                            .onScrollVisibilityChange(threshold: 0.1) { if $0 { visibleSection = section.id } }
                    }
                    .id(section.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.hard, for: .top)               // pinned headers stay legible
        .defaultScrollAnchor(.bottom)                          // newest photos at the bottom, like Photos
        .safeAreaBar(edge: .trailing) {                        // iOS 26+: registers as a bar
            DateScrubber(sections: library.sections, current: visibleSection) { id in
                position.scrollTo(id: id, anchor: .top)
            }
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in
                    if pinchBase == nil { pinchBase = library.columns }
                    let target = (pinchBase ?? library.columns) + (v.magnification > 1.25 ? -1 : v.magnification < 0.8 ? 1 : 0)
                    let clamped = min(max(target, 2), 7)
                    if clamped != library.columns { withAnimation(.snappy) { library.columns = clamped } }
                }
                .onEnded { _ in pinchBase = nil }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: library.columns)
        .refreshable { await library.refresh() }
        .accessibilityRotor("Dates") {
            ForEach(library.sections) { s in AccessibilityRotorEntry(s.title, id: s.id) }
        }
    }

    private func tap(_ asset: Asset) {
        if library.isSelecting {
            if library.selection.contains(asset.id) { library.selection.remove(asset.id) } else { library.selection.insert(asset.id) }
        } else {
            open(asset.id)
        }
    }
}

struct GridCell: View {
    let asset: Asset; let isSelected: Bool; let isSelecting: Bool
    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ThumbnailImage(asset: asset).scaledToFill() }   // load ~cell px size from server/cache
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.isVideo {
                    Text(asset.duration, format: .time(pattern: .minuteSecond))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.white).shadow(radius: 2).padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(4) }
            }
            .overlay {
                if isSelecting {
                    ZStack(alignment: .bottomTrailing) {
                        if isSelected { Color.white.opacity(0.25) }
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Color.accentColor : .clear)
                            .font(.title3).shadow(radius: 1).padding(6)
                    }
                }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(asset.accessibilityDescription)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .hoverEffect(.highlight)
    }
}

struct SectionHeader: View {
    let section: DaySection
    var body: some View {
        HStack {
            Text(section.title)                          // "Saturday, March 7" / "March 2026"
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: .capsule)   // content-layer material, not glass
            Spacer()
            if let place = section.place { Text(place).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityAddTraits(.isHeader)
    }
}
```

**Date scrubber** (Photos-style fast scroll): thin trailing hit area that becomes a draggable glass thumb with the current month/year while dragging; selection haptic per month; hidden when idle.

```swift
struct DateScrubber: View {
    let sections: [DaySection]
    let current: DaySection.ID?
    let jump: (DaySection.ID) -> Void
    @State private var dragging = false
    @State private var label = ""
    @State private var lastMonth = ""

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.clear.frame(width: 28).contentShape(.rect)           // hit area along the edge
                if dragging {
                    Text(label)
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)              // floating functional element
                        .offset(x: -36, y: thumbY(in: geo.size.height))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard !sections.isEmpty else { return }
                    dragging = true
                    let f = min(max(v.location.y / geo.size.height, 0), 1)
                    let s = sections[Int(f * Double(sections.count - 1))]
                    label = s.monthTitle                                  // "March 2026"
                    if s.monthTitle != lastMonth { lastMonth = s.monthTitle; jump(s.id) }
                }
                .onEnded { _ in withAnimation(.smooth) { dragging = false } })
        }
        .frame(width: 28)
        .sensoryFeedback(.selection, trigger: lastMonth)
        .accessibilityHidden(true)                                          // rotor covers VoiceOver navigation
    }
    private func thumbY(in h: CGFloat) -> CGFloat {
        guard let current, let i = sections.firstIndex(where: { $0.id == current }), sections.count > 1 else { return 0 }
        return h * CGFloat(i) / CGFloat(sections.count - 1)
    }
}
```

Performance rules for 50k+ assets: `LazyVGrid` inside one `ScrollView`; stable `Identifiable` IDs; cells do no synchronous work; thumbnails sized to cell pixels and cached in memory (NSCache) + disk; cancel loads for off-screen cells (`.task(id: asset.id)`); avoid `GeometryReader` per cell; group by month at small densities (Photos switches to month/year aggregation views — Years/Months/All segmented control is the Apple pattern) (unverified perf thresholds). If SwiftUI grid perf is insufficient, wrap `UICollectionView` with a compositional layout via `UIViewControllerRepresentable` (iOS 27: compositional layouts auto-invalidate on Observation changes).

### 6.3 Zoom transition into a full-screen viewer with paging, zoom and info

- Zoom transition (iOS 18+) from the tapped cell; swipe-down/pinch-in to dismiss is built into the zoom transition; when the user pages to another photo, update the **sourceID** so dismissal zooms into the right cell, and scroll the grid to it.
- Viewer is dark, chrome toggles on tap, controls use `.clear` glass over media, bottom toolbar holds Share / Favorite / Info / Delete.

```swift
struct PhotoViewer: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    let startID: Asset.ID
    let zoomNS: Namespace.ID
    @State private var currentID: Asset.ID?
    @State private var chromeHidden = false
    @State private var showInfo = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(library.allAssets) { asset in
                    ZoomableAsset(asset: asset)
                        .containerRelativeFrame(.horizontal)
                        .id(asset.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .background(.black)
        .ignoresSafeArea()
        .onAppear { currentID = startID }
        .onTapGesture { withAnimation(.smooth(duration: 0.2)) { chromeHidden.toggle() } }
        .navigationTitle(current?.dateTitle ?? "")
        .navigationSubtitle(current?.timeAndPlace ?? "")                  // iOS 26+
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if let current {
                    ShareLink(item: current.transferable, preview: SharePreview(current.title))
                    Spacer()
                    Button("Favorite", systemImage: current.isFavorite ? "heart.fill" : "heart") { library.toggleFavorite(current) }
                        .contentTransition(.symbolEffect(.replace))
                        .sensoryFeedback(.selection, trigger: current.isFavorite)
                    Spacer()
                    Button("Info", systemImage: "info.circle") { showInfo = true }
                    Spacer()
                    Button("Delete", systemImage: "trash") { confirmDelete = true }
                        .confirmationDialog("This photo will be moved to Recently Deleted.", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete Photo", role: .destructive) { library.trash(current); advance() }
                        }
                }
            }
        }
        .toolbarVisibility(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)   // light symbols over the photo (unverified that it affects glass bars)
        .statusBarHidden(chromeHidden)
        .persistentSystemOverlays(chromeHidden ? .hidden : .automatic)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) { if let current { PhotoInfoSheet(asset: current) } }
        .onChange(of: currentID) { _, id in if let id { library.scrollTargetInGrid = id } }   // grid scrolls to it so the zoom-back lands
    }

    private var current: Asset? { library.asset(currentID) }
    private func advance() { /* move currentID to next/previous */ }
}
```

Keeping the zoom source in sync: `navigationTransition(.zoom(sourceID:in:))` reads the ID you pass when the view is created. To land on the paged-to photo, drive navigation by a model property (e.g. `path = [currentID]` replacement on page change is jarring) — simpler: present with `.fullScreenCover(item:)` keyed by a `@State var viewerID`, pass `sourceID: viewerID` and update `viewerID` as the user pages (unverified whether the transition re-reads a changed sourceID; test both approaches).

**Zoomable image** — SwiftUI has no built-in zooming scroll view; two options:

1. `UIScrollView` wrapper (`UIViewRepresentable`) with `minimumZoomScale = 1`, `maximumZoomScale ≈ 4–5`, double-tap to zoom to the tap point — closest to Photos.app behavior (recommended).
2. Pure SwiftUI: `MagnifyGesture` + `DragGesture` + `.scaleEffect`/`.offset`, clamped, with double-tap toggle; disable the pager's scrolling while zoomed (`.scrollDisabled(isZoomed)` on the outer ScrollView via preference/binding).

```swift
struct ZoomableAsset: View {
    let asset: Asset
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        FullImage(asset: asset)                         // progressive: show thumbnail, then full-res
            .scaledToFit()
            .scaleEffect(scale)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(MagnifyGesture()
                .onChanged { scale = min(max(base * $0.magnification, 1), 5) }
                .onEnded { _ in base = scale; if scale == 1 { withAnimation(.smooth) { offset = .zero } } })
            .simultaneousGesture(scale > 1 ? DragGesture().updating($drag) { v, s, _ in s = v.translation }
                .onEnded { v in offset.width += v.translation.width; offset.height += v.translation.height } : nil)
            .onTapGesture(count: 2) {
                withAnimation(.smooth) {
                    if scale > 1 { scale = 1; base = 1; offset = .zero } else { scale = 2.5; base = 2.5 }
                }
            }
            .accessibilityLabel(asset.accessibilityDescription)
            .accessibilityAddTraits(.isImage)
    }
}
```

Video assets: replace `FullImage` with `VideoPlayer(player:)` (AVKit controls, own dimming) and pause on `onScrollVisibilityChange(false)`.

**Info sheet** (EXIF, map, people) — medium/large detents, nonmodal at medium so people can keep swiping photos:

```swift
struct PhotoInfoSheet: View {
    let asset: Asset
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Date", value: asset.date.formatted(date: .long, time: .shortened))
                    LabeledContent("File", value: asset.filename)
                    LabeledContent("Size") { Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(asset.bytes.formatted(.byteCount(style: .file)))") }
                }
                if let exif = asset.exif {
                    Section("Camera") {
                        LabeledContent("Device", value: exif.model)
                        LabeledContent("Lens", value: exif.lens)
                        LabeledContent("Exposure") { Text("ƒ\(exif.aperture, specifier: "%.1f") · 1/\(Int(1 / exif.shutter)) s · ISO \(exif.iso)").monospacedDigit() }
                    }
                }
                if let coord = asset.coordinate {
                    Section("Location") {
                        Map(initialPosition: .region(.init(center: coord, latitudinalMeters: 1500, longitudinalMeters: 1500))) {
                            Marker(asset.placeName ?? "Photo", coordinate: coord)
                        }
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if !asset.people.isEmpty {
                    Section("People") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) { ForEach(asset.people) { PersonChip(person: $0) } }
                        }.scrollIndicators(.hidden)
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
```

### 6.4 Selection mode with a glass action bar

Apple pattern (Photos): "Select" button (text) top trailing → grid enters selection; the tab bar is replaced by a bottom toolbar with Share · "N Selected" · Delete, plus a More menu; "Cancel" replaces "Select"; drag across cells to select multiple; title shows the count.

Preferred implementation = **system bottom toolbar** (gets Liquid Glass, scroll edge effect and placement automatically):

```swift
struct PhotosToolbar: ToolbarContent {
    @Environment(LibraryModel.self) private var library
    @State private var confirmDelete = false
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(library.isSelecting ? "Cancel" : "Select") {
                withAnimation(.snappy) { library.isSelecting.toggle(); library.selection.removeAll() }
            }
        }
        if !library.isSelecting {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu("View Options", systemImage: "ellipsis") {
                    Picker("Grid Size", selection: Bindable(library).columns) {
                        Label("Large", systemImage: "square.grid.2x2").tag(3)
                        Label("Medium", systemImage: "square.grid.3x3").tag(5)
                        Label("Small", systemImage: "square.grid.4x3.fill").tag(7)
                    }
                    Toggle("Show Favorites Only", systemImage: "heart", isOn: Bindable(library).favoritesOnly)
                }
            }
        }
        if library.isSelecting {
            ToolbarItemGroup(placement: .bottomBar) {
                ShareLink(items: library.selectedTransferables) { Label("Share", systemImage: "square.and.arrow.up") }
                    .disabled(library.selection.isEmpty)
                Spacer()
                Text(library.selection.isEmpty ? "Select Items" : "\(library.selection.count) Selected")
                    .font(.headline).monospacedDigit()
                Spacer()
                Button("Delete", systemImage: "trash") { confirmDelete = true }
                    .disabled(library.selection.isEmpty)
                    .confirmationDialog("Delete \(library.selection.count) Items?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete \(library.selection.count) Items", role: .destructive) { library.trashSelection() }
                    } message: { Text("They'll stay in Recently Deleted for 30 days.") }
            }
        }
    }
}
// In PhotosRoot: hide the tab bar while selecting so the bottom toolbar takes its place
.toolbarVisibility(library.isSelecting ? .hidden : .visible, for: .tabBar)
.sensoryFeedback(.selection, trigger: library.selection.count)
```

Custom floating glass bar (when you need a richer bar than a toolbar, e.g. iPad floating actions): use `safeAreaBar(edge: .bottom)` + one `GlassEffectContainer` + `glassEffectID` so it morphs in from the Select button region; keep ≤ 4 actions; icon-only with accessibility labels; `.glassProminent` only for one primary action (none here: delete is destructive and must not be prominent).

```swift
.safeAreaBar(edge: .bottom) {
    if library.isSelecting {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(BarAction.allCases) { action in
                    Button(action.title, systemImage: action.symbol) { perform(action) }
                        .labelStyle(.iconOnly)
                        .frame(width: 50, height: 50)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID(action, in: barNS)
                }
            }
        }
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
```

Drag-to-select (Photos behavior): a `DragGesture` that starts after a short horizontal movement on a cell in selection mode, maps location → cell index via cached cell frames (`onGeometryChange` per row, not per cell), and toggles the range; auto-scroll near edges with `ScrollPosition`. Keep vertical drags scrolling. (Implementation detail; no Apple API does this for `LazyVGrid` — `List` gets two-finger multi-select for free.)

### 6.5 Drive: Files-style browser

Rules applied: plain list by default with toggle to grid; sort in a menu (title-case items, checkmark on current); folders first; file name + secondary metadata; context menu = swipe actions (same order); multi-select via Edit; Quick Look preview; upload via `fileImporter` and `PhotosPicker`; rename in an alert with text field; move via a sheet folder picker; delete to server Trash without alert, with undo.

```swift
struct DriveFolderView: View {
    let folder: Folder
    @State private var items: [DriveItem] = []
    @AppStorage("drive.viewMode") private var mode: ViewMode = .list
    @AppStorage("drive.sort") private var sort: SortKey = .name
    @State private var filter = ""
    @State private var selection: Set<DriveItem.ID> = []
    @State private var editMode: EditMode = .inactive
    @State private var importing = false
    @State private var preview: URL?
    @State private var renaming: DriveItem?
    @State private var newName = ""
    @State private var moving: [DriveItem] = []

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder",
                                       description: Text("Upload files or create a folder."))
            } else if mode == .list {
                List(sorted, selection: $selection) { item in
                    row(item)
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 16)], spacing: 20) {
                        ForEach(sorted) { item in DriveTile(item: item).contextMenu { menu(for: item) } preview: { DrivePreview(item: item) } }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(folder.name)
        .searchable(text: $filter, prompt: "Search in \(folder.name)")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Options", systemImage: "ellipsis") {
                    Picker("View", selection: $mode) {
                        Label("Icons", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                        Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                    }
                    Picker("Sort By", selection: $sort) {
                        Text("Name").tag(SortKey.name); Text("Date").tag(SortKey.date)
                        Text("Size").tag(SortKey.size); Text("Kind").tag(SortKey.kind)
                    }
                    Divider()
                    Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
                    Button("Upload Files…", systemImage: "square.and.arrow.up") { importing = true }
                    Button(editMode.isEditing ? "Done" : "Select", systemImage: "checkmark.circle") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Move", systemImage: "folder") { moving = selectedItems }.disabled(selection.isEmpty)
                    Spacer()
                    ShareLink(items: selectedItems.map(\.transferable)).disabled(selection.isEmpty)
                    Spacer()
                    Button("Delete", systemImage: "trash") { delete(selectedItems) }.disabled(selection.isEmpty)
                }
            }
        }
        .navigationDestination(for: Folder.self) { DriveFolderView(folder: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { upload($0) }
        .quickLookPreview($preview)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let r = renaming { rename(r, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { !moving.isEmpty }, set: { if !$0 { moving = [] } })) {
            FolderPicker(title: "Move \(moving.count) Items") { dest in move(moving, to: dest) }
        }
        .refreshable { await reload() }
        .task(id: folder.id) { await reload() }
    }

    @ViewBuilder private func row(_ item: DriveItem) -> some View {
        Group {
            if let sub = item.folder {
                NavigationLink(value: sub) { FileRow(file: item) }
            } else {
                Button { Task { preview = try? await AtlasAPI.download(item) } } label: { FileRow(file: item) }
                    .foregroundStyle(.primary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete([item]) }
            Button("Move", systemImage: "folder") { moving = [item] }.tint(.indigo)
        }
        .swipeActions(edge: .leading) {
            Button("Favorite", systemImage: item.isFavorite ? "star.slash" : "star") { toggleFavorite(item) }.tint(.yellow)
        }
        .contextMenu { menu(for: item) } preview: { DrivePreview(item: item) }
    }

    @ViewBuilder private func menu(for item: DriveItem) -> some View {
        Section {
            Button("Quick Look", systemImage: "eye") { Task { preview = try? await AtlasAPI.download(item) } }
            ShareLink(item: item.transferable, preview: SharePreview(item.name))
        }
        Section {
            Button("Rename…", systemImage: "pencil") { newName = item.name; renaming = item }
            Button("Move…", systemImage: "folder") { moving = [item] }
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(item) }
            Button(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") { toggleFavorite(item) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { delete([item]) }   // last; matches swipe
    }
    // sorted, selectedItems, reload(), upload(_:), rename, move, delete (registers undo), newFolder … omitted
}
```

Drive root ("Browse"): a `List` with sections "Locations" (Home, Shared), "Favorites", "Tags" (optional) and "Recents"/"Trash" rows — mirroring Files.app's Browse tab; on iPad use it as the sidebar of a `NavigationSplitView`.

Upload progress: show per-file progress inline in the destination folder (row with `ProgressView(value:)` and a cancel button) and an aggregate in the bottom accessory; Live Activity for long multi-file uploads.

### 6.6 Settings with server status dashboard

Structure (Apple Settings look): `Form` grouped; header card (account); sections Backup, Server, Storage, App; destructive Sign Out last; detail screens pushed with `NavigationLink`.

```swift
struct SettingsRoot: View {
    @Environment(ServerModel.self) private var server
    var body: some View {
        NavigationStack {
            Form {
                Section { AccountHeader() }
                Section {
                    NavigationLink { ServerStatusView() } label: {
                        LabeledContent {
                            StatusBadge(status: server.status)
                        } label: {
                            Label { Text("Server Status") } icon: { SettingsIcon("server.rack", .blue) }
                        }
                    }
                    NavigationLink { ConnectionView() } label: { Label { Text("Connection") } icon: { SettingsIcon("network", .indigo) } }
                }
                Section("Backup") {
                    NavigationLink { BackupSettingsView() } label: { Label { Text("Photo Backup") } icon: { SettingsIcon("arrow.up.circle", .green) } }
                }
                Section("Storage") { StorageSummaryRow() }
                Section { Button("Sign Out", role: .destructive) { } }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Settings.app-style colored rounded-square icon (content layer — not glass)
struct SettingsIcon: View {
    let name: String; let color: Color
    init(_ name: String, _ color: Color) { self.name = name; self.color = color }
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)                                    // Settings.app tile size (unverified)
            .background(color.gradient, in: .rect(cornerRadius: 7, style: .continuous))
    }
}

struct StatusBadge: View {
    let status: ServerStatus
    var body: some View {
        Label(status.title, systemImage: status.symbol)                       // "Online" + checkmark.circle.fill
            .labelStyle(.titleAndIcon)
            .foregroundStyle(status.color)                                    // never color alone: symbol + text
            .font(.subheadline)
    }
}
```

**Server status screen** — live metrics, charts, gauges, services, power actions:

```swift
import Charts

struct ServerStatusView: View {
    @Environment(ServerModel.self) private var server
    @State private var range: TimeRange = .fiveMinutes
    @State private var confirmPower: PowerAction?

    var body: some View {
        Form {
            Section {
                MetricRow(title: "CPU", value: server.cpuNow, samples: server.cpu, color: .blue)
                MetricRow(title: "GPU", value: server.gpuNow, samples: server.gpu, color: .purple)
                MetricRow(title: "Memory", value: server.ramNow, samples: server.ram, color: .teal,
                          detail: "\(server.ramUsed.formatted(.byteCount(style: .memory))) of \(server.ramTotal.formatted(.byteCount(style: .memory)))")
                NetworkRow(samples: server.net)
            } header: {
                Text("Live")
            } footer: {
                Text("Updates every 2 seconds.")
            }

            Section("Disks") {
                ForEach(server.disks) { disk in
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(disk.name, value: "\(disk.free.formatted(.byteCount(style: .file))) free")
                        Gauge(value: disk.usedFraction) { EmptyView() }
                            .gaugeStyle(.linearCapacity)
                            .tint(disk.usedFraction > 0.9 ? .red : .orange)
                            .accessibilityLabel("\(disk.name) usage")
                            .accessibilityValue(Text(disk.usedFraction, format: .percent))
                    }
                }
            }

            Section("Services") {
                ForEach(server.services) { svc in
                    LabeledContent {
                        Label(svc.state.title, systemImage: svc.state.symbol).foregroundStyle(svc.state.color).labelStyle(.titleAndIcon)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(svc.name)
                            Text("Up \(svc.uptime.formatted(.units(allowed: [.days, .hours], width: .abbreviated)))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Restart", systemImage: "arrow.clockwise") { server.restart(svc) }.tint(.orange) }
                    .contextMenu { Button("Restart \(svc.name)", systemImage: "arrow.clockwise") { server.restart(svc) } }
                }
            }

            Section {
                Button("Restart Server", systemImage: "arrow.clockwise") { confirmPower = .restart }
                Button("Shut Down Server", systemImage: "power", role: .destructive) { confirmPower = .shutdown }
            } footer: {
                Text("Shutting down stops backups and Drive access until the server is turned on again.")
            }
        }
        .navigationTitle("Server Status")
        .navigationSubtitle(server.lastUpdated.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "")
        .confirmationDialog(Text(confirmPower?.title ?? ""), item: $confirmPower, titleVisibility: .visible) { action in   // iOS 15+ with Xcode 27
            Button(action.confirmTitle, role: .destructive) { Task { await server.perform(action) } }
        }
        .task { await server.poll() }                          // stops when the view disappears
        .refreshable { await server.refreshOnce() }
    }
}

struct MetricRow: View {
    let title: String; let value: Double; let samples: [Sample]; let color: Color
    var detail: String? = nil
    var body: some View {
        NavigationLink { MetricDetailView(title: title, samples: samples, color: color) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    Text(value, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText(value: value))
                        .animation(.smooth, value: value)
                }
                Chart(samples) { s in
                    AreaMark(x: .value("Time", s.date), y: .value(title, s.value))
                        .foregroundStyle(color.opacity(0.18))
                    LineMark(x: .value("Time", s.date), y: .value(title, s.value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartYScale(domain: 0...1)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 44)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text("\(value, format: .percent.precision(.fractionLength(0)))\(detail.map { ", \($0)" } ?? "")"))
    }
}

struct MetricDetailView: View {
    let title: String; let samples: [Sample]; let color: Color
    @State private var selected: Date?
    var body: some View {
        List {
            Section {
                Chart(samples) { s in
                    LineMark(x: .value("Time", s.date), y: .value(title, s.value)).foregroundStyle(color)
                    if let selected, let hit = samples.min(by: { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }) {
                        RuleMark(x: .value("Selected", hit.date))
                            .foregroundStyle(.secondary)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                Text(hit.value, format: .percent).font(.caption.weight(.semibold)).monospacedDigit()
                            }
                    }
                }
                .chartYScale(domain: 0...1)
                .chartYAxis { AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { AxisGridLine(); AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent()) } }
                .chartXSelection(value: $selected)                   // iOS 17+
                .frame(height: 240)
            }
        }
        .navigationTitle(title)
    }
}
```

Dashboard rules recap: fixed 0–100% axes for utilization, dynamic for throughput (with units: "MB/s"); same color per metric everywhere (CPU blue …); headline number + small chart per row; detail on tap; status via symbol + text + color; power actions in their own section at the bottom, confirmations anchored to the button, `Shut Down` destructive red, never prominent; polling stops off-screen; `monospacedDigit` + `numericText` transitions so numbers don't jitter.

Storage summary (donut via `SectorMark`, iOS 17+):

```swift
Chart(categories) { c in
    SectorMark(angle: .value("Size", c.bytes), innerRadius: .ratio(0.62), angularInset: 1.5)
        .foregroundStyle(by: .value("Category", c.name))
        .cornerRadius(3)
}
.chartForegroundStyleScale(["Photos": Color.blue, "Videos": .purple, "Files": .orange, "Other": .gray])
.frame(height: 180)
.accessibilityLabel("Storage by category")
```

### 6.7 Backup settings and progress

- Backup toggle in Settings ▸ Backup; requesting Photos access happens when the user turns it on (pre-permission explanation optional, one button).
- Progress: tab bottom accessory while running; Live Activity for long runs (§4.T1); per-asset badges optional (`arrow.up.circle` small overlay on not-yet-backed-up thumbnails in a "This iPhone" view).
- Background: `BGContinuedProcessingTask` (BackgroundTasks, iOS 26+) for a user-initiated long backup that continues after leaving the app (system shows progress); background `URLSession` for the transfers themselves.
- Copy: "Backing Up 340 of 1,203", "Paused — Waiting for Wi-Fi", "Up to Date · Last backup 5 minutes ago".

### 6.8 iPad and iPhone Duo adaptation

- iPad: `.tabViewStyle(.sidebarAdaptable)` with `TabSection`s (Library: Photos, Favorites, Albums, People; Drive: Browse, Recents, Shared); `NavigationSplitView` inside Drive for folder tree | folder | preview; photo grid columns from `containerRelativeFrame`/size class (6–10); keyboard shortcuts; pointer hover effects; multiple windows (`WindowGroup(for: Asset.ID.self)`).
- iPhone Duo (iOS 27.1+ APIs): standard bars move to the side automatically; grid uses **even** column counts on the inner display; avoid placing critical controls in the fold region; consider `ArrangementView` for Drive (folder list + preview) and Photos (grid + viewer) on the inner display; test poses in Device Hub.

### 6.9 Light/Dark, Dynamic Type, accessibility checklist per screen

- Grid: labels per cell; rotor by date; selection traits; works with Voice Control ("Tap Select", "Tap Delete").
- Viewer: image description; actions via toolbar (not gesture-only); captions for video.
- Drive: rows readable at AX5 (stack metadata under the name; thumbnail can shrink/hide at AX sizes).
- Settings/Status: charts summarized in text; gauge labels; status not color-only.
- All custom glass (scrubber thumb, floating bar): test Reduce Transparency, Increase Contrast, Reduce Motion, Clear vs Tinted glass setting.

---

## 7. "Does this look Apple-made?" checklist and common mistakes

### 7.1 Checklist (run per screen before calling it done)

**Structure**

- [ ] Top-level areas are tabs (Photos, Drive, Settings) + a trailing search tab; nothing else in the tab bar; no actions in the tab bar.
- [ ] Each tab has its own `NavigationStack`; titles are short (< 15 chars), large on root screens, inline on detail screens.
- [ ] Actions live in toolbars (top trailing / bottom bar), grouped by function, ≤ 3 groups, one prominent action max, More (`ellipsis`) menu for the rest.
- [ ] Every context-menu action also exists in visible UI; swipe actions match the top of the context menu.
- [ ] Modals: sheets for scoped tasks (Cancel leading, Done trailing), full-screen for the viewer, confirmation dialogs anchored to their buttons, alerts only for critical things.

**Liquid Glass**

- [ ] All bars/tab bar/search/sheets/menus are **system components** — no custom bar backgrounds, no `.toolbarBackground` color fills, no blur views behind bars.
- [ ] Custom glass only on a few floating functional elements, grouped in one `GlassEffectContainer`; no glass on cells, rows, cards or backgrounds; no glass on glass.
- [ ] Glass over photos/videos uses `.clear` (+ 35% dim if the media is bright); everywhere else `.regular`.
- [ ] Color on glass only for the single primary action / status; bars monochrome over colorful content.
- [ ] Scroll edge effect present wherever content scrolls under floating UI; custom bars use `safeAreaBar`; pinned headers use `.hard`.
- [ ] Custom shapes near screen edges are concentric (`ConcentricRectangle`, capsules), not arbitrary radii.
- [ ] Hidden toolbar items are hidden as items (no empty capsules).

**Foundations**

- [ ] Only system text styles; Dynamic Type works up to AX5 without truncating key content; layouts stack at accessibility sizes.
- [ ] Semantic colors (`.primary/.secondary`, grouped backgrounds in forms); custom colors have light/dark/high-contrast variants; accent used sparingly.
- [ ] Dark Mode correct everywhere; viewer forced dark only.
- [ ] SF Symbols for all icons, correct variants (system picks fill/outline), weights match text; standard symbols for standard actions (share, trash, ellipsis…).
- [ ] Tap targets ≥ 44×44 pt; spacing ~12 pt around bezeled controls.
- [ ] Contrast ≥ 4.5:1 for small text (3:1 large/bold).
- [ ] Every icon-only button has an accessibility label; images described; decorative hidden; status not color-only; charts summarized.
- [ ] Reduce Motion / Reduce Transparency / Increase Contrast / Bold Text tested; custom glass adapts.
- [ ] Haptics only from system controls or the documented `SensoryFeedback` meanings.
- [ ] Copy: title case for buttons/menus/titles/section headers, sentence case for descriptions; verbs on buttons; no "OK" on decisions; empty states say what to do next; errors say how to fix.
- [ ] Launch screen mirrors the first screen (no logo); state restored on relaunch.
- [ ] App icon: layered Icon Composer file with default, dark, clear and tinted appearances.

**Behavior**

- [ ] Instant launch from cache; never a blank screen; determinate progress where possible.
- [ ] Destructive actions are recoverable (Trash, undo) and only irreversible ones get confirmation.
- [ ] Gestures all have visible alternatives (pinch density ↔ View Options menu; swipe delete ↔ Edit/Delete).
- [ ] Permissions requested in context with clear purpose strings.
- [ ] iPad: sidebar-adaptable tabs, split view in Drive, keyboard shortcuts, pointer hover, multiwindow; iPhone Duo/resizing: no fixed widths, even grid columns.

### 7.2 Mistakes that make an app look non-native

| Mistake | Fix |
|---|---|
| Opaque or colored custom navigation/tab bar backgrounds (old `UINavigationBarAppearance` habits) | Delete them; let Liquid Glass + scroll edge effect work |
| Glass cards everywhere / glass list rows / glass behind every label | Glass only for floating functional UI; content uses opaque or standard materials |
| Hand-made floating tab bar (`ZStack` + `HStack` of buttons) | `TabView` with `Tab`; `tabBarMinimizeBehavior`; `tabViewBottomAccessory` |
| Custom search bar component | `.searchable` + `Tab(role: .search)` |
| Search placed in the middle of a screen header as a fake text field | System placement (tab / toolbar / navigationBarDrawer) |
| Brand color tinting every toolbar icon and tab | Monochrome bars; accent only for selection and one primary action |
| Multiple prominent (filled) buttons per screen | One prominent; others `.bordered` / plain / glass |
| Destructive action styled as primary/prominent | `role: .destructive`, never default/prominent; add Cancel |
| Alerts for routine confirmations ("Photo deleted!", "Saved!") | Inline/haptic feedback; reserve alerts for critical issues |
| Alert or custom modal for choices about an action | `confirmationDialog` anchored to the source button |
| ALL-CAPS section headers, custom header fonts | Title-case `Section("Backup")` with system styling |
| Fixed font sizes (`.font(.system(size: 15))`) everywhere | Text styles (`.body`, `.subheadline`…), `@ScaledMetric` for metrics |
| Hard-coded colors (`Color(red:…)`, `Color.white` backgrounds) | Semantic colors; asset colors with all variants |
| Custom back chevrons, custom close buttons with odd icons | System Back; `Button("Close", systemImage: "xmark")` in `.cancellationAction` |
| Non-SF icon sets (Material/FontAwesome) | SF Symbols; custom symbols from SF templates |
| Hamburger menus / side drawers on iPhone | Tab bar; sidebar only on iPad via `sidebarAdaptable` |
| Bottom sheets built from `ZStack` + `offset` drag gestures | `.sheet` + `presentationDetents` |
| Custom toasts/snackbars as primary feedback | System feedback patterns; inline status; Live Activity for long tasks |
| Spinner on a blank screen at launch; splash screen with logo | Cached content immediately, `UILaunchScreen` matching the first screen |
| Custom segmented controls / toggles / sliders | System `Picker(.segmented)`, `Toggle`, `Slider` (they get glass knobs) |
| Hidden or disabled tabs when offline | Keep tabs; show `ContentUnavailableView` with Retry |
| Pinch/swipe-only features | Menu or button equivalent for every gesture |
| Charts with no axes context, color-only series, no VoiceOver | Fixed meaningful domains, labels + symbols, accessibility labels/values |
| Gauges styled like Activity rings | `Gauge` styles; never mimic Activity rings |
| Using iCloud symbols/wording for self-hosted backup | Server/drive symbols and "Atlas Backup" wording |
| Permission prompts at first launch | Ask when the feature is first used, with a clear purpose string |
| In-app light/dark switch | Follow system appearance |
| Bars always visible in the photo viewer; status bar permanently hidden | Tap to toggle chrome; hide status bar only while chrome is hidden |
| Glass controls drawn with `.background(.ultraThinMaterial)` + shadows to imitate Liquid Glass | Real `glassEffect` / `.buttonStyle(.glass)` (iOS 26+) |
| `UIDesignRequiresCompatibility` set to keep the old look | Don't; design for Liquid Glass |

---

## Appendix A. Sources consulted (2026-10-03)

Read today from developer.apple.com (rendered pages via browser and DocC JSON via `https://developer.apple.com/tutorials/data/...`):

- HIG index and all 173 HIG pages (JSON), including: design-principles, designing-for-ios, designing-for-iphone-duo, designing-for-ipados, accessibility, voiceover, app-icons, branding, color, dark-mode, icons, images, layout, materials, motion, playing-haptics, privacy, right-to-left, sf-symbols, typography, writing; launching, loading, searching, settings, modality, feedback, file-management, managing-accounts, onboarding, going-full-screen, drag-and-drop, entering-data, undo-and-redo, charting-data; tab-bars, sidebars, search-fields, toolbars, split-views, tab-views, path-controls, lists-and-tables, collections, boxes, disclosure-controls, labels, buttons, context-menus, edit-menus, menus, pop-up-buttons, pull-down-buttons, activity-views, charts, image-views, text-views, web-views, action-sheets, alerts, page-controls, popovers, sheets, scroll-views, windows, pickers, segmented-controls, sliders, steppers, toggles, text-fields, color-wells, gauges, progress-indicators, rating-indicators, status-bars, gestures, keyboards, pointing-devices, live-activities, widgets, notifications, live-photos, playing-video, maps, generative-ai, icloud.
- Design "What's new": https://developer.apple.com/design/whats-new/
- Liquid Glass overview, Adopting Liquid Glass, Applying Liquid Glass to custom views, Landmarks sample article.
- SwiftUI updates (June 2025, June 2026, September 2026) and UIKit updates pages.
- iOS & iPadOS 27 release notes; developer.apple.com/ios; Xcode "What's new" (Xcode 27).
- DocC symbol pages for ~150 SwiftUI / Charts / PhotosUI / BackgroundTasks symbols (availability + declarations quoted in this file).
- WWDC26 video index and session pages 269 (What's new in SwiftUI), 292 (Design intuitive search experiences), 321 (Dive into lazy stacks and scrolling) — descriptions and chapter lists only; transcripts were not machine-readable.

## Appendix B. Known gaps and unverified items

- **Device screen-size table**: removed from the HIG Layout page in the Sept 2026 rewrite; sizes in §3.5 are from memory `(unverified)`.
- **Standard layout margins (16/20 pt)**, List/Form row heights and section corner radii in iOS 26/27: not stated in current HIG text `(unverified)`.
- **iPhone Duo SwiftUI APIs** (`ArrangementView`, `ReservedRegion`, `onHingeChange`, `toolbarVerticalEdge`, `toolbarVerticalBehavior`, `axisBehavior`, compression behavior) are **iOS 27.1 beta** in DocC — not in the installed iOS 27.0 SDK.
- Multi-item drag container APIs (`dragContainer`, `draggable(containerItemID:)`) show **iOS 27.0** in DocC although Apple's updates page lists them under June 2025.
- Whether `UIDesignRequiresCompatibility` still functions with the 27 SDK `(unverified)`.
- Exact visual result of `.toolbarColorScheme(.dark, ...)` on glass bars, conditional `tabViewBottomAccessory` content, and whether zoom transitions re-read a changed `sourceID` `(unverified — test on device)`.
- `WebView`/`WebPage` live in WebKit for SwiftUI; symbol paths not fetched `(unverified import details)`.
- Settings-style icon tile size (29 pt, 7 pt radius) `(unverified)`.
- SF Symbols names beyond the HIG "standard icons" table (e.g. `server.rack`, `memorychip`, `externaldrive.badge.checkmark`) — verify in the SF Symbols 7/8 app.
- WWDC session transcripts (Meet Liquid Glass, Get to know the new design system, WWDC26 sessions) were not read in full; the doc relies on HIG + documentation text instead.
