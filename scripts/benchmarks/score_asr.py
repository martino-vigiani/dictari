#!/usr/bin/env python3
"""Score paired, already-transcribed Dictari ASR clips without invoking a model.

Input is JSONL: one object per (model_id, clip_id). This tool never reads audio,
downloads weights, or sends transcripts to a service. See the model research report
for corpus and measurement protocol.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path


REQUIRED = ("model_id", "clip_id", "language", "scenario", "reference", "hypothesis")
OPTIONAL_TIMINGS = ("audio_duration_ms", "inference_ms", "stop_to_insert_ms", "peak_rss_mb")


def words(value: str) -> list[str]:
    """Casefold, retain letters/numbers/diacritics, split punctuation/space.

    This intentionally does not rewrite digits, abbreviations, compounds or
    apostrophes semantically. Corpus annotation must specify such conventions.
    """
    normalized = unicodedata.normalize("NFKC", value).casefold()
    token = []
    result = []
    for char in normalized:
        if unicodedata.category(char)[0] in ("L", "N", "M"):
            token.append(char)
        elif token:
            result.append("".join(token))
            token = []
    if token:
        result.append("".join(token))
    return result


def edit_counts(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int]:
    """Return substitutions, deletions, insertions with deterministic tie-breaks."""
    previous = [(0, 0, index) for index in range(len(hypothesis) + 1)]
    for ref_index, ref_word in enumerate(reference, 1):
        current = [(0, ref_index, 0)]
        for hyp_index, hyp_word in enumerate(hypothesis, 1):
            if ref_word == hyp_word:
                current.append(previous[hyp_index - 1])
                continue
            sub = previous[hyp_index - 1]
            delete = previous[hyp_index]
            insert = current[hyp_index - 1]
            candidates = (
                (sum(sub) + 1, 0, (sub[0] + 1, sub[1], sub[2])),
                (sum(delete) + 1, 1, (delete[0], delete[1] + 1, delete[2])),
                (sum(insert) + 1, 2, (insert[0], insert[1], insert[2] + 1)),
            )
            current.append(min(candidates)[2])
        previous = current
    return previous[-1]


def percentile(values: list[float], percentile_value: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percentile_value * len(ordered)) - 1)]


def load_rows(path: Path) -> list[dict]:
    rows = []
    seen = set()
    clip_metadata = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError as error:
            raise ValueError(f"line {number}: invalid JSON: {error}") from error
        if not isinstance(row, dict):
            raise ValueError(f"line {number}: expected a JSON object")
        for key in REQUIRED:
            if not isinstance(row.get(key), str):
                raise ValueError(f"line {number}: {key} must be a string")
        for key in REQUIRED[:4]:
            if not row[key].strip():
                raise ValueError(f"line {number}: {key} cannot be empty")
        if row["language"] not in ("it", "de", "en"):
            raise ValueError(f"line {number}: language must be it, de or en")
        key = (row["model_id"], row["clip_id"])
        if key in seen:
            raise ValueError(f"line {number}: duplicate model_id/clip_id {key}")
        seen.add(key)
        metadata = (row["language"], row["scenario"], row["reference"])
        prior_metadata = clip_metadata.setdefault(row["clip_id"], metadata)
        if metadata != prior_metadata:
            raise ValueError(f"line {number}: conflicting reference/language/scenario for clip_id")
        for field in OPTIONAL_TIMINGS:
            value = row.get(field)
            if value is not None and (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                or value < 0
            ):
                raise ValueError(f"line {number}: {field} must be non-negative and finite")
        if row.get("inference_ms") == 0 and row.get("audio_duration_ms", 0) > 0:
            raise ValueError(f"line {number}: inference_ms cannot be zero for nonempty audio")
        rows.append(row)
    if not rows:
        raise ValueError("input has no rows")
    return rows


def score_group(rows: list[dict]) -> dict:
    substitutions = deletions = insertions = reference_words = 0
    char_errors = reference_chars = 0
    language_checked = language_correct = 0
    non_speech = hallucinated_non_speech = 0
    inference = []
    stop_to_insert = []
    peak_rss = []
    real_time_factors = []
    for row in rows:
        ref_words = words(row["reference"])
        hyp_words = words(row["hypothesis"])
        if not ref_words:
            non_speech += 1
            hallucinated_non_speech += bool(hyp_words)
        else:
            sub, delete, insert = edit_counts(ref_words, hyp_words)
            substitutions += sub
            deletions += delete
            insertions += insert
            reference_words += len(ref_words)
            # CER over the same normalization, words joined by single spaces. It separates
            # "one letter off" (caffe/caffè, Johnson/Jonson) from a wrong or missing word.
            ref_chars, hyp_chars = list(" ".join(ref_words)), list(" ".join(hyp_words))
            char_errors += sum(edit_counts(ref_chars, hyp_chars))
            reference_chars += len(ref_chars)
            detected = row.get("detected_language")
            if isinstance(detected, str) and detected:
                language_checked += 1
                language_correct += detected == row["language"]
        if row.get("inference_ms") is not None:
            inference.append(row["inference_ms"])
            if row.get("audio_duration_ms") and row["inference_ms"]:
                real_time_factors.append(row["audio_duration_ms"] / row["inference_ms"])
        if row.get("stop_to_insert_ms") is not None:
            stop_to_insert.append(row["stop_to_insert_ms"])
        if row.get("peak_rss_mb") is not None:
            peak_rss.append(row["peak_rss_mb"])
    return {
        "clips": len(rows),
        "reference_words": reference_words,
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "wer": ((substitutions + deletions + insertions) / reference_words
                if reference_words else None),
        "cer": char_errors / reference_chars if reference_chars else None,
        "language_id_accuracy": (language_correct / language_checked
                                 if language_checked else None),
        "non_speech_clips": non_speech,
        "hallucinated_non_speech_clips": hallucinated_non_speech,
        "inference_ms_p50": percentile(inference, 0.5),
        "inference_ms_p95": percentile(inference, 0.95),
        "stop_to_insert_ms_p50": percentile(stop_to_insert, 0.5),
        "stop_to_insert_ms_p95": percentile(stop_to_insert, 0.95),
        "peak_rss_mb_max": max(peak_rss) if peak_rss else None,
        "rtf_x_p50": percentile(real_time_factors, 0.5),
    }


def score(rows: list[dict]) -> dict:
    by_model = defaultdict(list)
    by_language = defaultdict(list)
    by_scenario = defaultdict(list)
    for row in rows:
        by_model[row["model_id"]].append(row)
        by_language[(row["model_id"], row["language"])].append(row)
        by_scenario[(row["model_id"], row["language"], row["scenario"])].append(row)
    clip_sets = {model: {row["clip_id"] for row in model_rows}
                 for model, model_rows in by_model.items()}
    common_clips = set.intersection(*clip_sets.values())
    union_clips = set.union(*clip_sets.values())
    return {
        "pairing": {
            "complete": len(common_clips) == len(union_clips),
            "common_clips": len(common_clips),
            "all_clips": len(union_clips),
            "missing_by_model": {model: sorted(union_clips - clips)
                                 for model, clips in sorted(clip_sets.items())},
        },
        "models": {key: score_group(value) for key, value in sorted(by_model.items())},
        "languages": {f"{model}/{language}": score_group(value)
                      for (model, language), value in sorted(by_language.items())},
        "scenarios": {f"{model}/{language}/{scenario}": score_group(value)
                      for (model, language, scenario), value in sorted(by_scenario.items())},
    }


def markdown(report: dict) -> str:
    """Compact per-model and per-language table for research notes."""
    def pct(value):
        return "–" if value is None else f"{value * 100:.1f}%"

    def ms(value):
        return "–" if value is None else f"{value:.0f}"

    lines = ["| config | scope | WER | CER | lang-ID | p50 ms | p95 ms | non-speech with text |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for model, result in report["models"].items():
        groups = [("all", result)] + [
            (key.rsplit("/", 1)[1], value) for key, value in report["languages"].items()
            if key.rsplit("/", 1)[0] == model]
        for scope, value in groups:
            silent = (f"{value['hallucinated_non_speech_clips']}/{value['non_speech_clips']}"
                      if value["non_speech_clips"] else "–")
            lines.append(f"| {model} | {scope} | {pct(value['wer'])} | {pct(value['cer'])} | "
                         f"{pct(value['language_id_accuracy'])} | {ms(value['inference_ms_p50'])} | "
                         f"{ms(value['inference_ms_p95'])} | {silent} |")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, help="paired Dictari ASR JSONL measurements")
    parser.add_argument("--output", type=Path, help="optional JSON report path")
    parser.add_argument("--markdown", action="store_true",
                        help="print a per-model/per-language Markdown table instead of JSON")
    args = parser.parse_args()
    try:
        report = score(load_rows(args.results))
    except (OSError, ValueError) as error:
        parser.error(str(error))
    rendered = (markdown(report) if args.markdown
                else json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
