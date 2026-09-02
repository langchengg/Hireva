#!/usr/bin/env python3
"""Analyze privacy-safe evidence from the six-hour real Hireva.app continuation."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from statistics import fmean
from typing import Any, Iterable


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"expected JSON object at {path}:{line_number}")
        rows.append(value)
    return rows


def load_globbed_jsonl(paths: Iterable[Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(paths):
        rows.extend(load_jsonl(path))
    return rows


def numeric(rows: Iterable[dict[str, Any]], field: str) -> list[float]:
    values: list[float] = []
    for row in rows:
        value = row.get(field)
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value)):
            values.append(float(value))
    return values


def nearest_rank(values: Iterable[float]) -> dict[str, float | int | None]:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return {"count": 0, "p50": None, "p90": None, "p95": None, "p99": None, "max": None}

    def percentile(probability: float) -> float:
        return ordered[max(0, math.ceil(probability * len(ordered)) - 1)]

    return {
        "count": len(ordered),
        "p50": percentile(0.50),
        "p90": percentile(0.90),
        "p95": percentile(0.95),
        "p99": percentile(0.99),
        "max": ordered[-1],
    }


def weighted_asr(rows: list[dict[str, Any]]) -> dict[str, Any]:
    reference_words = sum(int(row.get("referenceWordCount", 0)) for row in rows)
    substitutions = sum(int(row.get("substitutions", 0)) for row in rows)
    deletions = sum(int(row.get("deletions", 0)) for row in rows)
    insertions = sum(int(row.get("insertions", 0)) for row in rows)
    character_edits = sum(int(row.get("characterEditDistance", 0)) for row in rows)
    character_denominator = sum(
        max(int(row.get("referenceCharacterCount", 0)), int(row.get("hypothesisCharacterCount", 0)))
        for row in rows
    )
    errors = substitutions + deletions + insertions
    return {
        "utterances": len(rows),
        "reference_words": reference_words,
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "word_error_rate": (errors / reference_words) if reference_words else 0.0,
        "normalized_character_edit_distance": (
            character_edits / character_denominator if character_denominator else 0.0
        ),
        "semantic_accepted": sum(row.get("semanticAccepted") is True for row in rows),
        "semantic_rejected": sum(row.get("semanticAccepted") is False for row in rows),
    }


def critical_clean_rows(
    rows: list[dict[str, Any]], repository_root: Path
) -> list[dict[str, Any]]:
    profile_by_scenario_turn: dict[tuple[str, str], str] = {}
    scenario_root = repository_root / "scripts/fixtures/real_audio_campaign"
    for scenario_name in sorted({str(row.get("scenario", "")) for row in rows if row.get("scenario")}):
        scenario = load_json(scenario_root / scenario_name)
        sessions = scenario.get("sessions")
        if not isinstance(sessions, list):
            raise ValueError(f"scenario sessions are invalid: {scenario_name}")
        for session in sessions:
            if not isinstance(session, dict) or not isinstance(session.get("turns"), list):
                raise ValueError(f"scenario turns are invalid: {scenario_name}")
            session_id = str(session.get("id", ""))
            for turn_index, turn in enumerate(session["turns"]):
                if not isinstance(turn, dict):
                    raise ValueError(f"scenario turn is invalid: {scenario_name}")
                profile_by_scenario_turn[(scenario_name, f"{session_id}.{turn_index}")] = str(
                    turn.get("audioProfile", "clean")
                )
    return [
        row for row in rows
        if profile_by_scenario_turn.get(
            (str(row.get("scenario", "")), str(row.get("matchedTurnID", "")))
        ) == "clean"
    ]


def load_resource_rows(resource_root: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(resource_root.glob("resource_metrics_attempt_*.csv")):
        with path.open("r", encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                converted: dict[str, Any] = dict(row)
                for key, value in list(converted.items()):
                    if key == "timestamp_utc" or value in (None, ""):
                        continue
                    try:
                        converted[key] = float(value)
                    except ValueError:
                        raise ValueError(f"nonnumeric resource metric in {path.name}: {key}")
                converted["resource_file"] = path.name
                rows.append(converted)
    return rows


def score_summary(rows: list[dict[str, Any]], field: str) -> dict[str, Any]:
    values = numeric(rows, field)
    return {
        "mean": fmean(values) if values else None,
        "percentiles": nearest_rank(values),
    }


def latency_summary(rows: list[dict[str, Any]], mapping: dict[str, str]) -> dict[str, Any]:
    return {output: nearest_rank(numeric(rows, source)) for output, source in mapping.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    args = parser.parse_args()

    state_dir = args.state_dir.resolve(strict=True)
    artifact_dir = args.artifact_dir.resolve(strict=True)
    state = load_json(state_dir / "campaign_state.json")
    if Path(state["state_dir"]).resolve() != state_dir or Path(state["artifact_dir"]).resolve() != artifact_dir:
        raise ValueError("state and artifact paths do not match campaign state")

    repository_root = Path(state["repository_root"]).resolve(strict=True)
    cycle_rows = load_jsonl(artifact_dir / "results/cycle_results.jsonl")
    asr_rows = load_jsonl(artifact_dir / "results/asr_accuracy.jsonl")
    answer_rows = load_jsonl(artifact_dir / "results/answer_quality.jsonl")
    real_latency_rows = load_jsonl(artifact_dir / "results/pipeline_latency.jsonl")
    resource_rows = load_resource_rows(artifact_dir / "resources")
    recorded_preflight = state.get("preflight_attempt")
    if isinstance(recorded_preflight, str) and recorded_preflight:
        preflight_roots = [artifact_dir / "preflight" / recorded_preflight]
    else:
        preflight_roots = sorted((artifact_dir / "preflight").glob("attempt-*"))
    curated_rows = load_globbed_jsonl(root / "answer_quality.jsonl" for root in preflight_roots)
    harness_rows = load_globbed_jsonl(root / "harness_metrics.jsonl" for root in preflight_roots)
    provider_rows = load_globbed_jsonl(root / "provider_only_metrics.jsonl" for root in preflight_roots)
    direct_asr_rows = load_globbed_jsonl(root / "direct_asr_metrics.jsonl" for root in preflight_roots)

    app_rows = [row for row in resource_rows if row.get("app_process_count") == 1.0]
    resource_metrics = {
        "samples": len(resource_rows),
        "exact_app_samples": len(app_rows),
        "exact_app_sample_coverage": (len(app_rows) / len(resource_rows)) if resource_rows else 0.0,
        "app_rss_bytes": nearest_rank(numeric(app_rows, "app_rss_bytes")),
        "app_open_file_count": nearest_rank(numeric(app_rows, "app_open_file_count")),
        "helper_rss_bytes": nearest_rank(numeric(resource_rows, "helper_rss_bytes")),
        "helper_open_file_count": nearest_rank(numeric(resource_rows, "helper_open_file_count")),
        "ollama_rss_bytes": nearest_rank(numeric(resource_rows, "ollama_rss_bytes")),
        "maximum_app_process_count": max(numeric(resource_rows, "app_process_count"), default=None),
        "maximum_helper_process_count": max(numeric(resource_rows, "helper_process_count"), default=None),
        "collection_error_count_max": max(numeric(resource_rows, "collection_error_count"), default=None),
        "rss_interpretation": "resident set size sampled by ps; this is not macOS physical footprint",
    }
    if app_rows:
        resource_metrics["app_rss_first_bytes"] = app_rows[0].get("app_rss_bytes")
        resource_metrics["app_rss_last_bytes"] = app_rows[-1].get("app_rss_bytes")
        resource_metrics["app_rss_first_to_last_delta_bytes"] = (
            float(app_rows[-1].get("app_rss_bytes", 0)) - float(app_rows[0].get("app_rss_bytes", 0))
        )

    hard_failure_fields = [
        "unsupportedPersonalClaim", "wrongProfileEvidence", "wrongJobContext", "staleAnswer",
        "duplicatePersistence", "providerSourceMislabel", "answerQuestionIdentityMismatch",
        "contextBleed", "jdToExperience", "futureToPast", "hardFail",
    ]
    answer_quality = {
        "curated_records": len(curated_rows),
        "real_app_records": len(answer_rows),
        "relevance": score_summary(answer_rows, "relevance"),
        "evidence_grounding": score_summary(answer_rows, "evidenceGrounding"),
        "directness": score_summary(answer_rows, "directness"),
        "spoken_fluency": score_summary(answer_rows, "spokenFluency"),
        "completeness": score_summary(answer_rows, "completeness"),
        "role_fit": score_summary(answer_rows, "roleFit"),
        "hard_failures": {
            field: sum(row.get(field) is True for row in curated_rows + answer_rows)
            for field in hard_failure_fields
        },
    }

    latency = {
        "deterministic_harness": latency_summary(harness_rows, {"elapsed_ms": "elapsedMS"}),
        "provider_only": latency_summary(provider_rows, {
            "provider_first_answer_content_ms": "firstAnswerContentMS",
            "provider_completed_ms": "completedMS",
        }),
        "direct_wav_asr": latency_summary(direct_asr_rows, {
            "first_final_ms": "firstFinalMS",
            "decode_completed_ms": "decodeCompletedMS",
        }),
        "real_screencapturekit_end_to_end": latency_summary(real_latency_rows, {
            "rag_retrieval_ms": "ragRetrievalMS",
            "provider_first_answer_content_ms": "providerFirstAnswerContentMS",
            "provider_completed_ms": "providerCompletedMS",
            "first_visible_answer_ms": "firstVisibleAnswerMS",
            "full_card_visible_ms": "fullCardVisibleMS",
            "persistence_completed_ms": "persistenceCompletedMS",
        }),
    }

    cycle_metrics = {
        "cycles": len(cycle_rows),
        "sessions": sum(int(row.get("session_count", 0)) for row in cycle_rows),
        "turns": sum(int(row.get("transcript_count", 0)) for row in cycle_rows),
        "questions": sum(int(row.get("question_count", 0)) for row in cycle_rows),
        "suggestions": sum(int(row.get("suggestion_count", 0)) for row in cycle_rows),
        "sqlite_identity_nulls": sum(int(row.get("identity_null_count", 0)) for row in cycle_rows),
        "sqlite_duplicate_identities": sum(int(row.get("duplicate_identity_count", 0)) for row in cycle_rows),
        "residual_apps": sum(int(row.get("app_count_after_cleanup", 0)) for row in cycle_rows),
        "residual_helpers": sum(int(row.get("helper_count_after_cleanup", 0)) for row in cycle_rows),
        "db_bytes": nearest_rank(numeric(cycle_rows, "db_bytes")),
        "wal_bytes": nearest_rank(numeric(cycle_rows, "wal_bytes")),
        "trace_bytes": nearest_rank(numeric(cycle_rows, "trace_bytes")),
        "artifact_disk_bytes": nearest_rank(numeric(cycle_rows, "artifact_disk_bytes")),
    }

    real_asr = weighted_asr(asr_rows)
    clean_asr = weighted_asr(critical_clean_rows(asr_rows, repository_root))
    hard_failure_total = sum(answer_quality["hard_failures"].values())
    real_latency_complete = all(
        summary["count"] == len(answer_rows)
        for summary in latency["real_screencapturekit_end_to_end"].values()
    )
    gates = {
        "six_hour_active_duration": state["active_elapsed_seconds"] >= state["target_active_seconds"],
        "all_sixteen_role_families": len({row.get("roleFamily") for row in cycle_rows}) == 16,
        "resource_exact_app_coverage_at_least_90_percent": (
            resource_metrics["exact_app_sample_coverage"] >= 0.90
        ),
        "critical_clean_semantic_acceptance_100_percent": (
            clean_asr["utterances"] > 0 and clean_asr["semantic_rejected"] == 0
        ),
        "overall_semantic_acceptance_at_least_95_percent": (
            real_asr["utterances"] > 0
            and real_asr["semantic_accepted"] / real_asr["utterances"] >= 0.95
        ),
        "curated_answer_records_exactly_800": len(curated_rows) == 800,
        "real_answer_evidence_complete": (
            len(answer_rows) > 0
            and len(answer_rows) == cycle_metrics["suggestions"]
            and hard_failure_total == 0
        ),
        "real_latency_fields_complete": real_latency_complete,
        "provider_only_iterations_at_least_5": len(provider_rows) >= 5,
        "direct_wav_utterances_at_least_3": len(direct_asr_rows) >= 3,
        "deterministic_harness_cases_at_least_64": len(harness_rows) >= 64,
        "sqlite_identity_and_exactly_once": (
            cycle_metrics["sqlite_identity_nulls"] == 0
            and cycle_metrics["sqlite_duplicate_identities"] == 0
        ),
        "process_cleanup": (
            cycle_metrics["residual_apps"] == 0 and cycle_metrics["residual_helpers"] == 0
        ),
        "no_open_continuation_failures": len([
            row for row in load_jsonl(state_dir / "failure_queue.jsonl")
            if row.get("status") == "open"
        ]) == 0,
    }
    gates["all_required_gates_passed"] = all(gates.values())

    metrics = {
        "campaign_id": state["campaign_id"],
        "status": state["status"],
        "target_active_seconds": state["target_active_seconds"],
        "active_elapsed_seconds": state["active_elapsed_seconds"],
        "duration_reached": state["active_elapsed_seconds"] >= state["target_active_seconds"],
        "cycle_metrics": cycle_metrics,
        "resource_metrics": resource_metrics,
        "asr": {
            "real_screencapturekit": real_asr,
            "critical_clean_subset": clean_asr,
            "direct_wav": weighted_asr(direct_asr_rows),
        },
        "answer_quality": answer_quality,
        "latency": latency,
        "gates": gates,
        "open_failures": len([row for row in load_jsonl(state_dir / "failure_queue.jsonl") if row.get("status") == "open"]),
    }

    reports = artifact_dir / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    (reports / "continuation_metrics.json").write_text(
        json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    report = f"""# Hireva Real App Soak Continuation

