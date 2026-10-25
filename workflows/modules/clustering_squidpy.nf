// Reference inputs the clustering broad annotation reads, by config field.
// main.nf stages the files and existing cache directory, then passes the local
// names back in to CLUSTERING_SQUIDPY_PREPARE and _COMPUTE.
def clusteringReferenceInputs() {
    def rawPipelineSpecies = params.species == null ? "human" : params.species.toString().trim().toLowerCase()
    def pipelineSpecies = rawPipelineSpecies in ["mouse", "mus_musculus", "mus musculus"] ? "mouse" : "human"
    def referenceAtlas = params.clustering_squidpy_broad_reference_atlas == null ? (pipelineSpecies == "mouse" ? "wmb" : "whb") : params.clustering_squidpy_broad_reference_atlas.toString().trim().toLowerCase()
    def whb = referenceAtlas == "whb"
    def inputs = [
        marker_lookup_path: params.clustering_squidpy_broad_marker_lookup_path ?: (whb ? params.clustering_squidpy_whb_marker_lookup_path : null),
        taxonomy_metadata_path: params.clustering_squidpy_broad_taxonomy_metadata_path ?: (whb ? params.clustering_squidpy_whb_taxonomy_metadata_path : null),
        cluster_membership_path: params.clustering_squidpy_broad_cluster_membership_path ?: (whb ? params.clustering_squidpy_whb_cluster_membership_path : null),
        reference_cache_dir: params.clustering_squidpy_broad_reference_cache_dir == null ? file(params.outdir).toAbsolutePath().resolve("mapmycells_cache") : params.clustering_squidpy_broad_reference_cache_dir,
    ].collectEntries { field, value -> [(field): value ? value.toString() : null] }
    inputs.reference_gene_metadata_paths = (params.clustering_squidpy_broad_reference_gene_metadata_paths ?: []).collect { path -> path.toString() }
    return inputs
}

