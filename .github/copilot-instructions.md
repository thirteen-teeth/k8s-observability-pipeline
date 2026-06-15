# Copilot Instructions

## Never Commit Plaintext Secrets (Use SOPS + age)

This repository encrypts all Kubernetes `Secret` data at rest with **SOPS + age**, and Flux
decrypts it at apply time. Any `Secret` (or other object carrying credentials) committed
under `gitops/` **must** have its `data`/`stringData` SOPS-encrypted — never commit a
plaintext password, token, key, or certificate private key.

When adding or editing a secret:

- Write the `Secret` manifest, then encrypt in place with
  `sops --encrypt --in-place <file>` (the `.sops.yaml` creation rule encrypts only
  `data`/`stringData` for files matching `gitops/.*\.ya?ml$`). To edit an existing one, use
  `sops <file>` (with `SOPS_AGE_KEY_FILE=.sops/age.key` if the key isn't in the default path).
- Confirm the committed file shows `ENC[AES256_GCM,...]` values and a `sops:` block — verify
  with `sops --decrypt <file>` and by grepping the working tree for the plaintext value.
- Ensure the consuming Flux Kustomization has
  `decryption: { provider: sops, secretRef: { name: sops-age } }` (the `apps.yaml`
  Kustomizations already do).
- Model new secrets on the existing encrypted ones
  (`gitops/apps/base/clickhouse/secret.yaml`, `gitops/apps/base/opensearch/admin-secret.yaml`).

Never commit the age private key (`.sops/age.key`); it is gitignored. If a plaintext secret
is ever committed, treat the value as compromised — rotate it, since encrypting later does
not remove it from Git history.

## Deploying Is Commit + Push to `main` (GitOps)

This repo is deployed exclusively through **FluxCD GitOps** — there is no manual
`kubectl apply` deploy step. Flux is bootstrapped per environment against
`gitops/clusters/<env>` and **reconciles the `main` branch**. The local cluster
(`rancher-desktop`) tracks `gitops/clusters/local`.

**When asked to deploy, always commit the relevant changes and push to `main`** — do not ask
which deploy method to use, and do not hand-apply manifests to the cluster (that diverges
from Flux ownership and bypasses SOPS decryption). After pushing:

- Trigger/observe reconciliation without blocking waits:
  `flux reconcile kustomization apps --with-source` (or just let it poll), then
  `kubectl get kustomization -n flux-system` and the per-namespace
  `kubectl -n <ns> get pods,helmrelease` one-shot polls described below.
- Flux applies `infrastructure` first, then `apps` once it's healthy; new `Secret`s are
  SOPS-decrypted by Flux at apply time using the `sops-age` secret.
- Verify the deploy reached the cluster by checking the Kustomization `Applied revision:`
  matches the pushed commit SHA, then confirm the affected workloads are Ready.

Only deviate from commit-and-push (e.g. a throwaway local `flux build` / test-apply) if the
user explicitly asks for a non-`main` or no-git workflow.

## Watching Long-Running Operations (Don't Block on Waits)

When monitoring rollouts, reconciliations, or pods coming up, **don't use blocking
wait commands** like `kubectl wait --for=condition=Ready --timeout=...`, `kubectl
rollout status`, `flux ... --wait`, or `sleep`. They rarely finish within a single
step, get pushed into a background terminal, and then replay a large stale scrollback
buffer that's easy to misread as the current state.

Instead, poll with quick one-shot status commands that return immediately and re-run
them as needed — for example:

- `kubectl -n <ns> get pods` / `kubectl -n <ns> get sts` for rollout progress
- `kubectl -n <ns> get helmrelease,kustomization` for Flux status
- `kubectl -n <ns> logs <pod> --tail=N` for a bounded log snapshot

Each poll shows fresh output, keeps the terminal free, and avoids scrollback confusion.

## Keep Documentation in Sync with the Code

`ARCHITECTURE.md` is the authoritative running document describing this repository's
architecture, components, data flows, and configuration. Keep it accurate at all times.

**After every change to the repository, update the documentation to reflect it.** Treat a
change as anything that alters observable behavior, structure, or configuration — for
example:

- Adding, removing, or modifying infrastructure or application definitions
- Changing configuration values, versions, endpoints, or runtime/deploy settings
- Adding or removing components, data flows, or install/operate steps
- Changing how the project is built, deployed, or run

`ARCHITECTURE.md` is the priority, but the same expectation applies to `README.md` and any
other docs — a single change rarely touches only one file.

When updating docs, keep every representation of a fact consistent: prose, diagrams, and
tables (ports, namespaces, components, and similar) must all match the actual configuration,
and reference/example commands must stay runnable. Update only the sections a change
actually affects.

## Documentation Must Reflect Reality, Not History

All documentation must describe **what the repository actually does right now** — as defined
by the current source of truth (definitions, config/values files, and scripts) — not what it
used to do or what it was intended to do.

Treat the docs as a mirror of the live configuration:

- **Verify against the source of truth.** Before writing a documented fact (a version, tag,
  port, count, name, path, setting, or command), open the actual file and confirm it
  matches. Don't copy from an older version of the docs, memory, or assumptions.
- **Replace stale statements; don't accumulate them.** When a value or behavior changes,
  overwrite the old description instead of leaving it beside the new one, and don't describe
  removed things as if they still exist.
- **Remove documentation for anything deleted.** If something is removed from the repo,
  delete its documentation rather than leaving an orphaned reference.
- **Don't present aspirational or planned behavior as current.** Label anything that isn't
  actually wired up (WIP, experimental, alternative) explicitly, instead of describing it as
  active.
- **Keep exact values exact.** A documented version, tag, or literal must equal the value in
  the source — never an approximation or a stale range — unless the config itself is
  approximate.
- **When in doubt, re-read the file.** If you're unsure a detail is still accurate, check the
  underlying source before editing rather than guessing.

## Consider the Whole Document, Not Just One Spot

A single change rarely touches only one sentence. The same fact is usually restated in many
places — prose, bullet lists, diagrams, tables, install/usage steps, and cross-references,
across multiple documents. A change isn't done until **every** affected place is updated
consistently.

Trace each change through the entire surface before finishing:

- **Find every place the fact appears.** Search the docs for the old value, name, path, and
  any synonyms, and update all of them — not just the first hit. Assume a fact is duplicated
  until you've confirmed otherwise.
- **Follow the ripple effects of a structural change.** When behavior or topology changes,
  revisit the diagrams, tables, overviews, install steps, and component descriptions — not
  only the section that names the changed file — and reconcile each with the new reality.
- **Check prose, not just structured fields.** Stale claims hide in narrative sentences and
  section intros/overviews, not only in tables and code blocks. Re-read the surrounding text
  and fix anything the change invalidated.
- **Keep cross-references and links honest.** When content moves, is renamed, or is
  re-scoped, update every pointer to it (links, anchors, "see X", paths) so none dangle or
  mislead.
- **Reconcile related or overlapping descriptions together.** When two parts of the docs
  describe overlapping things, a change to one often implies a clarification in the other —
  confirm both still read correctly.
- **Do a final consistency pass.** After editing, re-read the affected document(s) and
  confirm nothing contradicts the change you just made.

## Version Numbers in Documentation

Keep version numbers where they earn their place, and give each one a single canonical home:

- **Keep load-bearing versions.** Document a version when it is part of a copy-paste command
  or when it explains a decision or constraint. Removing it would break a command or lose
  important context.
- **Give every version one canonical home.** Don't repeat the same version in multiple
  places; document it once and reference that location elsewhere rather than restating it.
- **Make intentional divergence explicit.** When two parts of the repo legitimately use
  different versions, label why, so the difference reads as deliberate rather than stale.
- **Avoid mirror-only tables.** Prefer pointing at the source of truth over duplicating
  values that must be hand-synced; only restate a value when it adds context the source
  alone does not convey.

## Source of Truth

Treat the repository's actual configuration as authoritative — the definitions, config/values
files, and scripts — and consult `ARCHITECTURE.md` for the current high-level overview. When
establishing any specific fact, read these rather than relying on prior context or memory.
