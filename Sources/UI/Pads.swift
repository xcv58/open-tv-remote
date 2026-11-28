import SwiftUI

enum PadMode: String, CaseIterable, Identifiable {
    case dpad, keyboard, keypad
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .dpad: "dpad.fill"
        case .keyboard: "keyboard.fill"
        case .keypad: "circle.grid.3x3.fill"
        }
    }

    var title: String {
        switch self {
        case .dpad: "Directional pad"
        case .keyboard: "Keyboard"
        case .keypad: "Number pad"
        }
    }
}

// MARK: - D-pad

struct Wedge: InsettableShape {
    var direction: Angle
    var innerRatio: CGFloat = 0.44
    var gap: Angle = .degrees(2.2)
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let outer = r - insetAmount
        let inner = r * innerRatio + insetAmount
        let start = direction - .degrees(45) + gap
        let end = direction + .degrees(45) - gap
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Wedge {
        var w = self
        w.insetAmount += amount
        return w
    }
}

struct DPadView: View {
    @Environment(AppModel.self) private var model

    private let directions: [(key: RemoteKey, angle: Double, symbol: String)] = [
        (.right, 0, "chevron.right"),
        (.down, 90, "chevron.down"),
        (.left, 180, "chevron.left"),
        (.up, 270, "chevron.up"),
    ]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let iconDistance = radius * (1 + 0.44) / 2
            let arrowSize = min(32, max(14, size * 0.115))
            let okSize = min(36, max(16, size * 0.125))
            ZStack {
                Circle()
                    .fill(Theme.well)
                    .overlay(Circle().strokeBorder(.white.opacity(0.04), lineWidth: 1))
                    .padding(-6)

                ForEach(directions, id: \.angle) { d in
                    KeyCap(shape: Wedge(direction: .degrees(d.angle)), accessibilityLabel: d.key.accessibilityName,
                           repeatAction: model.repeatAction(for: d.key)) {
                        model.press(d.key)
                    } label: {
                        Image(systemName: d.symbol)
                            .font(.system(size: arrowSize, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                            .offset(x: cos(d.angle * .pi / 180) * iconDistance,
                                    y: sin(d.angle * .pi / 180) * iconDistance)
                    }
                }

                KeyCap(shape: Circle(), accessibilityLabel: "OK") {
                    model.press(.select)
                } label: {
                    Text("OK").font(.system(size: okSize, weight: .bold, design: .rounded))
                }
                .frame(width: size * 0.40, height: size * 0.40)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Keyboard

struct PressedKeyboardCharacter: PreferenceKey {
    let text: String
    let bounds: Anchor<CGRect>

    static var defaultValue: Self? { nil }

    static func reduce(value: inout Self?, nextValue: () -> Self?) {
        if let next = nextValue() { value = next }
    }
}

private struct KeyboardCharacterPreview: View {
    private static let height: CGFloat = 44
    private static let keyClearance: CGFloat = 8
    // The D-pad's backing circle extends six points below its frame.
    static let requiredSpacing = height + keyClearance + 6

    let key: PressedKeyboardCharacter

    var body: some View {
        GeometryReader { grid in
            let keyFrame = grid[key.bounds]
            let width = min(54, max(36, keyFrame.width))
            let halfWidth = width / 2
            let x = min(max(keyFrame.midX, halfWidth), grid.size.width - halfWidth)
            Text(key.text)
                .font(.system(size: 29, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.label)
                .frame(width: width, height: Self.height)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 12)
                    shape.fill(Theme.keyTop)
                        .overlay(shape.strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
                        .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
                }
                .position(x: x, y: keyFrame.minY - Self.height / 2 - Self.keyClearance)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct KeyboardPadView: View {
    enum PhoneLayout: Equatable {
        case adaptive, portrait, foldedPortrait, widePortrait, wideLandscape

        var usesPortraitSpacing: Bool { self == .portrait || self == .widePortrait }
        var allowsNumberRow: Bool { self == .widePortrait || self == .wideLandscape }
    }

    enum Layout {
        case stacked
        case phone(PhoneLayout)
        case phoneKeys
        case stackedTablet(controlsSpacing: CGFloat, padSize: CGFloat)
        case tabletKeys
    }

    private static let defaultKeyGap: CGFloat = 6
    private static let maximumKeyHeight: CGFloat = 64
    private static let minimumKeyHeight: CGFloat = 44
    private static let minimumPhoneKeyWidth: CGFloat = 24
    private static let portraitKeyHeight: CGFloat = 52
    private static let portraitGridHeight = 4 * portraitKeyHeight + 3 * defaultKeyGap
    private static let portraitPadSize: CGFloat = 176
    private static let phoneClearHeight: CGFloat = 48
    private static let phoneClearWidth: CGFloat = 60
    private static let phoneClearSideInset: CGFloat = phoneClearWidth + 12
    static let minimumPhoneKeyGridHeight = 4 * minimumKeyHeight + 3 * defaultKeyGap
    static let minimumTabletKeyGridWidth: CGFloat = 10 * 44 + 9 * defaultKeyGap

    private enum Layer { case letters, numbers, symbols }

    @Environment(\.adaptiveKeyboardLayout) private var adaptiveKeyboardLayout
    @Environment(AppModel.self) private var model
    @State private var shifted = false
    @State private var layer: Layer = .letters
    var layout: Layout = .stacked

    private static let digits = "1234567890".map(String.init)
    private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
    private static let legacySymbols = [
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "•"],
        [".", ",", "?", "!", "'", "`", "¥"],
    ]
    private static let punctuation = [".", ",", "?", "!", "'"]
    private static let numbers = [digits, legacySymbols[0], punctuation]
    private static let symbols = [legacySymbols[1], legacySymbols[2] + ["¥"], punctuation + ["`"]]
    private let gap = KeyboardPadView.defaultKeyGap

    var body: some View {
        Group {
            switch layout {
            case .stacked:
                VStack(spacing: 10) {
                    controls
                    keyGrid(tablet: false, inlineEditing: false)
                }
            case .phone(let posture):
                phoneKeyboard(posture)
            case .phoneKeys:
                keyGrid(tablet: false)
            case let .stackedTablet(controlsSpacing, padSize):
                VStack(spacing: controlsSpacing) {
                    TabletKeyboardNavigation(padSize: padSize)
                    keyGrid(tablet: true)
                }
            case .tabletKeys:
                keyGrid(tablet: true)
            }
        }
        #if DEBUG
        .frame(maxWidth: DemoMode.keyboardTestWidth ?? .infinity)
        #endif
    }

    private func phoneKeyboard(_ posture: PhoneLayout) -> some View {
        GeometryReader { viewport in
            let width = viewport.size.width
            let height = viewport.size.height
            let sideBySide = posture == .adaptive && width >= 480 && height < 360
            let isPortrait = posture.usesPortraitSpacing
            let padWidthLimit = max(60, width - 72)
            let compactPadSize = sideBySide ? min(108, max(64, height - Self.phoneClearHeight - 8))
                                            : min(132, padWidthLimit)
            let portraitClearFits = width >= Self.portraitPadSize + 2 * Self.phoneClearSideInset
            let stackedNavigation = (isPortrait && !portraitClearFits) ||
                (posture == .foldedPortrait && width < compactPadSize + 2 * Self.phoneClearSideInset)
            let baseNavigationSpacing: CGFloat = isPortrait ? 22 : 10
            let minimumHeight = sideBySide
                ? max(Self.minimumPhoneKeyGridHeight, compactPadSize + 8 + Self.phoneClearHeight)
                : compactPadSize + (stackedNavigation ? 10 + Self.phoneClearHeight : 0)
                    + baseNavigationSpacing + Self.minimumPhoneKeyGridHeight
            if height < minimumHeight {
                shortPhoneKeyboard(height: height)
            } else {
                let preferredPadSize = portraitClearFits ? Self.portraitPadSize : 150
                let minimumNumberRowHeight = Self.minimumKeyHeight + gap
                let extraHeight = height - minimumHeight
                let spaceForLargerPad = isPortrait ? preferredPadSize - compactPadSize : 0
                let showsNumberRow = posture.allowsNumberRow && extraHeight >= minimumNumberRowHeight + spaceForLargerPad
                let spaceForNumberRow = showsNumberRow ? minimumNumberRowHeight : 0
                let remainingHeight = extraHeight - spaceForNumberRow
                let padSize = isPortrait ? min(preferredPadSize, padWidthLimit, compactPadSize + remainingHeight)
                                         : compactPadSize
                let portraitGridHeight = Self.portraitGridHeight + (showsNumberRow ? Self.portraitKeyHeight + gap : 0)
                // Reserve the preferred key rows before distributing spare portrait height.
                let minimumGridHeight = Self.minimumPhoneKeyGridHeight + spaceForNumberRow
                let preferredSpacingHeight = (padSize - compactPadSize) + (portraitGridHeight - minimumGridHeight)
                let spareHeight = max(0, remainingHeight - preferredSpacingHeight)
                let bottomInset = isPortrait ? min(24, spareHeight / 3) : 0
                let navigationSpacing = baseNavigationSpacing + (isPortrait && !stackedNavigation ? min(40, spareHeight / 3) : 0)
                let spacingWithPreview = max(navigationSpacing, KeyboardCharacterPreview.requiredSpacing)
                let showsPreviews = (isPortrait || posture == .foldedPortrait)
                    && width >= 10 * Self.minimumPhoneKeyWidth + 9 * gap
                    && spareHeight >= bottomInset + spacingWithPreview - baseNavigationSpacing
                let finalSpacing = showsPreviews ? spacingWithPreview : navigationSpacing
                // Give the pad only the room left after the keys and preview have been laid out.
                let extraPadHeight = max(0, spareHeight - bottomInset - (finalSpacing - baseNavigationSpacing))
                let responsivePadSize = phoneDirectionPadSize(posture, width: width, height: height,
                                                              baseline: padSize, extraHeight: extraPadHeight,
                                                              sideBySide: sideBySide, stacked: stackedNavigation)
                phoneKeyboardContent(posture, sideBySide: sideBySide, stackedNavigation: stackedNavigation,
                                     padSize: responsivePadSize, navigationSpacing: finalSpacing,
                                     showsNumberRow: showsNumberRow, showsPreviews: showsPreviews, portraitGridHeight: portraitGridHeight)
                    .padding(.bottom, bottomInset)
            }
        }
        .clipped()
    }

    private func phoneDirectionPadSize(_ posture: PhoneLayout, width: CGFloat, height: CGFloat,
                                       baseline: CGFloat, extraHeight: CGFloat, sideBySide: Bool, stacked: Bool) -> CGFloat {
        if sideBySide {
            let minimumKeyGridWidth = 10 * Self.minimumPhoneKeyWidth + 9 * gap
            return max(baseline, min(176, height - Self.phoneClearHeight - 8, width - minimumKeyGridWidth - 12))
        }

        let widthForPad: CGFloat
        switch posture {
        case .portrait, .foldedPortrait, .widePortrait:
            widthForPad = width - (stacked ? 12 : 2 * Self.phoneClearSideInset)
        case .adaptive, .wideLandscape:
            widthForPad = width - Self.phoneClearWidth - 12
        }
        let cap: CGFloat = posture == .widePortrait ? 256 : 224
        return max(baseline, min(cap, width * 0.60, widthForPad, baseline + extraHeight))
    }

    private func shortPhoneKeyboard(height: CGFloat) -> some View {
        let padSize = min(108, max(64, height))
        let typing = KeyboardSheetButton().accessibilityIdentifier("phoneKeyboardSheet")
        return ViewThatFits {
            HStack(spacing: 12) {
                DPadView().frame(width: padSize, height: padSize)
                phoneClearButton
                typing
            }
            // Fit height at the proposed width so the typing label can wrap.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        DPadView().frame(width: 88, height: 88)
                        phoneClearButton
                    }
                    typing
                }
                typing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func phoneKeyboardContent(_ posture: PhoneLayout, sideBySide: Bool,
                                                   stackedNavigation: Bool, padSize: CGFloat,
                                                   navigationSpacing: CGFloat, showsNumberRow: Bool,
                                                   showsPreviews: Bool, portraitGridHeight: CGFloat) -> some View {
        if sideBySide {
            HStack(spacing: 12) {
                VStack(spacing: 8) {
                    DPadView().frame(width: padSize, height: padSize)
                    phoneClearButton
                }
                keyGrid(tablet: false)
            }
        } else {
            let isPortrait = posture.usesPortraitSpacing
            VStack(spacing: navigationSpacing) {
                phoneKeyboardNavigation(posture, stacked: stackedNavigation, padSize: padSize)
                keyGrid(tablet: false, addsNumberRow: showsNumberRow, showsCharacterPreviews: showsPreviews,
                        keepsNumberRowSpace: isPortrait && showsNumberRow)
                    .frame(maxHeight: isPortrait ? portraitGridHeight : .infinity)
            }
            .frame(maxHeight: .infinity, alignment: isPortrait ? .bottom : .center)
        }
    }

    @ViewBuilder private func phoneKeyboardNavigation(_ posture: PhoneLayout, stacked: Bool, padSize: CGFloat) -> some View {
        let pad = DPadView().frame(width: padSize, height: padSize)
        switch posture {
        case .portrait, .foldedPortrait, .widePortrait:
            if stacked {
                VStack(spacing: 10) {
                    pad
                    phoneClearButton
                }
            } else {
                pad.padding(.horizontal, Self.phoneClearSideInset)
                    .overlay(alignment: .trailing) { phoneClearButton }
            }
        case .adaptive, .wideLandscape:
            HStack(spacing: 12) {
                pad
                phoneClearButton
            }
        }
    }

    private var phoneClearButton: some View {
        KeyboardClearButton().frame(width: Self.phoneClearWidth, height: Self.phoneClearHeight)
    }

    private func rows(numberRow: Bool, inlineEditing: Bool = true) -> [[String]] {
        switch layer {
        case .letters: numberRow ? [Self.digits] + Self.letters : Self.letters
        case .numbers: inlineEditing ? Self.numbers : Self.legacySymbols
        case .symbols: Self.symbols
        }
    }

    private func keyGrid(tablet: Bool, inlineEditing: Bool = true, addsNumberRow: Bool = false,
                         showsCharacterPreviews: Bool = false, keepsNumberRowSpace: Bool = false) -> some View {
        GeometryReader { geo in
            let showsNumberRow = addsNumberRow || !inlineEditing || (tablet && geo.size.width >= Self.minimumTabletKeyGridWidth)
            let rows = self.rows(numberRow: showsNumberRow, inlineEditing: inlineEditing)
            // Use any extra width for spacing once all ten letter keys have 44-point targets.
            let extraWidth = max(0, geo.size.width - Self.minimumTabletKeyGridWidth)
            let keyGap = tablet ? min(9, gap + extraWidth / 9) : gap
            let keyWidth = (geo.size.width - keyGap * 9) / 10
            if inlineEditing && adaptiveKeyboardLayout && keyWidth < (tablet ? 28 : Self.minimumPhoneKeyWidth) {
                narrowKeys(rows)
            } else {
                // Keep the editing row anchored and size all layers using the letter layer's row count.
                let letterLayerRowCount = CGFloat(Self.letters.count + 2)
                let heightForKeys = geo.size.height - (letterLayerRowCount - 1) * keyGap
                let maximumKeyHeight = keepsNumberRowSpace
                    ? max(0, heightForKeys / letterLayerRowCount) : Self.maximumKeyHeight
                fullKeys(rows, width: keyWidth, gap: keyGap, inlineEditing: inlineEditing,
                         showsCharacterPreviews: showsCharacterPreviews, maximumKeyHeight: maximumKeyHeight,
                         alignment: keepsNumberRowSpace ? .bottom : .center)
            }
        }
    }

    @ViewBuilder private func fullKeys(_ rows: [[String]], width: CGFloat, gap: CGFloat, inlineEditing: Bool,
                                       showsCharacterPreviews: Bool, maximumKeyHeight: CGFloat,
                                       alignment: Alignment) -> some View {
        let wide = width * 1.5 + gap / 2
        let editingWidth = inlineEditing ? max(44, wide) : wide
        let grid = VStack(spacing: gap) {
            ForEach(0..<(rows.count - 1), id: \.self) { i in
                HStack(spacing: gap) {
                    characters(rows[i], width: width, showsPreviews: showsCharacterPreviews)
                }
            }
            HStack(spacing: gap) {
                layerModifier(inlineEditing: inlineEditing).frame(width: editingWidth)
                let lastRow = rows[rows.count - 1]
                let innerWidth = (10 * width + 9 * gap - 2 * editingWidth - 2 * gap - CGFloat(lastRow.count - 1) * gap)
                    / CGFloat(lastRow.count)
                HStack(spacing: gap) {
                    characters(lastRow, width: min(width, innerWidth), showsPreviews: showsCharacterPreviews)
                }
                .frame(maxWidth: .infinity)
                deleteButton.frame(width: editingWidth)
            }
            HStack(spacing: gap) {
                symbolsButton.frame(width: editingWidth)
                spaceButton
                if inlineEditing { returnButton.frame(width: editingWidth) }
            }
        }
        .frame(maxHeight: CGFloat(rows.count + 1) * maximumKeyHeight + CGFloat(rows.count) * gap)
        Group {
            if showsCharacterPreviews {
                grid.overlayPreferenceValue(PressedKeyboardCharacter.self) { key in
                    if let key { KeyboardCharacterPreview(key: key) }
                }
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func narrowKeys(_ rows: [[String]]) -> some View {
        VStack(spacing: gap) {
            ScrollView { narrowKeyGrid(rows.flatMap { $0 }) }
            HStack(spacing: gap) {
                layerModifier(inlineEditing: true).frame(width: 44, height: 44)
                Spacer(minLength: 0)
                deleteButton.frame(width: 44, height: 44)
            }
            HStack(spacing: gap) {
                symbolsButton.frame(width: 44)
                spaceButton
                returnButton.frame(width: 44)
            }
            .frame(height: 44)
        }
    }

    private func narrowKeyGrid(_ keys: [String]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 44), spacing: gap)]
        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(keys, id: \.self) { key in
                let text = shifted && layer == .letters ? key.uppercased() : key
                Button {
                    Haptics.tap()
                    typeCharacter(text)
                } label: {
                    Text(text)
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(KeySurface(shape: keyShape))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A small D-pad for moving through results, with clear, delete and Return beside it.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                KeyboardClearButton()
                    .frame(minWidth: 44)
                    .frame(height: 52)
                    .frame(maxWidth: .infinity, maxHeight: 114, alignment: .top)
                DPadView().frame(width: 150, height: 150)
                VStack(spacing: 10) {
                    deleteButton.frame(height: 52)
                    returnButton.frame(height: 52)
                }
                .frame(minWidth: 44, maxWidth: .infinity)
            }
            .frame(height: 150)

            VStack(spacing: 8) {
                DPadView().frame(width: 108, height: 108)
                HStack(spacing: 6) {
                    KeyboardClearButton()
                    deleteButton
                    returnButton
                }
                .frame(height: 44)
            }
        }
    }

    private var deleteButton: some View {
        let deviceID = model.currentID
        let repeatDelete: (RemoteInputRequest) async -> Void = { request in
            guard request.canDispatch, model.currentID == deviceID else {
                request.cancel()
                return
            }
            await model.repeatTypeDelete(request: request)
        }
        return KeyCap(shape: keyShape, enabled: model.typesLive ? model.canSendTVDelete : !model.typed.isEmpty,
                      accessibilityLabel: "Delete", repeatAction: repeatDelete,
                      repeatRequiresCurrentConnection: model.typesLive) {
            model.typeDelete()
        } label: {
            Image(systemName: "delete.left").font(.system(size: 16, weight: .semibold))
        }
    }

    private var returnButton: some View {
        KeyCap(shape: keyShape, accessibilityLabel: "Return") { model.typeReturn() } label: {
            Image(systemName: "return").font(.system(size: 16, weight: .semibold))
        }
    }

    private var keyShape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    private func characters(_ row: [String], width: CGFloat, showsPreviews: Bool) -> some View {
        ForEach(row, id: \.self) { c in
            let text = shifted && layer == .letters ? c.uppercased() : c
            KeyCap(shape: keyShape, accessibilityLabel: text,
                   showsCharacterPreview: showsPreviews) {
                typeCharacter(text)
            } label: {
                Text(text)
            }
            .font(.system(size: 19, weight: .medium, design: .rounded))
            .frame(width: width)
        }
    }

    private func typeCharacter(_ text: String) {
        model.type(text)
        shifted = false
    }

    private var shiftButton: some View {
        KeyCap(shape: keyShape, accessibilityLabel: "Shift") { shifted.toggle() } label: {
            Image(systemName: shifted ? "shift.fill" : "shift").font(.system(size: 16, weight: .semibold))
        }
    }

    private var symbolsButton: some View {
        KeyCap(shape: keyShape, accessibilityLabel: layer == .letters ? "Numbers and symbols" : "Letters") {
            layer = layer == .letters ? .numbers : .letters
        } label: {
            Text(layer == .letters ? "123" : "ABC").font(.system(size: 15, weight: .semibold, design: .rounded))
        }
    }

    @ViewBuilder private func layerModifier(inlineEditing: Bool) -> some View {
        if layer == .letters {
            shiftButton
        } else if inlineEditing {
            KeyCap(shape: keyShape, accessibilityLabel: layer == .numbers ? "More symbols" : "Numbers and punctuation") {
                layer = layer == .numbers ? .symbols : .numbers
            } label: {
                Text(layer == .numbers ? "#+=" : "123").font(.system(size: 15, weight: .semibold, design: .rounded))
            }
        } else {
            Color.clear
        }
    }

    private var spaceButton: some View {
        KeyCap(shape: keyShape, accessibilityLabel: "Space") { model.type(" ") } label: {
            Text("space").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondary)
        }
    }
}

struct KeyboardClearButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        KeyCap(shape: RoundedRectangle(cornerRadius: 8, style: .continuous), accessibilityLabel: "Clear") {
            model.typeClear()
        } label: {
            Text("Clear").font(.system(size: 15, weight: .semibold, design: .rounded))
        }
    }
}

struct TabletKeyboardNavigation: View {
    static let minimumPadSize: CGFloat = 150
    private static let spacing: CGFloat = 10
    private static let clearHeight: CGFloat = 48
    static let editingHeight = spacing + clearHeight
    let padSize: CGFloat

    var body: some View {
        VStack(spacing: Self.spacing) {
            DPadView().frame(width: padSize, height: padSize)
            KeyboardClearButton().frame(width: 64, height: Self.clearHeight)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Keypad

struct KeypadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Rows stretch to fill whatever height the pad gets.
        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(1...3, id: \.self) { col in digit(row * 3 + col) }
                }
            }
            GridRow {
                KeyCap(accessibilityLabel: "Back") { model.press(.back) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 18, weight: .semibold))
                }
                digit(0)
                KeyCap(enabled: model.canSendTVDelete, accessibilityLabel: "Delete",
                       repeatAction: model.repeatAction(for: .backspace)) {
                    model.press(.backspace)
                } label: {
                    Image(systemName: "delete.left").font(.system(size: 18, weight: .semibold))
                }
            }
        }
    }

    private func digit(_ n: Int) -> some View {
        KeyCap(enabled: model.supports(.digit(n)), accessibilityLabel: "\(n)") { model.press(.digit(n)) } label: {
            Text("\(n)").font(.system(size: 24, weight: .semibold, design: .rounded))
        }
    }
}
