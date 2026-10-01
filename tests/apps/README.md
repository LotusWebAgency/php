# Application tests

Real applications, populated with data, run against every image in the
matrix: **Laravel**, **WordPress** (with WooCommerce where it runs) and
**PrestaShop**. The point is what `tests/smoke.sh` can't show: a PHP compiled
from source with PGO, LTO and a hardened toolchain still runs the software
people deploy on it, on the data they already have.

```sh
./tests/apps/build-fixture.sh --all                    # once; images are reused afterwards
./tests/apps/run.sh lotuswebagency/php:8.4-fpm         # one image, every app
./tests/apps/run.sh lotuswebagency/php:8.4-cli --app laravel
./tests/apps/run-matrix.sh --stock                     # baseline on the stock image line
./tests/apps/run-matrix.sh --jobs 4                    # every built target
./tests/apps/run.sh lotuswebagency/php:8.5-fpm --app wordpress --keep   # leave it up to poke at
```

## How it fits together

| Piece | What it is |
|---|---|
| `sets` | Which application release each PHP version runs: the newest that supports it. Also names the PHP each fixture is built on (the set's `php-min`). |
| `apps.lock` | Every fetched source, pinned by version and sha256 (images by digest), except the PrestaShop translation packs, which fetch the latest export and are checked for shape. |
| `build-fixture.sh` | Builds `lotuswebagency/php-apptest:<app>-<set>`: MariaDB with the populated datadir, plus the installed app tree at `/srv/app`. |
| `compose.yml` | One test stack: the fixture as the database, a fresh copy of its `/srv/app` in a named volume, Redis, Memcached, nginx, and the image under test as `php` (fpm) or `cli`. |
| `run.sh` | Runs one image's suites; `run-matrix.sh` fans that out across the matrix. |
| `<app>/fixture/` | The recipe: `build.sh` (runs in the builder container), overlays, seeders, composer locks, optional `host-prep.sh`. |
| `<app>/suite/` | `web.py` (HTTP, fpm images), `cli.sh` (cli images), `builder.sh` (cli-builder images, then `cli.sh`). |
| `<app>/nginx.conf` | The vhost in front of `php:9000`. |
| `<app>/php.env`, `php-hardened.env`, `php-stock.env` | Extra environment for the `php`/`cli` container: ours in every config, ours in the `hardened` config, and the stock baseline. All optional. |

**Fixtures are built on the stock image, tested on ours.** Each set is
installed, composer-resolved and populated on the stock image for its
`php-min` (`APPTEST_BUILDER_REPO`, default `dementev/php-fpm-with-ext`), through
the application's own APIs. The from-source images then have to read what a
known-good PHP wrote: sessions, password hashes, serialized options, cache
entries. Values the fixture build computed are recorded in
`/srv/app/.apptest/manifest.json` and the suites compare against them.

**Every run starts from the pristine fixture and throws it away.** The
database is the fixture container's own layer, and the app tree is a fresh
volume, so runs never see each other's writes. That makes the fixture
reusable across images, hosts and CI alike: push it to a registry and set
`APPTEST_FIXTURE_REPO`. Its `com.lotuswebagency.apptest-hash` label is the
content hash of the recipe (`apptest_recipe_hash`), and `run.sh` rebuilds, or
with `--no-build` refuses, a fixture that doesn't match the tree. Suites are
not part of that hash, so editing a test never forces a data rebuild.

**Configs.** fpm images run the HTTP suite once per config: `default`, then
`hardened` (ours, PHP ≥ 7.2: `PHP_SNUFFLEUPAGUS=<app>` plus
`<app>/php-hardened.env`), with php-fpm recreated in between. After each step
the php container's log is scanned: a signal death, heap corruption or PHP
fatal fails the step even when every response looked fine. The one fatal
that is expected is Snuffleupagus refusing the suite's own `suite-<run>.php`
upload under `hardened`.

**Trying ruleset changes.** `APPTEST_SP_RULES=conf/snuffleupagus` mounts that
directory over the image's baked `/usr/local/etc/php/snuffleupagus`, so a rule
change can go across the whole matrix before a rebuild. Every RESULT line then
carries `[rules overridden from …]`: it is a verdict on the rules, not on the
image as built. `tests/test-snuffleupagus.sh` takes `SP_RULES_OVERRIDE` for
the same thing.

**WordPress and its object cache.** Each set is the newest WordPress line
whose `$required_php_version` fits the set's php-min, with the newest
WooCommerce whose plugin *header* (not readme) declares a PHP requirement the
set can meet, and Redis Object Cache with its `object-cache.php` drop-in
(phpredis at host `redis`, igbinary). The drop-in is switched on last in the
fixture build, so the data is written without it and every stack starts from
a cold cache; the suites check that it connects, that a later request finds
what an earlier one cached, that igbinary is what is stored, and that edits
invalidate. WooCommerce differs by era (shortcode vs block Cart and Checkout,
posts vs HPOS orders); the suites branch on what the fixture manifest records.
The composer lock of the builder suite is per set (`wordpress/suite/builder/<set>/`),
resolved on the stock image of the set's php-min.

**Host header.** Every app is installed as `http://apptest.test`. The suites
connect to nginx's published port on 127.0.0.1 and send that Host, mapping
redirects back onto the port, so no URL is rewritten per run. To browse a
`--keep` stack, point `apptest.test` at 127.0.0.1 and use the printed port.

## Writing a suite

`apptest.py` (HTTP) and `cli-lib.sh` (bash) share one output format:
`ok: <name>`, `FAIL: <name> -- <why>`, `SKIP: <name> -- <why>`, then one
summary line. `Suite.page()` is the default page assertion: status, size,
required substrings, and no PHP/framework error marker in the body.

Checks run through the application, not around it: pages, forms with their
CSRF tokens, logins, carts and checkouts, REST APIs, uploads through the
media pipeline, the app's own console commands. They're additive (unique
names, never deleting seeded rows), because one stack serves both configs.
