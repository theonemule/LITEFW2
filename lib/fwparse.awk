# Parse `iptables -S CHAIN` lines into JSON objects (one per line).
function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return s }
function tokenize(line,    i, c, cur, inq, have, L) {
  NT = 0; cur = ""; inq = 0; have = 0; L = length(line)
  for (i = 1; i <= L; i++) {
    c = substr(line, i, 1)
    if (inq) {
      if (c == "\\" && i < L) { i++; cur = cur substr(line, i, 1); continue }
      if (c == "\"") { inq = 0; continue }
      cur = cur c; continue
    }
    if (c == "\"") { inq = 1; have = 1; continue }
    if (c == " ") { if (have) { T[++NT] = cur; cur = ""; have = 0 }; continue }
    cur = cur c; have = 1
  }
  if (have) T[++NT] = cur
}
/^-A / {
  tokenize($0)
  chain = T[2]; iif = ""; oif = ""; src = ""; dst = ""; proto = ""; ports = ""
  comment = ""; target = ""; todst = ""; icmp = ""; odd = 0
  for (i = 3; i <= NT; i++) {
    t = T[i]
    if (t == "!") odd = 1
    else if (t == "-i") iif = T[++i]
    else if (t == "-o") oif = T[++i]
    else if (t == "-s") src = T[++i]
    else if (t == "-d") dst = T[++i]
    else if (t == "-p") proto = T[++i]
    else if (t == "-m") i++
    else if (t == "--dport" || t == "--dports") ports = T[++i]
    else if (t == "--comment") comment = T[++i]
    else if (t == "-j") target = T[++i]
    else if (t == "--to-destination") todst = T[++i]
    else if (t == "--icmp-type") icmp = T[++i]
    else if (t == "--reject-with") i++
    else odd = 1
  }
  id = ""; desc = ""
  if (comment ~ /^lfw:/) {
    c = substr(comment, 5); sp = index(c, " ")
    if (sp) { id = substr(c, 1, sp - 1); desc = substr(c, sp + 1) } else id = c
  }
  gsub(/:/, "-", ports)
  sub(/\/32$/, "", src); sub(/\/32$/, "", dst)
  managed = (id != "" && !odd) ? "true" : "false"
  printf "{\"chain\":\"%s\",\"id\":\"%s\",\"description\":\"%s\",\"in\":\"%s\",\"out\":\"%s\",\"src\":\"%s\",\"dst\":\"%s\",\"proto\":\"%s\",\"ports\":\"%s\",\"target\":\"%s\",\"toDestination\":\"%s\",\"managed\":%s,\"raw\":\"%s\"}\n", \
    jesc(chain), jesc(id), jesc(desc), jesc(iif), jesc(oif), jesc(src), jesc(dst), jesc(proto), jesc(ports), jesc(target), jesc(todst), managed, jesc($0)
}
