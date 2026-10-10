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
./tests/apps/run-matrix.sh --list --only 8.4           # the planned cells, nothing touched
./tests/apps/run.sh lotuswebagency/php:8.5-fpm --app wordpress --keep   # leave it up to poke at
```

## How it fits together

| Piece | What it is |
|---|---|
| `sets` | The cells: one row per application release (a fixture set) with the explicit list of PHP versions it runs on, which flavors and variants run it, and its database. Rows may overlap and leave gaps. See [The cells](#the-cells). |
| `appsets.py` | Reads `sets` and answers every question about it (`check`, `cells`, `sets`, `rows`, `field`); lib.sh, run.sh, run-matrix.sh, `tests/extended.sh` and `ci/extended-*.sh` all ask it, so the flavor rules live in `sets` and this one file. |
| `apps.lock` | Every fetched source, pinned by version and sha256 (images by digest), except the PrestaShop translation packs, which fetch the latest export and are checked for shape. |
| `build-fixture.sh` | Builds `lotuswebagency/php-apptest:<app>-<set>`: MariaDB with the populated datadir, plus the installed app tree at `/srv/app`. |
| `compose.yml` | One test stack: the fixture as the database, a fresh copy of its `/srv/app` in a named volume, Redis, Memcached, nginx, and the image under test as `php` (fpm) or `cli`. |
| `run.sh` | Runs one image's suites, for every cell of `sets` that image's PHP version, flavor and variant has; `run-matrix.sh` fans that out across the matrix. |
| `<app>/fixture/` | The recipe: `build.sh` (runs in the builder container), overlays, seeders, composer locks, optional `host-prep.sh`. |
| `<app>/suite/` | `web.py` (HTTP, fpm images), `cli.sh` (cli images), `builder.sh` (cli-builder images, then `cli.sh`). |
| `<app>/nginx.conf` | The vhost in front of `php:9000`. |
| `<app>/php.env`, `php-hardened.env`, `php-stock.env` | Extra environment for the `php`/`cli` container: ours in every config, ours in the `hardened` config, and the stock baseline. All optional. |

## The cells

```
# app        set    php        flags                 db
laravel      13     8.3-8.5    builder,v3,hardened   mariadb
wordpress    6.9    7.2,8.5    hardened              mariadb
prestashop   8.2    7.2,8.1-8.4    builder,hardened      mariadb
```

A **cell** is one application release on one image: (app, set, PHP version,
flavor, variant). The `php` column is an explicit comma list of `matrix.json`
versions (`7.2,8.1-8.4`; `a-b` is shorthand for every matrix version from `a` to
`b`). Nothing resolves a PHP version to "the" release for it: two sets of one
app can run on the same PHP, and a PHP version no row lists has no cell for that
app. Which images run a row follows from its flags:

| | |
|---|---|
| default | fpm and cli images. |
| `builder` | also the cli-builder images (composer against the real lock, then the cli suite). |
| `v3` | also the `-v3` images, in the cells whose PHP has one (`matrix.json` `uarch`: 8.4 and 8.5). Meant for the latest release of an app. A row with the flag and no such PHP is an error. |
| `hardened` | fpm also runs the `hardened` config (Snuffleupagus), in the cells whose PHP ships it (`php/ext.json`: 7.2 and later). The stock baseline never runs it. |

ext-builder images run no application suites (`tests/test-ext-builder.sh` is
theirs). An image with no cell, say 7.0-cli-builder, is one `SKIP` result:
nothing is pulled or run for it, and it is not a failure. `db` is the database
the fixture is installed on; only `mariadb` is supported, and a set's fixture is
one database, so it is a column of the row.

`appsets.py check` (also run first by `run-matrix.sh`) validates the syntax, that
every PHP version is in `matrix.json`, that every row has a fixture recipe
(`<app>/fixture/build.sh`), suites and `apps.lock` rows, that flags and database
are known, and that no `(app, set)` row and no PHP version within a row appears
twice. It has no coverage rule: a gap is a decision, not an error. To see what a
run will do without touching Docker: `./tests/apps/run-matrix.sh --list [--only
8.4] [--app wordpress]`.

The fixture's recipe hash carries only its row's lowest PHP, the one it is
built on. Adding or dropping a PHP the row is tested on rebuilds nothing;
moving the lowest one does.

Results are one `RESULT` line per (app, set, image, config or step), so several
sets of one app on one PHP never collide: each has its own fixture, run
directory (`<app>-<set>`) and compose project. `tests/extended.sh apps` compares
the rows against exactly the cells planned for each image.

**Fixtures are built on the stock image, tested on ours.** Each set is
installed, composer-resolved and populated on the stock image for the lowest
PHP version of its row (`APPTEST_BUILDER_REPO`, default `dementev/php-fpm-with-ext`), through
the application's own APIs. The from-source images then have to read what a
known-good PHP wrote: sessions, password hashes, serialized options, cache
entries. Values the fixture build computed are recorded in
`/srv/app/.apptest/manifest.json` and the suites compare against them.

**Every run starts from the pristine fixture and throws it away.** The
database is the fixture container's own layer, and the app tree is a fresh
volume, so runs never see each other's writes. That makes the fixture
reusable across images, hosts and CI alike ([from a
registry](#fixtures-from-a-registry), if you like). Its `com.lotuswebagency.apptest-hash` label is the
content hash of the recipe (`apptest_recipe_hash`), and `run.sh` rebuilds, or
with `--no-build` refuses, a fixture that doesn't match the tree. Suites are
not part of that hash, so editing a test never forces a data rebuild.

**Configs.** fpm images run the HTTP suite once per config of the cell:
`default`, then `hardened` where the row has the flag (ours, PHP ≥ 7.2:
`PHP_SNUFFLEUPAGUS=<app>` plus `<app>/php-hardened.env`), with php-fpm
recreated in between. `--config` narrows that list, it cannot add to it. After each step
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

**WordPress, its plugins and its object cache.** Four releases, each on the
PHP versions `sets` lists: 4.9.33, 5.9.18, 6.9.9 and 7.1.2. Every one is
installed with WooCommerce, Akismet, Contact Form 7, Yoast SEO, Classic Editor,
Wordfence, WPForms Lite and All-in-One WP Migration, plus Redis Object Cache with
its `object-cache.php` drop-in (phpredis at host `redis`, igbinary). Each plugin
is pinned per release in `apps.lock` to the newest version whose WordPress and
PHP minimums (readme *and* plugin header: WordPress enforces the header, and
they disagree on some WooCommerce releases) fit that release and the PHP the
fixture is built on, so the old sets run old plugins. A plugin that has no
such release for a set is left out of it, with the reason in `apps.lock`; the
manifest records what was installed and the suites check exactly that list
(activation, version, the plugin's own version constant in WP-CLI, one admin
screen, and a front-end page where the plugin has one: Yoast's head, Contact
Form 7's form). Two plugins are configured so they do not change what the suites
assert about core: Classic Editor leaves the block editor the default, and
Yoast's XML sitemaps are off so core's `wp-sitemap.xml` stays. The drop-in
is switched on last in the fixture build, so the data is written without it and
every stack starts from a cold cache; the suites check that it connects, that a
later request finds what an earlier one cached, that igbinary is what is stored,
and that edits invalidate. WooCommerce differs by era (shortcode vs block Cart
and Checkout, posts vs HPOS orders, no Store API before 6.0); the suites branch
on what the fixture manifest records, and on WordPress's own version for what
core gained when (block themes and templates 5.9, application passwords 5.6,
core sitemaps 5.5, the block editor 5.0): every gate is a version threshold
named after the release that added the feature, so the newer sets keep
asserting all of it. The composer lock of the builder suite is per set
(`wordpress/suite/builder/<set>/`), resolved on the stock image of the set's
php-min.

**Host header.** Every app is installed as `http://apptest.test`. The suites
connect to nginx's published port on 127.0.0.1 and send that Host, mapping
redirects back onto the port, so no URL is rewritten per run. To browse a
`--keep` stack, point `apptest.test` at 127.0.0.1 and use the printed port.

