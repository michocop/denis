package com.trinityenergie.energycourtage.ui.documents

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DocumentScanner
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.trinityenergie.energycourtage.core.Dates
import com.trinityenergie.energycourtage.data.DocumentsRepository
import com.trinityenergie.energycourtage.model.DocumentException
import com.trinityenergie.energycourtage.model.DocumentUpload
import com.trinityenergie.energycourtage.model.LeadDocument
import com.trinityenergie.energycourtage.ui.components.Files
import com.trinityenergie.energycourtage.ui.theme.Palette
import com.trinityenergie.energycourtage.ui.theme.Spacing
import com.trinityenergie.energycourtage.ui.theme.Type
import com.trinityenergie.energycourtage.ui.theme.brandGlass
import com.trinityenergie.energycourtage.ui.theme.cardSurface
import kotlinx.coroutines.launch
import java.time.Instant

// ------------------------------------------------------- the "Ajouter" menu

/** Whether the system document scanner can start here: it needs Google Play
 *  services and a camera. Once it has failed to start, it is not offered
 *  again in this run. */
private object Scanner {
    var failed = false
    private var prefetched = false

    val options: GmsDocumentScannerOptions = GmsDocumentScannerOptions.Builder()
        .setGalleryImportAllowed(false)
        .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_PDF)
        .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
        .build()

    /** The scanner is a Play services module downloaded on first use, behind
     *  a Google screen that fails without a connection. Fetching it as soon
     *  as Documents shows means the first scan opens at once. */
    fun prefetch(context: Context) {
        if (prefetched) return
        prefetched = true
        runCatching {
            val request = ModuleInstallRequest.newBuilder().addApi(GmsDocumentScanning.getClient(options)).build()
            ModuleInstall.getClient(context).installModules(request)
        }
    }

    fun isAvailable(context: Context): Boolean = !failed &&
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) &&
        runCatching { GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS }
            .getOrDefault(false)
}

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/**
 * Scan, photo or file: the three ways a bill reaches a phone. Calls back with
 * uploads ready to send (iOS AddDocumentButton).
 */
@Composable
fun AddDocumentButton(
    title: String = "Ajouter un document",
    enabled: Boolean = true,
    onPicked: (List<DocumentUpload>) -> Unit,
    onError: (String) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var reading by remember { mutableStateOf(false) }
    val scannerAvailable = remember { Scanner.isAvailable(context) }
    LaunchedEffect(scannerAvailable) { if (scannerAvailable) Scanner.prefetch(context.applicationContext) }

    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(5)) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            reading = true
            val uploads = DocumentSources.fromPhotos(context, uris)
            reading = false
            if (uploads.isEmpty()) onError("Ces photos n'ont pas pu être lues.") else onPicked(uploads)
        }
    }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            reading = true
            val uploads = mutableListOf<DocumentUpload>()
            var error: String? = null
            for (uri in uris) {
                try { uploads += DocumentSources.fromFile(context, uri) }
                catch (e: DocumentException) { error = e.message }
                catch (e: Exception) { error = DocumentException(DocumentException.Kind.Unsupported).message }
            }
            reading = false
            if (uploads.isNotEmpty()) onPicked(uploads)
            error?.let(onError)
        }
    }
    val scanner = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result: ActivityResult ->
        if (result.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult
        val pdf = GmsDocumentScanningResult.fromActivityResultIntent(result.data)?.pdf?.uri
            ?: return@rememberLauncherForActivityResult
        scope.launch {
            reading = true
            val upload = DocumentSources.fromScan(context, pdf, Dates.medium(Instant.now()))
            reading = false
            when {
                upload == null -> onError("Le scan n'a pas pu être lu.")
                upload.data.size > DocumentUpload.MAX_BYTES -> onError(DocumentException(DocumentException.Kind.TooLarge).message!!)
                else -> onPicked(listOf(upload))
            }
        }
    }

    fun startScanner() {
        val activity = context.activity() ?: run { Scanner.failed = true; onError("Le scanner n'est pas disponible sur ce téléphone."); return }
        GmsDocumentScanning.getClient(Scanner.options).getStartScanIntent(activity)
            .addOnSuccessListener { sender -> scanner.launch(IntentSenderRequest.Builder(sender).build()) }
            .addOnFailureListener {
                Scanner.failed = true
                onError("Le scanner n'est pas disponible sur ce téléphone.")
            }
    }

    val active = enabled && !reading
    Box(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .alpha(if (active) 1f else 0.5f)
                .brandGlass()
                .clickable(enabled = active, role = Role.Button) { menu = true }
                .padding(vertical = 14.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (reading) CircularProgressIndicator(Modifier.size(18.dp), color = Palette.brand, strokeWidth = 2.dp)
            else Icon(Icons.Filled.AttachFile, null, tint = Palette.textPrimary, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(Spacing.s))
            Text(title, style = Type.body.copy(fontWeight = Type.button.fontWeight), color = Palette.textPrimary)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, containerColor = Palette.surface) {
            if (scannerAvailable && !Scanner.failed) {
                MenuItem("Scanner une facture", Icons.Filled.DocumentScanner) { menu = false; startScanner() }
            }
            MenuItem("Choisir des photos", Icons.Filled.PhotoLibrary) {
                menu = false
                photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
            MenuItem("Choisir un fichier", Icons.Filled.Folder) {
                menu = false
                files.launch(arrayOf("application/pdf", "image/*"))
            }
        }
    }
}

