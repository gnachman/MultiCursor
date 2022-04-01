//  MultiCursorTextView.swift
//  MultiCursor
//
//  Created by George Nachman on 3/30/22.
//

import AppKit

fileprivate struct Drag {
    let start: NSPoint
    var end: NSPoint?

    var rect: NSRect? {
        guard let end = end else {
            return nil
        }
        return NSRect(x: min(start.x, end.x),
                      y: min(start.y, end.y),
                      width: abs(end.x - start.x),
                      height: abs(end.y - start.y))
    }
    init(_ start: NSPoint) {
        self.start = start
    }
}


@objc
class MultiCursorTextView: NSTextView {
    static var logger = MultiCursorTextViewLogging()
    private func DLog(_ messageBlock: @autoclosure () -> String,
                      file: String = #file,
                      line: Int = #line,
                      function: String = #function) {
        let message = messageBlock()
        Self.logger.log("\(file):\(line) \(function): \(message)")
    }

    private var optionDrag: Drag? = nil
    private var savedInsertionPointColor: NSColor? = nil
    var caretVisible = true  // true when blinking on, false when blinking off
    private var timer: Timer? = nil
    private var _multiCursorSelectedRanges: [NSRange]? = nil {
        willSet {
            redrawCursors()
        }
        didSet {
            if savedInsertionPointColor == nil && _multiCursorSelectedRanges != nil {
                // Just got ranges
                savedInsertionPointColor = insertionPointColor
                super.insertionPointColor = .clear
                caretVisible = true
                scheduleBlinkTimer(false)
                DLog("insertionPointColor <- .clear, savedInsertionPointColor <- \(String(describing: savedInsertionPointColor))")
            } else if let savedInsertionPointColor = savedInsertionPointColor, _multiCursorSelectedRanges == nil {
                // Just lost ranges
                DLog("insertionPointColor <- \(savedInsertionPointColor), savedInsertionPointColor <- nil")
                super.insertionPointColor = savedInsertionPointColor
                self.savedInsertionPointColor = nil
            }
            redrawCursors()
        }
    }
    var multiCursorSelectedRanges: [NSRange] {
        if let ranges = _multiCursorSelectedRanges {
            return ranges
        }
        return selectedRanges.map { $0.rangeValue }
    }
    private var settingMultiCursorSelectedRanges = false
    private let tabStop = 4

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

// MARK: - Drawing
extension MultiCursorTextView {
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
    }

    private func redrawCursors() {
        for rect in multiCursorRects {
            DLog("Set needs display in \(rect)")
            setNeedsDisplay(rect, avoidAdditionalLayout: true)
        }
    }

    private var caretOnTime: TimeInterval {
        let ud = UserDefaults.standard.double(forKey: "NSTextInsertionPointBlinkPeriodOn")
        if ud == 0 {
            return 0.56
        }
        return ud
    }

    private var caretOffTime: TimeInterval {
        let ud = UserDefaults.standard.double(forKey: "NSTextInsertionPointBlinkPeriodOff")
        if ud == 0 {
            return 0.56
        }
        return ud
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        if restartFlag && _multiCursorSelectedRanges != nil {
            timer?.invalidate()
            caretVisible = true
            redrawCursors()
            scheduleBlinkTimer(false)
        }
    }
    private func scheduleBlinkTimer(_ visible: Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: visible ? caretOffTime : caretOnTime, repeats: false) { [weak self] _ in
            guard let self = self else {
                return
            }
            if self._multiCursorSelectedRanges == nil {
                return
            }
            self.caretVisible = visible
            self.redrawCursors()
            self.scheduleBlinkTimer(!visible)
        }
    }

    override var insertionPointColor: NSColor {
        get {
            return super.insertionPointColor
        }
        set {
            if _multiCursorSelectedRanges == nil {
                super.insertionPointColor = newValue
            } else {
                savedInsertionPointColor = newValue
            }
        }
    }

    var multiCursorRects: [NSRect] {
        return _multiCursorSelectedRanges?.compactMap { range in
            if range.length > 0 {
                return nil
            }
            if var rect = rect(for: NSRange(location: range.location, length: 0)) {
                rect.size.width = 1
                return rect.retinaRound(self.window?.backingScaleFactor)
            }
            return nil
        } ?? []
    }

    override func draw(_ dirtyRect: NSRect) {
        DLog("draw \(dirtyRect)")
        super.draw(dirtyRect)

        if !caretVisible {
            return
        }
        (savedInsertionPointColor ?? insertionPointColor).set()
        for rect in multiCursorRects {
            var temp = rect
            temp.size.width = 1
            temp.fill()
        }
    }
}

// MARK: - Mouse
extension MultiCursorTextView {
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        optionDrag = Drag(point)
        updateSelectedRanges(optionDrag!)
    }

    override func mouseDragged(with event: NSEvent) {
        if optionDrag != nil {
            let point = convert(event.locationInWindow, from: nil)
            DLog("Drag to \(point)")
            optionDrag?.end = point
            updateSelectedRanges(optionDrag!)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if optionDrag != nil {
            DLog("Finish drag at \(String(describing: optionDrag?.end))")
            optionDrag = nil
            return
        }
        super.mouseUp(with: event)
    }
}

// MARK: - Utilities
extension MultiCursorTextView {
    private func enumerateLines<T>(in range: NSRange, closure: (CGRect) throws -> T) rethrows -> [T] {
        guard let layoutManager = layoutManager else {
            return []
        }
        DLog("Enumerate lines in \(range)")
        var glyphCount = 0
        var result = [T]()
        while glyphCount < range.length {
            var lineRange = NSRange()
            let rect = layoutManager.lineFragmentRect(forGlyphAt: range.location + glyphCount,
                                                      effectiveRange: &lineRange)
            DLog("For glyph at \(range.location + glyphCount) rect is \(rect) and lineRange is \(lineRange)")
            result.append(try closure(rect))
            glyphCount += lineRange.length
        }
        return result
    }

    private func updateSelectedRanges(_ drag: Drag) {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer,
              let rect = drag.rect?.withPositiveWidth else {
            DLog("Missing layout manager or text container")
            safelySetSelectedRanges([])
            return
        }
        DLog("updateSelectedRanges. rect=\(rect)")
        let range = layoutManager.glyphRange(forBoundingRect: rect,
                                             in: textContainer)
        DLog("updateSelectedRanges: range=\(range)")
        if range.location == NSNotFound {
            safelySetSelectedRanges([])
            return
        }
        let ranges = split(range, in: rect)
        DLog("updateSelectedRanges: Set selected ranges to \(ranges)")
        safelySetSelectedRanges(ranges)
    }

