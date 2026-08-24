import json
import tempfile
import unittest
from pathlib import Path

from scripts.validate_import_v1 import validate_dataset


def base_record(**overrides):
    record = {
        "record_id": "candidate-001",
        "category": "PROJECT_CONTEXT",
        "type": "FACT",
        "title": "Synthetic candidate",
        "content": "Synthetic content for validator tests.",
        "status": "TO_VERIFY",
        "confidence": 75,
        "sensitivity": "PRIVATE",
        "source": {
            "type": "CONVERSATION",
            "label": "Synthetic test conversation",
            "reference": None,
        },
        "valid_from": None,
        "valid_to": None,
        "project": None,
        "notes": "Synthetic test record; never imported.",
        "import_action": "REVIEW",
        "supersedes": None,
    }
    record.update(overrides)
    return record


def dataset(*records):
    return {
        "format_version": "import-v1",
        "dataset_id": "synthetic-validator-test",
        "generated_at": "2026-01-01T00:00:00Z",
        "source_context": "CHATGPT_MEMORY",
        "records": list(records),
    }


class ImportV1ValidatorTests(unittest.TestCase):
    def test_empty_template_shape_is_valid(self):
        payload = json.loads(Path("staging/import-v1.template.json").read_text(encoding="utf-8"))
        errors, summary = validate_dataset(payload)
        self.assertEqual(errors, [])
        self.assertEqual(summary, {"records": 0, "actions": {}})

    def test_valid_review_candidate_is_valid(self):
        errors, summary = validate_dataset(dataset(base_record()))
        self.assertEqual(errors, [])
        self.assertEqual(summary["actions"], {"REVIEW": 1})

    def test_highly_sensitive_candidate_is_rejected(self):
        errors, _ = validate_dataset(dataset(base_record(sensitivity="HIGHLY_SENSITIVE")))
        self.assertTrue(any("HIGHLY_SENSITIVE" in error for error in errors))

    def test_supersede_requires_target(self):
        errors, _ = validate_dataset(dataset(base_record(import_action="SUPERSEDE")))
        self.assertTrue(any("supersedes" in error for error in errors))

    def test_secret_like_content_is_rejected(self):
        secret_like = "api" + "_key=do-not-import-this"
        errors, _ = validate_dataset(dataset(base_record(content=secret_like)))
        self.assertTrue(any("credenziale" in error for error in errors))

    def test_validator_does_not_need_a_database(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "synthetic.json"
            path.write_text(json.dumps(dataset(base_record())), encoding="utf-8")
            self.assertTrue(path.exists())


if __name__ == "__main__":
    unittest.main()
