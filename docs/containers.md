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

### Without Docker

On a cluster with Apptainer but no Docker, build each image from the same
Dockerfile: `containers/dockerfile2def.py` translates it into an Apptainer
definition file, and a rootless build needs no administrator.

```bash
python containers/dockerfile2def.py containers/Dockerfile merxen.def
APPTAINER_TMPDIR=/local/tmp apptainer build --fakeroot merxen.sif merxen.def
```

Run it from the repository root, as for `docker build`. Point
`APPTAINER_TMPDIR` at a local disk: unpacking fails on network file systems
that refuse extended attributes (CephFS). Without `/etc/subuid` entries,
Apptainer needs the `fakeroot` command on `PATH` for the Rocky-based images
(`dnf`); the miniforge-based images build with `--ignore-fakeroot-command`.
Then point the `singularity` profile at the `.sif` files with a `process`
config (`container = '/path/merxen.sif'`, one `withName` per image).

### Base images

`torch` 2.10 (in `requirements.lock`) brings its own CUDA 12.8 runtime and
cuDNN as pip packages, and the RAPIDS wheels for GPU clustering are built for
CUDA 12.9. A CUDA or cuDNN in the base image is found first, so it must not be
older: `merxen` is on `nvidia/cuda:12.8.1-devel-rockylinux9` and
`merxen-clustering-gpu` on `12.9.1-devel`, both without cuDNN. The GPU
clustering image installs whatever RAPIDS release pip resolves for
`rapids-singlecell-cu12[rapids]==0.15.2` (26.6 when last built), so a newer
RAPIDS may need a newer base again.

## Run

```bash
nextflow run workflows/main.nf -profile docker      --samplesheet ... --outdir ...
nextflow run workflows/main.nf -profile singularity --samplesheet ... --outdir ...
```

Both profiles set the host settings that `nextflow.config` leaves to a site
profile: ProSeg from the image with 32 threads, and a 300 GB memory budget for
Cellpose tiling and transcript chunks (`--max_ram_gb`, `--warn_ram_gb`). Set
them to the size of your nodes.

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
| `merxen` | Cellpose-SAM `cpsam` (Cellpose 4.1.1, as locked, always loads it) | 1.2 GB | `CELLPOSE_LOCAL_MODELS_PATH=/opt/cellpose/models` |
| `merxen-alignment` | Kornia DISK `depth-save.pth`, LightGlue `disk_lightglue_v0-1_arxiv-pth` (VALIS feature matching) | 52 MB | `TORCH_HOME=/opt/torch` |

The alignment weights are the files the CREATE runs downloaded
(byte-identical). The CREATE conda env has Cellpose 4.2.1.1, newer than the
lock, which loads `cpsam_v2` instead, so segmentation in the image can differ
slightly from runs in that env. All four
images also set `MPLCONFIGDIR`, `NUMBA_CACHE_DIR` and `XDG_CACHE_HOME` (and the
GPU clustering image `CUPY_CACHE_DIR`) under `/tmp` as a fallback, because a
non-root container user usually has no writable home; MerXen's own code points
them at the task folder where it can.

## What each task can see

Every stage gets its input files as Nextflow `path` inputs, and each stage
that adds to the SpatialData zarr works on its own hard-linked copy
(`workflows/bin/merxen-link-copy`) and outputs it. So a task needs only its
work folder and its staged inputs; no data folder has to be mounted.

The Allen atlas reference files (47 GB) are inputs too, staged from the paths
in the `mecr_*`, `clustering_squidpy_*` and `mapmycells_*` params. Their cache
folders are still written to, so they must be writable.

## Tested so far

On KCL CREATE (no Docker), with rootless Apptainer 1.5.4:

- **The four images**, built from these Dockerfiles with
  `containers/dockerfile2def.py`. Building them found three faults that a
  `docker build` would hit too, now fixed: the base image's lock install did
  not resolve, and the CUDA in both GPU images was older than the CUDA that
  `torch` and RAPIDS bring, which broke `import torch` and cuML.
- **Import checks** in each image with nothing mounted and a clean
  environment: Cellpose finds `cpsam_v2`, VALIS finds the DISK and LightGlue
  weights, MENDER's `pip check` is clean, `torch` and RAPIDS run on an A100.
- **The full 17-stage run** in these images: see `PR_feat-flow-ready.md`
  for the result.

The `docker build` itself and a run with `-profile docker` have not been done
on a machine with Docker; the laptop check only exercised the profile's
settings with a small test image.
