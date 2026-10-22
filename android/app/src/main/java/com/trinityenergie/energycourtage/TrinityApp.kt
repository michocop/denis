package com.trinityenergie.energycourtage

import android.app.Application
import com.trinityenergie.energycourtage.push.Push

class TrinityApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // the notification channel, and Firebase if this build is configured for it
        Push.init(this)
    }
}
