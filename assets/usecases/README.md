# pg_govLite Use Case Test Case Standard

The tutorial acts as the use-case generator. Curated use cases should be
registered with a stable ID and, when possible, an executable SQL test case.

## ID scheme

- `SpCsNN` identifies a simple use case.
- `CxCsNN` identifies a complex use case.
- `tutcase_` is the object-name prefix for tutorial-derived cases.
- `_bronze`, `_silver`, and `_gold` are the Medallion suffixes.
- Extension-specific schemas may include an abbreviation before the Medallion
  suffix, such as `tutcase_grid_silver`.

## Simple vs complex

Simple use cases run with pg_govLite and deterministic local sample data. They
must be executable in development and CI without network access.

Complex use cases require external data, external extensions, or both. They must
document their dependencies and expected assertions. They become executable only
when those dependencies are available in the target environment.

## Required structure

Each curated use case should include:

- ID and title.
- Classification: simple or complex.
- Goal.
- Required extensions and external data.
- Input objects.
- Generated objects.
- Governance tags to create or check.
- Execution steps.
- Expected results.
- SQL assertions or a reference to an executable SQL script.

## Test case rules

- Approved simple use cases must have an executable SQL script.
- Test scripts must use deterministic local data.
- Test scripts must fail with `ASSERT` or `RAISE EXCEPTION` when a required
  result is missing.
- Use `gvlt.tag_include(...)` to create or update governed tags.
- Use `gvlt.tagobj_include(...)` to associate governed tags with relations,
  schemas, and columns.
- Keep the lower-level `gvlt.govtags_*` functions as internal implementation
  details for core tests and compatibility.

