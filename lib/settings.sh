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
      if (table != "bootstrap" && table != "ghostty" && table != "tmux" && table != "git" && table != "omnishell" && table !~ /^modules\./) {
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
#   enum:a,b,c | bool | list | string | number | positive (> 0) | fraction (0 to 1)
#   | nonneg (integer >= 0) | posint (integer > 0) | tmuxkey | email
SETTINGS_SCHEMA='bootstrap.install_zsh enum:yes,no,ask
bootstrap.assume_yes bool
bootstrap.terminals list
ghostty.keybinds enum:auto,mac,linux
ghostty.font_family string
ghostty.font_size positive
ghostty.background_opacity fraction
tmux.prefix tmuxkey
tmux.mouse bool
tmux.mode_keys enum:vi,emacs
tmux.base_index nonneg
tmux.escape_time nonneg
tmux.history_limit posint
tmux.status_position enum:top,bottom
git.user_name string
git.user_email email
git.signing_key string
git.default_branch string
git.editor string
git.pull_rebase bool'

settings_schema_keys() { printf '%s\n' "$SETTINGS_SCHEMA" | awk '{ print $1 }'; }

_settings_type() { printf '%s\n' "$SETTINGS_SCHEMA" | awk -v k="$1" '$1 == k { print $2 }'; }

# _settings_value_ok TYPE KIND VALUE
_settings_value_ok() {
  # TOML forbids leading zeros, and in shell arithmetic 007 would be octal
  if [ "$2" = int ]; then
    case "$3" in 0[0-9]* | -0[0-9]*) return 1 ;; esac
  fi
  case "$1" in
    enum:*) [ "$2" = str ] || return 1
            case "$3" in "" | *,*) return 1 ;; esac
            case ",${1#enum:}," in *",$3,"*) return 0 ;; esac
            return 1 ;;
    bool) [ "$2" = bool ] ;;
    list) [ "$2" = array ] ;;
    string) [ "$2" = str ] ;;
    number) [ "$2" = int ] || [ "$2" = float ] ;;
    positive) { [ "$2" = int ] || [ "$2" = float ]; } && awk -v v="$3" 'BEGIN { exit !(v > 0) }' ;;
    fraction) { [ "$2" = int ] || [ "$2" = float ]; } && awk -v v="$3" 'BEGIN { exit !(v >= 0 && v <= 1) }' ;;
    nonneg) [ "$2" = int ] && [ "${#3}" -le 9 ] && [ "$3" -ge 0 ] ;;
    posint) [ "$2" = int ] && [ "${#3}" -le 9 ] && [ "$3" -gt 0 ] ;;
    tmuxkey) [ "$2" = str ] || return 1
             case "$3" in
               C-[A-Za-z0-9] | M-[A-Za-z0-9] | C-Space | M-Space | F[1-9] | F1[0-2]) return 0 ;;
             esac
             return 1 ;;
    email) [ "$2" = str ] || return 1
           case "$3" in
             *" "* | *$'\t'* | @* | *@) return 1 ;;
             *?@?*) return 0 ;;
           esac
           return 1 ;;
    *) return 1 ;;
  esac
}

# _settings_literal TYPE ANSWER: the TOML literal for a prompt answer, printed to
# stdout; returns 1 (printing nothing) when the answer is empty, has a control
# character, or is not valid for TYPE by the rules used when the file is read.
_settings_literal() {
  local type="$1" ans="$2" kind value="" item out="" sep="" int_re='^-?[0-9]+$' float_re='^-?[0-9]+\.[0-9]+$'
  [ -n "$ans" ] || return 1
  case "$ans" in *[[:cntrl:]]*) return 1 ;; esac
  case "$type" in
    bool)
      case "$ans" in
        true | yes | y) kind=bool; value=true ;;
        false | no | n) kind=bool; value=false ;;
        *) return 1 ;;
      esac ;;
    list)
      kind=array
      set -f
      for item in ${ans//,/ }; do
        case "$item" in *[\"\\]*) set +f; return 1 ;; esac
        value="${value}${value:+$SETTINGS_RS}s$item"
        out="${out}${sep}\"$item\""; sep=", "
      done
      set +f
      [ -n "$value" ] || return 1 ;;
    number | positive | fraction | nonneg | posint)
      if [[ "$ans" =~ $int_re ]]; then kind=int
      elif [[ "$ans" =~ $float_re ]]; then kind=float
      else return 1; fi
      value="$ans" ;;
    *) kind=str; value="$ans" ;;
  esac
  _settings_value_ok "$type" "$kind" "$value" || return 1
  case "$kind" in
    str) printf '"%s"\n' "$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" ;;
    array) printf '[%s]\n' "$out" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# settings_update_file FILE CHANGES: FILE's text with the key changes applied, on
