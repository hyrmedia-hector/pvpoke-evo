# Premium Insight Training

This is the macOS Create ML training job for the IV League Premium intelligence bundle.

It intentionally trains task-specific tabular regressors behind one app-facing model manifest:

- `matchupImpact`
- `teamOptimizer`
- `draftSimulator`
- `metaTrend`
- `battleFrontier`
- `cupReadiness`
- `buildPlanner`
- `scanInbox`
- `battleLog`

The first training source is deterministic PvPoke ranking data. Draft Simulator rows also derive deterministic scenario-evidence inputs from those rankings: standard smart, zero-shield, two-shield, shield-advantage, and shield-deficit summaries with shield state, floor score, volatility, pacing-counter risk, Aegislash pressure, and worst-response pressure columns. These features help Premium Insight explain scenario priorities; they do not replace exact app-side battle simulation.

The output is a versioned Core ML artifact set under:

```text
ml/versions/{dataVersion}/premium-insight-v1/
```

The promoted sidecar is:

```text
ml/current/premium-insight-v1.json
```

Intermediate CSV datasets are written to `training-data/{dataVersion}/` and are not uploaded by the workflow.

The Worker only advertises this sidecar when its `dataVersion`, `modelId`, and `schemaVersion` are compatible with the current data catalog.

## Local Usage

From the `pvpoke-evo` repo root:

```bash
python3 tools/generate-api.py
swift run --package-path tools/premium-insight PremiumInsightTrainer \
  --data-root src/data \
  --catalog dist/v1/catalog.json \
  --output premium-insight-dist
```

Use `--dry-run` to verify dataset and manifest generation without spending time on Create ML training.

## Notes

V1 models rank and prioritize Premium decisions. They do not replace exact PvPoke-equivalent battle simulation. Exact parity remains owned by the app battle engine and its golden fixtures.
