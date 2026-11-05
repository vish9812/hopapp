import ServiceManagement

struct LoginItemAccess {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () throws -> Void
    var openSettings: () -> Void

    static let system = LoginItemAccess(
        status: { SMAppService.mainApp.status },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() },
        openSettings: { SMAppService.openSystemSettingsLoginItems() }
    )
}
