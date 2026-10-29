package com.longping.core

/** OEM battery / auto-start screens tried by openPowerManagerSettings(), in order. */
object PowerManagerTargets {
    data class Target(val oem: String, val packageName: String, val className: String)

    val ALL: List<Target> = listOf(
        Target("samsung", "com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
        Target("samsung", "com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"),
        Target("samsung", "com.samsung.android.sm", "com.samsung.android.sm.ui.battery.BatteryActivity"),
        Target("xiaomi", "com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
        Target("xiaomi", "com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"),
        Target("huawei", "com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        Target("huawei", "com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        Target("huawei", "com.huawei.systemmanager", "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"),
        Target("oppo", "com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
        Target("oppo", "com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
        Target("oppo", "com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
        Target("oppo", "com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"),
        Target("vivo", "com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
        Target("vivo", "com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
        Target("vivo", "com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
        Target("oneplus", "com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
        Target("asus", "com.asus.mobilemanager", "com.asus.mobilemanager.autostart.AutoStartActivity"),
        Target("asus", "com.asus.mobilemanager", "com.asus.mobilemanager.MainActivity"),
        Target("letv", "com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity"),
        Target("meizu", "com.meizu.safe", "com.meizu.safe.permission.SmartBGActivity"),
        Target("meizu", "com.meizu.safe", "com.meizu.safe.powerui.PowerAppPermissionActivity"),
    )

    /** Packages that must be in the manifest's <queries> for resolve checks on Android 11+. */
    val PACKAGES: List<String> = ALL.map { it.packageName }.distinct()
}
