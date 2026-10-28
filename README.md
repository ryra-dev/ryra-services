# Moved to Ryra templates

Services, external accounts, adapters and machine templates now live together in
[ryra-dev/ryra-templates](https://github.com/ryra-dev/ryra-templates).

Fork that repository and register it once with `ryra catalog --org ORG --add-source`.
It publishes both service and machine entries in `catalog.json` and keeps their
NixOS modules under one repository pin.

This repository is retained as an archive for history and existing pins.