    private func safelySetSelectedRanges(_ ranges: [NSRange]) {
        if ranges.isEmpty {
            _multiCursorSelectedRanges = nil
            selectedRanges = [NSValue(range: selectedRange())]
            return
        }
        if ranges.count == 1 {
            _multiCursorSelectedRanges = nil
        } else {
            _multiCursorSelectedRanges = ranges
        }
        mutate {
            selectedRanges = ranges.map { NSValue(range: $0) }
        }
        DLog("Selected ranges is now \(multiCursorSelectedRanges)")
    }

    private func split(_ range: NSRange, in containingRect: NSRect) -> [NSRange] {
        DLog("split \(range)")
        let ranges = enumerateLines(in: range) { rect -> NSRange in
            var effectiveRect = rect.intersection(containingRect)
            effectiveRect.size.height = 1
            DLog("split: Effective rect for \(rect) is \(effectiveRect)")
            let value = self.range(for: effectiveRect)!
            DLog("split: The range for \(effectiveRect) is \(value)")
            return value
        }
        return ranges
    }

    private func overflowingGlyphIndex(for point: NSPoint, in textContainer: NSTextContainer) -> Int {
        let i = layoutManager!.glyphIndex(for: point, in: textContainer)
        if i + 1 < layoutManager!.numberOfGlyphs {
            return i
        }
        let bounds = layoutManager!.boundingRect(forGlyphRange: NSRange(location: i, length: 1), in: textContainer)
        if bounds.contains(point) {
            return i
        }
        return layoutManager!.numberOfGlyphs
    }

    private func range(for rect: NSRect) -> NSRange? {
        guard let textContainer = textContainer else {
            return nil
        }
        let modifiedRect = NSOffsetRect(rect, -textContainerOrigin.x, -textContainerOrigin.y)
        let start = overflowingGlyphIndex(for: modifiedRect.origin, in: textContainer)
        let end = overflowingGlyphIndex(for: modifiedRect.maxPointWithinRect, in: textContainer)
        return NSRange(from: start, to: end)
    }

