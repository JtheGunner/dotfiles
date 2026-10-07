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

# fall back to simple helpers when the caller (bootstrap.sh) has not defined them;
# `command -v` would find /usr/bin/log on macOS, so ask for a shell function
if [ "$(type -t warn)" != function ]; then warn() { printf 'warn: %s\n' "$*" >&2; }; fi
if [ "$(type -t log)" != function ]; then log() { printf '==> %s\n' "$*"; }; fi

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
    BEGIN { bom = "\357\273\277" }
    FNR == 1 && substr($0, 1, length(bom)) == bom { $0 = substr($0, length(bom) + 1) }
    { line = trim(strip_comment($0)) }
    line == "" { next }
    line ~ /[\001-\010\013\014\016-\037\177]/ { warn("control character"); next }
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

# Known keys of [bootstrap] and [ghostty], with the value type each one takes:
#   enum:a,b,c | bool | list | string | number
SETTINGS_SCHEMA='bootstrap.install_zsh enum:yes,no,ask
bootstrap.assume_yes bool
bootstrap.terminals list
ghostty.keybinds enum:auto,mac,linux
ghostty.font_family string
ghostty.font_size number
ghostty.background_opacity number'

settings_schema_keys() { printf '%s\n' "$SETTINGS_SCHEMA" | awk '{ print $1 }'; }

_settings_type() { printf '%s\n' "$SETTINGS_SCHEMA" | awk -v k="$1" '$1 == k { print $2 }'; }

# _settings_value_ok TYPE KIND VALUE
_settings_value_ok() {
  case "$1" in
    enum:*) [ "$2" = str ] || return 1
            case ",${1#enum:}," in *",$3,"*) return 0 ;; esac
            return 1 ;;
    bool) [ "$2" = bool ] ;;
    list) [ "$2" = array ] ;;
    string) [ "$2" = str ] ;;
    number) [ "$2" = int ] || [ "$2" = float ] ;;
    *) return 1 ;;
  esac
}

# settings_load FILE: parse and validate into SETTINGS_RECORDS. [bootstrap] and
# [ghostty] keys must be in the schema with the right type; omnishell and
# modules.* tables pass through (omnishell validate checks those later).
settings_load() {
  local table key kind value type
  SETTINGS_FILE="$1"
  SETTINGS_RECORDS=""
  [ -r "$1" ] || return 0
  while IFS="$SETTINGS_US" read -r table key kind value; do
    case "$table" in
      bootstrap | ghostty)
        type="$(_settings_type "$table.$key")"
        if [ -z "$type" ]; then
          warn "$1: unknown key '$key' in [$table] - ignored"
          continue
        fi
        if ! _settings_value_ok "$type" "$kind" "$value"; then
          warn "$1: invalid $table.$key value '${value//$SETTINGS_RS/,}' (expected ${type#enum:}) - ignored"
          continue
        fi ;;
    esac
    SETTINGS_RECORDS="${SETTINGS_RECORDS}${table}${SETTINGS_US}${key}${SETTINGS_US}${kind}${SETTINGS_US}${value}"$'\n'
  done < <(settings_parse "$1")
}

# settings_get table.key: the value; arrays space-separated; empty when unset.
settings_get() {
  printf '%s' "$SETTINGS_RECORDS" | awk -F"$SETTINGS_US" -v t="${1%.*}" -v k="${1##*.}" -v rs="$SETTINGS_RS" '
    $1 == t && $2 == k { v = $4; kind = $3 }
    END {
      if (kind == "array") {
        n = split(v, a, rs); out = ""
        for (i = 1; i <= n; i++) out = out (i > 1 ? " " : "") substr(a[i], 2)
        v = out
      }
      printf "%s", v
    }'
}

# TOML text for the omnishell / modules.* tables of the loaded settings, built
# from the validated records (never from raw file text). One table after the
# other, in order of first appearance; a repeated key keeps its last value.
_settings_omnishell_blocks() {
  printf '%s' "$SETTINGS_RECORDS" | awk -F"$SETTINGS_US" -v rs="$SETTINGS_RS" '
    function quote(s,   i, c, out) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" || c == "\"") out = out "\\"
        out = out c
      }
      return "\"" out "\""
    }
    function element(e) { return substr(e, 1, 1) == "s" ? quote(substr(e, 2)) : substr(e, 2) }
    function render(kind, v,   n, a, i, out) {
      if (kind == "str") return quote(v)
      if (kind != "array") return v
      n = split(v, a, rs); out = ""
      for (i = 1; i <= n; i++) out = out (i > 1 ? ", " : "") element(a[i])
      return "[" out "]"
    }
    $1 == "omnishell" || $1 ~ /^modules\./ {
      if (!($1 in seen)) { seen[$1] = 1; tables[++nt] = $1 }
      tk = $1 SUBSEP $2
      if (!(tk in val)) klist[$1, ++kc[$1]] = $2
      val[tk] = render($3, $4)
    }
    END {
      for (i = 1; i <= nt; i++) {
        t = tables[i]; print "[" t "]"
        for (j = 1; j <= kc[t]; j++) print klist[t, j] " = " val[t SUBSEP klist[t, j]]
      }
    }'
}

