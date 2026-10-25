process MENDER_PREPARE {
    tag "${pair_id}:${platform}:${segmentation}"

    input:
    // the store is staged for reading here only; spatialdata_path stays its
    // location as text for the later stages' tuples, and MENDER_IMPORT
    // writes to its own copy of the newest store
    tuple val(task_key),
        val(pair_id),
        val(segmentation),
        val(platform),
        val(sample_id),
        val(spatialdata_path),
        path(spatialdata_zarr, stageAs: "spatialdata.zarr"),
        val(source_spatialdata_table),
        val(native_shape_key),
        val(source_h5ad_path),
        path(clustered_h5ad, stageAs: "source_clustered.h5ad"),
        val(_terminal_token)

    output:
    tuple val(task_key),
        val(pair_id),
        val(segmentation),
        val(platform),
        val(sample_id),
        val(spatialdata_path),
        val(source_spatialdata_table),
        val(native_shape_key),
        val(source_h5ad_path),
        path("mender_config.json"),
        path("mender_prepare_out")

    script:
    def targetKJson = params.mender_target_k == null ? "null" : (params.mender_target_k as int).toString()
    def cellStateKeyJson = groovy.json.JsonOutput.toJson(params.mender_cell_state_key.toString())
    def missingPolicyJson = groovy.json.JsonOutput.toJson(params.mender_missing_state_policy.toString())
    def nnModeJson = groovy.json.JsonOutput.toJson(params.mender_nn_mode.toString())
    def countRepJson = groovy.json.JsonOutput.toJson(params.mender_count_rep.toString())
    def clusteringModeJson = groovy.json.JsonOutput.toJson(params.mender_clustering_mode.toString())
    def sourceTableJson = groovy.json.JsonOutput.toJson(source_spatialdata_table.toString())
    def nativeShapeJson = groovy.json.JsonOutput.toJson(native_shape_key.toString())
    def spatialdataPathJson = groovy.json.JsonOutput.toJson("spatialdata.zarr")
    def sourceH5adJson = groovy.json.JsonOutput.toJson(clustered_h5ad.toString())
    def sourceH5adOriginJson = groovy.json.JsonOutput.toJson(source_h5ad_path.toString())
    """
    set -euo pipefail
    export PYTHONPATH="${projectDir}/../src:\${PYTHONPATH:-}"
    export OMP_NUM_THREADS="${task.cpus}"
    export OPENBLAS_NUM_THREADS="${task.cpus}"
    export MKL_NUM_THREADS="${task.cpus}"
    export NUMEXPR_NUM_THREADS="${task.cpus}"
    export NUMBA_NUM_THREADS="${task.cpus}"

    cat > mender_config.json <<JSON
{
  "pair_id": "${pair_id}",
  "sample_id": "${sample_id}",
  "platform": "${platform}",
  "segmentation": "${segmentation}",
  "source_h5ad": ${sourceH5adJson},
  "source_h5ad_origin": ${sourceH5adOriginJson},
  "spatialdata_path": ${spatialdataPathJson},
  "source_spatialdata_table": ${sourceTableJson},
  "native_shape_key": ${nativeShapeJson},
  "output_dir": "mender_out",
  "cell_state_key": ${cellStateKeyJson},
  "missing_state_policy": ${missingPolicyJson},
  "nn_mode": ${nnModeJson},
  "radius_um": ${params.mender_radius_um},
  "n_scales": ${params.mender_n_scales},
  "count_rep": ${countRepJson},
  "include_self": ${params.mender_include_self},
  "clustering_mode": ${clusteringModeJson},
  "leiden_resolution": ${params.mender_leiden_resolution},
  "target_k": ${targetKJson},
  "random_seed": ${params.mender_random_seed},
  "run_umap": ${params.mender_run_umap},
  "write_spatialdata_table": ${params.mender_write_spatialdata_table},
  "figure_dpi": ${params.mender_figure_dpi}
}
JSON

    python -m merxen.mender_stages prepare \
        --config mender_config.json \
        --output-dir mender_prepare_out
    """
}

process MENDER_COMPUTE {
    tag "${pair_id}:${platform}:${segmentation}"

    input:
    tuple val(task_key),
        val(pair_id),
        val(segmentation),
        val(platform),
        val(sample_id),
        val(spatialdata_path),
        val(source_spatialdata_table),
        val(native_shape_key),
        val(source_h5ad_path),
        path(mender_config),
        path(prepared_dir)

    output:
    tuple val(task_key),
        val(pair_id),
        val(segmentation),
        val(platform),
        val(sample_id),
        val(spatialdata_path),
        val(source_spatialdata_table),
        val(native_shape_key),
        val(source_h5ad_path),
        path(mender_config),
        path(prepared_dir),
        path("mender_compute_out")

    script:
    """
    set -euo pipefail
    export CUDA_VISIBLE_DEVICES=""
    export PYTHONPATH="${projectDir}/../src:\${PYTHONPATH:-}"
    export OMP_NUM_THREADS="${task.cpus}"
    export OPENBLAS_NUM_THREADS="${task.cpus}"
    export MKL_NUM_THREADS="${task.cpus}"
    export NUMEXPR_NUM_THREADS="${task.cpus}"
    export NUMBA_NUM_THREADS="${task.cpus}"

    python -m merxen.mender_compute \
        --config "${mender_config}" \
        --input-dir "${prepared_dir}" \
        --output-dir mender_compute_out
    """
}