# stdout. CHANGES is newline-separated table<US>key<US>literal, the literal being
# TOML text ready to write; an empty literal clears the key. An active key line is
# replaced in place (repeats collapse into the first), a missing key goes right
# below its [table] header, a missing table is appended, a cleared key loses its
# active line. Every other line - comments, commented template lines, tables and
# keys the schema does not know - is copied as it is.
settings_update_file() {
  CHG="$2" awk -v us="$SETTINGS_US" '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function header(line) { return line ~ /^[ \t]*\[[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\][ \t\r]*(#.*)?$/ }
    function tname(line,   n) { n = line; sub(/^[ \t]*\[/, "", n); sub(/\].*$/, "", n); return trim(n) }
    function keyof(line,   k) {
      if (line !~ /^[ \t]*[A-Za-z0-9_-]+[ \t]*=/) return ""
      k = line; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*$/, "", k); return k
    }
    # any line starting with "[" ends the previous table; only a header the parser accepts names one
    function bracket(line) { return line ~ /^[ \t]*\[/ }
    # lines this script writes end like the file does
    function out(s) { printf "%s%s\n", s, cr }
    BEGIN {
      n = split(ENVIRON["CHG"], rows, "\n"); nc = 0; cr = ""; nt = 0
      for (i = 1; i <= n; i++) {
        if (rows[i] == "") continue
        split(rows[i], f, us)
        nc++; ct[nc] = f[1]; ck[nc] = f[2]; cl[nc] = f[3]
        want[f[1], f[2]] = nc
      }
    }
    FNR == NR {
      lines++
      if (FNR == 1 && $0 ~ /\r$/) cr = "\r"
      if (header($0)) { t = tname($0); known[t] = 1 }
      else if (bracket($0)) t = ""
      else if ((k = keyof($0)) != "") active[t, k] = 1
      next
    }
    FNR == 1 { t = "" }
    header($0) {
      t = tname($0); print
      for (i = 1; i <= nc; i++)
        if (ct[i] == t && cl[i] != "" && !((t, ck[i]) in active) && !(i in done)) {
          out(ck[i] " = " cl[i]); done[i] = 1
        }
      next
    }
    bracket($0) { t = ""; print; next }
    (k = keyof($0)) != "" && ((t, k) in want) {
      i = want[t, k]
      if (!(i in done)) { if (cl[i] != "") out(k " = " cl[i]); done[i] = 1 }
      next
    }
    { print }
    END {
      for (i = 1; i <= nc; i++) {
        if (cl[i] == "" || (ct[i] in known) || (ct[i] in tdone)) continue
        if (lines > 0 || nt > 0) out("")
        out("[" ct[i] "]"); tdone[ct[i]] = 1; nt++
        for (j = i; j <= nc; j++) if (ct[j] == ct[i] && cl[j] != "") out(ck[j] " = " cl[j])
      }
    }
  ' "$1" "$1"
}

# settings_load FILE: parse and validate into SETTINGS_RECORDS. [bootstrap] and
# [ghostty] keys must be in the schema with the right type; omnishell and
# modules.* tables pass through (omnishell validate checks those later).
settings_load() {
  local table key kind value type
  SETTINGS_FILE="$1"
  SETTINGS_RECORDS=""
  [ -r "$1" ] || return 0
  # an old KEY=value bootstrap.conf (e.g. DOTFILES_CONFIG still points at one)
  if awk '/^[ \t]*\[/ { t = 1 } /^[ \t]*[A-Z][A-Z_]*[ \t]*=/ { k = 1 } END { exit !(k && !t) }' "$1"; then
    warn "$1 looks like the old bootstrap.conf format (KEY=value) - convert it to the TOML of config.toml.example"
  fi
  while IFS="$SETTINGS_US" read -r table key kind value; do
    case "$table" in
      bootstrap | ghostty | tmux | git)
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

# sorted records of one table of FILE
_settings_table_records() {
  settings_parse "$1" 2>/dev/null | awk -F"$SETTINGS_US" -v t="$2" '
    $1 == t { if (!($2 in seen)) { seen[$2] = 1; order[++n] = $2 } rec[$2] = $0 }
    END { for (i = 1; i <= n; i++) print rec[order[i]] }' | sort
}