    private func rect(for range: NSRange) -> NSRect? {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return nil
        }
        let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer)
        return NSOffsetRect(rect, textContainerOrigin.x, textContainerOrigin.y)
    }

    private func modifyRanges(_ closure: (NSRange) -> (NSRange?)) {
        guard let ranges = _multiCursorSelectedRanges else {
            return
        }
        let mapped = ranges.compactMap {
            closure($0)
        }
        let uniqueRanges = mapped.uniq
        let coalesced = uniqueRanges.reduce(into: [NSRange]()) { partialResult, range in
            guard let last = partialResult.last else {
                partialResult.append(range)
                return
            }
            guard last.intersection(range) != nil else {
                partialResult.append(range)
                return
            }
            partialResult.removeLast()
            partialResult.append(NSRange(from: last.location, to: range.upperBound))
        }
        safelySetSelectedRanges(coalesced)
    }

    private func moveLeft(by: NSString.EnumerationOptions) {
        modifyRanges { glyphRange in
            var replacementRange: NSRange? = nil
            let prefixRange = NSRange(from: 0, to: glyphRange.location)
            let nsstring = textStorage!.string as NSString
            nsstring.enumerateSubstrings(in: prefixRange,
                                         options: [by, .reverse]) { maybeString, wordRange, enclosingRange, stop in
                replacementRange = NSRange(location: wordRange.location, length: 0)
                stop.pointee = true
            }
            return replacementRange
        }
    }

    private func moveLeftAndModifySelection(by: NSString.EnumerationOptions) {
        modifyRanges { glyphRange in
            var replacementRange: NSRange? = nil
            let prefixRange = NSRange(from: 0, to: glyphRange.location)
            let nsstring = textStorage!.string as NSString
            nsstring.enumerateSubstrings(in: prefixRange,
                                         options: [by, .reverse]) { maybeString, wordRange, enclosingRange, stop in
                replacementRange = NSRange(from: wordRange.location, to: glyphRange.upperBound)
                stop.pointee = true
            }
            return replacementRange
        }
    }

    private func moveRight(by: NSString.EnumerationOptions) {
        let numberOfCharacters = textStorage!.string.utf16.count
        modifyRanges { glyphRange in
            let characterRange = self.layoutManager!.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var replacementRange: NSRange? = nil
            let suffixRange = NSRange(from: NSMaxRange(characterRange),
                                      to: numberOfCharacters)
            let nsstring = textStorage!.string as NSString
            nsstring.enumerateSubstrings(in: suffixRange,
                                         options: by) { maybeString, wordRange, enclosingRange, stop in
                replacementRange = NSMakeRange(NSMaxRange(wordRange), 0)
                stop.pointee = true
            }
            return replacementRange
        }
    }

    private func moveRightAndModifySelection(by: NSString.EnumerationOptions) {
        let numberOfCharacters = textStorage!.string.utf16.count
        modifyRanges { glyphRange in
            let characterRange = self.layoutManager!.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var replacementRange: NSRange? = nil
            let suffixRange = NSRange(from: NSMaxRange(characterRange),
                                      to: numberOfCharacters)
            let nsstring = textStorage!.string as NSString
            nsstring.enumerateSubstrings(in: suffixRange,
                                         options: by) { maybeString, wordRange, enclosingRange, stop in
                replacementRange = NSRange(from: glyphRange.location, to: wordRange.upperBound)
                stop.pointee = true
            }
            return replacementRange
        }
    }

    private func underflowingLineFragmentRect(forGlyphAt glyphIndex: Int,
                                              effectiveRange effectiveGlyphRange: NSRangePointer?) -> NSRect {
        let location: Int
        if glyphIndex >= layoutManager!.numberOfGlyphs && layoutManager!.numberOfGlyphs > 0 {
            location = layoutManager!.numberOfGlyphs - 1
        } else {
            location = glyphIndex
        }
        return layoutManager!.lineFragmentRect(forGlyphAt: location, effectiveRange: effectiveGlyphRange)
    }

    private func undoable<T>(_ closure: () throws -> T) rethrows -> T {
        if let ranges = _multiCursorSelectedRanges {
            undoManager?.beginUndoGrouping()
            undoManager?.registerUndo(withTarget: self, handler: { textView in
                textView.safelySetSelectedRanges(ranges)
            })
            defer { undoManager?.endUndoGrouping()}
            let result = try closure()
            return result
        }
        return try closure()
    }

    private func paragraphStartIndexes() -> [Int] {
        let ranges = _multiCursorSelectedRanges ?? selectedRanges.map { $0.rangeValue }
        return ranges.flatMap {
            glyphIndexesOfStartOfParagraphsContainingGlyphIndexRange($0)
        }.sorted().uniq
    }

    private func glyphIndexesOfStartOfParagraphsContainingGlyphIndexRange(_ range: NSRange) -> [Int] {
        let nsstring = textStorage!.string as NSString
        var result = [Int]()
        nsstring.enumerateSubstrings(in: NSRange(from: 0, to: range.upperBound),
                                     options: [.byParagraphs, .reverse]) { maybeString, paragraphRange, enclosingRange, stop in
            result.append(paragraphRange.location)
            stop.pointee = ObjCBool(paragraphRange.location <= range.location)
        }
        return result
    }

    private func glyphIndexOfStartOfParagraphContainingGlyphIndex(_ index: Int) -> Int {
        let nsstring = textStorage!.string as NSString
        var result: Int = index
        nsstring.enumerateSubstrings(in: NSRange(location: 0, length: min(nsstring.length, index + 1)),
                                     options: [.byParagraphs, .reverse]) { maybeString, paragraphRange, enclosingRange, stop in
            result = paragraphRange.location
            stop.pointee = true
        }
        return result
    }

    private func safelyInsert(_ string: String, at glyphIndex: Int) {
        let charIndex = layoutManager!.characterIndexForGlyph(at: glyphIndex)
        settingMultiCursorSelectedRanges = true
        multiCursorReplaceCharacters(in: NSRange(location: charIndex, length: 0), with: string)
        settingMultiCursorSelectedRanges = false
        let length = (string as NSString).length
        if let ranges = _multiCursorSelectedRanges {
            let replacementRanges = ranges.map { range -> NSRange in
                if range.upperBound < charIndex {
                    // [this range) >insertion point<
                    return range
                }
                if range.lowerBound > charIndex {
                    // >insertion point< [this range)
                    return NSRange(location: range.lowerBound + length, length: range.length)
                }
                if charIndex == range.location {
                    // Insert exactly at start of selection.
                    return NSRange(location: charIndex + length, length: range.length)
                }
                precondition(range.lowerBound < charIndex)
                precondition(range.upperBound >= charIndex)
                // [this >insertion point< range]
                return NSRange(location: range.lowerBound, length: range.length + length)
            }
            safelySetSelectedRanges(replacementRanges)
        }
    }

    // Escaping because enumerateSubstrings wrongly says its block is escaping.
    private func transformWordInPlace(_ closure: @escaping (String) -> (String)) {
        guard let ranges = _multiCursorSelectedRanges else {
            return
        }
        undoable {
            settingMultiCursorSelectedRanges = true
            let extendedRanges = ranges.map { extendWordLeft(extendWordRight($0)) }
            let nsstring = textStorage!.string as NSString
            for range in extendedRanges {
                nsstring.enumerateSubstrings(in: range,
                                             options: [.byWords]) { maybeString, wordRange, enclosingRange, stop in
                    let string = nsstring.substring(with: wordRange)
                    self.multiCursorReplaceCharacters(in: wordRange, with: closure(string))
                }
            }
            settingMultiCursorSelectedRanges = false
            safelySetSelectedRanges(extendedRanges)
        }
    }

    private func extendLeft(_ range: NSRange, by: NSString.EnumerationOptions) -> NSRange {
        var result = range
        let nsstring = textStorage!.string as NSString
        let rangeToSearch = NSRange(from: 0, to: range.location)
        nsstring.enumerateSubstrings(
            in: rangeToSearch,
            options: [by, .reverse]) { maybeString, wordRange, enclosingRange, stop in
                result = NSRange(from: wordRange.lowerBound, to: range.upperBound)
                stop.pointee = true
            }
        return result
    }

    private func extendRight(_ range: NSRange, by: NSString.EnumerationOptions) -> NSRange {
        let nsstring = textStorage!.string as NSString
        if range.upperBound == nsstring.length {
            return range
        }
        var result = range
        let rangeToSearch = NSRange(from: range.upperBound,
                                    to: nsstring.length)
        nsstring.enumerateSubstrings(
            in: rangeToSearch,
            options: [by]) { maybeString, wordRange, enclosingRange, stop in
                result = NSRange(from: range.lowerBound, to: wordRange.upperBound)
                stop.pointee = true
            }
        return result
    }

    private func extendWordLeft(_ range: NSRange) -> NSRange {
        return extendLeft(range, by: .byWords)
    }

    private func extendWordRight(_ range: NSRange) -> NSRange {
        return extendRight(range, by: .byWords)
    }

    private func extendParagraphLeft(_ range: NSRange) -> NSRange {
        return extendLeft(range, by: .byParagraphs)
    }

    private func extendParagraphRight(_ range: NSRange) -> NSRange {
        return extendRight(range, by: .byParagraphs)
    }

    private func extendLineLeft(_ range: NSRange) -> NSRange {
        let rect = underflowingLineFragmentRect(forGlyphAt: max(0, range.location - 1),
                                                effectiveRange: nil)
        let index = layoutManager!.glyphIndex(for: rect.origin, in: textContainer!)
        return NSRange(from: index, to: range.upperBound)
    }

    private func extendLineRight(_ range: NSRange) -> NSRange {
        let rect = layoutManager!.lineFragmentRect(forGlyphAt: range.location, effectiveRange: nil)
        let index = overflowingGlyphIndex(for: rect.maxPointWithinRect, in: textContainer!)
        return NSRange(from: range.lowerBound, to: index)
    }

    private func deleteRanges(closure: (Int) -> (Range<Int>)) {
        guard let ranges = _multiCursorSelectedRanges else {
            return
        }
        settingMultiCursorSelectedRanges = true
        var newRanges = [NSRange]()
        var count = 0
        for unadjustedRange in ranges {
            let glyphRange: NSRange
            let adjustedRange = NSRange(location: unadjustedRange.location - count,
                                        length: unadjustedRange.length)
            if unadjustedRange.length > 0 {
                glyphRange = adjustedRange
            } else {
                let count = (self.textStorage!.string as NSString).length
                let proposed = NSRange(closure(adjustedRange.location))
                guard let safe = proposed.intersection(NSRange(location: 0, length:count)) else {
                    continue
                }
                glyphRange = safe
            }
            let characterRange = self.layoutManager!.characterRange(forGlyphRange: glyphRange,
                                                                    actualGlyphRange: nil)
            multiCursorReplaceCharacters(in: characterRange, with: "")
            newRanges.append(NSRange(location: glyphRange.location, length: 0))
            count += glyphRange.length
        }
        settingMultiCursorSelectedRanges = false
        safelySetSelectedRanges(newRanges)
    }

    private func mutate<T>(_ closure: () throws -> T) rethrows -> T {
        let saved = settingMultiCursorSelectedRanges
        settingMultiCursorSelectedRanges = true
        let result = try closure()
        settingMultiCursorSelectedRanges = saved
        return result
    }

    private func didModifySubstringLength(originalCharacterRange: NSRange,
                                          newCharacterRange: NSRange) {
        precondition(originalCharacterRange.location == newCharacterRange.location)

        guard let originalRanges = _multiCursorSelectedRanges else {
            return
        }
        /*
         //         |----)   original glyph range that got changed (became longer or shorter)
         // Possible selection glyph ranges:
         // 1 |--)
         // 2 |-------)
         // 3 |--------------)
         // 4         |-)
         // 5         |------)
         // 6                |---)
         */
        let delta = newCharacterRange.length - originalCharacterRange.length
        let replacementCharRanges = originalRanges.compactMap { selectionGlyphRange -> NSRange? in
            let selectionCharRange = self.layoutManager!.characterRange(forGlyphRange: selectionGlyphRange, actualGlyphRange: nil)
            if selectionCharRange.lowerBound <= originalCharacterRange.lowerBound {
                // Selection starts at or before modified range.
                if selectionCharRange.upperBound <= originalCharacterRange.lowerBound {
                    // 1. Selection ends before the modification, so nothing to do here.
                    return selectionGlyphRange
                }
                if selectionCharRange.upperBound <= originalCharacterRange.upperBound {
                    // 2. Selection's tail was within the modified range. Ensure it doesn't go past
                    // the new end. This is kinda janky.
                    return NSRange(from: selectionCharRange.lowerBound,
                                   to: min(selectionCharRange.upperBound, newCharacterRange.upperBound))
                }
                // 3. Selection starts at or before the modified range and ends after it.
                return NSRange(from: selectionCharRange.lowerBound,
                               to: selectionCharRange.upperBound + delta)
            }
            if selectionCharRange.lowerBound < originalCharacterRange.upperBound {
                // Selection starts within modified range.
                if selectionCharRange.upperBound <= originalCharacterRange.upperBound {
                    // 4. Was entirely contained
                    let replacementRange = NSRange(from: min(selectionCharRange.location, newCharacterRange.upperBound),
                                                   to: min(selectionCharRange.upperBound, newCharacterRange.upperBound))
                    if replacementRange.length == 0 {
                        // All chars removed
                        return nil
                    }
                    return replacementRange
                }
                // 5. Ends after modified range
                return NSRange(from: min(selectionCharRange.location, newCharacterRange.upperBound),
                               to: selectionCharRange.upperBound + delta)
            }
            // 6. Starts after modified range
            return selectionCharRange.shifted(by: delta)
        }
        let replacementGlyphRanges = replacementCharRanges.map {
            return layoutManager!.glyphRange(forCharacterRange: $0, actualCharacterRange: nil)
        }.sorted { lhs, rhs in
            return lhs.location < rhs.location
        }.uniq
        if replacementGlyphRanges == originalRanges {
            return
        }
        safelySetSelectedRanges(replacementGlyphRanges)
    }

    // Returns the new glyph range.
    @discardableResult
    private func modify(glyphRange: NSRange, closure: (String) -> String) -> NSRange {
        let characterRange = self.layoutManager!.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let newCharacterRange = modify(characterRange: characterRange, closure: closure)
        return layoutManager!.glyphRange(forCharacterRange: newCharacterRange, actualCharacterRange: nil)
    }

    // Returns the new character range
    @discardableResult
    private func modify(characterRange: NSRange, closure: (String) -> String) -> NSRange {
        let nsstring = textStorage!.string as NSString
        let originalValue = nsstring.substring(with: characterRange)
        let replacement = closure(originalValue)
        if replacement == originalValue {
            return characterRange
        }
        return mutate {
            multiCursorReplaceCharacters(in: characterRange, with: replacement)
            let newRange = NSMakeRange(characterRange.location, (replacement as NSString).length)
            didModifySubstringLength(
                originalCharacterRange: characterRange,
                newCharacterRange: newRange)
            return newRange
        }
    }

    private func moveSelection(_ index: Int, to range: NSRange) {
        if index == 0 && _multiCursorSelectedRanges == nil {
            let glyphRange = layoutManager!.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            safelySetSelectedRanges([glyphRange])
            return
        }
        var temp = _multiCursorSelectedRanges!
        temp[index] = range
        safelySetSelectedRanges(temp)
    }

    // It is safe to modify existing ranges in the closure, but don't add or delete them.
    // Since ranges can get coalesced due to adjacency or non-uniqueness, it's hard to use this
    // correctly. Improve it.
    private func enumerateRanges(_ closure: (Int, NSRange) -> ()) {
        for i in 0 ..< (_multiCursorSelectedRanges?.count ?? selectedRanges.count) {
            guard i < (_multiCursorSelectedRanges?.count ?? selectedRanges.count) else {
                return
            }
            let range: NSRange
            if let multi = _multiCursorSelectedRanges {
                range = multi[i]
            } else {
                range = selectedRanges[i].rangeValue
            }
            closure(i, range)
        }
    }

    private func glyphIndexOnLineBelow(glyphIndex: Int) -> Int? {
        let rect = self.rect(for: NSRange(location: glyphIndex, length: 0))!
        let i = layoutManager!.glyphIndex(for: rect.neighborBelow.origin, in: textContainer!, fractionOfDistanceThroughGlyph: nil)
        let sanityCheckRect = layoutManager!.boundingRect(forGlyphRange: NSRange(location: i, length: 1), in: textContainer!)
        if sanityCheckRect.minY == rect.minY {
            return nil
        }
        return i
    }

}

