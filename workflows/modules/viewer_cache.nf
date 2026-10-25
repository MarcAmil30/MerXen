process VIEWER_CACHE {
    tag "${pair_id}:${platform}"

    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/viewer_cache" }, mode: "symlink", overwrite: true
    // latest/ follows the newest store in the chain (see bin/merxen-link-copy)
    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/latest" }, mode: "symlink", overwrite: true,
        saveAs: { filename -> filename == "latest_input.zarr" ? "latest_spatialdata.zarr" : null }

    input:
    tuple val(key), val(pair_id), val(platform), val(viewer_cache_config_json), path(latest_zarr, stageAs: "upstream_latest.zarr"), path(transform_input)

    output:
    tuple val(key), val(pair_id), val(platform), path("latest_input.zarr"), path("viewer_cache_out")

    script:
    """
    set -euo pipefail
    export OMP_NUM_THREADS="${task.cpus}"
    export OPENBLAS_NUM_THREADS="${task.cpus}"
    export MKL_NUM_THREADS="${task.cpus}"
    export NUMEXPR_NUM_THREADS="${task.cpus}"
    export NUMBA_NUM_THREADS="${task.cpus}"
    export VECLIB_MAXIMUM_THREADS="${task.cpus}"
    export BLIS_NUM_THREADS="${task.cpus}"
    export RAYON_NUM_THREADS="${task.cpus}"
    export POLARS_MAX_THREADS="${task.cpus}"
    export DASK_NUM_WORKERS="${task.cpus}"

    # own copy of the upstream store; see bin/merxen-link-copy
    merxen-link-copy "${latest_zarr}" latest_input.zarr

    cat > viewer_cache_config.json <<'JSON'
${viewer_cache_config_json}
JSON

    merxen build-viewer-caches --config viewer_cache_config.json
    """
}