- Campaign: `{metrics['campaign_id']}`
- Recorded status: `{metrics['status']}`
- Active duration: {metrics['active_elapsed_seconds']} / {metrics['target_active_seconds']} seconds
- Full six-hour target reached: {'yes' if metrics['duration_reached'] else 'no'}
- Real app cycles: {cycle_metrics['cycles']}
- Real system-audio turns: {cycle_metrics['turns']}
- Real answers scored: {answer_quality['real_app_records']}
- Resource samples: {resource_metrics['samples']}
- Exact-app sample coverage: {resource_metrics['exact_app_sample_coverage']:.3%}
- Corpus WER: {metrics['asr']['real_screencapturekit']['word_error_rate']:.6f}
- Normalized character edit distance: {metrics['asr']['real_screencapturekit']['normalized_character_edit_distance']:.6f}
- Unsupported personal claims: {answer_quality['hard_failures']['unsupportedPersonalClaim']}
- Stale answers: {answer_quality['hard_failures']['staleAnswer']}
- Duplicate persistence: {cycle_metrics['sqlite_duplicate_identities']}
- Residual app/helper processes: {cycle_metrics['residual_apps']} / {cycle_metrics['residual_helpers']}
- Open continuation failures: {metrics['open_failures']}
- All required continuation gates passed: {'yes' if gates['all_required_gates_passed'] else 'no'}

RSS is reported as resident set size sampled by `ps`, not as macOS physical footprint.
Missing fields remain missing; the analyzer never substitutes zero for unavailable measurements.
"""
    (reports / "real_app_soak_continuation.md").write_text(report, encoding="utf-8")
    print(json.dumps(metrics, sort_keys=True))
    return 0 if gates["all_required_gates_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