// MARK: - NSTextView
extension MultiCursorTextView {
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        if !settingMultiCursorSelectedRanges {
            DLog("Surprise! Setting ranges not by me to \(ranges).")
            if ranges.count < 2 {
                _multiCursorSelectedRanges = nil
            } else {
                _multiCursorSelectedRanges = ranges.map { $0.rangeValue }
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
    }
}

// MARK: - Movement
extension MultiCursorTextView {
    override func moveLeft(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveLeft(sender)
            return
        }
        modifyRanges { range in
            return NSRange(location: max(0, range.location - 1), length: 0)
        }
        updateInsertionPointStateAndRestartTimer(true)
    }

    override func moveRight(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveRight(sender)
            return
        }
        let maxLocation = layoutManager?.numberOfGlyphs ?? 0
        modifyRanges { range in
            return NSRange(location: min(maxLocation, range.location + 1), length: 0)
        }
        updateInsertionPointStateAndRestartTimer(true)
    }

    // TODO: RTL
    override func moveForward(_ sender: Any?) {
        moveRight(sender)
    }

    // TODO: RTL
    override func moveBackward(_ sender: Any?) {
        moveLeft(sender)
    }

    override func moveUp(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveUp(sender)
            return
        }
        modifyRanges { glyphRange in
            guard let glyphRangeRect = self.rect(for: glyphRange) else {
                return glyphRange
            }
            if glyphRangeRect.minY - 1 < 0 {
                return nil
            }
            let glyphIndex = self.layoutManager!.glyphIndex(for: NSPoint(x: glyphRangeRect.minX,
                                                                         y: glyphRangeRect.minY - 1),
                                                            in: textContainer!,
                                                            fractionOfDistanceThroughGlyph: nil)
            return NSRange(location: glyphIndex, length: 0)
        }
    }

    override func moveDown(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveDown(sender)
            return
        }
        let limit = layoutManager!.boundingRect(forGlyphRange: NSMakeRange(0, layoutManager!.numberOfGlyphs),
                                                in: textContainer!).maxY
        modifyRanges { glyphRange in
            guard let glyphRangeRect = self.rect(for: glyphRange) else {
                return glyphRange
            }
            if glyphRangeRect.maxY + 1 >= limit {
                return nil
            }
            let glyphIndex = self.layoutManager!.glyphIndex(for: NSPoint(x: glyphRangeRect.minX,
                                                                         y: glyphRangeRect.maxY + 1),
                                                            in: textContainer!,
                                                            fractionOfDistanceThroughGlyph: nil)
            return NSRange(location: glyphIndex, length: 0)
        }
    }

    override func moveWordRight(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveWordForward(sender)
            return
        }
        moveRight(by: .byWords)
    }

    override func moveWordLeft(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveWordLeft(sender)
            return
        }
        moveLeft(by: .byWords)
    }

    override func moveWordForward(_ sender: Any?) {
        moveWordRight(sender)
    }

    override func moveWordBackward(_ sender: Any?) {
        moveWordLeft(sender)
    }

    override func moveToBeginningOfParagraph(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToBeginningOfParagraph(sender)
            return
        }
        moveLeft(by: .byParagraphs)
    }

    override func moveToEndOfParagraph(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToEndOfParagraph(sender)
            return
        }
        moveRight(by: .byParagraphs)
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToBeginningOfLine(sender)
            return
        }
        modifyRanges { glyphRange in
            return NSRange(location: extendLineLeft(glyphRange).location, length: 0)
        }
    }

    override func moveToEndOfLine(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToEndOfLine(sender)
            return
        }
        modifyRanges { glyphRange in
            return NSRange(location: extendLineRight(glyphRange).upperBound, length: 0)
        }
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveBackwardAndModifySelection(sender)
            return
        }
        moveLeftAndModifySelection(by: .byCaretPositions)
    }

    override func moveBackwardAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveBackwardAndModifySelection(sender)
            return
        }
        moveLeftAndModifySelection(sender)
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveRightAndModifySelection(sender)
            return
        }
        moveRightAndModifySelection(by: .byCaretPositions)
    }

    override func moveForwardAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveForwardAndModifySelection(sender)
            return
        }
        moveRightAndModifySelection(by: .byCaretPositions)
    }

    override func moveWordForwardAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveWordForwardAndModifySelection(sender)
            return
        }
        moveRightAndModifySelection(by: .byWords)
    }

    override func moveWordRightAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveWordRightAndModifySelection(sender)
            return
        }
        moveRightAndModifySelection(by: .byWords)
    }

    override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveWordBackwardAndModifySelection(sender)
            return
        }
        moveLeftAndModifySelection(by: .byWords)
    }

    override func moveWordLeftAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveWordBackwardAndModifySelection(sender)
            return
        }
        moveLeftAndModifySelection(by: .byWords)
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveUpAndModifySelection(sender)
            return
        }
        modifyRanges { glyphRange in
            guard let glyphRangeRect = self.rect(for: glyphRange) else {
                return glyphRange
            }
            if glyphRangeRect.minY - 1 < 0 {
                return nil
            }
            let glyphIndex = self.layoutManager!.glyphIndex(for: NSPoint(x: glyphRangeRect.minX,
                                                                         y: glyphRangeRect.minY - 1),
                                                            in: textContainer!,
                                                            fractionOfDistanceThroughGlyph: nil)
            return NSRange(from: glyphIndex, to: glyphRange.upperBound)
        }
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveDownAndModifySelection(sender)
            return
        }
        let limit = layoutManager!.boundingRect(forGlyphRange: NSMakeRange(0, layoutManager!.numberOfGlyphs),
                                                in: textContainer!).maxY
        modifyRanges { glyphRange in
            guard let glyphRangeRect = self.rect(for: glyphRange) else {
                return glyphRange
            }
            if glyphRangeRect.maxY + 1 >= limit {
                return nil
            }
            let glyphIndex = self.layoutManager!.glyphIndex(for: NSPoint(x: glyphRangeRect.minX,
                                                                         y: glyphRangeRect.maxY + 1),
                                                            in: textContainer!,
                                                            fractionOfDistanceThroughGlyph: nil)
            return NSRange(from: glyphRange.location, to: glyphIndex)
        }
    }

    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToBeginningOfLineAndModifySelection(sender)
            return
        }
        modifyRanges { glyphRange in
            return extendLineLeft(glyphRange)
        }
    }

    override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToEndOfLineAndModifySelection(sender)
            return
        }
        modifyRanges { glyphRange in
            return extendLineRight(glyphRange)
        }
    }

    override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToBeginningOfParagraphAndModifySelection(sender)
            return
        }
        moveLeftAndModifySelection(by: .byParagraphs)
    }

    override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToEndOfParagraphAndModifySelection(sender)
            return
        }
        moveRightAndModifySelection(by: .byParagraphs)
    }

    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        guard let firstRange = _multiCursorSelectedRanges?.first else {
            super.moveToEndOfDocumentAndModifySelection(sender)
            return
        }
        safelySetSelectedRanges([NSRange(from: firstRange.location,
                                         to: layoutManager!.numberOfGlyphs)])
        scrollToEndOfDocument(nil)
    }

    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        guard let lastRange = _multiCursorSelectedRanges?.last else {
            super.moveToBeginningOfDocumentAndModifySelection(sender)
            return
        }
        safelySetSelectedRanges([NSRange(from: 0, to: lastRange.upperBound)])
        scrollToBeginningOfDocument(nil)
    }

    override func pageDownAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.pageDownAndModifySelection(sender)
            return
        }
        let pageHeight: CGFloat
        if let scrollView = enclosingScrollView {
            pageHeight = scrollView.documentVisibleRect.size.height - scrollView.verticalPageScroll
        } else {
            return
        }

        modifyRanges { glyphRange in
            let rect = layoutManager!.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let nextPageRect = NSOffsetRect(rect, 0, pageHeight)
            let index = overflowingGlyphIndex(for: nextPageRect.origin, in: textContainer!)
            return NSRange(from: glyphRange.location, to: index)
        }

        scrollPageDown(nil)
    }

    override func pageUpAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.pageUpAndModifySelection(sender)
            return
        }
        let pageHeight: CGFloat
        if let scrollView = enclosingScrollView {
            pageHeight = scrollView.documentVisibleRect.size.height - scrollView.verticalPageScroll
        } else {
            return
        }

        modifyRanges { glyphRange in
            let rect = layoutManager!.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let previousPageRect = NSOffsetRect(rect, 0, -pageHeight)
            let index = overflowingGlyphIndex(for: previousPageRect.origin, in: textContainer!)
            return NSRange(from: index, to: glyphRange.upperBound)
        }

        scrollPageUp(nil)
    }

    override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveParagraphForwardAndModifySelection(sender)
            return
        }
        moveRightAndModifySelection(by: .byParagraphs)
    }

    override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveParagraphBackwardAndModifySelection(sender)
            return
        }
        moveLeftAndModifySelection(by: .byParagraphs)
    }

    override func moveToLeftEndOfLine(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToLeftEndOfLine(sender)
            return
        }
        moveToBeginningOfLine(sender)
    }

    override func moveToRightEndOfLine(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToRightEndOfLine(sender)
            return
        }
        moveToEndOfLine(sender)
    }

    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToLeftEndOfLineAndModifySelection(sender)
            return
        }
        moveToBeginningOfLineAndModifySelection(sender)
    }

    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.moveToRightEndOfLineAndModifySelection(sender)
            return
        }
        moveToEndOfLineAndModifySelection(sender)
    }
}

