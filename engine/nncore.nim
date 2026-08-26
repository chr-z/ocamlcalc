## NimNote — instant-search notes engine
##
## The whole search/matching core lives here and is compiled to JavaScript
## with `nim js` (no runtime, no deps — the compiler emits plain JS).
## The UI (js/app.js) only binds DOM events to this API.
##
## All exported procs take/return JSON strings so the host can stay dumb:
##   nn_api(action: cstring, payload: cstring): cstring

import std/[json, strutils, algorithm, unicode, tables]

const
  NN_VERSION* = 1
  MAX_BODY = 20000        # hard cap per note body (chars)
  SNIPPET_RADIUS = 40     # context chars around each match

# ---------------------------------------------------------------------------
# Nil-safe JSON accessors.
#
# On the JS backend, dereferencing a null ref throws a raw JS TypeError that
# Nim's `except` does NOT catch — so every payload access goes through these.
# ---------------------------------------------------------------------------

proc jkey*(p: JsonNode, name: string): JsonNode =
  if p.isNil or p.kind != JObject: return nil
  if p.hasKey(name): result = p.fields[name]
  else: result = newJNull()

proc jstr*(n: JsonNode, def: string = ""): string =
  if n.isNil: return def
  case n.kind
  of JString: n.str
  of JInt: $n.num
  of JFloat: $n.fnum
  of JBool: $n.bval
  else: def

proc jint*(n: JsonNode, def: int64): int64 =
  if n.isNil: return def
  case n.kind
  of JInt: n.num
  of JFloat: int64(n.fnum)
  else: def

proc jarrStr*(n: JsonNode, def: string = ""): string =
  ## Accepts ["a","b"] or "a,b" — both become "a,b".
  if n.isNil: return def
  case n.kind
  of JArray:
    var parts: seq[string] = @[]
    for it in n.items:
      let s = jstr(it)
      if s.len > 0: parts.add(s)
    parts.join(",")
  else: jstr(n, def)

proc jjson*(n: JsonNode, def: string = ""): string =
  ## Serialize ANY node back to compact JSON text (arrays/objects included).
  if n.isNil: return def
  case n.kind
  of JObject, JArray: $n   # $ uses toUgly -> compact single-line
  else: jstr(n, def)

when defined(js):
  # JSON.parse returns RAW JS values (not Nim JsonNodes), so use it only as
  # a syntax gate and let Nim's own parseJson build the tree.
  proc jsonSyntaxOk(s: cstring): bool {.importjs:
    "(function(){ try { JSON.parse(#); return true; } catch (e) { return false; } })()".}

  proc safeJsonParse*(s: cstring): JsonNode =
    if jsonSyntaxOk(s):
      try: parseJson($s)
      except CatchableError: nil
    else: nil
else:
  proc safeJsonParse*(s: cstring): JsonNode =
    try: parseJson($s)
    except CatchableError: nil

when defined(js):
  proc floatNow(): float64 {.importc: "Date.now", nodecl.}

proc nowMs(): int64 {.inline.} =
  ## Epoch ms without importing times (keeps the JS bundle tiny).
  when defined(js):
    result = int64(floatNow())

var idSalt = 0

proc mkId(t: int64): string =
  ## Compact id for a single-user local store (base36-ish, never empty).
  ## Salted with a process-local counter so two notes created in the same
  ## millisecond still get distinct ids.
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
  inc idSalt
  result.add(alphabet[idSalt mod 36])
  var t2 = if t <= 0: 1'i64 else: t
  while true:
    var n = t2 mod 36'i64 + 1'i64
    while n > 0'i64 and result.len < 10:
      result.add(alphabet[int(n - 1)])
      n = n div 37'i64
    if result.len >= 6 or t2 <= 0'i64: break
    t2 = t2 div 36'i64
  if result.len == 0: result = "n"

proc normalize(s: string): string =
  ## Lowercase + collapse whitespace. Accent-insensitive on purpose so
  ## "Café" matches "cafe" both ways (common in pt-BR notes).
  result = newStringOfCap(s.len)
  var prevSpace = true
  for r in s.toRunes():
    var ch = r
    case ch
    of Rune(0xE1), Rune(0xE0), Rune(0xE2), Rune(0xE3), Rune(0xE5): ch = Rune('a') # á à â ã å
    of Rune(0xE9), Rune(0xE8), Rune(0xEA): ch = Rune('e')                          # é è ê
    of Rune(0xED), Rune(0xEC), Rune(0xEE): ch = Rune('i')                          # í ì î
    of Rune(0xF3), Rune(0xF2), Rune(0xF4), Rune(0xF5): ch = Rune('o')              # ó ò ô õ
    of Rune(0xFA), Rune(0xF9), Rune(0xFB): ch = Rune('u')                          # ú ù û
    of Rune(0xE7): ch = Rune('c')                                                  # ç
    of Rune(0xF1): ch = Rune('n')                                                  # ñ
    else: discard
    let lower = ch.toLower()
    if lower == Rune(' '):
      if not prevSpace:
        result.add(' ')
      prevSpace = true
    else:
      result.add($lower)
      prevSpace = false
  result = strip(result)

