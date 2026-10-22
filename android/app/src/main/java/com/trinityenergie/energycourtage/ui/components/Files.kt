package com.trinityenergie.energycourtage.ui.components

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File

/**
 * Files the app hands to the phone: a PDF to read, a document or an export to
 * send (iOS Quick Look and ShareLink). Written to the cache under a readable
 * name and offered through the FileProvider, never with a file:// path.
 */
object Files {
    private fun cached(context: Context, bytes: ByteArray, filename: String): Uri {
        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        val safe = filename.replace(Regex("[/\\\\:*?\"<>|]"), "-")
        val file = File(dir, safe).apply { writeBytes(bytes) }
        return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    }

    /** Opens the file in the phone's viewer (a PDF reader, the gallery). */
    fun open(context: Context, bytes: ByteArray, filename: String, mimeType: String = "application/pdf") {
        val uri = cached(context, bytes, filename)
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeType)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            // no viewer installed: offer to send it somewhere that can open it
            share(context, bytes, filename, mimeType)
        }
    }

    /** The share sheet with a file attached. */
    fun share(context: Context, bytes: ByteArray, filename: String, mimeType: String, title: String = filename) {
        val uri = cached(context, bytes, filename)
        val send = Intent(Intent.ACTION_SEND).setType(mimeType).putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(send, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** The share sheet with text: SMS, WhatsApp, mail. */
    fun shareText(context: Context, text: String, title: String = "Partager") {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
        context.startActivity(Intent.createChooser(send, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    /** Opens the dialer on a number (the tel: link of the action sheet). */
    fun dial(context: Context, phone: String) {
        runCatching {
            context.startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:${phone.filter { it.isDigit() || it == '+' }}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { Toast.makeText(context, phone, Toast.LENGTH_LONG).show() }
    }
}