# tables of FILE that have a line settings_parse rejects (one name per line)
_settings_tables_with_rejects() {
  local lines
  lines="$(settings_parse "$1" 2>&1 >/dev/null | sed -n 's/^[^:]*:\([0-9][0-9]*\):.*/\1/p')"
  [ -n "$lines" ] || return 0
  awk -v lines="$lines" '
    BEGIN { n = split(lines, a, "\n"); for (i = 1; i <= n; i++) bad[a[i]] = 1 }
    /^[ \t]*\[[^\[].*\]/ { t = $0; sub(/^[ \t]*\[/, "", t); sub(/\].*$/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", t) }
    (FNR in bad) && t != "" && !(t in out) { out[t] = 1; print t }
  ' "$1"
}

# settings_omnishell_changes LIVE DEFAULT FILE: "set NAME" or "drop NAME" for every
# omnishell / modules.* table of LIVE that differs from what FILE says today (its
# own table of that name, else the one in DEFAULT). A table equal to DEFAULT's is
# dropped from FILE, any other one is set whole.
settings_omnishell_changes() {
  local live="$1" default="$2" file="$3" t now cur def skipped off
  skipped="$(_settings_tables_with_rejects "$live")"
  for t in $skipped; do
    warn "$live: [$t] holds a value this settings format cannot hold - the table is left out of $file"
  done
  while IFS= read -r t; do
    if [ -n "$skipped" ] && grep -qxF "$t" <<< "$skipped"; then continue; fi
    now="$(_settings_table_records "$live" "$t")"
    cur="$(_settings_table_records "$file" "$t")"
    def="$(_settings_table_records "$default" "$t")"
    [ -n "$cur" ] || cur="$def"
    [ "$now" = "$cur" ] && continue
    # a module the default does not list, switched off again, is "the default"
    off="${t}${SETTINGS_US}enabled${SETTINGS_US}bool${SETTINGS_US}false"
    if [ "$now" = "$def" ] || { [ -z "$def" ] && [ "$now" = "$off" ]; }; then echo "drop $t"; else echo "set $t"; fi
  done < <(settings_parse "$live" 2>/dev/null |
    awk -F"$SETTINGS_US" '($1 == "omnishell" || $1 ~ /^modules\./) && !($1 in seen) { seen[$1] = 1; print $1 }')
}

# settings_update_omnishell FILE LIVE DEFAULT: FILE's text with the omnishell
# tables of LIVE taken over (see settings_omnishell_changes), on stdout. A "set"
# table replaces the table of that name as a whole, or is appended; a "drop" table
# is removed. Blank and comment lines right above the next table stay where they are.
settings_update_omnishell() {
  local file="$1" live="$2" default="$3" changes sets drops saved blocks
  changes="$(settings_omnishell_changes "$live" "$default" "$file")"
  if [ -z "$changes" ]; then cat "$file"; return 0; fi
  sets="$(printf '%s\n' "$changes" | awk '$1 == "set" { printf "%s ", $2 }')"
  drops="$(printf '%s\n' "$changes" | awk '$1 == "drop" { printf "%s ", $2 }')"
  saved="$SETTINGS_RECORDS"
  SETTINGS_RECORDS="$(settings_parse "$live" 2>/dev/null |
    awk -F"$SETTINGS_US" -v sel="$sets" 'BEGIN { n = split(sel, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 } ($1 in w)')"$'\n'
  blocks="$(_settings_omnishell_blocks)"
  SETTINGS_RECORDS="$saved"
  OVR="$blocks" DROP="$drops" awk '
    function blank_or_comment(s) { return s ~ /^[ \t]*(#.*)?$/ }
    function header(line) { return line ~ /^[ \t]*\[[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\][ \t\r]*(#.*)?$/ }
    function bracket(line) { return line ~ /^[ \t]*\[/ }
    function tname(line,   n) { n = line; sub(/^[ \t]*\[/, "", n); sub(/\].*$/, "", n); gsub(/^[ \t]+|[ \t]+$/, "", n); return n }
    BEGIN {
      n = split(ENVIRON["OVR"], ol, "\n"); cur = ""
      for (i = 1; i <= n; i++) {
        if (ol[i] ~ /^\[/) { cur = substr(ol[i], 2, length(ol[i]) - 2); oorder[++no] = cur; otext[cur] = ol[i] "\n" }
        else if (ol[i] != "") otext[cur] = otext[cur] ol[i] "\n"
      }
      m = split(ENVIRON["DROP"], dl, " ")
      for (i = 1; i <= m; i++) if (dl[i] != "") drop[dl[i]] = 1
      skipping = 0; pend = ""
    }
    header($0) {
      printf "%s", pend; pend = ""; skipping = 0
      name = tname($0)
      if (name in used) { skipping = 1; next }
      if (name in otext) { printf "%s", otext[name]; used[name] = 1; skipping = 1; next }
      if (name in drop) { skipping = 1; next }
      print; next
    }
    bracket($0) { printf "%s", pend; pend = ""; skipping = 0; print; next }
    skipping { if (blank_or_comment($0)) pend = pend $0 "\n"; else pend = ""; next }
    { print }
    END {
      printf "%s", pend
      sep = (NR > 0) ? "\n" : ""
      for (i = 1; i <= no; i++) if (!(oorder[i] in used)) { printf "%s%s", sep, otext[oorder[i]]; sep = "\n" }
    }
  ' "$file"
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

# rename a migrated legacy file to FILE.migrated, or FILE.migrated.N when that exists
_settings_retire_legacy() {
  local dest="$1.migrated" n=1
  while [ -e "$dest" ]; do dest="$1.migrated.$n"; n=$((n + 1)); done
  mv "$1" "$dest"
}

# settings_migrate_legacy LEGACY NEW: one-time conversion of the old KEY=value
# bootstrap.conf. Only runs when LEGACY exists and NEW does not. A legacy file
# without an active key (the seeded template) is renamed, not converted.
settings_migrate_legacy() {
  local legacy="$1" new="$2" line key value t list="" install="" assume="" terminals=""
  [ -f "$legacy" ] || return 0
  if [ -e "$new" ]; then
    [ "$legacy" = "$new" ] || warn "$legacy is ignored: $new exists (delete $legacy or move its values into $new)"
    return 0
  fi
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
    _settings_retire_legacy "$legacy"
    return 0
  fi
  mkdir -p "$(dirname "$new")"
  {
    printf '# Migrated from bootstrap.conf. config.toml.example lists every option.\n[bootstrap]\n'
    [ -z "$install" ] || printf 'install_zsh = "%s"\n' "$install"
    [ -z "$assume" ] || printf 'assume_yes = %s\n' "$assume"
    [ -z "$list" ] || printf 'terminals = [%s]\n' "$list"
  } > "$new"
  _settings_retire_legacy "$legacy"
  log "migrated $legacy to $new"
}

# tmux commands for the [tmux] values that are set, in a fixed order. A prefix
# change unbinds the tracked default C-a first, so setting C-a itself still works.
settings_render_tmux() {
  local v tracked="${1:-C-a}"
  v="$(settings_get tmux.prefix)"
  if [ -n "$v" ]; then
    printf 'unbind %s\nset -g prefix %s\nbind %s send-prefix\n' "$tracked" "$v" "$v"
  fi
  v="$(settings_get tmux.mouse)"
  case "$v" in
    true) printf 'set -g mouse on\n' ;;
    false) printf 'set -g mouse off\n' ;;
  esac
  v="$(settings_get tmux.mode_keys)"
  [ -z "$v" ] || printf 'set-window-option -g mode-keys %s\n' "$v"
  v="$(settings_get tmux.base_index)"
  [ -z "$v" ] || printf 'set -g base-index %s\n' "$v"
  v="$(settings_get tmux.escape_time)"
  [ -z "$v" ] || printf 'set -sg escape-time %s\n' "$v"
  v="$(settings_get tmux.history_limit)"
  [ -z "$v" ] || printf 'set -g history-limit %s\n' "$v"
  v="$(settings_get tmux.status_position)"
  [ -z "$v" ] || printf 'set -g status-position %s\n' "$v"
}

# git-config-key<US>value records for the [git] values that are set. signing_key
# is left to the bootstrap: it needs the public key file to exist and sets four
# keys (see write_git_signing_config).
settings_render_git() {
  local v
  v="$(settings_get git.user_name)"
  [ -z "$v" ] || printf 'user.name%s%s\n' "$SETTINGS_US" "$v"
  v="$(settings_get git.user_email)"
  [ -z "$v" ] || printf 'user.email%s%s\n' "$SETTINGS_US" "$v"
  v="$(settings_get git.default_branch)"
  [ -z "$v" ] || printf 'init.defaultBranch%s%s\n' "$SETTINGS_US" "$v"
  v="$(settings_get git.editor)"
  [ -z "$v" ] || printf 'core.editor%s%s\n' "$SETTINGS_US" "$v"
  v="$(settings_get git.pull_rebase)"
  [ -z "$v" ] || printf 'pull.rebase%s%s\n' "$SETTINGS_US" "$v"
}
