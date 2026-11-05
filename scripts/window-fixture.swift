import AppKit

// A separate setup process owns these disposable windows; the diagnostic never mutates their geometry/state.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
let frame = NSRect(x: screen.midX - 250, y: screen.midY - 130, width: 500, height: 260)
var windows: [NSWindow] = []
for index in 1...2 {
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "hopapp identical fixture"
    window.backgroundColor = index == 1 ? .systemBlue : .systemOrange
    let label = NSTextField(labelWithString: "Fixture window \(index)")
    label.font = .systemFont(ofSize: 30)
    label.frame = NSRect(x: 60, y: 100, width: 380, height: 50)
    window.contentView?.addSubview(label)
    window.orderFrontRegardless()
    windows.append(window)
}
print("pid=\(getpid()) window1=\(windows[0].windowNumber) window2=\(windows[1].windowNumber)")
print("Commands: minimize 1|2, restore 1|2, close 1|2, hide, show, overlap, quit")
fflush(stdout)
DispatchQueue.global(qos: .utility).async {
    while let line = readLine() {
        DispatchQueue.main.async {
            let words = line.split(separator: " ")
            guard let command = words.first else { return }
            let window = words.count == 2 ? Int(words[1]).flatMap { (1...2).contains($0) ? windows[$0 - 1] : nil } : nil
            switch command {
            case "minimize": window?.miniaturize(nil)
            case "restore": window?.deminiaturize(nil)
            case "close": window?.close()
            case "hide": app.hide(nil)
            case "show": app.unhideWithoutActivation()
            case "overlap": for item in windows { item.setFrame(windows[0].frame, display: true) }
            case "quit": exit(0)
            default: print("Unknown fixture command")
            }
            print("completed: \(line)")
            fflush(stdout)
        }
    }
    DispatchQueue.main.async { exit(0) }
}
app.run()
