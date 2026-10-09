#!/usr/bin/env bash
# Prove every corpus app actually serves, then write what was proven into
# /corpus/MANIFEST.
#
#   CORPUS_TIER=<floor> verify.sh <corpus-root> <src-root> <manifest>
#
# Which apps it serves comes from the tier's line in <src-root>/tiers.
#
# The build serves the apps rather than trusting `composer install`: an app that
# installs cleanly and then 500s on every request would train the profile on the
# exception path (the Symfony demo does exactly that, which is why this corpus
# does not use it).
#
# Status alone is not enough: a 200 with an empty body or a framework error page
# looks like a rendered page by HTTP code. Every declared path has to answer 200,
# exceed a byte floor, and contain a substring only a correctly rendered page has,
# all from the app's committed endpoints file.
#
# MANIFEST records only paths that passed, so train.sh derives its request list
# instead of hardcoding one.
set -euo pipefail

# An expected substring may list alternatives separated by '|' (see
# corpus/prestashop/endpoints) -- the body has to carry at least one.
body_has() {  # body_has <file> <expect>
  local alts=() args=() a
  IFS='|' read -ra alts <<<"$2"
  for a in "${alts[@]}"; do args+=(-e "$a"); done
  grep -qF "${args[@]}" -- "$1"
}
CORPUS="${1:?usage: verify.sh <corpus-root> <src-root> <manifest>}"
SRC="${2:?usage: verify.sh <corpus-root> <src-root> <manifest>}"
MANIFEST="${3:?usage: verify.sh <corpus-root> <src-root> <manifest>}"

port=18201
: > "$MANIFEST"
printf '# app\tdocroot\tversion\tpaths (each answered 200 with expected content at build time)\n' >> "$MANIFEST"

installed_version() {  # installed_version <app-dir> <composer-package>
  php -r '
    $f = $argv[1]."/vendor/composer/installed.json";
    if (!is_file($f)) { fwrite(STDERR, "no $f\n"); exit(1); }
    $d = json_decode(file_get_contents($f), true);
    $packages = isset($d["packages"]) ? $d["packages"] : $d;
    foreach ($packages as $p) {
      if ($p["name"] === $argv[2]) { echo ltrim($p["version"], "v"); exit(0); }
    }
    fwrite(STDERR, "package ".$argv[2]." not installed\n");
    exit(1);
  ' "$1" "$2"
}

wordpress_version() {  # wordpress_version <app-dir>
  php -r '
    $f = $argv[1]."/wp-includes/version.php";
    if (!is_file($f)) { fwrite(STDERR, "no $f\n"); exit(1); }
    $wp_version = "";
    require $f;
    if ("" === $wp_version) { fwrite(STDERR, "no \$wp_version in $f\n"); exit(1); }
    echo $wp_version;
  ' "$1"
}

prestashop_version() {  # prestashop_version <app-dir>
  php -r '
    $f = $argv[1]."/install/install_version.php";
    if (!is_file($f)) { fwrite(STDERR, "no $f\n"); exit(1); }
    require $f;
    if (!defined("_PS_INSTALL_VERSION_")) { fwrite(STDERR, "no _PS_INSTALL_VERSION_ in $f\n"); exit(1); }
    echo _PS_INSTALL_VERSION_;
  ' "$1"
}

