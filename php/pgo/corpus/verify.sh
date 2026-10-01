#!/usr/bin/env bash
# Prove every corpus app actually serves, then write what was proven into
# /corpus/MANIFEST.
#
#   verify.sh <corpus-root> <src-root> <manifest>
#
# Why the build serves the apps rather than trusting `composer install`: a
# Laravel or Symfony app that installs cleanly and then 500s on every request
# trains the profile on the exception path and nothing else. (Not theoretical:
# the Symfony demo application installs green and then 500s on `/` because its
# asset pipeline was never built -- that is why this corpus does not use it.)
#
# Status alone is not enough either. A 200 with an empty body, or a 200
# carrying a framework error page, is indistinguishable from a rendered page by
# HTTP code. Every declared path therefore has to answer 200, exceed a byte
# floor, and contain a substring only a correctly rendered page has -- all
# three from the app's committed endpoints file.
#
# MANIFEST records only paths that passed, so task 17's training script can
# derive its request list instead of hardcoding one.
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

# The one app whose database is not a bundled sqlite file: PrestaShop's
# ObjectModel/Db layer speaks MySQL/MariaDB only. Its endpoints file marks
# this with "database mysql:<host>:<port>:<dbname> <sql>" instead of a file
# path; every other app's "database <file> <sql>" is unchanged. db-up.sh/
# db-down.sh live next to that app's endpoints file
# (php/pgo/corpus/prestashop/) and are copied into the corpus source tree
# like everything else under corpus/.
mysql_row_count() {  # mysql_row_count <host> <port> <dbname> <sql>
  php -r '
    $pdo = new PDO("mysql:host=".$argv[1].";port=".$argv[2].";dbname=".$argv[3], null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    echo (int) $pdo->query($argv[4])->fetchColumn();
  ' "$1" "$2" "$3" "$4"
}

for appdir in "$SRC"/*/; do
  app="$(basename "$appdir")"
  spec="${appdir}endpoints"
  [ -f "$spec" ] || { echo "FATAL: $app has no endpoints file" >&2; exit 1; }

  docroot_rel=""; version_kind=""; version_arg=""; db_file=""; db_sql=""
  # Default shared by three of the four apps -- see the override below and its
  # comment for why PrestaShop needs its own.
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
      # Point the app at the host:port it is about to be served on, if it has
      # a hook for that (task 29e; see corpus/prestashop/set-host.sh). Not a
      # fixed-port special case: any app with a mysql: database and its own
      # set-host.sh gets this, keyed off the same $port every other app here
      # already serves on.
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
  # A request that never ends must fail, not spin: max_execution_time turns it
  # into a 500, and ulimit -f (100 MB) kills a server whose log runs away. A
  # PHP 7.2 optimizer miscompile once looped here writing notices for hours and
  # filled the build host's disk.
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

  # -L: PrestaShop 302s a query-string request to its own canonical parameter
  # order (?controller=x&id_y=n -> ?id_y=n&controller=x) even with
  # PS_REWRITING_SETTINGS off. Harmless for the other three apps -- none of
  # their required paths redirect -- so this follows redirects everywhere
  # rather than special-casing one app's curl calls.
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

  # The positive control for everything above: without it, "every required path
  # answered 200 with the right content" is equally true of a server that
  # answers 200 to literally everything, which is what a misconfigured front
  # controller does. Any non-200 passes -- WordPress answers 301 here rather
  # than 404, because an unknown path hits its canonical redirect first.
  #
  # An extension-less path with no matching file: PHP's built-in server
  # forwards it to index.php on every version this corpus trains (7.x-8.5,
  # measured directly, task 29e) -- Laravel/Symfony/WordPress each have a real
  # router behind that index.php, and each one's router rejects a path it
  # never defined, so the forward is invisible here on any of them. PrestaShop
  # is the one app with no such router: with rewriting off, index.php only
  # ever dispatches on ?controller=, so any path-only request that reaches it
  # -- forwarded or not, any PHP version -- renders the catalog home, 200.
  # PHP 8.4/8.5 additionally forward an extension-having miss too (measured:
  # 8.2/8.3 still 404 those at the server level, 8.4/8.5 forward everything),
  # which breaks a `.html`-style control for WordPress the same way, so
  # picking a "safer" extension buys nothing here -- the fix has to be at the
  # app, not the path shape. PrestaShop's own endpoints file overrides
  # control_path with a ?controller= query its dispatcher itself 404s on
  # (confirmed by hand), which reaches index.php as a real file match rather
  # than a routing decision, so it needs no PHP-version escape hatch either.
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
