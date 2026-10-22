package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.UserRole

/**
 * What a signed-in session hands to its screens (iOS `Dependencies`).
 *
 * Each feature builds its own repositories from it with an extension in its
 * own package -- `fun Dependencies.recommendations(): RecommendationsRepository`
 * -- returning the Supabase implementation, or the demo one when [isDemo].
 * Supabase repositories are stateless wrappers over [client]; demo ones keep
 * their state in a singleton so what the demo does stays done across screens.
 */
data class Dependencies(
    /** null in demo mode */
    val client: SupabaseClient?,
    val isDemo: Boolean,
    val role: UserRole,
    val fullName: String,
    val profiles: ProfileRepository,
) {
    /** The signed-in person's id (auth.uid()); the demo's stable ids otherwise. */
    val myId: String get() = client?.userId ?: if (role.isAdmin) Demo.them else Demo.me

    /** The live client; only call from a Supabase repository. */
    fun requireClient(): SupabaseClient = client ?: error("no Supabase client in demo mode")
}
