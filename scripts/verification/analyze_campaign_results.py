#!/usr/bin/env python3
"""Summarize privacy-safe Hireva campaign state and JSONL result metadata."""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path.name}")
    return value


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError(f"expected object in {path.name}:{line_number}")
            rows.append(value)
    return rows


def count_values(rows: Iterable[dict[str, Any]], key: str) -> Counter[str]:
    return Counter(str(row.get(key, "unknown")) for row in rows)


def write_csv(path: Path, fieldnames: list[str], rows: Iterable[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    arguments = parser.parse_args()

    state_dir = arguments.state_dir.resolve(strict=True)
    artifact_dir = arguments.artifact_dir.resolve(strict=True)
    state = load_json(state_dir / "campaign_state.json")
    if Path(state["state_dir"]).resolve() != state_dir:
        raise ValueError("state directory does not match campaign_state.json")
    if Path(state["artifact_dir"]).resolve() != artifact_dir:
        raise ValueError("artifact directory does not match campaign_state.json")

    scenarios = load_jsonl(artifact_dir / "results" / "scenario_results.jsonl")
    real_audio = load_jsonl(artifact_dir / "results" / "real_audio_results.jsonl")
    answer_quality = load_jsonl(artifact_dir / "results" / "answer_quality_results.jsonl")
    failures = load_jsonl(state_dir / "failure_queue.jsonl")
    sources = load_jsonl(state_dir / "research_sources.jsonl")
    checkpoints = load_jsonl(state_dir / "checkpoints.jsonl")

    metrics = {
        "campaign_id": state["campaign_id"],
        "status": state["status"],
        "active_elapsed_seconds": state["active_elapsed_seconds"],
        "target_active_seconds": state["target_active_seconds"],
        "completed_cycles": state["completed_cycles"],
        "scenario_results": len(scenarios),
        "scenario_passes": sum(bool(row.get("passed")) for row in scenarios),
        "scenario_failures": sum(not bool(row.get("passed")) for row in scenarios),
        "real_audio_results": len(real_audio),
        "answer_quality_results": len(answer_quality),
        "open_failures": sum(row.get("status") == "open" for row in failures),
        "fixed_failures": sum(row.get("status") == "fixed" for row in failures),
        "research_sources": len(sources),
        "checkpoints": len(checkpoints),
        "scenario_categories": dict(count_values(scenarios, "category")),
        "failure_categories": dict(count_values(failures, "category")),
    }

    reports_dir = artifact_dir / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)
    with (reports_dir / "metrics.json").open("w", encoding="utf-8") as handle:
        json.dump(metrics, handle, indent=2, sort_keys=True)
        handle.write("\n")

    write_csv(
        reports_dir / "failures.csv",
        ["id", "severity", "category", "scenarioID", "status", "firstSeenAt", "actual", "logPath"],
        failures,
    )
    write_csv(
        reports_dir / "scenario_coverage.csv",
        ["timestamp", "scenarioID", "category", "passed", "exitCode", "logPath"],
        scenarios,
    )
    write_csv(
        reports_dir / "source_provenance.csv",
        ["accessedAt", "problemID", "sourceType", "title", "url", "repository", "commitOrVersion", "license", "codeCopied"],
        sources,
    )

    duration_met = state["active_elapsed_seconds"] >= state["target_active_seconds"]
    report = f"""# Hireva Continuous Validation Campaign

## Campaign

- Campaign ID: `{state['campaign_id']}`
- Status: `{state['status']}`
- Start: `{state['start_time_utc']}`
- Target wall-clock marker: `{state['target_end_time_utc']}`
- Active elapsed: `{state['active_elapsed_seconds']}` seconds
- Target active duration: `{state['target_active_seconds']}` seconds
- Full duration reached: `{'yes' if duration_met else 'no'}`
- Base commit: `{state['base_commit']}`
- Last good commit: `{state['last_good_commit']}`
- Branch: `{state['branch']}`

## Evidence summary

- Scenario records: {len(scenarios)}
- Passing scenario records: {metrics['scenario_passes']}
- Failing scenario records: {metrics['scenario_failures']}
- Real-audio records: {len(real_audio)}
- Answer-quality records: {len(answer_quality)}
- Open failures: {metrics['open_failures']}
- Fixed failures: {metrics['fixed_failures']}
- Research sources: {len(sources)}
- Checkpoints: {len(checkpoints)}

This report only summarizes recorded evidence. Empty or missing categories are
not treated as passed or verified.
"""
    (reports_dir / "full_campaign_report.md").write_text(report, encoding="utf-8")
    print(json.dumps(metrics, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
