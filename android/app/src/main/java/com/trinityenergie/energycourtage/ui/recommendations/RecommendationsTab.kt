package com.trinityenergie.energycourtage.ui.recommendations

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import com.trinityenergie.energycourtage.data.Dependencies
import com.trinityenergie.energycourtage.data.RecommendationEvents
import com.trinityenergie.energycourtage.data.changes
import com.trinityenergie.energycourtage.data.documents
import com.trinityenergie.energycourtage.data.recommendations
import com.trinityenergie.energycourtage.data.reminders
import com.trinityenergie.energycourtage.model.Profile
import com.trinityenergie.energycourtage.model.Recommendation
import com.trinityenergie.energycourtage.model.RecommendationFilter
import com.trinityenergie.energycourtage.ui.components.LoadingBlock
import com.trinityenergie.energycourtage.ui.components.ScreenTitle
import com.trinityenergie.energycourtage.ui.components.SearchField
import com.trinityenergie.energycourtage.ui.components.SegmentedPicker
import com.trinityenergie.energycourtage.ui.theme.BrandBackground
import com.trinityenergie.energycourtage.ui.theme.Spacing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** Everything this tab can raise over itself, one at a time (iOS's single
 *  sheet enum: two presentations at once fight). */
private sealed interface RecoSheet {
    data class Notes(val reco: Recommendation, val body: String) : RecoSheet
    data class Detail(val reco: Recommendation) : RecoSheet
    data class Actions(val reco: Recommendation) : RecoSheet
    data class Reminders(val reco: Recommendation) : RecoSheet
    data class Appointment(val reco: Recommendation) : RecoSheet
}

