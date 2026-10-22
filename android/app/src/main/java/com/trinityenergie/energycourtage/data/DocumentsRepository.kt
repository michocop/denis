package com.trinityenergie.energycourtage.data

import com.trinityenergie.energycourtage.core.SupabaseClient
import com.trinityenergie.energycourtage.model.DocumentException
import com.trinityenergie.energycourtage.model.DocumentUpload
import com.trinityenergie.energycourtage.model.LeadDocument
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.time.Instant
import java.util.UUID

interface DocumentsRepository {
    suspend fun documents(recommendationId: String): List<LeadDocument>
    suspend fun add(upload: DocumentUpload, recommendationId: String): LeadDocument
    suspend fun data(document: LeadDocument): ByteArray
    suspend fun remove(document: LeadDocument)

    companion object {
        const val BUCKET = "documents"

        /** `<recoId>/<uuid>.<ext>`, lowercase, as the storage policy expects. */
        fun storagePath(recommendationId: String, upload: DocumentUpload, uuid: String = UUID.randomUUID().toString()) =
            "${recommendationId.lowercase()}/${uuid.lowercase()}.${upload.fileExtension}"

        /** Checked before a byte is sent: the server's own limits. */
        fun validate(upload: DocumentUpload) {
            if (upload.data.size > DocumentUpload.MAX_BYTES) throw DocumentException(DocumentException.Kind.TooLarge)
            if (upload.mimeType !in DocumentUpload.ACCEPTED) throw DocumentException(DocumentException.Kind.Unsupported)
        }
    }
}

fun Dependencies.documents(): DocumentsRepository =
    if (isDemo) DemoDocumentsRepository else SupabaseDocumentsRepository(requireClient())

/** Bytes in the private `documents` bucket, listed in the `documents` table.
 *  Uploading is the file, then `register_document`, which checks the file is
 *  really there, under this lead, of an accepted type and size. */
class SupabaseDocumentsRepository(private val client: SupabaseClient) : DocumentsRepository {
    override suspend fun documents(recommendationId: String): List<LeadDocument> =
        client.decode(client.select("documents", "recommendation_id=eq.$recommendationId&order=created_at.desc"))

    override suspend fun add(upload: DocumentUpload, recommendationId: String): LeadDocument {
        DocumentsRepository.validate(upload)
        val path = DocumentsRepository.storagePath(recommendationId, upload)
        client.upload(DocumentsRepository.BUCKET, path, upload.data, upload.mimeType)
        return client.decode(client.rpc("register_document", buildJsonObject {
            put("p_recommendation_id", recommendationId)
            put("p_path", path)
            put("p_filename", upload.filename)
            put("p_byte_size", upload.data.size)
            put("p_mime_type", upload.mimeType)
            put("p_kind", upload.kind)
        }))
    }

    override suspend fun data(document: LeadDocument): ByteArray =
        client.download(DocumentsRepository.BUCKET, document.storagePath)

    /** The row first, so the list never shows a file that is gone; the bytes
     *  after. A failure between leaves an unlisted file, not a broken row. */
    override suspend fun remove(document: LeadDocument) {
        val path = (client.rpc("remove_document", buildJsonObject { put("p_document_id", document.id) }) as? JsonPrimitive)
            ?.jsonPrimitive?.content ?: document.storagePath
        runCatching { client.removeFile(DocumentsRepository.BUCKET, path) }
    }
}

/** Documents for the demo: kept in memory for as long as the app runs. */
object DemoDocumentsRepository : DocumentsRepository {
    private val files = linkedMapOf<String, Pair<LeadDocument, ByteArray>>()

    override suspend fun documents(recommendationId: String): List<LeadDocument> = synchronized(this) {
        files.values.map { it.first }.filter { it.recommendationId == recommendationId }.sortedByDescending { it.createdAt }
    }

    override suspend fun add(upload: DocumentUpload, recommendationId: String): LeadDocument {
        DocumentsRepository.validate(upload)
        delay(250)
        val doc = LeadDocument(
            id = UUID.randomUUID().toString(), recommendationId = recommendationId, kind = upload.kind,
            storagePath = DocumentsRepository.storagePath(recommendationId, upload), filename = upload.filename,
            byteSize = upload.data.size.toLong(), mimeType = upload.mimeType, uploadedBy = Demo.me, createdAt = Instant.now(),
        )
        synchronized(this) { files[doc.id] = doc to upload.data }
        return doc
    }

    override suspend fun data(document: LeadDocument): ByteArray = synchronized(this) { files[document.id]?.second ?: ByteArray(0) }

    override suspend fun remove(document: LeadDocument) { synchronized(this) { files.remove(document.id) } }

    fun removeAll(recommendationId: String) = synchronized(this) { files.values.removeAll { it.first.recommendationId == recommendationId } }
}
