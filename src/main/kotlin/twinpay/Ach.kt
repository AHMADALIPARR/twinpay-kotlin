// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Ahmad Parr

package twinpay

/**
 * NACHA CCD file builder for token-to-fiat redemption.
 * Pure function: same input always yields the same file.
 * Record layout follows the Nacha file format (94-char records,
 * blocking factor 10): File Header (1), Batch Header (5),
 * Entry Detail (6), Batch Control (8), File Control (9).
 */
object Ach {
    fun abaCheck(routing: String): Boolean {
        if (routing.length != 9 || !routing.all { it.isDigit() }) return false
        val d = routing.map { it.digitToInt() }
        val sum = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
        return sum % 10 == 0
    }

    data class Entry(val routing: String, val account: String, val amountCents: Long, val name: String, val id: String)

    /**
     * Builds a balanced credits-only CCD file. Returns the file text,
     * or a failure naming the first invalid field. Every line is
     * exactly 94 characters.
     */
    fun buildFile(
        entries: List<Entry>,
        effectiveDate: String,
        odfiRouting: String = "021000021"
    ): Result<String> {
        if (entries.isEmpty()) return Result.failure(IllegalArgumentException("no_entries"))
        if (!abaCheck(odfiRouting)) return Result.failure(IllegalArgumentException("invalid_odfi_routing"))
        for (e in entries) {
            if (!abaCheck(e.routing)) return Result.failure(IllegalArgumentException("invalid_routing"))
            if (e.account.isEmpty() || !e.account.all { it.isDigit() })
                return Result.failure(IllegalArgumentException("invalid_account"))
            if (e.amountCents <= 0) return Result.failure(IllegalArgumentException("invalid_amount"))
        }

        val now = java.time.LocalDateTime.now()
        val fileDate = now.format(java.time.format.DateTimeFormatter.ofPattern("yyMMdd"))
        val fileTime = now.format(java.time.format.DateTimeFormatter.ofPattern("HHmm"))
        val odfi8 = odfiRouting.take(8)
        val company = Config.companyName.padEnd(23, ' ').take(23)
        val batchNo = 1

        val lines = mutableListOf<String>()

        // File Header (1): 1+2+10+10+6+4+1+3+2+1+23+23+8 = 94
        lines += "1" + "01" +
            (" $odfiRouting").padEnd(10, ' ').take(10) +
            "1000000000" +
            fileDate + fileTime + "A" + "094" + "10" + "1" +
            company + company +
            " ".repeat(8)

        // Batch Header (5): 1+3+16+20+10+3+10+6+6+3+1+8+7 = 94
        lines += "5" + "225" +
            Config.companyName.padEnd(16, ' ').take(16) +
            " ".repeat(20) +
            Config.companyId.padEnd(10, ' ').take(10) +
            "CCD" +
            "TWIN REDEEM".padEnd(10, ' ').take(10) +
            " ".repeat(6) +
            effectiveDate +
            " ".repeat(3) +
            "1" +
            odfi8 +
            batchNo.toString().padStart(7, '0')

        // Entry Detail (6): 1+2+8+1+17+10+15+22+2+1+15 = 94
        var entrySeq = 0
        var batchCredits = 0L
        var entryHash = 0L
        for (e in entries) {
            entrySeq++
            batchCredits += e.amountCents
            entryHash += e.routing.take(8).toLong()
            lines += "6" + "22" +
                e.routing.take(8) +
                e.routing[8].toString() +
                e.account.padEnd(17, ' ').take(17) +
                e.amountCents.toString().padStart(10, '0') +
                e.id.padEnd(15, ' ').take(15) +
                e.name.padEnd(22, ' ').take(22) +
                "  " +
                "0" +
                odfi8 +
                entrySeq.toString().padStart(7, '0')
        }

        // Batch Control (8): 1+3+6+10+12+12+10+19+6+8+7 = 94
        val hash10 = (entryHash % 10_000_000_000L).toString().padStart(10, '0')
        lines += "8" + "225" +
            entrySeq.toString().padStart(6, '0') +
            hash10 +
            "0".repeat(12) +
            batchCredits.toString().padStart(12, '0') +
            Config.companyId.padEnd(10, ' ').take(10) +
            " ".repeat(19) +
            " ".repeat(6) +
            odfi8 +
            batchNo.toString().padStart(7, '0')

        // File Control (9): 1+6+6+8+10+12+12+39 = 94.
        // Block count depends on 9-padding, so compute it first.
        val paddedSize = ((lines.size + 1 + 9) / 10) * 10
        val blockCount = paddedSize / 10
        lines += "9" +
            "1".padStart(6, '0') +
            blockCount.toString().padStart(6, '0') +
            entrySeq.toString().padStart(8, '0') +
            hash10 +
            "0".repeat(12) +
            batchCredits.toString().padStart(12, '0') +
            " ".repeat(39)
        while (lines.size < paddedSize) lines += "9".repeat(94)

        for ((i, l) in lines.withIndex()) {
            if (l.length != 94) return Result.failure(IllegalStateException("line $i length ${l.length}"))
        }
        return Result.success(lines.joinToString("\n") + "\n")
    }
}