# ---------------------------------------------------------------------------
# Scoring / matching
# ---------------------------------------------------------------------------

type Hit = object
  score: int
  firstPos: int     # position in normalized haystack for snippet anchoring
  fieldTitle: bool  # best match happened in the title

type Note = object
  id: string          # short id, stable once created
  title: string
  body: string
  tagsCsv: string     # comma separated, lowercase
  created: int64      # epoch ms
  updated: int64      # epoch ms

proc scoreNote(normQuery: string, n: Note): Hit =
  let nt = normalize(n.title)
  let nb = normalize(n.body & " " & n.tagsCsv)
  if normQuery.len == 0:
    return Hit(score: 1, firstPos: -1)   # recency-ordered listing mode
  var h = Hit(score: 0, firstPos: -1, fieldTitle: false)

  # exact phrase anywhere beats everything
  let tp = find(nt, normQuery)
  let bp = find(nb, normQuery)
  if tp >= 0:
    h.score += 100
    h.firstPos = tp
    h.fieldTitle = true
  if bp >= 0:
    h.score += 60
    if h.firstPos < 0: h.firstPos = bp

  # word/prefix hits keep refining while the user types
  for word in split(normQuery, ' '):
    if word.len == 0: continue
    let tw = find(nt, word)
    let bw = find(nb, word)
    if tw >= 0:
      h.score += 12
      if h.firstPos < 0:
        h.firstPos = tw
        h.fieldTitle = true
    if bw >= 0:
      h.score += 6
      if h.firstPos < 0: h.firstPos = bw

  if h.score > 1: h.score += 1  # any real match floors above empty-query listing
  result = h

proc makeSnippet(bodyNorm: string, pos: int, rawBody: string): string =
  ## Slice around `pos`, re-anchored onto the RAW text by ratio so the
  ## user sees their own characters (accents intact).
  if rawBody.len == 0: return ""
  if pos < 0 or bodyNorm.len == 0:
    if rawBody.len <= 2 * SNIPPET_RADIUS: return rawBody.replace("\n", " ")
    return rawBody[0 ..< 2 * SNIPPET_RADIUS].replace("\n", " ") & "…"
  let startB = max(pos - SNIPPET_RADIUS div 2, 0)
  let endB = min(startB + 2 * SNIPPET_RADIUS, bodyNorm.len)
  let ratio = rawBody.len / bodyNorm.len
  var s = clamp(int(startB.float * ratio), 0, rawBody.len)
  var e = clamp(int(endB.float * ratio), s, rawBody.len)
  if e - s > 2 * SNIPPET_RADIUS + 8:
    e = s + 2 * SNIPPET_RADIUS + 8
  var outp = rawBody[s ..< e]
  if s > 0: outp = "…" & outp
  if e < rawBody.len: outp = outp & "…"
  result = outp.replace("\n", " ")

# ---------------------------------------------------------------------------
# Store ops
# ---------------------------------------------------------------------------

proc parseNotes(stateJson: string): seq[Note] =
  try:
    let node = safeJsonParse(cstring(stateJson))
    if not node.isNil and node.kind == JArray:
      for item in node.items:
        let obj = item
        if obj.isNil or obj.kind != JObject: continue
        result.add(Note(
          id: jstr(jkey(obj, "id")),
          title: jstr(jkey(obj, "title")),
          body: jstr(jkey(obj, "body")),
          tagsCsv: jarrStr(jkey(obj, "tags")).toLowerAscii(),
          created: jint(jkey(obj, "created"), 0),
          updated: jint(jkey(obj, "updated"), 0)
        ))
  except CatchableError:
    discard  # corrupt state -> treat as empty store (app keeps memory copy)

proc noteRow(n: Note): JsonNode =
  %*{ "id": n.id, "title": n.title, "body": n.body,
      "tags": n.tagsCsv, "created": n.created, "updated": n.updated }

proc noteToJson(n: Note, hit: Hit, query: string): JsonNode =
  let nb = normalize(n.body & " " & n.tagsCsv)
  result = %*{
    "id": n.id,
    "title": n.title,
    "body": n.body,
    "tags": n.tagsCsv,
    "updated": n.updated,
    "score": hit.score,
    "inTitle": hit.fieldTitle,
    "snippet": if query.len == 0: "" else: makeSnippet(nb, hit.firstPos, n.body)
  }

