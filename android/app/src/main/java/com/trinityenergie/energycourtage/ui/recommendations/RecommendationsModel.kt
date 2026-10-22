package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.trinityenergie.energycourtage.data.RecommendationsRepository
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.model.RecommendationCursor
import com.trinityenergie.energycourtage.model.RecommendationFilter
import com.trinityenergie.energycourtage.model.Stage
import com.trinityenergie.energycourtage.model.UserRole
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/**
 * The Recommandations tab's state (iOS RecommendationsViewModel): one page at
 * a time from the server, search on the server, the stale-data banner, and
 * "Valider l'étape".
 */
class RecommendationsModel(
    private val repository: RecommendationsRepository,
    val role: UserRole,
    private val scope: CoroutineScope,
    private val searchDebounceMillis: Long = 350,
) {
    sealed interface LoadState {
        data object Idle : LoadState
        data object Loading : LoadState
        data object Loaded : LoadState
        data class Failed(val message: String) : LoadState
    }

    var state by mutableStateOf<LoadState>(LoadState.Idle); private set
    var pipeline by mutableStateOf<List<Stage>>(emptyList()); private set
    var recommendations by mutableStateOf<List<Recommendation>>(emptyList()); private set
    /** Set by the change poll: drives the "Actualiser" banner. */
    var hasStaleData by mutableStateOf(false)
    var filter by mutableStateOf(RecommendationFilter.Active); private set
    var query by mutableStateOf(""); private set
    var expandedId by mutableStateOf<String?>(null)
    var isLoadingMore by mutableStateOf(false); private set
    var hasMorePages by mutableStateOf(true); private set
    var isRefreshing by mutableStateOf(false); private set
    /** The recommendation whose stage is being validated, for its button. */
    var validatingId by mutableStateOf<String?>(null); private set
    /** Stages validated from this screen, counted for their vibration. */
    var stageAdvances by mutableIntStateOf(0); private set

    private var searchJob: Job? = null
    /** A newer load supersedes an older one still in flight: switching tabs
     *  fast must not let the first answer overwrite the second. */
    private var generation = 0

    val isEmpty get() = state == LoadState.Loaded && recommendations.isEmpty()
    private val trimmedQuery get() = query.trim()

    suspend fun load() {
        val mine = ++generation
        state = LoadState.Loading
        try {
            val (stages, page) = coroutineScope {
                val p = async { repository.loadPipeline() }
                val r = async { repository.loadPage(filter.isArchived, trimmedQuery, null) }
                p.await() to r.await()
            }
            if (mine != generation) return
            pipeline = stages
            recommendations = page
            hasMorePages = page.size == RecommendationsRepository.PAGE_SIZE
            hasStaleData = false
            state = LoadState.Loaded
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (mine == generation) state = LoadState.Failed(e.message ?: "Erreur inconnue")
        }
    }

    fun reload() { scope.launch { load() } }

    /** Pull to refresh, and the banner's "Actualiser". */
    fun refresh() {
        hasStaleData = false
        scope.launch {
            isRefreshing = true
            try { load() } finally { isRefreshing = false }
        }
    }

    fun selectFilter(value: RecommendationFilter) {
        if (value == filter) return
        filter = value
        expandedId = null
        reload()
    }

    /** Debounced so typing a name is one request, not one per keystroke. */
    fun updateQuery(text: String) {
        if (text == query) return
        query = text
        searchJob?.cancel()
        searchJob = scope.launch {
            delay(searchDebounceMillis)
            load()
        }
    }

    /** Called as each card appears; acts for the last one only. Guarded
     *  against re-entry: a fast scroll fires it several times. */
    suspend fun loadNextPageIfNeeded(current: Recommendation) {
        val last = recommendations.lastOrNull() ?: return
        if (!hasMorePages || isLoadingMore || current.id != last.id) return
        val mine = generation
        isLoadingMore = true
        try {
            val page = repository.loadPage(filter.isArchived, trimmedQuery, RecommendationCursor(last.createdAt, last.id))
            if (mine != generation) return
            // a row edited between pages can appear twice
            val known = recommendations.mapTo(HashSet()) { it.id }
            recommendations = recommendations + page.filter { it.id !in known }
            hasMorePages = page.size == RecommendationsRepository.PAGE_SIZE
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            state = LoadState.Failed(e.message ?: "Erreur inconnue")
        } finally {
            isLoadingMore = false
        }
    }

    fun nextStage(recommendation: Recommendation): Stage? = recommendation.nextStage(pipeline)

    /** "Valider l'étape": the next stage not yet reached. Admins only. */
    suspend fun validateNextStage(recommendation: Recommendation) {
        if (!role.isAdmin || validatingId != null) return
        val next = nextStage(recommendation) ?: return
        validatingId = recommendation.id
        try {
            val updated = repository.advanceStage(recommendation.id, next.key)
            recommendations = recommendations.map { if (it.id == updated.id) updated else it }
            stageAdvances++
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            report(e)
        } finally {
            validatingId = null
        }
    }

    fun report(error: Throwable) { state = LoadState.Failed(error.message ?: "Erreur inconnue") }

    fun stage(id: String): Stage? = pipeline.firstOrNull { it.id == id }
}
