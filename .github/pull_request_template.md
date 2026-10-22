## What and why

<!-- One change per pull request. Link the issue it closes, if any. -->

## How it was tested

<!-- Which `scripts/test.sh` runs (each target on its own), and anything you checked by hand. -->

## Checklist

- [ ] Every commit is signed off (`git commit -s`, Developer Certificate of Origin; there is no CLA).
- [ ] `scripts/test.sh` passes, with no new compiler warnings; new behaviour has tests (Swift Testing).
- [ ] `scripts/scrub-check.sh --generic-only` prints `scrub: clean`.
- [ ] Tests and docs use invented data only: no real session text, names, hosts, paths, addresses or secrets.
- [ ] New log lines hold labels and numbers only (no session text, commands, paths, hosts or titles); no `print`.
- [ ] If this touches the protected core (CONTRIBUTING.md): the description says what changes for the threat model,
      and `docs/THREAT_MODEL.md` is updated.
- [ ] New or changed settings keys are documented in `docs/SETTINGS.md`.
