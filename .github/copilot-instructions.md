# Copilot Instructions

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