process CLUSTERING_SQUIDPY_PREPARE {
    tag "${pair_id}:${segmentation}"

    input:
    tuple val(pair_id),
        val(segmentation),
        val(samples_json),
        path(sample_zarrs, stageAs: "zarrs/??/*")
    // clusteringReferenceInputs() as staged by main.nf
    tuple val(reference_inputs), path(reference_files, stageAs: "inputs/??/*")

    output:
    tuple val(pair_id),
        val(segmentation),
        val(samples_json),
        path("clustering_squidpy_config.json"),
        path("clustering_prepare_out")

    script:
    def rawPipelineSpecies = params.species == null ? "human" : params.species.toString().trim().toLowerCase()
    def pipelineSpecies = rawPipelineSpecies in ["mouse", "mus_musculus", "mus musculus"] ? "mouse" : "human"
    def hierarchicalEnabled = params.clustering_squidpy_hierarchical_enabled == null ? true : params.clustering_squidpy_hierarchical_enabled.toString().trim().toLowerCase() == "true"
    def referenceAtlas = params.clustering_squidpy_broad_reference_atlas == null ? (pipelineSpecies == "mouse" ? "wmb" : "whb") : params.clustering_squidpy_broad_reference_atlas.toString().trim().toLowerCase()
    def markerLevel = params.clustering_squidpy_broad_marker_level == null ? (referenceAtlas == "wmb" ? "CCN20230722_CLAS" : "CCN202210140_SUPC") : params.clustering_squidpy_broad_marker_level.toString()
    def referenceCacheDir = reference_inputs.reference_cache_dir
    def referenceGeneMetadataPaths = reference_inputs.reference_gene_metadata_paths
    def markerLookupPath = reference_inputs.marker_lookup_path
    def taxonomyMetadataPath = reference_inputs.taxonomy_metadata_path
    def clusterMembershipPath = reference_inputs.cluster_membership_path
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

    cat > clustering_squidpy_config.json <<JSON
{
  "pair_id": "${pair_id}",
  "output_dir": "clustering_squidpy_out",
  "samples": ${samples_json},
  "drop_control_features": ${params.clustering_squidpy_drop_control_features},
  "min_counts": ${params.clustering_squidpy_min_counts},
  "min_cells": ${params.clustering_squidpy_min_cells},
  "normalize_target_sum": ${params.clustering_squidpy_normalize_target_sum},
  "normalize_exclude_highly_expressed": ${params.clustering_squidpy_normalize_exclude_highly_expressed},
  "normalize_max_fraction": ${params.clustering_squidpy_normalize_max_fraction},
  "n_pcs": ${params.clustering_squidpy_n_pcs},
  "n_neighbors": ${params.clustering_squidpy_n_neighbors},
  "leiden_resolution": ${params.clustering_squidpy_leiden_resolution},
  "umap_min_dist": ${params.clustering_squidpy_umap_min_dist},
  "umap_spread": ${params.clustering_squidpy_umap_spread},
  "random_seed": ${params.clustering_squidpy_random_seed},
  "spatial_point_size": ${params.clustering_squidpy_spatial_point_size},
  "spatial_scatter_point_size": ${params.clustering_squidpy_spatial_scatter_point_size},
  "figure_dpi": ${params.clustering_squidpy_figure_dpi},
  "use_gpu": ${params.clustering_squidpy_use_gpu},
  "write_spatialdata_table": ${params.clustering_squidpy_write_spatialdata_table},
  "hierarchical_enabled": ${hierarchicalEnabled},
  "broad_round": {
    "leiden_resolution": ${params.clustering_squidpy_broad_leiden_resolution}
  },
  "subcluster_round": {
    "leiden_resolution": ${params.clustering_squidpy_subcluster_leiden_resolution}
  },
  "subcluster_resolution_overrides": ${groovy.json.JsonOutput.toJson(params.clustering_squidpy_subcluster_resolution_overrides ?: [:])},
  "neuron_split_round": {
    "leiden_resolution": ${params.clustering_squidpy_neuron_split_leiden_resolution}
  },
  "neuron_subcluster_round": {
    "leiden_resolution": ${params.clustering_squidpy_neuron_subcluster_leiden_resolution}
  },
  "min_branch_cells": ${params.clustering_squidpy_min_branch_cells},
  "broad_annotation": {
    "reference_atlas": ${groovy.json.JsonOutput.toJson(referenceAtlas)},
    "marker_lookup_path": ${markerLookupPath ? groovy.json.JsonOutput.toJson(markerLookupPath.toString()) : "null"},
    "taxonomy_metadata_path": ${taxonomyMetadataPath ? groovy.json.JsonOutput.toJson(taxonomyMetadataPath.toString()) : "null"},
    "cluster_membership_path": ${clusterMembershipPath ? groovy.json.JsonOutput.toJson(clusterMembershipPath.toString()) : "null"},
    "reference_cache_dir": ${groovy.json.JsonOutput.toJson(referenceCacheDir)},
    "auto_download_reference": ${params.clustering_squidpy_broad_auto_download_reference},
    "reference_gene_metadata_paths": ${groovy.json.JsonOutput.toJson(referenceGeneMetadataPaths)},
    "marker_level": ${groovy.json.JsonOutput.toJson(markerLevel)},
    "min_marker_overlap": ${params.clustering_squidpy_broad_min_marker_overlap},
    "max_markers_per_label": ${params.clustering_squidpy_broad_max_markers_per_label},
    "score_margin_threshold": ${params.clustering_squidpy_broad_score_margin_threshold},
    "unknown_label": ${groovy.json.JsonOutput.toJson(params.clustering_squidpy_broad_unknown_label.toString())}
  }
}
JSON

    python -m merxen.clustering_squidpy_stages prepare \
        --config clustering_squidpy_config.json \
        --output-dir clustering_prepare_out
    """
}

process CLUSTERING_SQUIDPY_COMPUTE {
    tag "${pair_id}:${segmentation}"

    input:
    tuple val(pair_id),
        val(segmentation),
        val(samples_json),
        path(clustering_config),
        path(prepared_dir)
    // same staging as PREPARE, so the config's inputs/<nn>/ names resolve here
    tuple val(_reference_inputs), path(reference_files, stageAs: "inputs/??/*")

    output:
    tuple val(pair_id),
        val(segmentation),
        val(samples_json),
        path("clustering_compute_out")

    script:
    """
    set -euo pipefail
    export PYTHONPATH="${projectDir}/../src:\${PYTHONPATH:-}"
    export OMP_NUM_THREADS="${task.cpus}"
    export OPENBLAS_NUM_THREADS="${task.cpus}"
    export MKL_NUM_THREADS="${task.cpus}"
    export NUMEXPR_NUM_THREADS="${task.cpus}"
    export NUMBA_NUM_THREADS="${task.cpus}"
    export DASK_NUM_WORKERS="${task.cpus}"

    if ${params.clustering_squidpy_gpu_vram_monitor}; then
        mkdir -p clustering_compute_out/gpu_vram
        gpu_vram_stem="${pair_id}_${segmentation}"
        python -m merxen.clustering_squidpy_stages compute \
            --config "${clustering_config}" \
            --input-dir "${prepared_dir}" \
            --output-dir clustering_compute_out &
        clustering_pid=\$!
        python -m merxen.monitoring.gpu_vram \
            --pid "\${clustering_pid}" \
            --interval-seconds ${params.clustering_squidpy_gpu_vram_monitor_interval_seconds} \
            --samples-path "clustering_compute_out/gpu_vram/\${gpu_vram_stem}_samples.tsv" \
            --summary-path "clustering_compute_out/gpu_vram/\${gpu_vram_stem}_summary.json" &
        monitor_pid=\$!

        set +e
        wait "\${clustering_pid}"
        clustering_exit=\$?
        wait "\${monitor_pid}" || true
        set -e
        exit "\${clustering_exit}"
    fi

    python -m merxen.clustering_squidpy_stages compute \
        --config "${clustering_config}" \
        --input-dir "${prepared_dir}" \
        --output-dir clustering_compute_out
    """
}

process CLUSTERING_SQUIDPY_FINALIZE {
    tag "${pair_id}:${segmentation}"

    publishDir { "${params.outdir}/${pair_id}/${segmentation}/clustering_squidpy" }, mode: "copy", overwrite: true

    input:
    tuple val(pair_id),
        val(segmentation),
        val(samples_json),
        path(computed_dir)

    output:
    tuple val(pair_id),
        val(segmentation),
        val(samples_json),
        path("clustering_squidpy_out")

    script:
    // The clustered table goes into the zarr in CLUSTERING_SQUIDPY_IMPORT, once
    // per platform for every segmentation, so the segmentations do not write
    // one store side by side. Finalize writes the same clustered H5AD either way.
    """
    set -euo pipefail
    cat > clustering_finalize_config.json <<JSON
{
  "pair_id": "${pair_id}",
  "output_dir": "clustering_squidpy_out",
  "samples": ${samples_json},
  "write_spatialdata_table": false
}
JSON

    python -m merxen.clustering_squidpy_stages finalize \
        --config clustering_finalize_config.json \
        --input-dir "${computed_dir}" \
        --output-dir clustering_squidpy_out
    """
}


process CLUSTERING_SQUIDPY_IMPORT {
    tag "${pair_id}:${platform}"

    // latest/ follows the newest store in the chain (see bin/merxen-link-copy)
    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/latest" }, mode: "symlink", overwrite: true,
        saveAs: { filename -> filename == "latest_input.zarr" ? "latest_spatialdata.zarr" : null }

    input:
    // one clustered H5AD per segmentation, in the same order as segmentations
    tuple val(key),
        val(pair_id),
        val(platform),
        path(latest_zarr, stageAs: "upstream_latest.zarr"),
        val(segmentations),
        path(clustered_h5ads, stageAs: "clustered/??/*")

    output:
    tuple val(key), val(pair_id), val(platform), path("latest_input.zarr")

    script:
    def h5adList = (clustered_h5ads instanceof List ? clustered_h5ads : [clustered_h5ads])
        .collect { h5ad -> h5ad.toString() }
    def pairsJson = groovy.json.JsonOutput.toJson(
        [segmentations, h5adList].transpose().collect { seg, h5ad -> [seg.toString(), h5ad] }
    )
    """
    set -euo pipefail
    # own copy of the upstream store; see bin/merxen-link-copy
    merxen-link-copy "${latest_zarr}" latest_input.zarr

    python - <<'PY'
import json

import anndata as ad

from merxen.analysis.clustering_squidpy import write_clustered_spatialdata_table

for segmentation, h5ad in json.loads('''${pairsJson}'''):
    _, table_key = write_clustered_spatialdata_table(
        "latest_input.zarr", ad.read_h5ad(h5ad), segmentation=segmentation
    )
    print(f"{segmentation}: wrote {table_key}")
PY
    """
}