# PrestaShop is the one app whose database is not a bundled sqlite file (its
# ObjectModel/Db layer speaks MySQL/MariaDB only). Its endpoints file says
# "database mysql:<host>:<port>:<dbname> <sql>" instead of a file path; db-up.sh
# and db-down.sh live next to it in php/pgo/corpus/prestashop/.
mysql_row_count() {  # mysql_row_count <host> <port> <dbname> <sql>
  php -r '
    $pdo = new PDO("mysql:host=".$argv[1].";port=".$argv[2].";dbname=".$argv[3], null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    echo (int) $pdo->query($argv[4])->fetchColumn();
  ' "$1" "$2" "$3" "$4"
}

# The apps are the tier's own line in corpus/tiers, not whatever directories sit
# under $SRC: that tree holds every app any tier trains, and a tier that does not
# train one (Drupal below 8.4) never installed it. CORPUS_TIER is baked into the
# corpus image; a caller that mounts the corpus into another runtime
# (tests/test-corpus-tiers.sh) must pass it. There is no directory-glob fallback,
# which would silently serve the wrong set.
tier="${CORPUS_TIER:?verify.sh needs CORPUS_TIER, the tier floor whose apps it serves}"
apps="$(awk -v t="$tier" '$1 == t { for (i = 2; i <= NF; i++) print $i }' "${SRC}/tiers")"
[ -n "$apps" ] || { echo "FATAL: tier '$tier' names no apps in ${SRC}/tiers" >&2; exit 1; }

for app in $apps; do
  appdir="${SRC}/${app}/"
  spec="${appdir}endpoints"
  [ -f "$spec" ] || { echo "FATAL: $app has no endpoints file" >&2; exit 1; }

  docroot_rel=""; version_kind=""; version_arg=""; db_file=""; db_sql=""
  # Default for every app but PrestaShop, whose endpoints file overrides it (see
  # the negative control below).
  control_path="/corpus-negative-control-4f21a9"
  paths=(); required=(); floors=(); expects=()
  while read -r key a b c rest; do
    case "$key" in
      ''|\#*)   continue ;;
      docroot)  docroot_rel="$a" ;;
      version)  version_kind="$a"; version_arg="${b:-}" ;;
      database) db_file="$a"; db_sql="${b:?endpoints: database $a has no query} ${c:-} ${rest:-}" ;;
      negative-control) control_path="${a:?endpoints: negative-control has no path}" ;;
      path)     paths+=("$a")
                required+=("${b:?endpoints: path $a has no required/optional flag}")
                floors+=("${c:?endpoints: path $a has no byte floor}")
                expects+=("${rest:?endpoints: path $a has no expected substring}") ;;
      *)        echo "FATAL: $spec: unknown key '$key'" >&2; exit 1 ;;
    esac
  done < "$spec"

  root="${CORPUS}/${app}"
  [ -d "$root" ] || { echo "FATAL: $spec exists but $root was never installed" >&2; exit 1; }
  [ "${#paths[@]}" -gt 0 ] || { echo "FATAL: $spec declares no paths" >&2; exit 1; }

  case "$docroot_rel" in
    .) docroot="$root" ;;
    *) docroot="${root}/${docroot_rel}" ;;
  esac
  [ -d "$docroot" ] || { echo "FATAL: docroot $docroot does not exist" >&2; exit 1; }

  case "$version_kind" in
    composer)   version="$(installed_version "$root" "$version_arg")" ;;
    wordpress)  version="$(wordpress_version "$root")" ;;
    prestashop) version="$(prestashop_version "$root")" ;;
    *)          echo "FATAL: $spec: unknown version kind '$version_kind'" >&2; exit 1 ;;
  esac

  # The seeded database, before anything is served: an app that boots and then
  # answers 200 out of an empty schema is exactly the failure this catches.
  [ -n "$db_file" ] || { echo "FATAL: $spec declares no database" >&2; exit 1; }
  mysql_started=no
  case "$db_file" in
    mysql:*)
      rest="${db_file#mysql:}"
      db_name="${rest##*:}"
      hostport="${rest%:*}"
      db_host="${hostport%%:*}"
      db_port="${hostport#*:}"
      "${appdir}db-up.sh" "$root"
      mysql_started=yes
      # Point the app at the host:port it is about to be served on, if it has a
      # hook for that (see corpus/prestashop/set-host.sh).
      [ -x "${appdir}set-host.sh" ] && "${appdir}set-host.sh" "$root" "127.0.0.1:${port}"
      rows="$(mysql_row_count "$db_host" "$db_port" "$db_name" "$db_sql")"
      ;;
    *)
      rows="$(php -r '
        $f = $argv[1];
        if (!is_file($f)) { fwrite(STDERR, "no $f\n"); exit(1); }
        $pdo = new PDO("sqlite:".$f, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        echo (int) $pdo->query($argv[2])->fetchColumn();
      ' "${root}/${db_file}" "$db_sql")"
      ;;
  esac
  [ "$rows" -gt 0 ] 2>/dev/null || { echo "FATAL: $app: '$db_sql' returned '$rows' against ${db_file}" >&2; exit 1; }
  echo "  $app ${db_file}: $rows rows"

  # WordPress pins WP_HOME to this host:port; anything else and every request
  # is answered with a canonical redirect instead of a rendered page.
  export CORPUS_WP_HOST="127.0.0.1:${port}"
  # A request that never ends must fail, not spin: max_execution_time turns it into
  # a 500, and ulimit -f (100 MB) kills a server whose log runs away. A PHP 7.2
  # optimizer miscompile once looped here writing notices until the disk filled.
  ( ulimit -f 102400; cd "$root" && exec php -d max_execution_time=120 -S "127.0.0.1:${port}" -t "$docroot" ) \
    >"/tmp/verify-${app}.log" 2>&1 &
  server=$!

  up=no
  for _ in $(seq 1 80); do
    if curl -fsSL -o /dev/null "http://127.0.0.1:${port}${paths[0]}" 2>/dev/null; then up=yes; break; fi
    kill -0 "$server" 2>/dev/null || break
    sleep 0.25
  done
  [ "$up" = yes ] || {
    echo "FATAL: $app never answered 200 on ${paths[0]}" >&2
    tail -20 "/tmp/verify-${app}.log" >&2
    kill "$server" 2>/dev/null || true
    [ "$mysql_started" = yes ] && "${appdir}db-down.sh" || true
    exit 1
  }

  die() { echo "FATAL: $*" >&2; tail -20 "/tmp/verify-${app}.log" >&2; kill "$server" 2>/dev/null || true; [ "$mysql_started" = yes ] && "${appdir}db-down.sh" || true; exit 1; }

  # -L: PrestaShop 302s a query-string request to its canonical parameter order
  # (?controller=x&id_y=n -> ?id_y=n&controller=x) even with PS_REWRITING_SETTINGS
  # off. No other app's required paths redirect, so following redirects everywhere
  # avoids special-casing one app.
  served=""
  i=0
  for path in "${paths[@]}"; do
    code="$(curl -sL -o /tmp/verify-body -w '%{http_code}' "http://127.0.0.1:${port}${path}")"
    bytes="$(wc -c < /tmp/verify-body)"
    echo "  $app $path -> $code ($bytes bytes)"
    if [ "$code" = 200 ]; then
      [ "$bytes" -ge "${floors[$i]}" ] \
        || die "$app $path answered 200 with $bytes bytes, floor is ${floors[$i]}"
      body_has /tmp/verify-body "${expects[$i]}" \
        || die "$app $path answered 200 without '${expects[$i]}' in the body"
      served="${served:+${served},}${path}"
    elif [ "${required[$i]}" = required ]; then
      die "$app $path answered $code, expected 200"
    fi
    i=$((i + 1))
  done

  # Negative control for everything above: "every required path answered 200 with
  # the right content" is equally true of a server that answers 200 to everything,
  # as a misconfigured front controller does. Any non-200 passes; WordPress
  # answers 301 here rather than 404 because an unknown path hits its canonical
  # redirect first.
  #
  # The control is an extension-less path with no matching file. PHP's built-in
  # server forwards it to index.php on every trained version (7.x-8.5), and
  # Laravel, Symfony and WordPress each have a router that rejects an undefined
  # path. PrestaShop has none: with rewriting off, index.php only dispatches on
  # ?controller=, so any path-only request renders the catalog home with 200. PHP
  # 8.4/8.5 also forward extension-having misses (8.2/8.3 still 404 them), so
  # choosing another extension does not help; the fix is at the app. PrestaShop's
  # endpoints file overrides control_path with a ?controller= query its
  # dispatcher itself 404s on, which reaches index.php as a real file match
  # rather than a routing decision, on any PHP version.
  code="$(curl -sL -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}${control_path}")"
  [ "$code" != 200 ] || die "$app answered 200 for a path that does not exist -- the 200s above prove nothing"
  echo "  $app ${control_path} -> $code (negative control)"

  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  [ "$mysql_started" = yes ] && "${appdir}db-down.sh"

  printf '%s\t%s\t%s\t%s\n' "$app" "$docroot" "$version" "$served" >> "$MANIFEST"
  port=$((port + 1))
done

echo "=== MANIFEST"
cat "$MANIFEST"
