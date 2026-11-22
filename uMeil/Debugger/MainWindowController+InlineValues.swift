import AppKit

/// Prints variables' values after the lines of code that use them while the
/// program is stopped. The values come from the debug panels' last refresh.
extension MainWindowController {
    /// Prints the values of the chosen frame's locals after the lines of its
    /// function that use them, if that frame's file is the one showing.
    func showInlineValues() {
        let frameVariables = debugPanels.frameVariables
        guard debugger.isStopped, let frame = frameVariables.selected,
              let file = frame.file, let line = frame.line, isShowing(file),
              let variables = frameVariables.selectedVariables
        else {
            editor.showInlineValues([:])
            return
        }
        editor.showInlineValues(
            InlineValues.annotations(source: editor.textView.string, stoppedAt: line, variables: variables)
        )
    }
}
