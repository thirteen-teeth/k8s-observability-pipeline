#!/usr/bin/env python3
"""Repository-invariant policy checks for the GitOps manifests under gitops/.

These encode the non-negotiable rules from .github/copilot-instructions.md so a
violation fails CI before it can be merged or reconciled by Flux:

  1. No plaintext secrets   — every `kind: Secret` under gitops/ must have its
     data/stringData SOPS-encrypted (ENC[...] values + a top-level `sops:` block).
  2. No floating image tags — container `image:` refs must be pinned to a concrete
     tag or digest (never `:latest` or untagged).
  3. Pinned Helm charts     — every HelmRelease `spec.chart.spec.version` must be a
     concrete version, not a range (`*`, `^`, `~`, `>=`, `x`, ...).

Run locally:  python3 tests/policy/check_manifests.py
Exits non-zero (and prints every violation) if any rule is broken.
"""
from __future__ import annotations

import glob
import os
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GITOPS_GLOB = os.path.join(REPO_ROOT, "gitops", "**", "*.y*ml")

# Range/wildcard characters that indicate a non-pinned Helm chart version.
RANGE_CHARS = ("*", "^", "~", ">", "<", " - ", "||")


def rel(path: str) -> str:
    return os.path.relpath(path, REPO_ROOT)


def iter_docs(path: str):
    """Yield each YAML document in a (possibly multi-doc) file."""
    with open(path, "r", encoding="utf-8") as fh:
        try:
            for doc in yaml.safe_load_all(fh):
                if isinstance(doc, dict):
                    yield doc
        except yaml.YAMLError as exc:
            # Surface parse errors as a violation rather than crashing.
            yield {"__parse_error__": str(exc)}


def check_secret(doc: dict, path: str, violations: list[str]) -> None:
    if doc.get("kind") != "Secret":
        return
    has_sops = "sops" in doc
    payload = {}
    payload.update(doc.get("data") or {})
    payload.update(doc.get("stringData") or {})
    if not payload:
        return  # nothing sensitive to protect
    plaintext_keys = [
        k for k, v in payload.items()
        if not (isinstance(v, str) and v.startswith("ENC["))
    ]
    if plaintext_keys or not has_sops:
        name = (doc.get("metadata") or {}).get("name", "<unnamed>")
        detail = []
        if plaintext_keys:
            detail.append(f"plaintext keys: {', '.join(sorted(plaintext_keys))}")
        if not has_sops:
            detail.append("missing `sops:` block")
        violations.append(
            f"[secret] {rel(path)}: Secret/{name} not SOPS-encrypted ({'; '.join(detail)})"
        )


def _image_tag_ok(image: str) -> bool:
    if "@sha256:" in image:  # digest-pinned
        return True
    last = image.rsplit("/", 1)[-1]  # strip registry/repo so host:port isn't seen as a tag
    if ":" not in last:
        return False  # untagged -> implicitly :latest
    return last.rsplit(":", 1)[-1] != "latest"


def check_images(node, path: str, violations: list[str]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "image" and isinstance(value, str) and value:
                # Skip tokens left for Flux substitution.
                if "${" not in value and not _image_tag_ok(value):
                    violations.append(
                        f"[image] {rel(path)}: floating/untagged image `{value}`"
                    )
            else:
                check_images(value, path, violations)
    elif isinstance(node, list):
        for item in node:
            check_images(item, path, violations)


def check_helm_version(doc: dict, path: str, violations: list[str]) -> None:
    if doc.get("kind") != "HelmRelease":
        return
    version = (
        ((doc.get("spec") or {}).get("chart") or {}).get("spec") or {}
    ).get("version")
    name = (doc.get("metadata") or {}).get("name", "<unnamed>")
    if version is None:
        violations.append(f"[helm] {rel(path)}: HelmRelease/{name} has no pinned chart version")
        return
    version = str(version)
    if any(tok in version for tok in RANGE_CHARS):
        violations.append(
            f"[helm] {rel(path)}: HelmRelease/{name} chart version `{version}` is a range, not pinned"
        )


def main() -> int:
    files = sorted(glob.glob(GITOPS_GLOB, recursive=True))
    if not files:
        print("No gitops manifests found — nothing to check.")
        return 0

    violations: list[str] = []
    for path in files:
        for doc in iter_docs(path):
            if "__parse_error__" in doc:
                violations.append(f"[yaml] {rel(path)}: parse error: {doc['__parse_error__']}")
                continue
            check_secret(doc, path, violations)
            check_helm_version(doc, path, violations)
            check_images(doc, path, violations)

    if violations:
        print(f"Policy check FAILED — {len(violations)} violation(s):\n")
        for v in violations:
            print(f"  - {v}")
        return 1

    print(f"Policy check passed: scanned {len(files)} manifest file(s), no violations.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
