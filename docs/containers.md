# Container images

MerXen runs in four images, because some stages pin software that cannot
share one environment. `workflows/conf/containers.config` maps each process to
one of them; the `docker` and `singularity` profiles use it.

| Image | Stages | Dockerfile |
|---|---|---|
| `merxen` | every stage not listed below | `containers/Dockerfile` |
| `merxen-alignment` | `ALIGN`, `MATERIALIZE_ALIGNMENT` | `containers/Dockerfile.alignment` |
| `merxen-mender` | `MENDER_COMPUTE` | `containers/Dockerfile.mender` |
| `merxen-clustering-gpu` | `CLUSTERING_SQUIDPY_COMPUTE` when `clustering_squidpy_use_gpu` | `containers/Dockerfile.clustering-gpu` |

Images are named `<container_registry>/<image>:<container_tag>`, by default
`ghcr.io/bourdenxlab/merxen:0.1.0`.

## Build and push

From the repository root (the build context):

```bash
REG=ghcr.io/bourdenxlab TAG=0.1.0
docker build -f containers/Dockerfile                 -t $REG/merxen:$TAG .
docker build -f containers/Dockerfile.alignment       -t $REG/merxen-alignment:$TAG .
docker build -f containers/Dockerfile.mender          -t $REG/merxen-mender:$TAG .
docker build -f containers/Dockerfile.clustering-gpu  -t $REG/merxen-clustering-gpu:$TAG .
docker push $REG/merxen:$TAG   # and the other three
```

Or run the **Container images** GitHub Actions workflow
(`.github/workflows/containers.yml`), which builds all four and pushes them to
GHCR. It only runs when started by hand.

## Run

```bash
nextflow run workflows/main.nf -profile docker      --samplesheet ... --outdir ...
nextflow run workflows/main.nf -profile singularity --samplesheet ... --outdir ...
```

Use `--container_registry` and `--container_tag` for other images. GPUs are
passed to Cellpose (`--cellpose_gpu true`) and GPU clustering
(`--clustering_squidpy_use_gpu true`) as `--gpus all` (Docker) or `--nv`
(Singularity).

Nextflow 25.04 or newer is needed (nf-schema 2.5.1); 26.04.0 is tested.

## Model weights in the images

Weights that the tools would otherwise download into the home folder on first
use are fetched at build time, so a task needs no network and no writable home:

| Image | Weights | Size | Found through |
|---|---|---|---|
| `merxen` | Cellpose-SAM `cpsam_v2` (Cellpose 4 always loads it) | 1.2 GB | `CELLPOSE_LOCAL_MODELS_PATH=/opt/cellpose/models` |
| `merxen-alignment` | Kornia DISK `depth-save.pth`, LightGlue `disk_lightglue_v0-1_arxiv-pth` (VALIS feature matching) | 52 MB | `TORCH_HOME=/opt/torch` |

These are the files the CREATE runs downloaded (byte-identical). All four
images also set `MPLCONFIGDIR` and `NUMBA_CACHE_DIR` under `/tmp` as a
fallback; MerXen's own code points them at the task folder where it can.

## What each task can see

Every stage gets its input files as Nextflow `path` inputs, and each stage
that adds to the SpatialData zarr works on its own hard-linked copy
(`workflows/bin/merxen-link-copy`) and outputs it. So a task needs only its
work folder and its staged inputs; no data folder has to be mounted.

The Allen atlas reference files (47 GB) are inputs too, staged from the paths
in the `mecr_*`, `clustering_squidpy_*` and `mapmycells_*` params. Their cache
folders are still written to, so they must be writable.

## Tested so far

On KCL CREATE, with rootless Apptainer and a plain Ubuntu 22.04 image, with
the conda environments mounted read-only in place of these images. Only the
task folder, the staged inputs and the software were visible to a task, and
the output folder was outside every mount. These images themselves have not
been built yet.