// MARK: - Insertion
extension MultiCursorTextView {
    override func insertText(_ insertString: Any) {
        guard let ranges = _multiCursorSelectedRanges else {
            super.insertText(insertString, replacementRange: selectedRange())
            return
        }

        let stringLength: Int
        if let string = insertString as? String {
            stringLength = string.utf16.count
        } else if let string = insertString as? NSAttributedString {
            stringLength = string.string.utf16.count
        } else {
            fatalError()
        }

        var selectionCharacterRanges: [NSRange] = []
        let preCharacterRanges = ranges.map {
            layoutManager!.characterRange(forGlyphRange: $0, actualGlyphRange: nil)
        }

        undoable {
            settingMultiCursorSelectedRanges = true
            var delta = 0
            for preCharacterRange in preCharacterRanges {
                var characterRange = preCharacterRange
                characterRange.location -= delta
                delta += characterRange.length - stringLength

                if let string = insertString as? String {
                    multiCursorReplaceCharacters(in: characterRange, with: string)
                } else if let string = insertString as? NSAttributedString {
                    multiCursorReplaceCharacters(in: characterRange, with: string.string)
                }

                selectionCharacterRanges.append(NSMakeRange(characterRange.location + stringLength, 0))
            }
            settingMultiCursorSelectedRanges = false
            safelySetSelectedRanges(selectionCharacterRanges.map {
                layoutManager!.glyphRange(forCharacterRange: $0, actualCharacterRange: nil)
            })
        }
    }

