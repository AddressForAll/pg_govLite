# CxCs01 - Municipal Climate

## Classification

Complex use case.

## Dependencies

- pg_govLite schema: `gvlt`
- PostGIS raster/vector support
- DNGS/grid extension represented by `_grid_` in schema names
- `fwa_br` extension
- External municipal jurisdiction polygons
- External climate raster data

## Goal

Produce climate attributes by municipality from jurisdiction polygons and a
climate raster, preserving governed tags across Bronze and Silver objects.

## Naming

- Tutorial prefix: `tutcase_`
- Bronze schema: `tutcase_bronze`
- Grid Silver schema: `tutcase_grid_silver`
- Medallion suffixes: `_bronze`, `_silver`, `_gold`

## Input objects

- `tutcase_bronze.br_rr_jurisdiction`
  - Columns: `gid`, `local_id`, `name`, `isolabel_ext`, `geom`
  - Meaning: municipality mosaic for BR-RR.
- `tutcase_bronze.br_climate1`
  - Columns: `id`, `rast`
  - Meaning: climate raster for Brazil.

## Generated objects

- `tutcase_grid_silver.br_rr_cliemate1_mvw01resample`
  - Materialized view created by a resampling operation.
- `tutcase_grid_silver.br_rr_jurisdiction_cliemate1_mvw01stats`
  - Materialized view with zonal statistics by jurisdiction.
- `tutcase_grid_silver.br_rr_jurisdiction_cliemate1_vw01main`
  - View joining statistics back to jurisdiction attributes.

## Governance tags

The case must create or confirm at least:

- `climate`
- `avg-temperature`
- `BR`
- `BR-RR`

Use:

```sql
SELECT gvlt.tag_include(
  'climate',
  'semantic',
  'Long-term statistical characterization of atmospheric conditions in a region.',
  'wd:Q7937'
);
```

Use `gvlt.tagobj_include(...)` to associate governed tags to all generated
relations and relevant subcolumns.

## Expected assertions

- Required external extensions are present.
- Required input relations exist.
- Generated materialized views and final view exist.
- The final view exposes one row per expected jurisdiction key.
- Climate statistics columns exist.
- All required tags are active in `gvlt.tag`.
- All expected object/tag associations are active in `gvlt.tag_obj`.

This use case is not part of the default local assert target because it depends
on external extensions and external geospatial data.