## Fixtures from a registry

Building every fixture takes a while and the result is the same on
every host of one architecture, so they can be shared. Set
`APPTEST_FIXTURE_REPO` to a registry repository, for example
`ghcr.io/lotuswebagency/php/apptest`, and the harness treats it as one (Docker's
own rule: the first path component has a dot or a colon, or is `localhost`).
Left unset, or a bare name like the default `lotuswebagency/php-apptest`,
fixtures stay local: tags `<app>-<set>`, never pulled, never pushed.

```sh
APPTEST_FIXTURE_REPO=ghcr.io/lotuswebagency/php/apptest ./tests/apps/build-fixture.sh --all --push
APPTEST_FIXTURE_REPO=ghcr.io/lotuswebagency/php/apptest ./tests/apps/run.sh lotuswebagency/php:8.4-fpm
```

- **Package link.** Fixtures carry `org.opencontainers.image.source` pointing at
  `https://github.com/LotusWebAgency/php`, so the first push links the GHCR
  package to the repository and the Actions `GITHUB_TOKEN` can push and pull
  it. A package of that name created before the label was set must be
  given repository access by hand (package settings, "Manage Actions access").
- **Tags carry the architecture**: `<app>-<set>-<arch>` (`laravel-12-amd64`).
  A fixture is MariaDB plus its datadir, so one architecture's image is no use
  on the other; a local daemon only ever holds its own, which is why local
  names have no suffix.
