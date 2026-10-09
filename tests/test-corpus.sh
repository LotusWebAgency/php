#!/usr/bin/env bash
# Assertions for a PGO training corpus image.
#
#   ./tests/test-corpus.sh ghcr.io/lotuswebagency/php/corpus:php8.2
#
# Nothing here carries a hand-written list of what the corpus contains. The app
# list comes from the tier's line in php/pgo/corpus/tiers, the expected versions
# from the same corpus.lock and composer.lock files the build installs from, and
# the expected request paths from each app's committed endpoints file. Name an
# app in the tier without teaching the build about it and this fails.
#
# Capture, then match. `docker run ... | grep -q` exits at the first match and
# SIGPIPEs the producer, which pipefail reports as a failed pipeline -- and in
# `if` form it fails open. See tests/smoke.sh.
set -euo pipefail
IMAGE="${1:?usage: test-corpus.sh <corpus-image>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../php/pgo/corpus"

fail() { echo "FAIL: $*" >&2; exit 1; }

# lock_version <composer.lock> <package>  -- prints the version, minus the v.
lock_version() {
  python3 - "$1" "$2" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
for section in ("packages", "packages-dev"):
    for p in lock.get(section) or []:
        if p["name"] == sys.argv[2]:
            print(p["version"].lstrip("v"))
            sys.exit(0)
sys.exit("package %s not in %s" % (sys.argv[2], sys.argv[1]))
PY
}

# --- tier --------------------------------------------------------------------
tier="$(docker run --rm "$IMAGE" sh -c 'printf %s "${CORPUS_TIER:-}"')"
[ -n "$tier" ] || fail "image does not declare CORPUS_TIER"
python3 "${HERE}/../scripts/pgo_tiers.py" apps-of "$tier" >/dev/null 2>&1 || fail "'$tier' is not a tier floor in ${SRC}/tiers"
echo "ok: tier $tier"

# A tier floor is a PHP version, and the image has to be built on it: an image
# built from another tier's builder passes every other check in this file --
# the apps install, the locks match -- while profiling the wrong PHP.
got_php="$(docker run --rm "$IMAGE" php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
[ "$tier" = "$got_php" ] || fail "tier $tier must be built on php $tier, image is php $got_php"
echo "ok: php $got_php, the floor of tier $tier"

