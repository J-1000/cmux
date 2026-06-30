import AppKit
import CmuxFoundation
import CmuxTerminalCore
import SwiftUI

@MainActor
protocol FilePreviewTextEditingPanel: AnyObject {
    var textContent: String { get }

    func attachTextView(_ textView: NSTextView)
    func retryPendingFocus()
    func updateTextContent(_ nextContent: String)
    @discardableResult
    func saveTextContent() -> Task<Void, Never>?
}

struct GhosttyBackgroundImageBackdrop: NSViewRepresentable {
    let settings: GhosttyBackgroundImageSettings
    let backgroundOpacity: Double

    func makeNSView(context: Context) -> GhosttyBackgroundImageBackdropView {
        let view = GhosttyBackgroundImageBackdropView()
        view.update(settings: settings, backgroundOpacity: backgroundOpacity)
        return view
    }

    func updateNSView(_ view: GhosttyBackgroundImageBackdropView, context: Context) {
        view.update(settings: settings, backgroundOpacity: backgroundOpacity)
    }
}

final class GhosttyBackgroundImageBackdropView: NSView {
    private var settings: GhosttyBackgroundImageSettings?
    private var backgroundOpacity: Double = 1
    private var loadedImagePath: String?
    private var image: NSImage?

    override var isOpaque: Bool { false }

    func update(settings nextSettings: GhosttyBackgroundImageSettings, backgroundOpacity nextBackgroundOpacity: Double) {
        let shouldReloadImage = loadedImagePath != nextSettings.path
        let shouldRedraw = settings != nextSettings ||
            abs(backgroundOpacity - nextBackgroundOpacity) > 0.0001

        settings = nextSettings
        backgroundOpacity = nextBackgroundOpacity

        if shouldReloadImage {
            loadedImagePath = nextSettings.path
            image = NSImage(contentsOfFile: nextSettings.path)
        }
        if shouldReloadImage || shouldRedraw {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let settings,
              let image,
              bounds.width > 0,
              bounds.height > 0 else { return }

        let opacity = Self.clampedOpacity(backgroundOpacity * settings.opacity)
        guard opacity > 0 else { return }

        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let tileSize = Self.tileSize(for: settings.fit, imageSize: imageSize, bounds: bounds)
        guard tileSize.width > 0, tileSize.height > 0 else { return }

        if settings.repeats {
            drawRepeated(image: image, tileSize: tileSize, opacity: opacity, position: settings.position)
        } else {
            let destination = Self.destinationRect(for: tileSize, in: bounds, position: settings.position)
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: opacity)
        }
    }