@Composable
private fun MenuItem(title: String, icon: ImageVector, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(title, style = Type.body) },
        leadingIcon = { Icon(icon, null) },
        onClick = onClick,
        colors = MenuDefaults.itemColors(textColor = Palette.textPrimary, leadingIconColor = Palette.textPrimary),
    )
}

// ----------------------------------------------------- a lead's documents

/** The documents section of a recommendation's detail (iOS
 *  LeadDocumentsSection): the list, opened in the phone's viewer on a tap,
 *  "Retirer" on a long press, and the add menu. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LeadDocumentsSection(recommendationId: String, repository: DocumentsRepository) {
    val context = LocalContext.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val documents = remember { mutableStateListOf<LeadDocument>() }
    var loading by remember { mutableStateOf(true) }
    var uploading by remember { mutableStateOf(false) }
    var opening by remember { mutableStateOf<String?>(null) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun load() {
        try {
            val list = repository.documents(recommendationId)
            documents.clear(); documents.addAll(list)
        } catch (e: Exception) {
            error = e.message
        }
        loading = false
    }

    LaunchedEffect(recommendationId) { load() }

    Column(
        Modifier.fillMaxWidth().cardSurface().padding(Spacing.cardPadding),
        verticalArrangement = Arrangement.spacedBy(Spacing.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Documents", style = Type.body.copy(fontWeight = Type.button.fontWeight), color = Palette.textPrimary,
                modifier = Modifier.weight(1f))
            if (uploading || loading) CircularProgressIndicator(Modifier.size(18.dp), color = Palette.brand, strokeWidth = 2.dp)
        }

        if (!loading && documents.isEmpty()) {
            Text("Ajoutez la facture d'énergie du filleul : c'est elle qui permet de comparer les offres.",
                style = Type.secondary, color = Palette.textSecondary)
        }

        documents.forEach { document ->
            Box {
                DocumentRow(
                    document = document,
                    opening = opening == document.id,
                    modifier = Modifier
                        .combinedClickable(
                            onClick = {
                                if (opening != null) return@combinedClickable
                                scope.launch {
                                    opening = document.id
                                    try {
                                        val bytes = repository.data(document)
                                        Files.open(context, bytes, document.filename, document.viewerMimeType)
                                    } catch (e: Exception) {
                                        error = e.message
                                    }
                                    opening = null
                                }
                            },
                            onLongClick = { haptics.performHapticFeedback(HapticFeedbackType.LongPress); menuFor = document.id },
                        )
                        .semantics { contentDescription = "${document.filename}, ${document.subtitle}. Ouvrir le document" },
                )
                DropdownMenu(expanded = menuFor == document.id, onDismissRequest = { menuFor = null }, containerColor = Palette.surface) {
                    DropdownMenuItem(
                        text = { Text("Retirer", style = Type.body) },
                        leadingIcon = { Icon(Icons.Filled.Delete, null) },
                        colors = MenuDefaults.itemColors(textColor = Palette.destructive, leadingIconColor = Palette.destructive),
                        onClick = {
                            menuFor = null
                            scope.launch {
                                try { repository.remove(document); load() } catch (e: Exception) { error = e.message }
                            }
                        },
                    )
                }
            }
        }

        error?.let { Text(it, style = Type.secondary, color = Palette.destructive) }

        AddDocumentButton(
            enabled = !uploading,
            onPicked = { uploads ->
                scope.launch {
                    uploading = true
                    error = null
                    for (upload in uploads) {
                        try { repository.add(upload, recommendationId) }
                        catch (e: Exception) { error = "${upload.filename} : ${e.message}" }
                    }
                    load()
                    uploading = false
                }
            },
            onError = { error = it },
        )
    }
}

@Composable
private fun DocumentRow(document: LeadDocument, opening: Boolean, modifier: Modifier) {
    Row(modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacing.m)) {
        Box(Modifier.size(38.dp).background(Palette.brandSoft, CircleShape), contentAlignment = Alignment.Center) {
            Icon(if (document.isPdf) Icons.Filled.PictureAsPdf else Icons.Filled.Image, null, tint = Palette.brand, modifier = Modifier.size(18.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(document.filename, style = Type.label, color = Palette.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(document.subtitle, style = Type.caption, color = Palette.textSecondary, maxLines = 1)
        }
        if (opening) CircularProgressIndicator(Modifier.size(16.dp), color = Palette.brand, strokeWidth = 2.dp)
        else Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.textSecondary, modifier = Modifier.size(18.dp))
    }
}
