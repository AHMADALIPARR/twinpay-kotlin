package twinpay

import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Append-only SHA-256 hash-chained log implementing the finance-twin WORM
 * discipline in pure Kotlin (no JNI): every block links to the previous
 * block's hash, so history cannot be rewritten without breaking the chain.
 *
 * Block layout (4236 bytes):
 *   0..3    magic "WORM"
 *   4..67   prev block SHA-256, lowercase hex (64 ascii chars)
 *   68..131 this block SHA-256, lowercase hex (64 ascii chars)
 *   132..135 block index, big-endian
 *   136..4231 payload, zero-padded to 4096 bytes
 *
 * blockHash = SHA256(prevHashAscii || payload4096), hex-encoded.
 */
class Worm(dataFile: File) {
    data class Receipt(val index: Long, val hash: String)

    companion object {
        const val PAYLOAD_SIZE = 4096
        const val BLOCK_SIZE = 4 + 64 + 64 + 4 + PAYLOAD_SIZE // 4236
        const val MAGIC = "WORM"
        val GENESIS_PREV = "0".repeat(64)
    }

    private val lock = ReentrantLock()
    private val raf: RandomAccessFile

    private var prevHash: String
    private var count: Long

    init {
        dataFile.parentFile?.mkdirs()
        raf = RandomAccessFile(dataFile, "rw")
        val len = raf.length()
        require(len % BLOCK_SIZE == 0L) { "worm file corrupt: length not a multiple of block size" }
        count = len / BLOCK_SIZE
        prevHash = if (count == 0L) {
            GENESIS_PREV
        } else {
            raf.seek((count - 1) * BLOCK_SIZE + 68)
            val hb = ByteArray(64)
            raf.readFully(hb)
            String(hb, Charsets.US_ASCII)
        }
    }

    fun count(): Long = lock.withLock { count }

    /** Append one payload block; returns its index and hash. */
    fun commit(payload: ByteArray): Receipt {
        require(payload.size <= PAYLOAD_SIZE) { "payload too large" }
        return lock.withLock {
            val padded = payload + ByteArray(PAYLOAD_SIZE - payload.size)
            val hashHex = sha256Hex(prevHash.toByteArray(Charsets.US_ASCII) + padded)

            val block = ByteArray(BLOCK_SIZE)
            MAGIC.toByteArray(Charsets.US_ASCII).copyInto(block, 0)
            prevHash.toByteArray(Charsets.US_ASCII).copyInto(block, 4)
            hashHex.toByteArray(Charsets.US_ASCII).copyInto(block, 68)
            block[132] = ((count ushr 24) and 0xFF).toByte()
            block[133] = ((count ushr 16) and 0xFF).toByte()
            block[134] = ((count ushr 8) and 0xFF).toByte()
            block[135] = (count and 0xFF).toByte()
            padded.copyInto(block, 136)

            raf.seek(raf.length())
            raf.write(block)
            raf.fd.sync()

            val receipt = Receipt(count, hashHex)
            prevHash = hashHex
            count++
            receipt
        }
    }

    /** Walk the whole chain; returns block count on success, throws on break. */
    fun verify(): Long = lock.withLock {
        var prev = GENESIS_PREV
        val buf = ByteArray(BLOCK_SIZE)
        for (i in 0 until count) {
            raf.seek(i * BLOCK_SIZE)
            raf.readFully(buf)
            require(String(buf, 0, 4, Charsets.US_ASCII) == MAGIC) { "bad magic at $i" }
            val filePrev = String(buf, 4, 64, Charsets.US_ASCII)
            require(filePrev == prev) { "prev-hash mismatch at $i" }
            val fileHash = String(buf, 68, 64, Charsets.US_ASCII)
            val idx = ((buf[132].toLong() and 0xFF) shl 24) or
                ((buf[133].toLong() and 0xFF) shl 16) or
                ((buf[134].toLong() and 0xFF) shl 8) or
                (buf[135].toLong() and 0xFF)
            require(idx == i) { "index mismatch at $i" }
            val payload = buf.copyOfRange(136, 136 + PAYLOAD_SIZE)
            val recomputed = sha256Hex(prev.toByteArray(Charsets.US_ASCII) + payload)
            require(recomputed == fileHash) { "hash mismatch at $i" }
            prev = fileHash
        }
        count
    }

    fun close() = raf.close()

    private fun sha256Hex(data: ByteArray): String {
        val d = MessageDigest.getInstance("SHA-256").digest(data)
        return d.joinToString("") { "%02x".format(it) }
    }
}

/**
 * 128-byte fixed entry payload, same text discipline as the twin's
 * worm_block.h: space-padded fields, zero-padded amount, kind char.
 *   0..35   tx id, space padded (36)
 *   36..49  timestamp YYYYMMDDHHMMSS (14)
 *   50..59  seq, zero padded (10)
 *   60..75  source, space padded (16)
 *   76..91  dest, space padded (16)
 *   92..107 amount signed minor units, zero padded (16)
 *   108..110 currency "TWN" (3)
 *   111     kind char: T transfer, I issue, B burn, R reversal
 *   112..127 zeros
 */
object EntryCodec {
    fun encode(txId: String, src: String, dst: String, amount: Long, kind: Char, seq: Long): ByteArray {
        require(amount >= -999_999_999_999_999L && amount <= 999_999_999_999_999L)
        val buf = ByteArray(128)
        fun put(off: Int, len: Int, text: String, pad: Char = ' ') {
            val t = text.take(len).padEnd(len, pad)
            t.toByteArray(Charsets.US_ASCII).copyInto(buf, off)
        }
        val ts = java.time.LocalDateTime.now(java.time.ZoneOffset.UTC)
            .format(java.time.format.DateTimeFormatter.ofPattern("yyyyMMddHHmmss"))
        put(0, 36, txId)
        put(36, 14, ts)
        put(50, 10, seq.toString().padStart(10, '0'), '0')
        put(60, 16, src)
        put(76, 16, dst)
        val amt = if (amount < 0) "-" + (-amount).toString().padStart(15, '0')
        else amount.toString().padStart(16, '0')
        put(92, 16, amt, '0')
        put(108, 3, "TWN")
        buf[111] = kind.code.toByte()
        return buf
    }
}
