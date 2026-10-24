import std/[strutils, algorithm, json, options, tables, times, hashes, sets]
import failure
import grim
import jsondocs

const suggestionThreshold = 0.6
const suggestionsPerMiss = 3

type Scope* = object
  account*: Option[string]
  vault*: Option[string]

type SecretMatch* = object
  secretRef*: string
  title*: string
  kind*: string

proc kindOf*(category: string): string =
  category.toLowerAscii().replace("_", "-")

proc words*(text: string): seq[string] =
  result = @[]
  var word = ""
  for ch in text.toLowerAscii():
    if ch in {'a' .. 'z', '0' .. '9'}:
      word.add ch
    elif word.len > 0:
      result.add word
      word = ""
  if word.len > 0:
    result.add word

proc distance*(a, b: string): int =
  var previous = newSeq[int](b.len + 1)
  for j in 0 .. b.len:
    previous[j] = j
  for i in 1 .. a.len:
    var current = newSeq[int](b.len + 1)
    current[0] = i
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      current[j] = min(min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost)
    previous = current
  previous[b.len]

proc closeness*(terms: seq[string], title: string): float =
  let candidates = words(title)
  proc scoreTerm(term: string): float =
    var best = 0.0
    for word in candidates:
      var s = 0.0
      if word.contains(term) or (word.len >= 3 and term.contains(word)):
        s = 1.0
      else:
        s = 1.0 - distance(term, word).float / max(term.len, word.len).float
      best = max(best, s)
    best
  var sum = 0.0
  for t in terms:
    sum += scoreTerm(t)
  sum / terms.len.float

proc safeUrl*(input: string): string =
  let q = input.find('?')
  let h = input.find('#')
  var cut = input.len
  if q >= 0:
    cut = min(cut, q)
  if h >= 0:
    cut = min(cut, h)
  input[0 ..< cut]

type ListedEntry = object
  summary: JsonNode
  raw: JsonNode

proc listItems(scope: Scope): seq[ListedEntry] =
  var args = @["item", "list", "--format", "json"]
  if scope.vault.isSome:
    args.add "--vault"
    args.add scope.vault.get
  let opts = GrimCallOptions(account: scope.account)
  let raw = grimJson(args, opts)
  if raw.kind != JArray:
    raise fail("grim returned invalid JSON")
  for item in raw:
    result.add ListedEntry(summary: item, raw: item)

proc itemDetails(entries: seq[ListedEntry], scope: Scope): seq[JsonNode] =
  if entries.len == 0:
    return @[]
  var arr = newJArray()
  for e in entries:
    arr.add e.raw
  let input = $arr & "\n"
  let batchText = grimOp(
    @["item", "get", "-", "--format", "json"],
    GrimCallOptions(account: scope.account, input: some(input)),
  )
  parseJsonDocuments(batchText)

proc secretsFromItem(item: JsonNode): seq[SecretMatch] =
  let title = item["title"].getStr()
  let category = kindOf(item["category"].getStr())
  if "fields" notin item:
    return @[]
  for field in item["fields"]:
    let hasRef = "reference" in field and field["reference"].kind == JString
    if not hasRef:
      continue
    let ftype = field["type"].getStr()
    let purpose = if "purpose" in field: field["purpose"].getStr() else: ""
    if ftype == "CONCEALED" or purpose == "PASSWORD":
      result.add SecretMatch(
        secretRef: field["reference"].getStr(),
        title: title,
        kind: category,
      )

proc find*(queries: seq[string], scope: Scope = Scope()): JsonNode =
  let listed = listItems(scope)
  var uniqueQueries: seq[string] = @[]
  for q in queries:
    if q notin uniqueQueries:
      uniqueQueries.add q

  type Search = object
    query: string
    items: seq[ListedEntry]
    suggested: seq[ListedEntry]

  var searches: seq[Search] = @[]
  for query in uniqueQueries:
    let terms = query.toLowerAscii().splitWhitespace()
    var items: seq[ListedEntry] = @[]
    for entry in listed:
      let title = entry.summary["title"].getStr().toLowerAscii()
      block:
        var ok = true
        for term in terms:
          if not title.contains(term):
            ok = false
            break
        if ok:
          items.add entry
    var suggested: seq[ListedEntry] = @[]
    if items.len == 0:
      type Scored = tuple[entry: ListedEntry, score: float]
      var scored: seq[Scored] = @[]
      for entry in listed:
        let sc = closeness(terms, entry.summary["title"].getStr())
        if sc >= suggestionThreshold:
          scored.add (entry, sc)
      proc cmpScored(a, b: Scored): int =
        if a.score != b.score:
          return cmp(b.score, a.score)
        cmp(a.entry.summary["title"].getStr(), b.entry.summary["title"].getStr())
      scored.sort(cmpScored)
      for i in 0 ..< min(suggestionsPerMiss, scored.len):
        suggested.add scored[i].entry
    searches.add Search(query: query, items: items, suggested: suggested)

  var wanted: seq[ListedEntry] = @[]
  var seenIds = initHashSet[string]()
  for s in searches:
    for e in s.items:
      let id = e.summary["id"].getStr()
      if id notin seenIds:
        seenIds.incl id
        wanted.add e
    for e in s.suggested:
      let id = e.summary["id"].getStr()
      if id notin seenIds:
        seenIds.incl id
        wanted.add e

  let detailed = itemDetails(wanted, scope)
  var byId = initTable[string, seq[SecretMatch]]()
  for item in detailed:
    byId[item["id"].getStr()] = secretsFromItem(item)

  proc secretsOf(items: seq[ListedEntry]): seq[SecretMatch] =
    for e in items:
      if e.summary["id"].getStr() in byId:
        result.add byId[e.summary["id"].getStr()]

  type MatchWithQueries = object
    match: SecretMatch
    queries: seq[string]

  var matches = initTable[string, MatchWithQueries]()
  for s in searches:
    for m in secretsOf(s.items):
      if m.secretRef in matches:
        matches[m.secretRef].queries.add s.query
      else:
        matches[m.secretRef] = MatchWithQueries(match: m, queries: @[s.query])

  var matchArr = newJArray()
  var keys: seq[string] = @[]
  for k in matches.keys:
    keys.add k
  keys.sort()
  for k in keys:
    let mw = matches[k]
    var obj = %*{
      "ref": mw.match.secretRef,
      "title": mw.match.title,
      "kind": mw.match.kind,
    }
    if uniqueQueries.len > 1:
      obj["queries"] = %mw.queries
    matchArr.add obj

  var suggArr = newJArray()
  for s in searches:
    for m in secretsOf(s.suggested):
      suggArr.add(%*{"query": s.query, "ref": m.secretRef, "title": m.title, "kind": m.kind})

  var resultJson = %*{"matches": matchArr}
  if suggArr.len > 0:
    resultJson["suggestions"] = suggArr
  resultJson