- **Pull before build.** `build-fixture.sh`, and `run.sh` before it refuses or
  rebuilds, pull a fixture that is not current locally and use it only if its
  `com.lotuswebagency.apptest-hash` label equals `apptest_recipe_hash` for
  this tree and it is the daemon's architecture. The pull runs under
  `ci/retry.sh`. A missing or stale one is reported (`note: ...`) and built
  instead; so is one that stays unpullable for another reason, except under CI
  (`CI=true`) or `APPTEST_NO_BUILD=1`, where that fails instead of turning an
  outage into a rebuild. `--force` skips the pull; `run.sh --no-build` still
  refuses what the pull did not make current.
- **`build-fixture.sh --push`** pushes every fixture it ends with, built here,
  pulled or already current, and refuses when the repository is a local name
  rather than a registry (a push to `lotuswebagency/php-apptest` would go to
  Docker Hub). Run it once per architecture to publish both.
- The recipe hash covers `build-fixture.sh`, `fetch.sh`, `install-composer.sh`,
  `bake-composer-cache.sh`, `<app>/fixture/` and WordPress's
  `suite/builder/<set>/` (its composer lock is baked, below), so an edit to the
  shared scripts makes every published fixture stale and one under
  `<app>/fixture/` that app's. `lib.sh`, `run.sh`, the other suite files, the
  nginx configs and `ci/retry.sh` are outside it.
- **Baked composer inputs.** A fixture carries what the builder suites would
  otherwise download: the pinned `composer` and `composer-lts` phars in
  `/srv/app/.apptest/bin` (`install-composer.sh` copies from there and downloads
  only when they are absent), and a composer cache in
  `/srv/app/.apptest/composer-cache` filled from the lock each suite installs
  (Laravel's dev and `--no-dev` installs, WordPress's `suite/builder/<set>` lock,
  PrestaShop's release lock with `--no-dev`; PrestaShop 1.6 has none). The build
  repeats those installs with `COMPOSER_DISABLE_NETWORK=1`
  (`bake-composer-cache.sh`), so a cache that is not enough fails the build.
- Every download in a fixture build goes through `ci/retry.sh`, which
  `build-fixture.sh` mounts into the builder container as `/usr/local/bin/retry`.

PrestaShop 1.6 to 8.2 are the official GitHub release zips, pinned by sha256
(`prestashop-zip` rows; the release asset is a zip in a zip, which
`prestashop/fixture/unpack.php` opens, restoring the unix modes). 9.2.0 has no
zip anywhere, so its tree is unpacked out of the vendor's Docker image, pinned
by digest: that pin is a multi-arch index, so `host-prep.sh` asks for
`linux/amd64` explicitly (nothing in it executes the image, it is only
`docker cp`'d from, which works on an arm64 daemon too).

## Writing a suite

`apptest.py` (HTTP) and `cli-lib.sh` (bash) share one output format:
`ok: <name>`, `FAIL: <name> -- <why>`, `SKIP: <name> -- <why>`, then one
summary line. `Suite.page()` is the default page assertion: status, size,
required substrings, and no PHP/framework error marker in the body.

Checks run through the application, not around it: pages, forms with their
CSRF tokens, logins, carts and checkouts, REST APIs, uploads through the
media pipeline, the app's own console commands. They're additive (unique
names, never deleting seeded rows), because one stack serves both configs.
