package com.sansebas.nexus.mobile

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/** Remuxes complete encoded samples; source bytes are never sliced or modified. */
object M4aSegmenter {
    fun split(inputPath: String, outputDirectory: String, baseName: String, partCount: Int): List<String> {
        val extractor = MediaExtractor()
        extractor.setDataSource(inputPath)
        require(extractor.trackCount > 0) { "M4A has no media tracks" }
        val formats = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
        val totalDurationUs = formats.maxOfOrNull { format ->
            if (format.containsKey(android.media.MediaFormat.KEY_DURATION))
                format.getLong(android.media.MediaFormat.KEY_DURATION) else 0L
        } ?: 0L
        require(totalDurationUs > 0 && partCount >= 2) { "M4A duration is unavailable" }
        val partDurationUs = (totalDurationUs / partCount).coerceAtLeast(1L)
        formats.indices.forEach(extractor::selectTrack)
        val maxInputSize = formats.maxOfOrNull { format ->
            if (format.containsKey(android.media.MediaFormat.KEY_MAX_INPUT_SIZE))
                format.getInteger(android.media.MediaFormat.KEY_MAX_INPUT_SIZE) else 1024 * 1024
        } ?: 1024 * 1024
        val buffer = ByteBuffer.allocateDirect(maxInputSize.coerceAtLeast(1024 * 1024))
        val info = MediaCodec.BufferInfo()
        val outputPaths = mutableListOf<String>()
        var muxer: MediaMuxer? = null
        var outputTracks = emptyList<Int>()
        var partStartUs = -1L
        var partIndex = 0

        fun openMuxer(sampleTimeUs: Long) {
            val path = File(outputDirectory, "${baseName}_${partIndex.toString().padStart(3, '0')}.m4a")
            if (path.exists()) path.delete()
            muxer = MediaMuxer(path.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            outputTracks = formats.map { muxer!!.addTrack(it) }
            muxer!!.start()
            partStartUs = sampleTimeUs
            outputPaths.add(path.path)
            partIndex++
        }

        try {
            while (true) {
                val inputTrack = extractor.sampleTrackIndex
                if (inputTrack < 0) break
                val sampleTime = extractor.sampleTime
                if (muxer == null) openMuxer(sampleTime)
                if (sampleTime - partStartUs >= partDurationUs) {
                    muxer!!.stop()
                    muxer!!.release()
                    muxer = null
                    openMuxer(sampleTime)
                }
                buffer.clear()
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                info.set(0, size, sampleTime - partStartUs, extractor.sampleFlags)
                muxer!!.writeSampleData(outputTracks[inputTrack], buffer, info)
                extractor.advance()
            }
        } finally {
            try { muxer?.stop() } catch (_: Exception) { }
            muxer?.release()
            extractor.release()
        }
        require(outputPaths.size >= 2) { "Expected at least two recovery parts" }
        return outputPaths
    }
}