    override func insertNewline(_ sender: Any?) {
        if _multiCursorSelectedRanges == nil {
            super.insertNewline(sender)
        } else {
            insertText("\n")
        }
    }

    override func insertParagraphSeparator(_ sender: Any?) {
        if _multiCursorSelectedRanges == nil {
            super.insertParagraphSeparator(sender)
        } else {
            // The documentation is garbage. I can't get it to behave differently than insertNewline.
            insertText("\n")
        }
    }

    override func insertLineBreak(_ sender: Any?) {
        if _multiCursorSelectedRanges == nil {
            super.insertLineBreak(sender)
        } else {
            insertText("\n")
        }
    }

    override func insertContainerBreak(_ sender: Any?) {
        if _multiCursorSelectedRanges == nil {
            super.insertContainerBreak(sender)
        } else {
            insertNewline(sender)
        }
    }

    override func insertSingleQuoteIgnoringSubstitution(_ sender: Any?) {
        if _multiCursorSelectedRanges == nil {
            super.insertSingleQuoteIgnoringSubstitution(sender)
        } else {
            // I don't support substitution
            insertText("'")
        }
    }

    override func insertDoubleQuoteIgnoringSubstitution(_ sender: Any?) {
        if _multiCursorSelectedRanges == nil {
            super.insertDoubleQuoteIgnoringSubstitution(sender)
        } else {
            // I don't support substitution
            insertText("\"")
        }
    }
}

