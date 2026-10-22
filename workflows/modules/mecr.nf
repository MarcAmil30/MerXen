// Reference inputs MECR_REFERENCE reads, by config field. main.nf stages the
// files and existing cache directory, then passes the local names back in.
def mecrReferenceInputs(referenceAtlas) {
    def rawH5adPaths = params.mecr_reference_h5ad_paths
    def h5adPaths = rawH5adPaths == null
        ? []
        : (rawH5adPaths instanceof Collection ? rawH5adPaths : rawH5adPaths.toString().split(","))
            .collect { path -> path.toString().trim() }
            .findAll { path -> path }
    def whb = referenceAtlas == "whb"
    def inputs = [
        neurons_h5ad_path: params.mecr_neurons_h5ad_path ?: (whb ? params.mecr_whb_neurons_h5ad_path : null),
        nonneurons_h5ad_path: params.mecr_nonneurons_h5ad_path ?: (whb ? params.mecr_whb_nonneurons_h5ad_path : null),
        cell_metadata_path: params.mecr_cell_metadata_path ?: (whb ? params.mecr_whb_cell_metadata_path : null),
        taxonomy_metadata_path: params.mecr_taxonomy_metadata_path ?: (whb ? params.mecr_whb_taxonomy_metadata_path : null),
        cluster_membership_path: params.mecr_cluster_membership_path ?: (whb ? params.mecr_whb_cluster_membership_path : null),
        reference_cache_dir: params.mecr_reference_cache_dir == null ? file(params.outdir).toAbsolutePath().resolve("mapmycells_cache") : params.mecr_reference_cache_dir,
    ].collectEntries { field, value -> [(field): value == null ? null : value.toString()] }
    inputs.reference_h5ad_paths = h5adPaths
    return inputs
}

process MECR_REFERENCE {
    tag "${reference_atlas.toUpperCase()}"

    publishDir { "${params.outdir}/mecr_reference" }, mode: "copy", overwrite: true

    input:
    tuple val(reference_atlas),
        val(samples_json)
    // mecrReferenceInputs() as staged by main.nf: local names plus the files
    tuple val(reference_inputs), path(reference_files, stageAs: "inputs/??/*")

    output:
    path("mecr_reference_out")

    script:
    def taxonomyLevel = params.mecr_taxonomy_level == null ? null : params.mecr_taxonomy_level.toString()
    def targetClasses = params.mecr_target_broad_classes ?: []
    """
    set -euo pipefail
    export OMP_NUM_THREADS="${task.cpus}"
    export OPENBLAS_NUM_THREADS="${task.cpus}"
    export MKL_NUM_THREADS="${task.cpus}"
    export NUMEXPR_NUM_THREADS="${task.cpus}"

    cat > mecr_reference_config.json <<JSON
{
  "output_dir": "mecr_reference_out",
  "samples": ${samples_json},
  "reference_atlas": ${groovy.json.JsonOutput.toJson(reference_atlas)},
  "reference_h5ad_paths": ${groovy.json.JsonOutput.toJson(reference_inputs.reference_h5ad_paths)},
  "neurons_h5ad_path": ${groovy.json.JsonOutput.toJson(reference_inputs.neurons_h5ad_path)},
  "nonneurons_h5ad_path": ${groovy.json.JsonOutput.toJson(reference_inputs.nonneurons_h5ad_path)},
  "cell_metadata_path": ${groovy.json.JsonOutput.toJson(reference_inputs.cell_metadata_path)},
  "taxonomy_metadata_path": ${groovy.json.JsonOutput.toJson(reference_inputs.taxonomy_metadata_path)},
  "cluster_membership_path": ${groovy.json.JsonOutput.toJson(reference_inputs.cluster_membership_path)},
  "reference_cache_dir": ${groovy.json.JsonOutput.toJson(reference_inputs.reference_cache_dir)},
  "auto_download_reference": ${params.mecr_auto_download_reference},
  "taxonomy_level": ${groovy.json.JsonOutput.toJson(taxonomyLevel)},
  "gene_symbol_column": "${params.mecr_gene_symbol_column}",
  "target_broad_classes": ${groovy.json.JsonOutput.toJson(targetClasses)},
  "marker_min_target_fraction": ${params.mecr_marker_min_target_fraction},
  "marker_max_other_fraction": ${params.mecr_marker_max_other_fraction},
  "normalize_target_sum": ${params.mecr_normalize_target_sum},
  "reference_chunk_rows": ${params.mecr_reference_chunk_rows},
  "wilcoxon_tie_correct": ${params.mecr_wilcoxon_tie_correct},
  "figure_dpi": ${params.mecr_figure_dpi}
}
JSON

    merxen mecr-reference --config mecr_reference_config.json
    """
}


process MECR {
    tag "${pair_id}:${segmentation}"

    publishDir { "${params.outdir}/${pair_id}/${segmentation}/mecr" }, mode: "copy", overwrite: true

    input:
    tuple val(pair_id),
        val(segmentation),
        val(samples_json),
        path(reference_out)

    output:
    tuple val(pair_id),
        val(segmentation),
        path("mecr_out")

    script:
    """
    set -euo pipefail
    export OMP_NUM_THREADS="${task.cpus}"
    export OPENBLAS_NUM_THREADS="${task.cpus}"
    export MKL_NUM_THREADS="${task.cpus}"
    export NUMEXPR_NUM_THREADS="${task.cpus}"

    cat > mecr_config.json <<JSON
{
  "pair_id": "${pair_id}",
  "segmentation": "${segmentation}",
  "output_dir": "mecr_out",
  "samples": ${samples_json},
  "reference_markers_path": "${reference_out}/mecr_reference_markers.csv",
  "figure_dpi": ${params.mecr_figure_dpi},
  "barnyard_top_n_pairs": ${params.mecr_barnyard_top_n_pairs},
  "barnyard_max_points": ${params.mecr_barnyard_max_points},
  "barnyard_random_seed": ${params.mecr_barnyard_random_seed},
  "barnyard_log1p": ${params.mecr_barnyard_log1p}
}
JSON

    merxen mecr --config mecr_config.json
    """
}
