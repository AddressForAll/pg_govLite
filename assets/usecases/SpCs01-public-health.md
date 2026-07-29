# SpCs01 - Public Health Municipality Access

## Classification

Simple use case.

## Goal

Create a deterministic Bronze/Silver/Gold tutorial flow that combines
municipality reference data with supplementary-health operator data and publishes
a governed Gold view.

## Executable test

Run:

```sh
make manualExamples
```

The executable SQL script is:

```text
assets/data/manual01-public_health_tutorial.sql
```

## Input objects

- `geo_bronze.ibge_municipality_raw`
- `hlth_bronze.ans_operator_raw`

## Generated objects

- `geo_silver.ibge_municipality`
- `hlth_silver.ans_operator`
- `hlth_gold.vw_municipality_health_access`

## Governance checks

- `HLTH` domain tag exists and is active.
- Bronze input relations are tagged with domain, stage, and tier tags.
- Identifier columns are tagged.
- The Gold view is tagged as `isProduct`.
- The Sao Paulo sample result has `active_operator_count = 2`.
- A documentation example is registered in `gvlt.doc_examples`.
