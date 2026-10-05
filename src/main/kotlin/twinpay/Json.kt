package twinpay

/** Minimal JSON parser/encoder, zero dependencies. Objects -> Map<String, JVal>. */
sealed interface JVal {
    data class Obj(val map: Map<String, JVal>) : JVal
    data class Arr(val list: List<JVal>) : JVal
    data class Str(val s: String) : JVal
    data class Num(val n: Number) : JVal
    data object True : JVal
    data object False : JVal
    data object Null : JVal
}

object Json {
    fun parse(text: String): JVal {
        val p = Parser(text)
        val v = p.value()
        p.ws()
        if (!p.eof()) throw JsonError("trailing data")
        return v
    }

    fun stringify(v: JVal): String = buildString { render(v) }

    private fun StringBuilder.render(v: JVal) {
        when (v) {
            is JVal.Obj -> {
                append('{')
                v.map.entries.forEachIndexed { i, (k, vv) ->
                    if (i > 0) append(',')
                    string(k); append(':'); render(vv)
                }
                append('}')
            }
            is JVal.Arr -> {
                append('[')
                v.list.forEachIndexed { i, e -> if (i > 0) append(','); render(e) }
                append(']')
            }
            is JVal.Str -> string(v.s)
            is JVal.Num -> append(v.n.toString())
            JVal.True -> append("true")
            JVal.False -> append("false")
            JVal.Null -> append("null")
        }
    }

    private fun StringBuilder.string(s: String) {
        append('"')
        for (c in s) when (c) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (c.code < 0x20) append("\\u%04x".format(c.code)) else append(c)
        }
        append('"')
    }

    class JsonError(msg: String) : RuntimeException(msg)

    private class Parser(val s: String) {
        var pos = 0
        fun eof() = pos >= s.length
        fun ws() { while (!eof() && s[pos].isWhitespace()) pos++ }
        fun value(): JVal {
            ws()
            if (eof()) throw JsonError("unexpected end")
            return when (s[pos]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> JVal.Str(str())
                't' -> lit("true", JVal.True)
                'f' -> lit("false", JVal.False)
                'n' -> lit("null", JVal.Null)
                '-', in '0'..'9' -> num()
                else -> throw JsonError("bad value at $pos")
            }
        }
        fun lit(word: String, v: JVal): JVal {
            if (!s.startsWith(word, pos)) throw JsonError("bad literal")
            pos += word.length
            return v
        }
        fun obj(): JVal.Obj {
            pos++ // {
            val m = LinkedHashMap<String, JVal>()
            ws()
            if (!eof() && s[pos] == '}') { pos++; return JVal.Obj(m) }
            while (true) {
                ws()
                if (eof() || s[pos] != '"') throw JsonError("bad key")
                val k = str()
                ws()
                if (eof() || s[pos] != ':') throw JsonError("no colon")
                pos++
                m[k] = value()
                ws()
                if (eof()) throw JsonError("unterminated object")
                when (s[pos]) {
                    ',' -> { pos++; continue }
                    '}' -> { pos++; return JVal.Obj(m) }
                    else -> throw JsonError("bad object")
                }
            }
        }
        fun arr(): JVal.Arr {
            pos++ // [
            val l = mutableListOf<JVal>()
            ws()
            if (!eof() && s[pos] == ']') { pos++; return JVal.Arr(l) }
            while (true) {
                l += value()
                ws()
                if (eof()) throw JsonError("unterminated array")
                when (s[pos]) {
                    ',' -> { pos++; ws(); continue }
                    ']' -> { pos++; return JVal.Arr(l) }
                    else -> throw JsonError("bad array")
                }
            }
        }
        fun str(): String {
            pos++ // "
            val sb = StringBuilder()
            while (true) {
                if (eof()) throw JsonError("unterminated string")
                val c = s[pos++]
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        if (eof()) throw JsonError("bad escape")
                        when (val e = s[pos++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (pos + 4 > s.length) throw JsonError("bad unicode")
                                sb.append(s.substring(pos, pos + 4).toInt(16).toChar())
                                pos += 4
                            }
                            else -> throw JsonError("bad escape")
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }
        fun num(): JVal.Num {
            val start = pos
            if (!eof() && s[pos] == '-') pos++
            while (!eof() && (s[pos].isDigit() || s[pos] in ".eE+-")) pos++
            val raw = s.substring(start, pos)
            return try {
                if ('.' in raw || 'e' in raw || 'E' in raw) JVal.Num(raw.toDouble())
                else JVal.Num(raw.toLong())
            } catch (_: NumberFormatException) { throw JsonError("bad number") }
        }
    }
}

/** Convenience builders. */
fun jobj(vararg pairs: Pair<String, JVal>) = JVal.Obj(mapOf(*pairs))
fun jarr(vararg items: JVal) = JVal.Arr(items.toList())
fun JVal.obj(key: String): JVal? = (this as? JVal.Obj)?.map?.get(key)
fun JVal.str(key: String): String? = (obj(key) as? JVal.Str)?.s
fun JVal.long(key: String): Long? = (obj(key) as? JVal.Num)?.n?.toLong()
