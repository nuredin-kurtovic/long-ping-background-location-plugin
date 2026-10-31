package com.longping.engine

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network

/** Connectivity regained -> upload trigger. */
internal class NetworkMonitor(private val context: Context, private val log: Logger, private val onAvailable: () -> Unit) {
    private var registered = false

    fun start() {
        if (registered) return
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        try {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = onAvailable()
            })
            registered = true
        } catch (e: Exception) {
            // TooManyRequestsException / SecurityException: uploads still run on record and watchdog triggers.
            log.warn(TAG, "could not watch connectivity", e)
        }
    }

    private companion object {
        const val TAG = "network"
    }
}