# ---------------------------------------------------------------------------
# Exported API — one JSON-in/JSON-out entry point
# ---------------------------------------------------------------------------

proc nn_version(): cint {.exportc.} = NN_VERSION

proc nn_api(action: cstring, payload: cstring): cstring {.exportc.} =
  let act = $action
  var resp = JsonNode(nil)

  case act
  of "search":
    # payload: {state:[notes], q:"query"}
    try:
      let p = safeJsonParse(payload)
      if p.isNil:
        resp = %*{ "ok": false, "error": "bad-json" }
      else:
        let stateRaw = jkey(p, "state")
        let notes = if stateRaw.isNil: @[] else: parseNotes(jjson(stateRaw, "[]"))
        let q = normalize(jstr(jkey(p, "q")))
        type Row = tuple[n: Note, h: Hit]
        var rows: seq[Row] = @[]
        for n in notes:
          rows.add((n, scoreNote(q, n)))
        rows.sort() do (a, b: Row) -> int:
          if a.h.score != b.h.score: cmp(b.h.score, a.h.score)
          elif a.n.updated != b.n.updated: cmp(b.n.updated, a.n.updated)
          else: cmp(a.n.id, b.n.id)
        var arr = newJArray()
        for r in rows:
          if q.len > 0 and r.h.score <= 1:
            continue
          arr.add(noteToJson(r.n, r.h, q))
        resp = %*{ "ok": true, "results": arr, "total": arr.len }
    except CatchableError as e:
      resp = %*{ "ok": false, "error": e.msg }

  of "upsert":
    # payload: {note:{id?,title,body,tags}, now:epochms, state:[...]}
    try:
      let p = safeJsonParse(payload)
      if p.isNil:
        resp = %*{ "ok": false, "error": "bad-json" }
      else:
        let inp = jkey(p, "note")
        if inp.isNil or inp.kind != JObject:
          resp = %*{ "ok": false, "error": "missing-note" }
        else:
          let title = strutils.strip(jstr(jkey(inp, "title")))
          let body = strutils.strip(jstr(jkey(inp, "body")))
          if title.len == 0 and body.len == 0:
            resp = %*{ "ok": false, "error": "empty-note" }
          else:
            var notes = parseNotes(jjson(jkey(p, "state"), "[]"))
            let tags = jarrStr(jkey(inp, "tags"))
            var updated = jint(jkey(p, "now"), 0)
            if updated <= 0: updated = nowMs()
            var id = jstr(jkey(inp, "id"))
            var found = false
            if id.len > 0:
              for i in 0 ..< notes.len:
                if notes[i].id == id:
                  notes[i].title = title
                  notes[i].body = body
                  notes[i].tagsCsv = tags.toLowerAscii()
                  notes[i].updated = updated
                  found = true
                  break
            if not found:
              id = mkId(updated)
              notes.add(Note(
                id: id, title: title, body: body,
                tagsCsv: tags.toLowerAscii(),
                created: updated, updated: updated
              ))
            var arr = newJArray()
            for n in notes: arr.add(noteRow(n))
            resp = %*{ "ok": true, "id": id, "state": arr }
    except CatchableError as e:
      resp = %*{ "ok": false, "error": e.msg }

  of "delete":
    # payload: {id, state}
    try:
      let p = safeJsonParse(payload)
      if p.isNil:
        resp = %*{ "ok": false, "error": "bad-json" }
      else:
        let delId = jstr(jkey(p, "id"))
        let notes = parseNotes(jjson(jkey(p, "state"), "[]"))
        var arr = newJArray()
        var removed = false
        for n in notes:
          if delId.len > 0 and n.id == delId:
            removed = true
            continue
          arr.add(noteRow(n))
        resp = %*{ "ok": removed, "state": arr }
    except CatchableError as e:
      resp = %*{ "ok": false, "error": e.msg }

  of "validate":
    # payload: {title, body} -> length caps etc.
    try:
      let p = safeJsonParse(payload)
      if p.isNil:
        resp = %*{ "ok": false, "error": "bad-json" }
      else:
        let badLen = jstr(jkey(p, "body")).len > MAX_BODY
        resp = %*{ "ok": not badLen, "maxBody": MAX_BODY }
    except CatchableError as e:
      resp = %*{ "ok": false, "error": e.msg }

  else:
    resp = %*{ "ok": false, "error": "unknown-action" }

  result = cstring($resp)
