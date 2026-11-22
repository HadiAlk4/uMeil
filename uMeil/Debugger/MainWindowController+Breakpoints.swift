import AppKit

/// The Breakpoints list in the bottom panel: turning breakpoints on and
/// off, deleting them, and jumping to their lines.
extension MainWindowController {
    var breakpointsPanel: BreakpointsViewController { bottomPanel.breakpoints }

    /// Called once from `init`, after the debugger is set up.
    func setUpBreakpointsAndAppearance() {
        observeAppearanceSettings()

        // Follow the debugger's breakpoints as well as the gutter does.
        let showInGutter = debugger.onBreakpointsChange
        debugger.onBreakpointsChange = { [weak self] in
            showInGutter?()
            self?.refreshBreakpointList()
        }
        editor.disabledBreakpointLinesProvider = { [weak self] file in
            self?.breakpointsPanel.list.disabledLines(in: file) ?? []
        }
        breakpointsPanel.onSetEnabled = { [weak self] location, isOn in
            Task { await self?.setBreakpoint(location, enabled: isOn) }
        }
        breakpointsPanel.onRemove = { [weak self] entries in
            Task { await self?.removeBreakpoints(entries) }
        }
        breakpointsPanel.onOpen = { [weak self] location in
            self?.navigate(to: location.file, line: location.line, column: nil)
        }
        breakpointsPanel.lineText = { [weak self] location in self?.text(of: location) }
        refreshBreakpointList()
    }

    /// Called when the folder is set. Breakpoints belong to the project
    /// they were set in, and opening a folder clears the debugger's, so the
    /// ones that are off go too.
    func folderDidChange() {
        refreshStatusBar()
        breakpointsPanel.list.removeAll()
        refreshBreakpointList()
    }

    func refreshBreakpointList() {
        breakpointsPanel.show(enabled: debugger.breakpoints)
        editor.disabledBreakpointLines = editor.document.map { breakpointsPanel.list.disabledLines(in: $0.url) } ?? []
    }

    /// Turns a breakpoint off by taking it out of the debugger and
    /// remembering it, or back on by handing it to the debugger again.
    func setBreakpoint(_ location: SourceLine, enabled isOn: Bool) async {
        // Already as asked, such as after a second click arrived first.
        guard debugger.breakpoints.contains(location) != isOn else { return }
        guard await debugger.toggleBreakpoint(at: location) else {
            breakpointsPanel.showMessage("Stop the program to change breakpoints.")
            refreshBreakpointList()
            return
        }
        breakpointsPanel.showMessage("")
        if isOn {
            breakpointsPanel.list.forget(location)
        } else {
            breakpointsPanel.list.markDisabled(location)
        }
        refreshBreakpointList()
    }

    /// Deletes breakpoints, on or off. While the program runs, the ones
    /// that are on stay: GDB cannot change breakpoints then.
    func removeBreakpoints(_ entries: [BreakpointList.Entry]) async {
        var refused = false
        for entry in entries {
            if entry.isEnabled {
                guard debugger.breakpoints.contains(entry.location) else { continue }
                let removed = await debugger.toggleBreakpoint(at: entry.location)
                refused = refused || !removed
            } else {
                breakpointsPanel.list.forget(entry.location)
            }
        }
        breakpointsPanel.showMessage(refused ? "Stop the program to remove breakpoints that are on." : "")
        refreshBreakpointList()
    }

    /// The code on `location`'s line: from the editor for the open file,
    /// so unsaved changes show, or from disk.
    private func text(of location: SourceLine) -> String? {
        let text: String
        if let document = editor.document, SourceLine(file: document.url, line: 0).file == location.file {
            text = editor.textView.string
        } else if let loaded = try? TextDocument.load(from: location.file) {
            text = loaded.text
        } else {
            return nil
        }
        let index = LineIndex(text)
        guard let range = index.range(ofLine: location.line) else { return nil }
        return (text as NSString).substring(with: range)
    }
}
