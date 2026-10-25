process REGISTER_IMAGES {
    tag "${pair_id}:${platform}"

    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/register_images" }, mode: "symlink", overwrite: true
    // latest/.chain/<place in the chain>_<stage>: this stage's store; at the end
    // of the run the highest one becomes latest/ (materializeLatestStores, main.nf)
    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/latest/.chain" }, mode: "symlink", overwrite: true,
        saveAs: { filename -> filename == "latest_input.zarr" ? "02_REGISTER_IMAGES" : null }

    input:
    tuple val(key),
        val(pair_id),
        val(platform),
        val(register_images_config_json),
        path(latest_zarr, stageAs: "upstream_latest.zarr"),
        path(input_files, stageAs: "inputs/??/*")

    output:
    tuple val(key),
        val(pair_id),
        val(platform),
        path("latest_input.zarr"),
        path("register_images_out")

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
    export DASK_NUM_WORKERS="${task.cpus}"

    # own copy of the upstream store; see bin/merxen-link-copy
    merxen-link-copy "${latest_zarr}" latest_input.zarr

    cat > register_images_config.json <<'JSON'
${register_images_config_json}
JSON

    merxen register-images --config register_images_config.json
    """
}
