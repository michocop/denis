package com.trinityenergie.energycourtage.push

import com.google.firebase.FirebaseOptions
import com.trinityenergie.energycourtage.BuildConfig

/** The Firebase app's four values, from android/firebase.properties through BuildConfig. */
internal data class PushConfig(
    val projectId: String,
    val appId: String,
    val apiKey: String,
    val senderId: String,
) {
    /** All four, or push stays off: a half-filled file must not half-start Firebase. */
    val isComplete: Boolean
        get() = listOf(projectId, appId, apiKey, senderId).all { it.isNotBlank() }

    fun options(): FirebaseOptions = FirebaseOptions.Builder()
        .setProjectId(projectId)
        .setApplicationId(appId)
        .setApiKey(apiKey)
        .setGcmSenderId(senderId)
        .build()

    companion object {
        val fromBuild = PushConfig(
            projectId = BuildConfig.FIREBASE_PROJECT_ID,
            appId = BuildConfig.FIREBASE_APP_ID,
            apiKey = BuildConfig.FIREBASE_API_KEY,
            senderId = BuildConfig.FIREBASE_SENDER_ID,
        )
    }
}