// MARK: - Tranposition
extension MultiCursorTextView {
    override func transpose(_ sender: Any?) {
        guard let ranges = _multiCursorSelectedRanges else {
            super.transpose(sender)
            return
        }
        undoable {
            for range in ranges.reversed() {
                if range.length > 0 {
                    continue
                }
                if range.location == 0 {
                    continue
                }
                let rightCharRange = layoutManager!.characterRange(forGlyphRange: NSRange(location: range.location, length: 1), actualGlyphRange: nil)
                let leftCharRange = layoutManager!.characterRange(forGlyphRange: NSRange(location: range.location - 1, length: 1), actualGlyphRange: nil)
                let rightString = (textStorage!.string as NSString).substring(with: rightCharRange)
                let leftString = (textStorage!.string as NSString).substring(with: leftCharRange)

                settingMultiCursorSelectedRanges = true
                multiCursorReplaceCharacters(in: rightCharRange, with: leftString)
                multiCursorReplaceCharacters(in: leftCharRange, with: rightString)
                settingMultiCursorSelectedRanges = false
            }
        }
    }

    // I can't get the built-in transposeWords: to work at all so I haven't written a replacement
    // for it as it is untestable (macOS 12.2.1)
}

// MARK: - Indentation
extension MultiCursorTextView {
    // I don't implement insertTabIgnoringFieldEditor: because I think it's irrelevant for NSTextView.

    override func indent(_ sender: Any?) {
        let ranges = _multiCursorSelectedRanges ?? selectedRanges.map { $0.rangeValue }
        if NSTextView.instancesRespond(to: #selector(indent(_:))) && ranges.count == 1 {
            super.indent(sender)
            return
        }
        let locations = paragraphStartIndexes()
        undoable {
            for index in locations.reversed() {
                safelyInsert(String(repeating: " ", count: tabStop), at: index)
            }
        }
    }

    override func insertBacktab(_ sender: Any?) {
        undoable {
            let ranges = _multiCursorSelectedRanges ?? selectedRanges.map { $0.rangeValue }
            let nsstring = textStorage!.string as NSString
            settingMultiCursorSelectedRanges = true
            var delta = 0
            // `i` indexes into _multiCursorSelectedRanges to fix up locations as we delete. No index
            // before `i` needs to be changed
            var i = 0
            let numRanges = _multiCursorSelectedRanges?.count ?? 0
            var replacementRanges = ranges
            let startIndexes = paragraphStartIndexes()
            for oldGlyphIndex in startIndexes {
                let glyphIndex = oldGlyphIndex + delta
                let charIndex = layoutManager!.characterIndexForGlyph(at: glyphIndex)
                guard nsstring.substring(from: charIndex).hasPrefix(String(repeating: " ", count: tabStop)) else {
                    continue
                }
                multiCursorReplaceCharacters(in: NSRange(location: charIndex, length: tabStop),
                                             with: "")
                delta -= tabStop

                let deletedRange = NSRange(location: glyphIndex, length: tabStop)
                for j in i..<numRanges {
                    let selection = replacementRanges[j]
                    precondition(selection.length >= 0)
                    guard let intersection = deletedRange.intersection(selection) else {
                        // Doesn't intersect deletion.
                        if selection.upperBound <= deletedRange.lowerBound {
                            // Never need to revisit this selection. Further deletions all occur
                            // after its end.
                            i += 1
                            continue
                        }
                        precondition(selection.lowerBound >= deletedRange.upperBound)
                        // The selection ends after the start of the deletion. Since it doesn't
                        // intersect, the selection must *start* after the deletion as well. So just
                        // shift it back by the number of characters deleted.
                        // This is the common case.
                        replacementRanges[j] = NSRange(location: selection.location - tabStop,
                                                       length: selection.length)
                        continue
                    }
                    var modified = selection
                    if intersection.location == selection.location {
                        // Delete from start of selection
                        modified.location += intersection.length - tabStop
                        modified.length -= intersection.length
                    } else {
                        modified.length -= intersection.length
                    }
                    precondition(modified.length >= 0)
                    replacementRanges[j] = modified
                }
            }
            settingMultiCursorSelectedRanges = false
            if _multiCursorSelectedRanges != nil {
                safelySetSelectedRanges(replacementRanges)
            }
        }
    }

    override func insertTab(_ sender: Any?) {
        insertText(String(repeating: " ", count: tabStop))
    }

    override func insertTabIgnoringFieldEditor(_ sender: Any?) {
        if _multiCursorSelectedRanges == nil {
            super.insertTabIgnoringFieldEditor(sender)
        } else {
            insertTab(sender)
        }
    }
}

// MARK: - Case Transformation
extension MultiCursorTextView {
    // I don't implement changeCaseOfLetter: because NSTextView does not support it
    override func uppercaseWord(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.uppercaseWord(sender)
            return
        }
        transformWordInPlace { $0.uppercased() }
    }

    override func lowercaseWord(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.lowercaseWord(sender)
            return
        }
        transformWordInPlace { $0.lowercased() }
    }

    override func capitalizeWord(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.capitalizeWord(sender)
            return
        }
        transformWordInPlace { $0.firstCapitalized }
    }
}

