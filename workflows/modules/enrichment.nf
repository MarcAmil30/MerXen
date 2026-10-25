process ENRICH {
    tag "${pair_id}:${platform}"

    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/enrichment" }, mode: "symlink", overwrite: true
    // Later stages still add to this store in place, so latest/ links to it
    // rather than holding a copy.
    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/latest" }, mode: "symlink", overwrite: true,
        saveAs: { filename -> filename == "latest_input.zarr" ? "latest_spatialdata.zarr" : null }

    input:
    tuple val(key), val(pair_id), val(platform), val(enrich_config_json), path(latest_zarr), path(mask_path), path(nuclei_mask_path), path(original_data, stageAs: "source_spatialdata.zarr")

    output:
    tuple val(key), val(pair_id), val(platform), path("latest_input.zarr"), path("enrich_out")

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

    # Enrich a hard-linked copy, so SEGMENT's zarr is left as it was and costs
    # no extra space. zarr replaces a chunk by writing a new file and renaming
    # it, which never touches the linked original. The linked files are made
    # read-only, so a writer that edits a file in place fails here instead of
    # changing SEGMENT's output.
    mkdir latest_input.zarr
    if ! cp -a --link "${latest_zarr}/." latest_input.zarr/ 2>/dev/null; then
        # different filesystem: start again with a plain copy, so cp never
        # writes into a file that is still linked to the original
        rm -rf latest_input.zarr && mkdir latest_input.zarr
        cp -a "${latest_zarr}/." latest_input.zarr/
    fi
    find latest_input.zarr -type f -links +1 -exec chmod a-w {} +
    ln -s ${mask_path} enrich_input_mask.npy
    ln -s ${nuclei_mask_path} enrich_input_nuclei_mask.npy

    cat > enrich_config.json <<'JSON'
${enrich_config_json}
JSON

    merxen enrich --config enrich_config.json
    """
}