proc inventory*(scope: Scope = Scope()): JsonNode =
  let listed = listItems(scope)
  let items = itemDetails(listed, scope)
  type Row = tuple[vault: string, title: string, node: JsonNode]
  var rows: seq[Row] = @[]
  for item in items:
    let vaultName = item["vault"]["name"].getStr()
    let title = item["title"].getStr()
    var tags = newJArray()
    if "tags" in item:
      var t: seq[string] = @[]
      for x in item["tags"]:
        t.add x.getStr()
      t.sort()
      for x in t:
        tags.add %x
    var urls = newJArray()
    if "urls" in item:
      for u in item["urls"]:
        urls.add %safeUrl(u["href"].getStr())
    var fields = newJArray()
    if "fields" in item:
      for field in item["fields"]:
        var f = %*{
          "label": (if "label" in field: field["label"].getStr() else: field["id"].getStr()),
          "type": field["type"].getStr().toLowerAscii(),
        }
        if "purpose" in field:
          f["purpose"] = %field["purpose"].getStr().toLowerAscii()
        if "section" in field and "label" in field["section"]:
          f["section"] = %field["section"]["label"].getStr()
        if "reference" in field:
          f["ref"] = %field["reference"].getStr()
        fields.add f
    var node = %*{
      "id": item["id"].getStr(),
      "title": title,
      "vault": vaultName,
      "kind": kindOf(item["category"].getStr()),
      "tags": tags,
      "urls": urls,
      "fields": fields,
    }
    if "created_at" in item:
      node["createdAt"] = item["created_at"]
    if "updated_at" in item:
      node["updatedAt"] = item["updated_at"]
    rows.add (vaultName, title, node)
  proc cmpRow(a, b: Row): int =
    let c = cmp(a.vault, b.vault)
    if c != 0:
      c
    else:
      cmp(a.title, b.title)
  rows.sort(cmpRow)
  var arr = newJArray()
  for r in rows:
    arr.add r.node
  arr

const machineKinds = [
  "api-credential", "database", "document", "password", "secure-note", "ssh-key",
].toHashSet()

const transientPatterns = [
  "callback", "oauth", "invite", "signup", "register", "activate", "accept", "forgot", "reset", "checkout",
]

proc isTransientUrl(url: string): bool =
  let lower = url.toLowerAscii()
  for p in transientPatterns:
    if lower.contains(p):
      return true
  false

proc audit*(scope: Scope = Scope()): JsonNode =
  let items = inventory(scope)
  var tagged = 0
  var untagged = 0
  for item in items:
    if item["tags"].len > 0:
      inc tagged
    else:
      inc untagged
  var byTitle = initTable[string, seq[JsonNode]]()
  for item in items:
    let key = item["title"].getStr().toLowerAscii()
    if key notin byTitle:
      byTitle[key] = @[]
    byTitle[key].add item
  var dupes = newJArray()
  for key, group in byTitle.pairs:
    if group.len > 1:
      var itemsArr = newJArray()
      for g in group:
        itemsArr.add(%*{"id": g["id"], "title": g["title"]})
      dupes.add(%*{"title": group[0]["title"], "items": itemsArr})
  var untaggedMachine = newJArray()
  for item in items:
    if item["tags"].len == 0 and item["kind"].getStr() in machineKinds:
      untaggedMachine.add(%*{
        "id": item["id"], "title": item["title"], "kind": item["kind"],
      })
  let cutoff = now() - initDuration(days = 365 * 5)
  let cutoffIso = format(cutoff, "yyyy-MM-dd'T'HH:mm:ss'Z'")
  var oldLogins = newJArray()
  for item in items:
    if item["kind"].getStr() == "login" and "updatedAt" in item:
      if item["updatedAt"].getStr() < cutoffIso:
        oldLogins.add(%*{
          "id": item["id"],
          "title": item["title"],
          "updatedAt": item["updatedAt"],
        })
  var urlsReview = newJArray()
  for item in items:
    var bad: seq[string] = @[]
    for u in item["urls"]:
      let href = u.getStr()
      if isTransientUrl(href):
        bad.add href
    if bad.len > 0:
      urlsReview.add(%*{"id": item["id"], "title": item["title"], "urls": %bad})
  %*{
    "summary": %*{"items": items.len, "tagged": tagged, "untagged": untagged},
    "duplicateTitles": dupes,
    "untaggedMachineCredentials": untaggedMachine,
    "oldLogins": oldLogins,
    "urlsToReview": urlsReview,
  }