// MARK: - Deletion
extension MultiCursorTextView {
    override func deleteForward(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.deleteForward(sender)
            return
        }
        undoable {
            deleteRanges { index in
                return index ..< index + 1
            }
        }
    }

    override func deleteBackward(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.deleteBackward(sender)
            return
        }
        undoable {
            deleteRanges() { index in
                return (index - 1) ..< index
            }
        }
    }

    override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        guard let glyphRanges = _multiCursorSelectedRanges else {
            super.deleteBackwardByDecomposingPreviousCharacter(sender)
            return
        }
        undoable {
            for glyphRange in glyphRanges.reversed() {
                let characterRange = self.layoutManager!.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                if characterRange.location == 0 {
                    continue
                }
                // Modify the predecessor if this is an insertion point; modify the range if it is non-empty.
                let rangeToModify = glyphRange.length == 0 ? NSRange(from: characterRange.lowerBound - 1, to: characterRange.lowerBound) : characterRange
                modify(characterRange: rangeToModify) { string in
                    if glyphRange.length > 0 {
                        return ""
                    }
                    return String(string.decomposedStringWithCanonicalMapping.unicodeScalars.dropLast())
                }
            }
        }
    }

    override func deleteWordForward(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.deleteWordForward(sender)
            return
        }
        undoable {
            deleteRanges() { index in
                return Range(extendWordRight(NSRange(location: index, length: 0)))!
            }
        }
    }

    override func deleteWordBackward(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.deleteWordBackward(sender)
            return
        }
        undoable {
            deleteRanges() { index in
                return Range(extendWordLeft(NSRange(location: index, length: 0)))!
            }
        }
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.deleteToBeginningOfLine(sender)
            return
        }
        undoable {
            deleteRanges() { index in
                return Range(extendLineLeft(NSRange(location: index, length: 0)))!
            }
        }
    }

    override func deleteToEndOfLine(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.deleteToEndOfLine(sender)
            return
        }
        undoable {
            deleteRanges() { index in
                return Range(extendLineRight(NSRange(location: index, length: 0)))!
            }
        }
    }

    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.deleteToBeginningOfParagraph(sender)
            return
        }
        undoable {
            deleteRanges() { index in
                return Range(extendParagraphLeft(NSRange(location: index, length: 0)))!
            }
        }
    }

    override func deleteToEndOfParagraph(_ sender: Any?) {
        guard _multiCursorSelectedRanges != nil else {
            super.deleteToEndOfParagraph(sender)
            return
        }
        undoable {
            deleteRanges() { index in
                return Range(extendParagraphRight(NSRange(location: index, length: 0)))!
            }
        }
    }
}

// MARK: - Copy/Paste
extension MultiCursorTextView {
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        guard board.availableType(from: [.multipleTextSelection]) == .multipleTextSelection,
              let string = board.string(forType: .string),
              let groupCounts = board.propertyList(forType: .multipleTextSelection) as? [Int] else {
            super.paste(sender)
            return
        }
        undoable {
            let ranges = _multiCursorSelectedRanges ?? selectedRanges.map { $0.rangeValue }
            let lines = string.components(separatedBy: .newlines)

            // groupCounts gives the number of lines in each selection. It's usually 1. Turn the array
            // of lines into an array of per-cursor string
            var groups = [String]()
            var i = 0
            for numberOfLines in groupCounts {
                groups.append(lines[i..<i + numberOfLines].joined(separator: "\n"))
                i += numberOfLines
            }

            enumerateRanges { i, glyphRange in
                let newGlyphRange = modify(glyphRange: glyphRange) { originalValue in
                    if i < groups.count {
                        // Replace existing cursor
                        return groups[i]
                    } else {
                        // There are more cursors than values to paste so don't change this on
                        return originalValue
                    }
                }
                moveSelection(i, to: NSRange(location: newGlyphRange.upperBound, length: 0))
            }

            if ranges.count < groups.count {
                let copyOfSelectedRanges = selectedRanges
                // Add more cursors.
                // (glyph index we inserted at, number of characters inserted at that point)
                var indexes = [(Int, Int)]()
                var glyphIndexAboveLocationToInsert = ranges.last!.location
                for string in groups[ranges.count...] {
                    let stringLength = (string as NSString).length
                    if let index = glyphIndexOnLineBelow(glyphIndex: glyphIndexAboveLocationToInsert) {
                        glyphIndexAboveLocationToInsert = index
                        multiCursorReplaceCharacters(in: NSRange(index..<index), with: string)
                        indexes.append((index, stringLength))
                    } else {
                        multiCursorReplaceCharacters(in: NSRange(location: (textStorage!.string as NSString).length, length: 0),
                                                     with: "\n")
                        let index = layoutManager!.numberOfGlyphs
                        multiCursorReplaceCharacters(in: NSRange(location: (textStorage!.string as NSString).length, length: 0),
                                                     with: string)
                        indexes.append((index, stringLength))
                        glyphIndexAboveLocationToInsert = layoutManager!.numberOfGlyphs
                    }
                }
                var replacementRanges = _multiCursorSelectedRanges ?? copyOfSelectedRanges.map { $0.rangeValue }
                for (startGlyphIndex, numberOfCharacters) in indexes {
                    let startCharacterIndex = layoutManager!.characterIndexForGlyph(at: startGlyphIndex)
                    let glyphIndex = layoutManager!.glyphIndexForCharacter(at: startCharacterIndex + numberOfCharacters)
                    replacementRanges.append(NSRange(glyphIndex..<glyphIndex))
                }
                safelySetSelectedRanges(replacementRanges)
            }
        }
    }

    internal override func copy(_ sender: Any?) {
        guard let ranges = _multiCursorSelectedRanges else {
            super.copy(sender)
            return
        }
        let values = ranges.map { range in
            (textStorage!.string as NSString).substring(with: range)
        }
        let linesPerGroup = values.map { string in
            return string.components(separatedBy: "\n").count
        }
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.declareTypes([.multipleTextSelection, .string], owner: nil)
        if pboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.multipleTextSelection.rawValue]) {
            pboard.setPropertyList(linesPerGroup,
                                   forType: .multipleTextSelection)
        }
        let string = values.joined(separator: "\n") as NSPasteboardWriting
        pboard.writeObjects([string])
    }
}

// MARK: - Other NSResponder
extension MultiCursorTextView {
    override func cancelOperation(_ sender: Any?) {
        if _multiCursorSelectedRanges == nil {
            super.cancelOperation(sender)
            return
        }
        safelySetSelectedRanges([_multiCursorSelectedRanges!.last!])
    }
}

// MARK: - New APIs
extension MultiCursorTextView {
    public func multiCursorReplaceCharacters(in range: NSRange, with replacement: String) {
        if shouldChangeText(in: range, replacementString: replacement) {
            textStorage?.beginEditing()
            textStorage?.replaceCharacters(in: range, with: replacement)
            textStorage?.endEditing()
            didChangeText()
        }
    }
}

extension StringProtocol {
    var firstCapitalized: String { prefix(1).capitalized + dropFirst() }
}

extension Array where Element: Equatable {
    var uniq: [Element] {
        return enumerated().filter { tuple in
            let (i, value) = tuple
            if i > 0 && self[i - 1] == value {
                return false
            }
            return true
        }.map {
            $0.1
        }
    }
}

