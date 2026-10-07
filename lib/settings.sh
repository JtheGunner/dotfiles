# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are read by the functions below and by bootstrap.sh
# Settings file support for bootstrap.sh: a restricted TOML subset parsed with awk
# (no associative arrays, no gawk extensions - macOS ships bash 3.2 and BWK awk).
# Sourced, never executed; defining the functions has no side effects.
#
# Records: table<US>key<US>kind<US>value
#   US = $'\037'; kind = str | int | float | bool | array
#   array values: elements joined by RS = $'\036', each prefixed "s" (string) or
#   "r" (raw number / boolean).

SETTINGS_US=$'\037'
SETTINGS_RS=$'\036'
SETTINGS_FILE=""
SETTINGS_RECORDS=""

if ! command -v warn >/dev/null 2>&1; then warn() { printf 'warn: %s\n' "$*" >&2; }; fi
if ! command -v log >/dev/null 2>&1; then log() { printf '==> %s\n' "$*"; }; fi

# settings_parse FILE: syntax check and normalisation. Records go to stdout; every
# rejected line becomes "FILE:LINE: <reason> - ignored" on stderr.
settings_parse() {
  awk '
    function warn(msg) { printf "%s:%d: %s - ignored\n", FILENAME, FNR, msg > "/dev/stderr" }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    # drop a trailing # comment that is not inside a string
    function strip_comment(s,   i, c, q, out) {
      q = 0; out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && q) { out = out c substr(s, i + 1, 1); i++; continue }
        if (c == "\"") q = !q
        if (c == "#" && !q) break
        out = out c
      }
      return out
    }
    # one scalar -> SK (kind) and SV (value); returns 0 when invalid
    function scalar(v,   i, c, n, out) {
      if (v ~ /^"/) {
        out = ""; i = 2
        while (i <= length(v)) {
          c = substr(v, i, 1)
          if (c == "\\") {
            n = substr(v, i + 1, 1)
            if (n != "\"" && n != "\\") return 0
            out = out n; i += 2; continue
          }
          if (c == "\"") {
            if (i != length(v)) return 0
            SK = "str"; SV = out; return 1
          }
          out = out c; i++
        }
        return 0
      }
      if (v ~ /^-?[0-9]+$/) { SK = "int"; SV = v; return 1 }
      if (v ~ /^-?[0-9]+\.[0-9]+$/) { SK = "float"; SV = v; return 1 }
      if (v == "true" || v == "false") { SK = "bool"; SV = v; return 1 }
      return 0
    }
    # one-line array of scalars -> SK = array, SV = prefixed elements joined by RS
    function array(v,   inner, i, c, q, tok, out, n) {
      inner = trim(substr(v, 2, length(v) - 2))
      if (inner == "") { SK = "array"; SV = ""; return 1 }
      out = ""; n = 0; tok = ""; q = 0
      for (i = 1; i <= length(inner) + 1; i++) {
        c = (i <= length(inner)) ? substr(inner, i, 1) : ","
        if (c == "\\" && q) { tok = tok c substr(inner, i + 1, 1); i++; continue }
        if (c == "\"") q = !q
        if (c == "," && !q) {
          if (!scalar(trim(tok))) return 0
          out = out (n++ ? "\036" : "") (SK == "str" ? "s" : "r") SV
          tok = ""; continue
        }
        tok = tok c
      }
      if (q) return 0
      SK = "array"; SV = out
      return 1
    }
    FNR == 1 && substr($0, 1, 3) == "\357\273\277" { $0 = substr($0, 4) }
    { line = trim(strip_comment($0)) }
    line == "" { next }
    line ~ /^\[/ {
      if (line !~ /^\[[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\]$/) { warn("invalid table header"); skip = 1; table = ""; next }
      table = substr(line, 2, length(line) - 2)
      if (table != "bootstrap" && table != "ghostty" && table != "omnishell" && table !~ /^modules\./) {
        warn("unknown table [" table "]"); skip = 1; next
      }
      skip = 0; next
    }
    skip { next }
    {
      eq = index(line, "=")
      if (eq == 0) { warn("not a key = value line"); next }
      key = trim(substr(line, 1, eq - 1)); v = trim(substr(line, eq + 1))
      if (table == "") { warn("key outside a table"); next }
      if (key !~ /^[A-Za-z0-9_-]+$/) { warn("unsupported key \"" key "\""); next }
      if (v ~ /^\[/ && v ~ /\]$/) ok = array(v); else ok = scalar(v)
      if (!ok) { warn("invalid value for " key); next }
      printf "%s\037%s\037%s\037%s\n", table, key, SK, SV
    }
  ' "$1"
}
