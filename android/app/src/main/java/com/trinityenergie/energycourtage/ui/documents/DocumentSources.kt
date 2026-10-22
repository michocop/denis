package com.trinityenergie.energycourtage.ui.documents

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.provider.OpenableColumns
import com.trinityenergie.energycourtage.model.DocumentException
import com.trinityenergie.energycourtage.model.DocumentUpload
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Turning what the person picked into an upload (iOS DocumentSources).
 *
 * Photos are shrunk to at most 2400 px on their long side and saved as JPEG
 * at 75 %: a bill photographed on a recent phone is 5-10 MB as it comes, and
 * perfectly legible at a quarter of that. PDFs go as they are.
 */
object DocumentSources {
    const val LONGEST_SIDE = 2400
    const val JPEG_QUALITY = 75

    /** The size an image of [width]×[height] is drawn at: never enlarged. */
    fun targetSize(width: Int, height: Int, longest: Int = LONGEST_SIDE): Pair<Int, Int> {
        val scale = min(1.0, longest.toDouble() / max(max(width, height), 1))
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    /** The largest power-of-two subsampling that still leaves the long side
     *  at least [longest] px: decoding a 48 MP photo whole would not fit. */
    fun sampleSize(width: Int, height: Int, longest: Int = LONGEST_SIDE): Int {
        var sample = 1
        while (max(width, height) / (sample * 2) >= longest) sample *= 2
        return sample
    }

    /** A photo as a resized, upright JPEG, or null if it cannot be read. */
    fun jpeg(bytes: ByteArray, name: String): DocumentUpload? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val viaFactory = bounds.outWidth > 0 && bounds.outHeight > 0
        val decoded = if (viaFactory) {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight) })
        } else decodeWithImageDecoder(bytes)
        decoded ?: return null
        // ImageDecoder has already turned the image upright
        val rotation = if (viaFactory) exifRotation(bytes) else 0

        val (w, h) = targetSize(decoded.width, decoded.height)
        val matrix = Matrix().apply {
            postScale(w.toFloat() / decoded.width, h.toFloat() / decoded.height)
            postRotate(rotation.toFloat())
        }
        val upright = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        val out = ByteArrayOutputStream()
        upright.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
        if (upright !== decoded) upright.recycle()
        decoded.recycle()
        return DocumentUpload(out.toByteArray(), "$name.jpg", "image/jpeg")
    }

    /** HEIC and the like, which BitmapFactory cannot read before Android 9. */
    private fun decodeWithImageDecoder(bytes: ByteArray): Bitmap? {
        if (android.os.Build.VERSION.SDK_INT < 28) return null
        return runCatching {
            val source = android.graphics.ImageDecoder.createSource(java.nio.ByteBuffer.wrap(bytes))
            android.graphics.ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val (w, h) = targetSize(info.size.width, info.size.height)
                decoder.setTargetSize(w, h)
                decoder.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }.getOrNull()
    }

    /** BitmapFactory ignores EXIF: a phone held upright saves a sideways
     *  image with a "rotate 90°" tag. */
    private fun exifRotation(bytes: ByteArray): Int = runCatching {
        when (ExifInterface(bytes.inputStream()).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> 0
        }
    }.getOrDefault(0)

    /** Picked photos, "Photo 1", "Photo 2"…; those that cannot be read are left out. */
    suspend fun fromPhotos(context: Context, uris: List<Uri>): List<DocumentUpload> = withContext(Dispatchers.IO) {
        uris.mapIndexedNotNull { index, uri ->
            runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
                ?.let { jpeg(it, "Photo ${index + 1}") }
        }
    }

    /** A picked file: a PDF as it is, an image resized. Anything else, or a
     *  PDF over the limit, throws [DocumentException]. */
    suspend fun fromFile(context: Context, uri: Uri): DocumentUpload = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "Document"
        var size = -1L
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { name = it }
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
        }
        val type = resolver.getType(uri) ?: when {
            name.lowercase().endsWith(".pdf") -> "application/pdf"
            name.lowercase().matches(Regex(".*\\.(jpe?g|png|heic|heif|webp)$")) -> "image/*"
            else -> ""
        }
        when {
            type == "application/pdf" -> {
                if (size > DocumentUpload.MAX_BYTES) throw DocumentException(DocumentException.Kind.TooLarge)
                val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw DocumentException(DocumentException.Kind.Unsupported)
                if (bytes.size > DocumentUpload.MAX_BYTES) throw DocumentException(DocumentException.Kind.TooLarge)
                DocumentUpload(bytes, if (name.lowercase().endsWith(".pdf")) name else "$name.pdf", "application/pdf")
            }
            type.startsWith("image/") -> {
                val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw DocumentException(DocumentException.Kind.Unsupported)
                jpeg(bytes, name.substringBeforeLast('.')) ?: throw DocumentException(DocumentException.Kind.Unsupported)
            }
            else -> throw DocumentException(DocumentException.Kind.Unsupported)
        }
    }

    /** The scanner's PDF, named as iOS names it: "Facture scannée 22 oct. 2026.pdf". */
    suspend fun fromScan(context: Context, pdf: Uri, stamp: String): DocumentUpload? = withContext(Dispatchers.IO) {
        runCatching { context.contentResolver.openInputStream(pdf)?.use { it.readBytes() } }.getOrNull()
            ?.let { DocumentUpload(it, "Facture scannée $stamp.pdf", "application/pdf") }
    }
}
