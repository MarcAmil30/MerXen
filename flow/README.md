# Flow.bio

`flow/schema/main.json` is the Flow.bio pipeline schema: the run form Flow
shows and how it maps onto MerXen's params. It follows the format of Flow's
own pipelines (for example `goodwright/differential-analysis`,
`flow/schema/main.json`) and uses only fields those schemas use.

- **Sections** is a `csv` param that becomes `--samplesheet`: one row per
  tissue section, the same columns as `workflows/samplesheet.example.csv`.
  The raw exports, transforms and annotations are `data` columns, so Flow
  passes them as files and Nextflow stages them into each task.
- **Pipeline options** and **Reference data** become `--<param>`. The Allen
  atlas files are `data` params.
- **Outputs** are matched by process name and file pattern, using the file
  names of a full run.

Run with `-profile docker` or `-profile singularity` (`docs/containers.md`).
Nextflow 25.04 or newer is needed; 26.04.0 is tested.

## Not covered yet

- **Reusing a zarr across Flow runs.** `merscope_spatialdata_path` and
  `xenium_spatialdata_path` (start from an earlier run's SpatialData zarr) are
  left out of the form, and the latest zarr is not listed as an output, until
  that is designed.

## Open questions for the Flow team

1. **Entry point.** The workflow is `workflows/main.nf`, not `main.nf` at the
   repository root. Can a pipeline point at a subfolder, or should there be a
   root `main.nf`?
2. **Folders as data.** `merscope_dir` and `xenium_dir` are folders (a vendor
   region export, many files). Can Flow data be a folder, or should they be
   uploaded as an archive?
3. **Registered images.** `xenium_registered_images_csv` lists image and
   matrix files by path inside the CSV. Those files are staged by Nextflow,
   but on Flow their paths must point at something Nextflow can read.
4. **Reference data.** About 47 GB for the human atlas. Uploaded once as Flow
   data, or pre-staged on the cluster? Their cache folders
   (`mecr_reference_cache_dir`, `mapmycells_region_cache_dir`, ...) are written
   to, so they cannot be read-only.
5. **Runtime and storage.** Docker or Singularity; a shared work disk or
   object storage; GPUs for Cellpose.
6. **Sample types.** A section is not one of Flow's sample types, so the form
   takes rows directly (`takes_samples: false`). Is there a spatial sample
   type it should use instead?
