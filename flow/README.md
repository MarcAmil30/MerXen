# Flow.bio

`flow/schema/merxen.json` is the Flow.bio pipeline schema: the run form Flow
shows and how it maps onto MerXen's params. It follows the format of Flow's
own pipelines (for example `goodwright/differential-analysis`,
`flow/schema/main.json`). Every field it uses, at every level (sections,
params, csv columns, outputs), also appears in the schemas of the 25
pipelines public on app.flow.bio (checked through Flow's API, 2026-10-25).

- **Sections** is a `csv` param that becomes `--samplesheet`: one row per
  tissue section, the same columns as `workflows/samplesheet.example.csv`.
  The raw exports, transforms and annotations are `data` columns, so Flow
  passes them as files and Nextflow stages them into each task. A raw export
  is a folder of many files and Flow data are single files, so
  `merscope_dir` and `xenium_dir` also take a .tar, .tar.gz, .tgz or .zip of
  the folder, which the first stage unpacks.
- **Pipeline options** and **Reference data** become `--<param>`. The Allen
  atlas files are `data` params.
- **Outputs** are matched by process name and file pattern, using the file
  names of a full run.

`nextflow run <repository>` finds the pipeline through the root
`nextflow.config` (`manifest.mainScript = 'workflows/main.nf'`). Run with
`-profile docker` or `-profile singularity` (`docs/containers.md`). Nextflow
25.04 or newer is needed; 26.04.0 is tested.

A section is not one of Flow's sample types (ChIP-Seq, CLIP, Hi-C, Ribo-Seq,
RNA-Seq, scRNA-Seq on app.flow.bio), so the form takes rows directly
(`takes_samples: false`), as Flow's own `Scdownstream` pipeline does.

## Registering on Flow

One repo, one pipeline. Add a version with:

| Field | Value |
|---|---|
| Path | `workflows/main.nf` |
| Schema | `flow/schema/merxen.json` |
| Config | `flow/conf/merxen.config`: runs every stage in its Apptainer image (Flow passes no `-profile`) |

### Simple version (0.2, branch `feat/flow-simple`)

The same pipeline with a short form for users: the sample name and its
Xenium .tar.gz, plus presets (analysis mode, species, channels, min QV, GPU)
and an advanced section (MapMyCells reference, segmentation, clustering
resolution, MENDER radius, alignment).

| Field | Value |
|---|---|
| Git reference | `feat/flow-simple` |
| Path | `workflows/main.nf` |
| Schema | `flow/schema/merxen_simple.json` |
| Config | `flow/conf/merxen_simple.config` |

`merxen_simple.config` includes `merxen.config` and fixes the rest: every run
goes from `build_spatialdata` to `mender` with MECR and MENDER on, and the
three GeoJSON stages off. MapMyCells defaults to `whole_brain`, which uses the
uploaded precomputed stats; `region` and `both` download about 38 GB from
Allen and build a frontal reference on every run. The Allen files come from
`flow/conf/staging3.config` (paths under `/media/storage/staging3/uploads/`);
another Flow server needs its own copy of that file.

### Figures version (0.3, branch `feat/flow-figures`)

Version 0.2 plus one stage, `ANNOTATION_FIGURES` (`workflows/modules/annotation_figures.nf`,
script `workflows/bin/merxen-annotation-figures`), switched on by
`annotation_figures_enabled = true` in `merxen_simple.config`. After MapMyCells and MENDER it
draws, per section and segmentation:

| File | Shows |
|---|---|
| `<sample>_celltypes_markers.png` | cells coloured by marker-scored type (each leiden cluster scored against canonical cortical markers; best type if its score is above 0.35) |
| `<sample>_celltypes_allen.png` | A: cells named by MapMyCells against the Allen atlas; B: share of each type |
| `<sample>_tissue_domains.png` | C: MENDER domains; D: each domain's size and the type that dominates it |

They are listed first among the outputs in `merxen_simple.json`. Register 0.3 like 0.2, with Git
reference `feat/flow-figures`.

The schema is named after the pipeline, as in `goodwright/rnaseq`
(`flow/schema/rnaseq.json`). `workflows/main.nf` keeps its upstream name.
Leave the four pipeline properties (nf-core, demultiplex, prepares genome,
imports samples) unticked.

## Not covered yet

- **Reusing a zarr across Flow runs.** `merscope_spatialdata_path` and
  `xenium_spatialdata_path` (start from an earlier run's SpatialData zarr) are
  left out of the form, and the latest zarr is not listed as an output, until
  that is designed.

## Open questions for the Flow team

These depend on how Flow is set up, so only Flow can answer them.

1. **Registered images.** `xenium_registered_images_csv` lists image and
   matrix files by path inside the CSV. Nextflow stages them, but on Flow
   their paths must point at something Nextflow can read. Should they be
   separate `data` columns instead?
2. **Reference data.** About 47 GB for the human atlas. Uploaded once as Flow
   data, or pre-staged on the cluster? Their cache folders
   (`mecr_reference_cache_dir`, `mapmycells_region_cache_dir`, ...) are written
   to, so they cannot be read-only.
3. **Runtime and storage.** Docker or Singularity; a shared work disk or
   object storage (`latest/` is made of hard links into the work folder, which
   needs both on one file system; otherwise it is copied); GPUs for Cellpose.

Answered on our side: the entry point (root `nextflow.config`), folders as
data (archives), and sample types (none fits).