# settings_merge_omnishell DEFAULT_FILE: the default config with the omnishell and
# modules.* tables of the loaded settings laid over it. A table replaces the
# default table of the same name as a whole; override tables the default lacks
# are appended; every other line, comments included, is kept as it is. Comment and
# blank lines directly above a table travel with that table.
settings_merge_omnishell() {
  OVR="$(_settings_omnishell_blocks)" awk '
    function blank_or_comment(s) { return s ~ /^[ \t]*(#.*)?$/ }
    function flush(   i) {
      printf "%s", lead
      if (bhas && (bh in otext)) { printf "%s", otext[bh]; used[bh] = 1; return }
      for (i = 1; i <= bc; i++) print bl[i]
    }
    BEGIN {
      n = split(ENVIRON["OVR"], ol, "\n"); cur = ""
      for (i = 1; i <= n; i++) {
        if (ol[i] ~ /^\[/) {
          cur = substr(ol[i], 2, length(ol[i]) - 2)
          if (!(cur in otext)) oorder[++no] = cur
          otext[cur] = otext[cur] ol[i] "\n"
        } else if (ol[i] != "") otext[cur] = otext[cur] ol[i] "\n"
      }
      lead = ""; bh = ""; bhas = 0; bc = 0
    }
    /^\[[^\[]/ {
      k = bc
      while (k > 0 && blank_or_comment(bl[k])) k--
      newlead = ""
      for (i = k + 1; i <= bc; i++) newlead = newlead bl[i] "\n"
      bc = k
      flush()
      name = substr($0, 2); sub(/\].*$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", name)
      lead = newlead; bh = name; bhas = 1; bc = 1; bl[1] = $0
      next
    }
    { bc++; bl[bc] = $0 }
    END {
      flush()
      for (i = 1; i <= no; i++) if (!(oorder[i] in used)) printf "\n%s", otext[oorder[i]]
    }
  ' "$1"
}

# Ghostty `key = value` lines for the [ghostty] values that are set. `keybinds`
# is not rendered: setup_ghostty_keybinds links the matching keybinds file.
settings_render_ghostty() {
  local v
  v="$(settings_get ghostty.font_family)"
  if [ -n "$v" ]; then
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    printf 'font-family = "%s"\n' "$v"
  fi
  v="$(settings_get ghostty.font_size)"
  [ -z "$v" ] || printf 'font-size = %s\n' "$v"
  v="$(settings_get ghostty.background_opacity)"
  [ -z "$v" ] || printf 'background-opacity = %s\n' "$v"
}

# settings_migrate_legacy LEGACY NEW: one-time conversion of the old KEY=value
# bootstrap.conf. Only runs when LEGACY exists and NEW does not. A legacy file
# without an active key (the seeded template) is renamed, not converted.
settings_migrate_legacy() {
  local legacy="$1" new="$2" line key value t list="" install="" assume="" terminals=""
  { [ -f "$legacy" ] && [ ! -e "$new" ]; } || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      INSTALL_ZSH) case "$value" in yes | no | ask) install="$value" ;; esac ;;
      ASSUME_YES) case "$value" in yes) assume=true ;; no) assume=false ;; esac ;;
      TERMINALS) terminals="$value" ;;
    esac
  done < "$legacy"
  for t in $terminals; do
    case "$t" in
      *[!A-Za-z0-9_.-]*) warn "$legacy: skipped terminal '$t' (not a valid package name)" ;;
      *) list="${list:+$list, }\"$t\"" ;;
    esac
  done
  if [ -z "$install$assume$list" ]; then
    mv "$legacy" "$legacy.migrated"
    return 0
  fi
  mkdir -p "$(dirname "$new")"
  {
    printf '# Migrated from bootstrap.conf. config.toml.example lists every option.\n[bootstrap]\n'
    [ -z "$install" ] || printf 'install_zsh = "%s"\n' "$install"
    [ -z "$assume" ] || printf 'assume_yes = %s\n' "$assume"
    [ -z "$list" ] || printf 'terminals = [%s]\n' "$list"
  } > "$new"
  mv "$legacy" "$legacy.migrated"
  log "migrated $legacy to $new"
}
