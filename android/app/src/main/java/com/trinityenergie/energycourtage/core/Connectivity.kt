package com.trinityenergie.energycourtage.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.transformLatest

/** Whether the phone can reach the internet, as it changes (iOS
 *  NWPathMonitor). The first value is the current state. Going offline is
 *  only reported after 1.5 s: Android drops the default network for an
 *  instant when it hands over between Wi-Fi and mobile data, and a banner
 *  that flashes "Hors ligne" for nothing teaches people to ignore it. */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
fun Context.onlineFlow(): Flow<Boolean> = rawOnlineFlow().transformLatest { online ->
    if (!online) kotlinx.coroutines.delay(1500)
    emit(online)
}.distinctUntilChanged()

private fun Context.rawOnlineFlow(): Flow<Boolean> = callbackFlow {
    val manager = getSystemService(ConnectivityManager::class.java)
    fun current() = manager.getNetworkCapabilities(manager.activeNetwork)
        ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
    trySend(current())
    val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { trySend(current()) }
        override fun onLost(network: Network) { trySend(current()) }
        override fun onAvailable(network: Network) { trySend(current()) }
    }
    manager.registerDefaultNetworkCallback(callback)
    awaitClose { manager.unregisterNetworkCallback(callback) }
}.distinctUntilChanged()