# config.platform.php is what Composer resolved against, and therefore the floor
# it wrote into vendor/composer/platform_check.php. It has to be this tier's own
# release from matrix.json: higher and the lock stops installing on the tier's
# floor, lower and Composer picked packages older than it had to.
release="$(python3 "${HERE}/../scripts/pgo_tiers.py" field "$tier" release)"
for manifest in "${SRC}"/*/"${tier}"/composer.json; do
  [ -f "$manifest" ] || continue
  platform="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["config"]["platform"]["php"])' "$manifest")"
  [ "$platform" = "$release" ] \
    || fail "$manifest resolves against php $platform, but matrix.json says tier $tier is php $release"
done
echo "ok: every tier $tier manifest resolves against php $release, the matrix.json release"

# --- the tier's line in corpus/tiers is the app list --------------------------
# Not the directories under $SRC: that tree holds every app any tier trains, so
# a tier that does not train one of them (Drupal below 8.4) would be expected to
# have it, and the check below that nothing else is in /corpus would pass or
# fail for the wrong reason.
mapfile -t apps < <(python3 "${HERE}/../scripts/pgo_tiers.py" apps-of "$tier")
[ "${#apps[@]}" -gt 0 ] || fail "tier $tier names no apps in ${SRC}/tiers"
for app in "${apps[@]}"; do
  [ -f "${SRC}/${app}/endpoints" ] || fail "tier $tier names $app, which has no ${SRC}/${app}/endpoints"
done

listing="$(docker run --rm "$IMAGE" sh -c 'ls -1 /corpus')"
for app in "${apps[@]}"; do
  grep -qx "$app" <<<"$listing" || fail "missing /corpus/$app (image has: $(tr '\n' ' ' <<<"$listing"))"
done
for entry in $listing; do
  [ "$entry" = MANIFEST ] && continue
  found=no
  for app in "${apps[@]}"; do [ "$entry" = "$app" ] && found=yes; done
  [ "$found" = yes ] || fail "/corpus/$entry is in the image but not in $SRC"
done
echo "ok: all ${#apps[@]} apps present, and nothing else (${apps[*]})"

# --- the image was built from this working tree, not an older one ------------
# One hash over every file under php/pgo/corpus, compared with the same hash
# over /corpus-src. Everything the build reads is in there -- the lockfiles,
# the pins, the Symfony app, the endpoint manifests this file derives its own
# assertions from -- so a green run against a stale image is not possible.
#
# The host side has to skip exactly what docker skipped when it copied the tree
# in, or a developer who runs `composer install` under corpus/symfony/app makes
# this fail forever with "rebuild the image" -- the vendor tree is on disk but
# was never in the image, and no rebuild can fix that. The prune list is read
# from php/pgo/.dockerignore rather than restated here, so the two cannot drift.
prunes=()
while read -r pattern; do
  case "$pattern" in ''|\#*) continue ;; esac
  case "$pattern" in corpus/*) ;; *) continue ;; esac   # anything else is outside $SRC
  rel="${pattern#corpus/}"; rel="${rel%/}"
  prunes+=( -path "./${rel}" -prune -o )
done < "${HERE}/../php/pgo/.dockerignore"

file_hashes() {  # file_hashes: reads from cwd
  find . "${prunes[@]}" -type f ! -name corpus.lock -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
}
host_files="$( (cd "$SRC" && file_hashes) )"
image_files="$(docker run --rm "$IMAGE" sh -c '
  cd /corpus-src && find . -type f ! -name corpus.lock -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
')"
[ -n "$host_files" ] || fail "no files under $SRC -- the prune list from .dockerignore swallowed the whole tree"
if [ "$host_files" != "$image_files" ]; then
  fail "/corpus-src does not match $SRC. Either rebuild the image (./tests/build-corpus.sh $tier),
or remove the local build artifacts listed here that were never in it:
$(diff <(echo "$host_files") <(echo "$image_files") | head -20)"
fi

want="$(sha256sum "${HERE}/../php/pgo/corpus.lock")"; want="${want%% *}"
got="$(docker run --rm "$IMAGE" sha256sum /corpus-src/corpus.lock)"; got="${got%% *}"
[ "$want" = "$got" ] || fail "corpus.lock in the image differs from the working tree -- rebuild the image"
echo "ok: image was built from the committed pins, lockfiles and manifests"

# --- versions match what the pins say, read off the installed artifacts -------
for app in "${apps[@]}"; do
  spec="${SRC}/${app}/endpoints"
  [ -f "$spec" ] || fail "$app has no endpoints file"
  kind=""; arg=""
  while read -r key a b; do
    case "$key" in
      version) kind="$a"; arg="${b:-}" ;;
    esac
  done < "$spec"

  case "$kind" in
    composer)
      want="$(lock_version "${SRC}/${app}/${tier}/composer.lock" "$arg")"
      got="$(docker run --rm "$IMAGE" php -r '
        $d = json_decode(file_get_contents($argv[1]."/vendor/composer/installed.json"), true);
        $ps = isset($d["packages"]) ? $d["packages"] : $d;
        foreach ($ps as $p) { if ($p["name"] === $argv[2]) { echo ltrim($p["version"], "v"); exit; } }
        exit(1);
      ' "/corpus/$app" "$arg")"
      ;;
    wordpress)
      want="$(bash "${SRC}/fetch.sh" --pin "$tier" wordpress)"
      got="$(docker run --rm "$IMAGE" php -r '
        $wp_version = ""; require $argv[1]."/wp-includes/version.php"; echo $wp_version;
      ' "/corpus/$app")"
      ;;
    prestashop)
      # Pinned by corpus.lock's PrestaShop rows (image digest, not a fetched
      # zip -- see its header), read the same way verify.sh does.
      want="$(awk -v t="$tier" '$1==t && $2=="prestashop" {print $3}' "${HERE}/../php/pgo/corpus.lock")"
      [ -n "$want" ] || fail "corpus.lock has no prestashop row for tier $tier"
      got="$(docker run --rm "$IMAGE" php -r '
        require $argv[1]."/install/install_version.php"; echo _PS_INSTALL_VERSION_;
      ' "/corpus/$app")"
      ;;
    *) fail "$spec: unknown version kind '$kind'" ;;
  esac
  [ "$want" = "$got" ] || fail "$app: pinned $want, image has $got"
  echo "ok: $app $got matches the pin"
done

# --- the SQLite databases hold real rows, not just an inode ------------------
# File, query and expected-nonzero all come from each app's endpoints file --
# the same three lines the build asserted against before it served anything.
# PrestaShop's is "database mysql:<socket>:<dbname> <sql>" -- skipped here and
# checked separately below, since it needs mariadbd running, not a PDO sqlite
# open.
args=()
mysql_apps=()
for app in "${apps[@]}"; do
  while read -r key a b; do
    [ "$key" = database ] || continue
    case "$a" in
      mysql:*) mysql_apps+=("$app") ;;
      *)       args+=("$app" "/corpus/${app}/${a}" "$b") ;;
    esac
  done < "${SRC}/${app}/endpoints"
done
[ "${#args[@]}" -eq $(( (${#apps[@]} - ${#mysql_apps[@]}) * 3 )) ] || fail "not every non-mysql app declares a database in its endpoints file"

rows="$(docker run --rm "$IMAGE" php -r '
  for ($i = 1; $i + 2 < $argc; $i += 3) {
    $name = $argv[$i]; $file = $argv[$i + 1]; $sql = $argv[$i + 2];
    if (!is_file($file)) { echo "$name missing $file\n"; continue; }
    try {
      $pdo = new PDO("sqlite:".$file, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
      echo $name." ".$pdo->query($sql)->fetchColumn()."\n";
    } catch (Exception $e) { echo $name." ERROR ".$e->getMessage()."\n"; }
  }
' "${args[@]}")"
is_mysql_app() { local a="$1" m; for m in "${mysql_apps[@]:-}"; do [ "$m" = "$a" ] && return 0; done; return 1; }

for app in "${apps[@]}"; do
  is_mysql_app "$app" && continue
  line="$(grep "^${app} " <<<"$rows" || true)"
  [ -n "$line" ] || fail "no sqlite result for $app (got: $rows)"
  count="${line#* }"
  [[ "$count" =~ ^[0-9]+$ ]] || fail "$app sqlite query failed: $line"
  [ "$count" -gt 0 ] || fail "$app sqlite database is empty ($line)"
  echo "ok: $app sqlite seeded ($count rows)"
done

# PrestaShop's database check needs mariadbd running, which needs
# mariadb-server installed fresh in this --rm container (the runtime image
# does not ship it -- same reasoning as tests/test-corpus-tiers.sh's
# run_corpus). --network host for the apt-get; --user 0 to install packages
# and to start mariadbd against the volume's uid-33 datadir (root can read and
# write it regardless of ownership, so nothing here needs a chown).
for app in "${mysql_apps[@]:-}"; do
  [ -n "$app" ] || continue
  spec="${SRC}/${app}/endpoints"
  db_line="$(awk '$1=="database"{print; exit}' "$spec")"
  db_arg="$(awk '{print $2}' <<<"$db_line")"
  db_sql="$(cut -d' ' -f3- <<<"$db_line")"
  rest="${db_arg#mysql:}"; db_name="${rest##*:}"; hostport="${rest%:*}"; db_host="${hostport%%:*}"; db_port="${hostport#*:}"
  out="$(docker run --rm --user 0 --network host --entrypoint sh "$IMAGE" -c '
    set -eu
    apt-get update -qq >/tmp/apt.log 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends mariadb-server >>/tmp/apt.log 2>&1 \
      || { tail -30 /tmp/apt.log >&2; exit 1; }
    '"/corpus-src/${app}/db-up.sh"' "/corpus/'"${app}"'"
    php -r "\$pdo = new PDO(\"mysql:host=\$argv[1];port=\$argv[2];dbname=\$argv[3]\", null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]); echo (int) \$pdo->query(\$argv[4])->fetchColumn();" '"$db_host"' '"$db_port"' '"$db_name"' "'"$db_sql"'"
  ' 2>&1)"
  count="$(tail -1 <<<"$out")"
  [[ "$count" =~ ^[0-9]+$ ]] || fail "$app mysql query failed: $out"
  [ "$count" -gt 0 ] || fail "$app mysql database is empty ($out)"
  echo "ok: $app mysql seeded ($count rows)"
done

# --- every app still serves, measured now, not trusted from build time -------
served="$(docker run --rm "$IMAGE" /corpus-src/verify.sh /corpus /corpus-src /tmp/MANIFEST)"
echo "$served" | sed 's/^/    /'
for app in "${apps[@]}"; do
  spec="${SRC}/${app}/endpoints"
  # Four fields, not three: a path line is "path <p> <required|optional>
  # <min-bytes> <expected substring>", so reading it into three variables puts
  # "required 2048 PGO training corpus" in $b and quietly matches nothing --
  # every required-path assertion below would be skipped, and skipped silently.
  checked=0
  control_path="/corpus-negative-control-4f21a9"
  while read -r key a b _rest; do
    if [ "$key" = negative-control ]; then control_path="$a"; continue; fi
    [ "$key" = path ] || continue
    [ "$b" = required ] || continue
    grep -qF "  $app $a -> 200 " <<<"$served" || fail "$app $a did not answer 200 in the built image"
    checked=$((checked + 1))
  done < "$spec"
  [ "$checked" -gt 0 ] || fail "$spec declares no required path -- nothing was checked for $app"
  grep -qF "  $app ${control_path} -> " <<<"$served" \
    || fail "$app: verify.sh ran no negative control"
done
echo "ok: every required path answers 200, each app against a 404 control"

# --- the build's own manifest agrees with what just happened ------------------
# Byte-for-byte, not "has a row per app". PGO training derives its request list
# from /corpus/MANIFEST, so a path that served at build time and stopped serving
# since would otherwise be requested and silently 404 during training -- and
# optional paths are never re-checked anywhere else.
built="$(docker run --rm "$IMAGE" cat /corpus/MANIFEST)"
# verify.sh prints the manifest it just wrote after a "=== MANIFEST" marker;
# the run above already produced it, so this needs no second container.
fresh="$(sed -n '/^=== MANIFEST$/,$p' <<<"$served" | tail -n +2)"
[ "$built" = "$fresh" ] || fail "/corpus/MANIFEST no longer matches what the corpus serves:
$(diff <(echo "$built") <(echo "$fresh") || true)"
for app in "${apps[@]}"; do
  grep -qE "^${app}	" <<<"$built" || fail "/corpus/MANIFEST has no row for $app"
done
echo "ok: /corpus/MANIFEST still matches what the corpus serves, every app covered"

# --- ownership: uid 33 only, with a control that proves find can see otherwise
owners="$(docker run --rm "$IMAGE" sh -c '
  echo "strays: $(find /corpus ! -uid 33 -print -quit)"
  echo "control: $(find /usr/local/bin/php ! -uid 33 -print -quit)"
')"
strays="$(grep '^strays: ' <<<"$owners")"; strays="${strays#strays: }"
control="$(grep '^control: ' <<<"$owners")"; control="${control#control: }"
[ -n "$control" ] || fail "'find ! -uid 33' matched nothing on a root-owned file -- it could not have seen a stray either"
[ -z "$strays" ] || fail "$strays under /corpus is not owned by uid 33"
echo "ok: /corpus is uid 33 only (control saw $control)"

# --- no setuid binaries, with a control that plants one and finds it ----------
# Scanned as uid 0, not as the image's www-data: as www-data, find cannot read
# /root, /etc/ssl/private or /var/cache/ldconfig, so "found nothing" would be
# partly a statement about what it was allowed to look at. rc is checked for
# the same reason -- a find that hit a single permission denial has not scanned
# the filesystem, and an empty result from it proves nothing.
scan="$(docker run --rm --user 0 --entrypoint sh "$IMAGE" -c '
  find / -xdev -perm /6000 -type f; echo "rc=$?"
')"
rc="$(grep '^rc=' <<<"$scan")"
[ "$rc" = "rc=0" ] || fail "the setuid scan could not read the whole filesystem ($rc)"
suid="$(grep -v '^rc=' <<<"$scan" || true)"
[ -z "$suid" ] || fail "setuid/setgid binaries present: $(tr '\n' ' ' <<<"$suid")"
planted="$(docker run --rm --user 0 --entrypoint sh "$IMAGE" -c '
  cp /bin/true /tmp/suid-control && chmod u+s /tmp/suid-control
  find / -xdev -perm /6000 -type f
')"
grep -qx '/tmp/suid-control' <<<"$planted" \
  || fail "the setuid scan did not find a setuid file that was deliberately planted -- it measures nothing"
echo "ok: no setuid binaries (control found the planted one)"

echo "CORPUS TESTS PASSED"
