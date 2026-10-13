Overlay copied on top of `corpus/symfony/app` for the 7.0 tier, which runs
Symfony 3.4 — the last branch whose PHP floor (7.0.8) is below PHP 7.0.33.

Only the four files that cannot be shared are here. `symfony/runtime` and
`MicroKernelTrait`'s default config-directory loading arrived in 5.3 and 5.1,
and routing's `controller:` shorthand in 4.1, so 3.4 needs its own front
controller, console, kernel and routes file. Everything else — the controller,
the PDO service, the templates, the seeder, the package config and `.env` — is
shared with every other tier, so a change to the workload lands on all of them
at once.
