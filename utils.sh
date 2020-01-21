# shellcheck shell=dash
# shellcheck enable=all

readonly NL='
'

readonly DEFAULT_IFS="${IFS}"

# Variable to return the results
R=

err() {
  local s
  s="${0##*/}:"
  # take advantage of few bash-exposed variables when available
  if test -n "${BASH_LINENO-}"; then
    eval 's="${s}${BASH_LINENO[0]}:"'
  fi
  if test -n "${FUNCNAME-}"; then
    eval 's="${s}${FUNCNAME[1]}:"'
  fi
  printf '%s %s\n' "${s}" "$*" >&2
  exit 1
}

has_value() {
  # check that the passed name is a valid variable name
  local "${1}x"
  eval 'test 0 -ne "${#'"$1"'}"'
}

is_empty() {
  # check that the passed name is a valid variable name
  local "${1}x"
  eval 'test 0 -eq "${#'"$1"'}"'
}

# Append to eargs space-separated arguments with spaces and other special
# characters escaped.
earg() {
  local arg do_escape escaped before_quote
  for arg in "$@"; do
    do_escape=
    case "${arg}" in
    "" | *[!A-Z0-9a-z_.,/:-]*) do_escape=1 ;;
    *) ;;
    esac
    if test -n "${do_escape}"; then
      escaped=
      while : ; do
        before_quote="${arg%%\'*}"
        if test "x${arg}" = "x${before_quote}"; then
          break
        fi
        escaped="${escaped}${before_quote}'\\''"
        arg="${arg#*\'}"
      done
      arg="'${escaped}${arg}'"
    fi
    eargs="${eargs}${eargs:+ }${arg}"
  done
}

# Set R to concatenation of arguments with spaces escaped if necessary.
escape_for_shell() {
  test 1 -eq $# || \
    err "escape_for_shell takes exactly one argument while $# were given"
  R=
  local eargs
  eargs=
  earg "$1"
  R="${eargs}"
}

pl(){
  lines="${lines}$*${NL}"
}

read_stdin() {
  local line
  if test -t 0; then
    err "cannot read from stdin when it is a terminal"
  fi
  R=
  line=
  while IFS= read -r line; do
    R="${R}${line}${NL}"
    line=
  done
  # line is not empty when last line was not terminated by eof
  R="${R}${line}"
}
