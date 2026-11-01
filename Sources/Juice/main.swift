import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = BatteryModel()
    private var statusItem: NSStatusItem!
    private var panel: GlassPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel = GlassPanel { [unowned self] in
            PopoverView(model: model)
        }
        panel.onClose = { [weak self] in
            self?.statusItem.button?.highlight(false)
            self?.model.popoverDidClose()
        }

        model.onChange = { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            StatusItemContent.apply(self.model.snapshot, to: button)
        }
        model.onEnergyChange = { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return }
            // Let SwiftUI apply the new rows first, then measure.
            DispatchQueue.main.async { panel.fitContent() }
        }
        StatusItemContent.apply(model.snapshot, to: button)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if panel.isVisible {
            panel.dismiss()
        } else {
            model.popoverDidOpen()
            panel.show(below: sender)
            sender.highlight(true)
        }
    }

    // Right-click: the few things that don't belong in the popover.
    private func showMenu() {
        let menu = NSMenu()
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Juice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
