process BUILD_SPATIALDATA {
    tag "${pair_id}:${platform}"

    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/spatialdata" }, mode: "symlink", overwrite: true

    input:
    // raw_input and aux_input are staged by Nextflow; build_config_json holds settings only
    tuple val(key), val(pair_id), val(platform), val(build_config_json), path(raw_input), path(aux_input)

    output:
    tuple val(key), val(pair_id), val(platform), path("spatialdata_out/source_spatialdata.zarr")

    script:
    def forceFlag = params.force_spatialdata_build ? "--force-rerun" : ""
    def buildConfig = new groovy.json.JsonSlurper().parseText(build_config_json)
    // Readers name elements after the raw folder's parent, so stage it under the
    // platform name rather than the task work directory. A raw export can also
    // arrive as one archive (bin/merxen-unpack-raw), named after the folder.
    def rawName = raw_input.name
    def rawFolder = rawName.replaceFirst(/\.(tar\.gz|tgz|tar|zip)$/, "")
    def stageRawInput = rawFolder != rawName
        ? "merxen-unpack-raw '${raw_input}' '${platform}/${rawFolder}'"
        : "ln -sfn '../${raw_input}' '${platform}/${raw_input}'"
    buildConfig.input_path = "${platform}/${rawFolder}".toString()
    if (aux_input) {
        def auxField = platform == "MERSCOPE" ? "merscope_transform_path" : "xenium_spec_path"
        buildConfig[auxField] = "${aux_input}".toString()
    }
    def buildConfigText = groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(buildConfig))
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

    mkdir -p "${platform}"
    ${stageRawInput}

    cat > build_config.json <<'JSON'
${buildConfigText}
JSON

    merxen build-spatialdata --config build_config.json ${forceFlag}
    """
}