process MENDER_FINALIZE {
    tag "${pair_id}:${platform}:${segmentation}"

    publishDir {
        "${params.outdir}/${pair_id}/${segmentation}/mender"
    }, mode: "copy", overwrite: true, pattern: "mender_out/**"

    input:
    tuple val(task_key),
        val(pair_id),
        val(segmentation),
        val(platform),
        val(sample_id),
        val(spatialdata_path),
        val(source_spatialdata_table),
        val(native_shape_key),
        val(source_h5ad_path),
        path(mender_config),
        path(prepared_dir),
        path(computed_dir),
        path(clustered_h5ad, stageAs: "source_clustered.h5ad")

    output:
    tuple val(task_key),
        val(pair_id),
        val(segmentation),
        val(platform),
        val(sample_id),
        val(spatialdata_path),
        val(source_spatialdata_table),
        val(native_shape_key),
        val(source_h5ad_path),
        path(mender_config),
        path("mender_out/${platform.toLowerCase()}")

    script:
    """
    set -euo pipefail
    export PYTHONPATH="${projectDir}/../src:\${PYTHONPATH:-}"
    export OMP_NUM_THREADS="${task.cpus}"
    export OPENBLAS_NUM_THREADS="${task.cpus}"
    export MKL_NUM_THREADS="${task.cpus}"
    export NUMEXPR_NUM_THREADS="${task.cpus}"
    export NUMBA_NUM_THREADS="${task.cpus}"

    python -m merxen.mender_stages finalize \
        --config "${mender_config}" \
        --source-h5ad "${clustered_h5ad}" \
        --prepared-dir "${prepared_dir}" \
        --computed-dir "${computed_dir}" \
        --output-dir mender_out
    """
}

process MENDER_IMPORT {
    tag "${pair_id}:${platform}"

    // manifests land where the per-segmentation import used to publish them:
    // <segmentation>/mender/mender_out/<platform>/spatialdata_import_manifest.json
    publishDir { "${params.outdir}/${pair_id}" }, mode: "copy", overwrite: true,
        saveAs: { filename -> filename.startsWith("mender_publish/") ? filename.substring("mender_publish/".length()) : null }
    // latest/ follows the newest store in the chain (see bin/merxen-link-copy)
    publishDir { "${params.outdir}/${pair_id}/${platform.toLowerCase()}/latest" }, mode: "symlink", overwrite: true,
        saveAs: { filename -> filename == "latest_input.zarr" ? "latest_spatialdata.zarr" : null }

    input:
    // one MENDER config and finalized folder per segmentation, in the same order
    tuple val(key),
        val(pair_id),
        val(platform),
        path(latest_zarr, stageAs: "upstream_latest.zarr"),
        val(segmentations),
        path(mender_configs, stageAs: "configs/??/*"),
        path(finalized_dirs, stageAs: "finalized/??/*")

    output:
    // the manifests themselves, not their folder, so saveAs sees each one's path
    tuple val(key), val(pair_id), val(platform), path("latest_input.zarr"),
        path("mender_publish/**/spatialdata_import_manifest.json")

    script:
    def jobsJson = groovy.json.JsonOutput.toJson(
        [segmentations, mender_configs, finalized_dirs]
            .collect { value -> (value instanceof List ? value : [value]).collect { item -> item.toString() } }
            .transpose()
    )
    """
    set -euo pipefail
    export PYTHONPATH="${projectDir}/../src:\${PYTHONPATH:-}"
    export OMP_NUM_THREADS="${task.cpus}"
    export OPENBLAS_NUM_THREADS="${task.cpus}"
    export MKL_NUM_THREADS="${task.cpus}"
    export NUMEXPR_NUM_THREADS="${task.cpus}"
    export NUMBA_NUM_THREADS="${task.cpus}"

    # own copy of the upstream store; see bin/merxen-link-copy
    merxen-link-copy "${latest_zarr}" latest_input.zarr

    python - <<'PY'
import json
import subprocess
import sys
from pathlib import Path

for segmentation, config_path, finalized_dir in json.loads('''${jobsJson}'''):
    config = json.loads(Path(config_path).read_text())
    config["spatialdata_path"] = "latest_input.zarr"
    local_config = Path("import_configs") / f"{segmentation}.json"
    local_config.parent.mkdir(exist_ok=True)
    local_config.write_text(json.dumps(config, indent=2))
    out_dir = Path("mender_publish") / segmentation / "mender" / "mender_out" / "${platform.toLowerCase()}"
    subprocess.run(
        [sys.executable, "-m", "merxen.mender_stages", "import",
         "--config", str(local_config), "--finalized-dir", finalized_dir,
         "--output-dir", str(out_dir)],
        check=True,
    )
PY
    """
}
