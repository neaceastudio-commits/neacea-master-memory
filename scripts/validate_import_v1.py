#!/usr/bin/env python3
"""Validate a NEACEA MASTER MEMORY Import V1 staging file.

This validator intentionally uses only the Python standard library. It validates
the controlled envelope and applies safety rules that a generic JSON Schema
validator cannot express, including action dependencies and secret detection.
It never connects to Supabase and never writes data.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


FORMAT_VERSION = "import-v1"
SOURCE_CONTEXT = "CHATGPT_MEMORY"
ALLOWED_TYPES = {
    "FACT",
    "PREFERENCE",
    "DECISION",
    "EVENT",
    "PROJECT_STATE",
    "PROCEDURE",
    "GOAL",
    "NOTE",
}
ALLOWED_STATUSES = {"CURRENT", "ARCHIVED", "TO_VERIFY"}
ALLOWED_SENSITIVITIES = {"PUBLIC", "PRIVATE", "CONFIDENTIAL", "HIGHLY_SENSITIVE"}
ALLOWED_ACTIONS = {"IMPORT", "REVIEW", "SKIP", "SUPERSEDE"}
ALLOWED_SOURCE_TYPES = {
    "CONVERSATION",
    "DOCUMENT",
    "MANUAL_ENTRY",
    "SYSTEM_APPLICATION",
    "IMPORT",
}

SECRET_PATTERNS = (
    re.compile(
        r"(?i)\b(?:password|passwd|api[_ -]?key|secret(?:[_ -]?key)?|"
        r"access[_ -]?token|refresh[_ -]?token|private[_ -]?key)\s*[:=]"
    ),
    re.compile(r"(?i)\bbearer\s+[a-z0-9._~-]{12,}"),
    re.compile(r"\beyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\."),
    re.compile(r"\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b"),
    re.compile(r"\b\d{13,19}\b"),
)

REQUIRED_ROOT_KEYS = {
    "format_version",
    "dataset_id",
    "generated_at",
    "source_context",
    "records",
}
REQUIRED_RECORD_KEYS = {
    "record_id",
    "category",
    "type",
    "title",
    "content",
    "status",
    "confidence",
    "sensitivity",
    "source",
    "valid_from",
    "valid_to",
    "project",
    "notes",
    "import_action",
    "supersedes",
}
OPTIONAL_RECORD_KEYS = {"metadata"}
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{2,120}$")


def _is_string(value: Any) -> bool:
    return isinstance(value, str)


def _parse_temporal(value: Any, path: str, errors: list[str]) -> datetime | None:
    if value is None:
        return None
    if not _is_string(value):
        errors.append(f"{path}: deve essere una stringa ISO-8601 o null")
        return None
    try:
        if "T" in value:
            normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
            parsed = datetime.fromisoformat(normalized)
            if parsed.tzinfo is None:
                errors.append(f"{path}: datetime senza timezone")
                return None
            return parsed.astimezone(timezone.utc)
        return datetime.combine(date.fromisoformat(value), datetime.min.time(), tzinfo=timezone.utc)
    except ValueError:
        errors.append(f"{path}: valore temporale non valido")
        return None


def _scan_secrets(record: dict[str, Any], index: int, errors: list[str]) -> None:
    fields = [
        ("title", record.get("title")),
        ("content", record.get("content")),
        ("notes", record.get("notes")),
        ("project", record.get("project")),
    ]
    source = record.get("source")
    if isinstance(source, dict):
        fields.extend(
            [
                ("source.label", source.get("label")),
                ("source.reference", source.get("reference")),
            ]
        )
    for field, value in fields:
        if not isinstance(value, str):
            continue
        for pattern in SECRET_PATTERNS:
            if pattern.search(value):
                errors.append(
                    f"records[{index}].{field}: possibile credenziale, token, IBAN o numero carta; rimuovere il record"
                )
                break


def validate_dataset(payload: Any) -> tuple[list[str], dict[str, Any]]:
    errors: list[str] = []
    if not isinstance(payload, dict):
        return ["root: deve essere un oggetto JSON"], {}

    missing_root = REQUIRED_ROOT_KEYS - payload.keys()
    unknown_root = payload.keys() - REQUIRED_ROOT_KEYS
    for key in sorted(missing_root):
        errors.append(f"root: campo obbligatorio mancante: {key}")
    for key in sorted(unknown_root):
        errors.append(f"root: campo non supportato: {key}")

    if payload.get("format_version") != FORMAT_VERSION:
        errors.append(f"format_version: atteso {FORMAT_VERSION!r}")
    if not isinstance(payload.get("dataset_id"), str) or not ID_PATTERN.fullmatch(payload.get("dataset_id", "")):
        errors.append("dataset_id: usare solo minuscole, numeri, punto, underscore o trattino")
    _parse_temporal(payload.get("generated_at"), "generated_at", errors)
    if payload.get("source_context") != SOURCE_CONTEXT:
        errors.append(f"source_context: atteso {SOURCE_CONTEXT!r}")

    records = payload.get("records")
    if not isinstance(records, list):
        errors.append("records: deve essere un array")
        return errors, {"records": 0, "actions": {}}

    record_ids: set[str] = set()
    actions: Counter[str] = Counter()
    for index, record in enumerate(records):
        path = f"records[{index}]"
        if not isinstance(record, dict):
            errors.append(f"{path}: deve essere un oggetto")
            continue
        missing = REQUIRED_RECORD_KEYS - record.keys()
        unknown = record.keys() - REQUIRED_RECORD_KEYS - OPTIONAL_RECORD_KEYS
        for key in sorted(missing):
            errors.append(f"{path}: campo obbligatorio mancante: {key}")
        for key in sorted(unknown):
            errors.append(f"{path}: campo non supportato: {key}")

        record_id = record.get("record_id")
        if not isinstance(record_id, str) or not ID_PATTERN.fullmatch(record_id):
            errors.append(f"{path}.record_id: identificatore non valido")
        elif record_id in record_ids:
            errors.append(f"{path}.record_id: duplicato {record_id!r}")
        else:
            record_ids.add(record_id)

        for field, maximum in (("category", 200), ("title", 500), ("content", 100000), ("notes", 10000)):
            value = record.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{path}.{field}: deve essere una stringa non vuota")
            elif len(value) > maximum:
                errors.append(f"{path}.{field}: supera il limite di {maximum} caratteri")

        if record.get("type") not in ALLOWED_TYPES:
            errors.append(f"{path}.type: valore non supportato")
        if record.get("status") not in ALLOWED_STATUSES:
            errors.append(f"{path}.status: SUPERSEDED non si importa; usare import_action=SUPERSEDE")
        confidence = record.get("confidence")
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or not 0 <= confidence <= 100:
            errors.append(f"{path}.confidence: numero da 0 a 100")
        sensitivity = record.get("sensitivity")
        if sensitivity not in ALLOWED_SENSITIVITIES:
            errors.append(f"{path}.sensitivity: valore non supportato")
        elif sensitivity == "HIGHLY_SENSITIVE":
            errors.append(f"{path}.sensitivity: HIGHLY_SENSITIVE non è ammesso nello staging Import V1")

        source = record.get("source")
        if not isinstance(source, dict):
            errors.append(f"{path}.source: deve essere un oggetto")
        else:
            if set(source) != {"type", "label", "reference"}:
                errors.append(f"{path}.source: chiavi richieste type, label, reference")
            if source.get("type") not in ALLOWED_SOURCE_TYPES:
                errors.append(f"{path}.source.type: valore non supportato")
            if not isinstance(source.get("label"), str) or not source.get("label", "").strip():
                errors.append(f"{path}.source.label: deve essere non vuoto")
            if source.get("reference") is not None and not isinstance(source.get("reference"), str):
                errors.append(f"{path}.source.reference: deve essere stringa o null")

        valid_from = _parse_temporal(record.get("valid_from"), f"{path}.valid_from", errors)
        valid_to = _parse_temporal(record.get("valid_to"), f"{path}.valid_to", errors)
        if valid_from and valid_to and valid_to < valid_from:
            errors.append(f"{path}: valid_to precede valid_from")
        if record.get("project") is not None and not isinstance(record.get("project"), str):
            errors.append(f"{path}.project: deve essere stringa o null")

        action = record.get("import_action")
        if action not in ALLOWED_ACTIONS:
            errors.append(f"{path}.import_action: valore non supportato")
        else:
            actions[action] += 1
            supersedes = record.get("supersedes")
            if action == "SUPERSEDE" and (not isinstance(supersedes, str) or not supersedes.strip()):
                errors.append(f"{path}.supersedes: obbligatorio quando import_action=SUPERSEDE")
            if action != "SUPERSEDE" and supersedes is not None:
                errors.append(f"{path}.supersedes: deve essere null salvo import_action=SUPERSEDE")

        _scan_secrets(record, index, errors)

    return errors, {"records": len(records), "actions": dict(sorted(actions.items()))}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Valida un dataset staging Import V1 senza collegarsi a Supabase")
    parser.add_argument("path", type=Path, help="percorso del file JSON Import V1")
    args = parser.parse_args(argv)

    try:
        payload = json.loads(args.path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(json.dumps({"valid": False, "errors": [f"file non trovato: {args.path}"]}, ensure_ascii=False))
        return 2
    except json.JSONDecodeError as exc:
        print(json.dumps({"valid": False, "errors": [f"JSON non valido: riga {exc.lineno}, colonna {exc.colno}"]}, ensure_ascii=False))
        return 2

    errors, summary = validate_dataset(payload)
    result = {"valid": not errors, **summary}
    if errors:
        result["errors"] = errors
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