    private func drawRepeated(
        image: NSImage,
        tileSize: NSSize,
        opacity: CGFloat,
        position: GhosttyBackgroundImagePosition
    ) {
        let anchor = Self.destinationRect(for: tileSize, in: bounds, position: position)
        var startX = anchor.minX
        var startY = anchor.minY
        while startX > bounds.minX {
            startX -= tileSize.width
        }
        while startY > bounds.minY {
            startY -= tileSize.height
        }

        var y = startY
        while y < bounds.maxY {
            var x = startX
            while x < bounds.maxX {
                let destination = NSRect(origin: NSPoint(x: x, y: y), size: tileSize)
                image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: opacity)
                x += tileSize.width
            }
            y += tileSize.height
        }
    }

    private static func clampedOpacity(_ opacity: Double) -> CGFloat {
        CGFloat(max(0, min(1, opacity)))
    }

    private static func tileSize(
        for fit: GhosttyBackgroundImageFit,
        imageSize: NSSize,
        bounds: NSRect
    ) -> NSSize {
        switch fit {
        case .contain:
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        case .cover:
            let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
            return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        case .stretch:
            return bounds.size
        case .none:
            return imageSize
        }
    }

    private static func destinationRect(
        for size: NSSize,
        in bounds: NSRect,
        position: GhosttyBackgroundImagePosition
    ) -> NSRect {
        let x: CGFloat
        switch position {
        case .topLeft, .centerLeft, .bottomLeft:
            x = bounds.minX
        case .topCenter, .center, .bottomCenter:
            x = bounds.midX - size.width / 2
        case .topRight, .centerRight, .bottomRight:
            x = bounds.maxX - size.width
        }

        let y: CGFloat
        switch position {
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = bounds.minY
        case .centerLeft, .center, .centerRight:
            y = bounds.midY - size.height / 2
        case .topLeft, .topCenter, .topRight:
            y = bounds.maxY - size.height
        }

        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

struct FilePreviewTextEditor<PanelModel>: NSViewRepresentable where PanelModel: ObservableObject & FilePreviewTextEditingPanel {
    @ObservedObject var panel: PanelModel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool
    /// Whether long lines soft-wrap at the editor's right edge. Sourced from
    /// the persisted `fileEditor.wordWrap` setting; updates apply live.
    let wordWrap: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.isHidden = !isVisibleInUI
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = drawsBackground

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.panel = panel
        textView.delegate = context.coordinator
        textView.drawsBackground = drawsBackground
        textView.string = panel.textContent
        panel.attachTextView(textView)

        scrollView.documentView = textView
        textView.applyFilePreviewWordWrap(wordWrap, scrollView: scrollView)
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.panel = panel
        scrollView.isHidden = !isVisibleInUI
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        textView.panel = panel
        textView.applyFilePreviewTextEditorInsets()
        textView.applyFilePreviewWordWrap(wordWrap, scrollView: scrollView)
        panel.attachTextView(textView)
        guard textView.string != panel.textContent else { return }
        context.coordinator.isApplyingPanelUpdate = true
        textView.string = panel.textContent
        context.coordinator.isApplyingPanelUpdate = false
    }

    static func applyTheme(
        to scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = drawsBackground ? backgroundColor : .clear
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.drawsBackground = drawsBackground
            textView.backgroundColor = resolvedBackgroundColor
            textView.textColor = foregroundColor
            textView.insertionPointColor = foregroundColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: PanelModel
        var isApplyingPanelUpdate = false

        init(panel: PanelModel) {
            self.panel = panel
        }

        deinit {}

        func textDidChange(_ notification: Notification) {
            guard !isApplyingPanelUpdate,
                  let textView = notification.object as? NSTextView else { return }
            panel.updateTextContent(textView.string)
        }
    }
}

enum FilePreviewTextEditorLayout {
    static let textContainerInset = NSSize(width: 12, height: 10)
    static let lineFragmentPadding: CGFloat = 0
}

extension SavingTextView {
    /// Builds the File Preview text view configured for large plain-text files.
    ///
    /// File Preview opens files up to `FilePreviewPanel.maximumLoadedTextBytes` (16 MB), which can
    /// be hundreds of thousands of lines. Selection responsiveness on that content is the reason
    /// this configuration is centralized; see `manaflow-ai/cmux#4576`.
    static func makeFilePreviewTextView() -> SavingTextView {
        // Build an EXPLICIT TextKit 1 stack so this view is never TextKit 2.
        //
        // A default `NSTextView()` is TextKit 2: selection/hit-testing then runs through
        // `NSTextSelectionNavigation`, whose work is O(N) in line-fragment count, so clicking or
        // drag-selecting in a large document pegs the main thread inside AppKit's modal
        // mouse-tracking loop and freezes the whole app (`manaflow-ai/cmux#4576`, `#5255`).
        //
        // Merely *reading* `.layoutManager` afterward — the previous mitigation — only drops the
        // view to TextKit 2 *compatibility* mode: `textLayoutManager` stays non-nil and the slow
        // selection path remains active (confirmed by live `sample` captures of the hung process).
        // Constructing the view from an `NSTextStorage` / `NSLayoutManager` / `NSTextContainer`
        // stack is the only way to guarantee `textLayoutManager == nil`, i.e. a pure TextKit 1 view
        // whose hit-testing uses `NSLayoutManager` (O(log N) with non-contiguous layout).
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Lazy glyph layout so multi-hundred-thousand-line documents still open instantly.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        // No-wrap baseline; `applyFilePreviewWordWrap(_:scrollView:)` flips this live per the
        // `fileEditor.wordWrap` setting.
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = SavingTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.applyCurrentPreviewFont()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.applyFilePreviewTextEditorInsets()
        return textView
    }
}

