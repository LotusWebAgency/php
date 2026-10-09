# shellcheck shell=bash
# Helpers for tests/apps/<app>/suite/{cli,builder}.sh. Those run inside the
# image under test (bash is there on ours and on every stock image), with the
# fixture tree at /srv/app (the cwd) and tests/apps read-only at /apptest.
#
#   . /apptest/cli-lib.sh
#   check "artisan boots" php artisan --version
#   check_out "post count" "2000" php artisan apptest:count posts
#   finish laravel-cli
#
# Same line format as apptest.py: "ok: <name>", "FAIL: <name> -- <why>",
# "SKIP: <name> -- <why>", one summary line last, exit 1 when anything failed.
# A failing check listed for this cell in tests/apps/known-failures prints
# "XFAIL: <name> -- <why>" instead and does not fail the suite.

APPTEST_PASSED=0
APPTEST_FAILED=0
APPTEST_SKIPPED=0
APPTEST_XFAILED=0
APPTEST_T0=$(date +%s)
APPTEST_OUT="$(mktemp)"

# known_failure <check name> -- prints the reason when tests/apps/known-failures
# lists that check for this cell (APPTEST_APP/SET/PHP, set by compose.yml).
known_failure() {
  local app set php rest
  [ -r /apptest/known-failures ] || return 1
  while read -r app set php rest; do
    case "$app" in ''|\#*) continue ;; esac
    [ "$app" = "${APPTEST_APP:-}" ] && [ "$set" = "${APPTEST_SET:-}" ] && [ "$php" = "${APPTEST_PHP:-}" ] || continue
    [ "${rest%% -- *}" = "$1" ] || continue
    printf '%s\n' "${rest#* -- }"
    return 0
  done < /apptest/known-failures
  return 1
}

ok() {
  APPTEST_PASSED=$((APPTEST_PASSED + 1)); echo "ok: $*"
  if known_failure "$*" >/dev/null; then
    echo "note: '$*' is listed in tests/apps/known-failures for ${APPTEST_APP:-} ${APPTEST_SET:-} on ${APPTEST_PHP:-} and passed -- drop the row"
  fi
}
fail() {
  local why
  if why="$(known_failure "${*%% -- *}")"; then
    APPTEST_XFAILED=$((APPTEST_XFAILED + 1)); echo "XFAIL: $* [known: $why]"
  else
    APPTEST_FAILED=$((APPTEST_FAILED + 1)); echo "FAIL: $*"
  fi
}
skip() { APPTEST_SKIPPED=$((APPTEST_SKIPPED + 1)); echo "SKIP: $*"; }

# check <name> <cmd...> -- passes when the command exits 0; its output is
# shown only on failure.
check() {
  local name="$1"; shift
  if "$@" >"$APPTEST_OUT" 2>&1; then
    ok "$name"
  else
    fail "$name -- exit $? from: $*"
    sed 's/^/    | /' "$APPTEST_OUT" | tail -40
  fi
}

# check_out <name> <expected substring> <cmd...> -- the command must exit 0
# and print the substring.
check_out() {
  local name="$1" want="$2"; shift 2
  if "$@" >"$APPTEST_OUT" 2>&1 && grep -qF -- "$want" "$APPTEST_OUT"; then
    ok "$name"
  else
    fail "$name -- expected '$want' from: $*"
    sed 's/^/    | /' "$APPTEST_OUT" | tail -40
  fi
}

# php_at_least X.Y -- true when the running php is at least X.Y.
php_at_least() {
  php -r 'exit(version_compare(PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION, $argv[1], ">=") ? 0 : 1);' "$1"
}

finish() {
  local total=$((APPTEST_PASSED + APPTEST_FAILED)) status=passed
  [ "$APPTEST_FAILED" -eq 0 ] || status=FAILED
  rm -f "$APPTEST_OUT"
  echo "$1: $APPTEST_PASSED/$total passed, $APPTEST_FAILED failed, $APPTEST_XFAILED known, $APPTEST_SKIPPED skipped in $(( $(date +%s) - APPTEST_T0 ))s -- $status"
  [ "$APPTEST_FAILED" -eq 0 ]
}