/**
 * The Recommandations tab (iOS RecommendationsView): Actives / Archivées,
 * server-side search, pages of 20 loaded as the list scrolls, pull to
 * refresh, and the "Actualiser" banner when the server has moved on.
 *
 * @param openRecommendationId a recommendation to open in its detail (a
 *   tapped notification); [onRouteConsumed] is called once it is handled.
 * @param onOpenInvoice opens the invoice screen: "Voir le contrat", and
 *   right after "Établir la facture" has issued one.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecommendationsTab(
    deps: Dependencies,
    openRecommendationId: String?,
    onRouteConsumed: () -> Unit,
    onOpenInvoice: (invoiceId: String) -> Unit,
) {
    val repository = remember(deps) { deps.recommendations() }
    val documents = remember(deps) { deps.documents() }
    val reminders = remember(deps) { deps.reminders() }
    val scope = rememberCoroutineScope()
    val model = remember(deps) { RecommendationsModel(repository, deps.role, scope) }
    val haptics = LocalHapticFeedback.current
    val focus = LocalFocusManager.current
    val routeConsumed by rememberUpdatedState(onRouteConsumed)
    val openInvoice by rememberUpdatedState(onOpenInvoice)

    var sheet by remember { mutableStateOf<RecoSheet?>(null) }
    var comment by remember { mutableStateOf<Pair<String, String>?>(null) }
    var admins by remember { mutableStateOf<List<Profile>>(emptyList()) }

    LaunchedEffect(model) {
        model.load()
        // needed before "Réassigner" can offer anyone; it changes about never
        if (deps.role.isAdmin) admins = runCatching { repository.loadAdmins() }.getOrDefault(emptyList())
    }
    LaunchedEffect(deps) { deps.changes().collect { model.hasStaleData = true } }
    LaunchedEffect(model) { RecommendationEvents.created.collect { model.reload() } }
    LaunchedEffect(model.stageAdvances) { if (model.stageAdvances > 0) haptics.performHapticFeedback(HapticFeedbackType.LongPress) }

    // a notification about one recommendation opens that recommendation
    LaunchedEffect(openRecommendationId) {
        val id = openRecommendationId ?: return@LaunchedEffect
        val reco = model.recommendations.firstOrNull { it.id == id }
            ?: try { repository.recommendation(id) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        if (reco != null) sheet = RecoSheet.Detail(reco)
        routeConsumed()
    }

    fun openNotes(reco: Recommendation) {
        scope.launch {
            val body = try { repository.note(reco.id) } catch (e: CancellationException) { throw e } catch (_: Exception) { "" }
            sheet = RecoSheet.Notes(reco, body)
        }
    }

    fun openContract(reco: Recommendation) {
        val invoiceId = reco.invoiceId ?: return
        sheet = null
        openInvoice(invoiceId)
    }

    fun perform(action: RecoAction, reco: Recommendation) {
        when (action) {
            // reassigning needs a person picked: the detail owns that choice
            RecoAction.Reassign -> { sheet = RecoSheet.Detail(reco); return }
            RecoAction.Reminders -> { sheet = RecoSheet.Reminders(reco); return }
            RecoAction.Appointment -> { sheet = RecoSheet.Appointment(reco); return }
            else -> sheet = null
        }
        scope.launch {
            try {
                when (action) {
                    RecoAction.Reset -> repository.resetPipeline(reco.id)
                    RecoAction.ArchiveWon -> repository.archive(reco.id, won = true)
                    RecoAction.ArchiveLost -> repository.archive(reco.id, won = false)
                    RecoAction.Delete -> repository.softDelete(reco.id)
                    RecoAction.EraseFilleul -> repository.eraseFilleul(reco.id)
                    RecoAction.IssueInvoice -> {
                        // straight into the invoice: it needs both signatures,
                        // and the admin's is one of them
                        val invoiceId = repository.issueInvoice(reco.id)
                        model.load()
                        openInvoice(invoiceId)
                        return@launch
                    }
                    else -> return@launch
                }
                model.load()
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                model.report(e)
            }
        }
    }

    // the keyboard goes as soon as the list is dragged
    val dismissKeyboard = remember {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput && available.y != 0f) focus.clearFocus()
                return Offset.Zero
            }
        }
    }

    BrandBackground {
        PullToRefreshBox(
            isRefreshing = model.isRefreshing,
            onRefresh = { model.refresh() },
            modifier = Modifier.fillMaxSize().statusBarsPadding(),
        ) {
            LazyColumn(
                state = rememberLazyListState(),
                modifier = Modifier.fillMaxSize().nestedScroll(dismissKeyboard),
                contentPadding = PaddingValues(start = Spacing.gutter, end = Spacing.gutter, bottom = Spacing.xl),
                verticalArrangement = Arrangement.spacedBy(Spacing.l),
            ) {
                item(key = "title") { ScreenTitle("Recommandations") }
                item(key = "filter") {
                    SegmentedPicker(
                        selection = model.filter,
                        options = listOf(RecommendationFilter.Active to "Actives", RecommendationFilter.Archived to "Archivées"),
                        onSelect = { model.selectFilter(it) },
                    )
                }
                item(key = "search") { SearchField("Rechercher...", model.query, { model.updateQuery(it) }) }
                if (model.hasStaleData) item(key = "banner") {
                    Box(Modifier.animateItem()) { RefreshBanner { model.refresh() } }
                }

                when (val state = model.state) {
                    RecommendationsModel.LoadState.Idle, RecommendationsModel.LoadState.Loading ->
                        items(3, key = { "skeleton-$it" }) { SkeletonCard() }
                    is RecommendationsModel.LoadState.Failed ->
                        item(key = "error") { RecoErrorState(state.message) { model.reload() } }
                    RecommendationsModel.LoadState.Loaded ->
                        if (model.isEmpty) {
                            item(key = "empty") { RecoEmptyState(model.filter, hasQuery = model.query.isNotEmpty()) }
                        } else {
                            items(model.recommendations, key = { it.id }) { reco ->
                                RecommendationCard(
                                    recommendation = reco,
                                    pipeline = model.pipeline,
                                    role = model.role,
                                    expanded = model.expandedId == reco.id,
                                    validating = model.validatingId == reco.id,
                                    onToggle = {
                                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                        model.expandedId = if (model.expandedId == reco.id) null else reco.id
                                    },
                                    onComment = { row -> row.comment?.let { comment = row.label to it } },
                                    onNotes = { openNotes(reco) },
                                    onContract = { openContract(reco) },
                                    onMore = { sheet = RecoSheet.Detail(reco) },
                                    onValidate = { scope.launch { model.validateNextStage(reco) } },
                                    // the action sheet is the admin's, reached by pressing the
                                    // card rather than by a control the apporteur cannot use
                                    onLongPress = if (model.role.isAdmin) ({ sheet = RecoSheet.Actions(reco) }) else null,
                                    modifier = Modifier.animateItem(),
                                )
                                LaunchedEffect(reco.id) { model.loadNextPageIfNeeded(reco) }
                            }
                            if (model.isLoadingMore) item(key = "more") { LoadingBlock(Modifier.padding(vertical = Spacing.s)) }
                        }
                }
            }
        }
    }

    comment?.let { (label, message) -> StageCommentDialog(label, message) { comment = null } }

    when (val presented = sheet) {
        null -> Unit
        is RecoSheet.Notes -> PersonalNotesSheet(
            initialBody = presented.body,
            onDismiss = { sheet = null },
            save = { text ->
                repository.saveNote(presented.reco.id, text)
                scope.launch { model.load() }
            },
        )
        is RecoSheet.Detail -> {
            val reco = presented.reco
            RecommendationDetailSheet(
                recommendation = reco,
                pipeline = model.pipeline,
                admins = if (model.role.isAdmin) admins else emptyList(),
                documents = documents,
                onDismiss = { sheet = null },
                onOpenInvoice = { openContract(reco) },
                onOpenNotes = { openNotes(reco) },
                onReassign = if (model.role.isAdmin) { adminId ->
                    try {
                        repository.reassign(reco.id, adminId)
                        model.load()
                        sheet = null
                    } catch (e: CancellationException) { throw e } catch (e: Exception) { sheet = null; model.report(e) }
                } else null,
                onSetAmount = if (model.role.isAdmin) { amount ->
                    try {
                        repository.setRewardAmount(reco.id, amount)
                        model.load()
                        sheet = null
                    } catch (e: CancellationException) { throw e } catch (e: Exception) { sheet = null; model.report(e) }
                } else null,
            )
        }
        is RecoSheet.Actions -> RecommendationActionSheet(
            recommendation = presented.reco,
            onDismiss = { sheet = null },
            onAction = { perform(it, presented.reco) },
        )
        is RecoSheet.Reminders -> RemindersSheet(
            recommendationId = presented.reco.id,
            filleulName = presented.reco.filleulName,
            repository = reminders,
            onDismiss = { sheet = null },
        )
        is RecoSheet.Appointment -> AppointmentSheet(
            recommendation = presented.reco,
            save = { at -> repository.setAppointment(presented.reco.id, at); model.refresh() },
            onDismiss = { sheet = null },
        )
    }
}