extension NSTextView {
    /// Configures the text view and its scroll view for soft line wrapping
    /// (`wrap == true`) or the no-wrap baseline with a horizontal scroller
    /// (`wrap == false`). Idempotent, so it is safe to call on every SwiftUI
    /// update; toggling the `fileEditor.wordWrap` setting reflows open editors.
    func applyFilePreviewWordWrap(_ wrap: Bool, scrollView: NSScrollView) {
        guard let textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        isHorizontallyResizable = !wrap
        if wrap {
            textContainer.widthTracksTextView = true
            // `widthTracksTextView` keeps the container pinned to the text view
            // width, so wrapping is correct even before the scroll view is laid
            // out. Only snap the frame/container to a real measured width to
            // avoid collapsing to a zero-width container during `makeNSView`,
            // before the clip view has a size; `updateNSView` re-runs once laid
            // out and reflows.
            let visibleWidth = scrollView.contentSize.width
            if visibleWidth > 0 {
                textContainer.size = NSSize(width: visibleWidth, height: .greatestFiniteMagnitude)
                setFrameSize(NSSize(width: visibleWidth, height: frame.height))
            }
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    func applyFilePreviewTextEditorInsets() {
        let targetInset = FilePreviewTextEditorLayout.textContainerInset
        if textContainerInset.width != targetInset.width || textContainerInset.height != targetInset.height {
            textContainerInset = targetInset
        }
        if textContainer?.lineFragmentPadding != FilePreviewTextEditorLayout.lineFragmentPadding {
            textContainer?.lineFragmentPadding = FilePreviewTextEditorLayout.lineFragmentPadding
        }
    }
}

final class SavingTextView: NSTextView {
    private static let defaultPreviewFontSize: CGFloat = 13
    private static let minimumPreviewFontSize: CGFloat = 8
    private static let maximumPreviewFontSize: CGFloat = 36

    weak var panel: (any FilePreviewTextEditingPanel)?
    private var previewFontSize: CGFloat = 13
    private var pendingSaveShortcutChordPrefix: ShortcutStroke?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        installFontMagnificationObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installFontMagnificationObserver()
    }

    deinit {}

    private func installFontMagnificationObserver() {
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyCurrentPreviewFont()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFilePreviewTextEditorInsets()
        panel?.retryPendingFocus()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        guard let shouldSave = saveShortcutMatch(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        if shouldSave {
            panel?.saveTextContent()
        }
        return true
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor.isFinite, factor > 0 else { return }
        adjustPreviewFontSize(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard FilePreviewInteraction.hasZoomModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        adjustPreviewFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
    }

    override func smartMagnify(with event: NSEvent) {
        if previewFontSize == Self.defaultPreviewFontSize {
            setPreviewFontSize(18)
        } else {
            setPreviewFontSize(Self.defaultPreviewFontSize)
        }
    }

    private func adjustPreviewFontSize(by factor: CGFloat) {
        setPreviewFontSize(previewFontSize * factor)
    }

    private func setPreviewFontSize(_ nextFontSize: CGFloat) {
        let clamped = min(max(nextFontSize, Self.minimumPreviewFontSize), Self.maximumPreviewFontSize)
        guard clamped.isFinite else { return }
        previewFontSize = clamped
        applyCurrentPreviewFont()
    }

    func applyCurrentPreviewFont() {
        let nextFont = GlobalFontMagnification.monospacedSystemFont(ofSize: previewFontSize, weight: .regular)
        font = nextFont
        typingAttributes[.font] = nextFont
    }

    private func saveShortcutMatch(for event: NSEvent) -> Bool? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingSaveShortcutChordPrefix = nil
            return shortcut.matches(event: event) ? true : nil
        }

        if let pendingPrefix = pendingSaveShortcutChordPrefix {
            pendingSaveShortcutChordPrefix = nil
            guard pendingPrefix == shortcut.firstStroke,
                  let secondStroke = shortcut.secondStroke else {
                return nil
            }
            return secondStroke.matches(event: event) ? true : nil
        }

        if shortcut.firstStroke.matches(event: event) {
            pendingSaveShortcutChordPrefix = shortcut.firstStroke
            return false
        }
        return nil
    }
}
