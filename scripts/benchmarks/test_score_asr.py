import json
import tempfile
import unittest
from pathlib import Path

from score_asr import edit_counts, load_rows, markdown, score, words


class ScorerTests(unittest.TestCase):
    def test_unicode_and_punctuation(self):
        self.assertEqual(words("  Grüß' Gott, caffè!  "), ["grüss", "gott", "caffè"])

    def test_edit_counts(self):
        self.assertEqual(edit_counts(words("uno due tre"), words("uno tre")), (0, 1, 0))
        self.assertEqual(edit_counts(words("uno due"), words("uno altro")), (1, 0, 0))
        self.assertEqual(edit_counts(words("uno"), words("uno due")), (0, 0, 1))

    def test_aggregate_wer_not_average_utterance_wer(self):
        rows = [
            self.row("a", "one", "uno due tre quattro", "uno due tre quattro"),
            self.row("a", "two", "ciao", ""),
        ]
        result = score(rows)["models"]["a"]
        self.assertEqual(result["reference_words"], 5)
        self.assertEqual(result["wer"], 0.2)

    def test_silence_is_separate_from_wer(self):
        rows = [self.row("a", "one", "", "invented words")]
        result = score(rows)["models"]["a"]
        self.assertIsNone(result["wer"])
        self.assertEqual(result["hallucinated_non_speech_clips"], 1)

    def test_reject_duplicate_clip_and_bad_measurement(self):
        row = self.row("a", "one", "ciao", "ciao")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            path.write_text(json.dumps(row) + "\n" + json.dumps(row), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate"):
                load_rows(path)
            row["inference_ms"] = float("nan")
            path.write_text(json.dumps(row), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "finite"):
                load_rows(path)

    def test_pairing_detects_missing_model_results(self):
        rows = [
            self.row("a", "one", "ciao", "ciao"),
            self.row("a", "two", "buongiorno", "buongiorno"),
            self.row("b", "one", "ciao", "ciao"),
        ]
        pairing = score(rows)["pairing"]
        self.assertFalse(pairing["complete"])
        self.assertEqual(pairing["common_clips"], 1)
        self.assertEqual(pairing["missing_by_model"]["b"], ["two"])

    def test_reject_conflicting_reference_for_same_clip(self):
        rows = [
            self.row("a", "one", "ciao", "ciao"),
            self.row("b", "one", "addio", "addio"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "conflicting"):
                load_rows(path)

    def test_cer_and_language_id(self):
        rows = [
            {**self.row("a", "one", "caffè", "caffe"), "detected_language": "it"},
            {**self.row("a", "two", "ciao", "ciao"), "detected_language": "es"},
        ]
        result = score(rows)["models"]["a"]
        self.assertEqual(result["wer"], 0.5)
        self.assertAlmostEqual(result["cer"], 1 / 9)
        self.assertEqual(result["language_id_accuracy"], 0.5)
        self.assertIn("| a | all | 50.0% | 11.1% | 50.0% |", markdown(score(rows)))

    @staticmethod
    def row(model, clip, reference, hypothesis):
        return {
            "model_id": model, "clip_id": clip, "language": "it", "scenario": "quiet",
            "reference": reference, "hypothesis": hypothesis,
        }


if __name__ == "__main__":
    unittest.main()
