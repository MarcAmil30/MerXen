// Annotation figures: one set per sample, platform and segmentation, drawn
// from MAPMYCELLS (cell names) and MENDER_FINALIZE (tissue domains). Enabled
// with --annotation_figures_enabled; needs both stages in the run.
//
// Writes, under <outdir>/<pair>/<segmentation>/annotation_figures/<platform>/:
//   <sample>_celltypes_markers.png  cells coloured by marker-scored type
//   <sample>_celltypes_allen.png    MapMyCells types on the section + counts
//   <sample>_tissue_domains.png     MENDER domains + size and dominant type
//   <sample>_annotation_summary.json, <sample>_marker_cluster_types.csv

process ANNOTATION_FIGURES {
    tag "${pair_id}:${platform}:${segmentation}"

    publishDir { "${params.outdir}/${pair_id}/${segmentation}/annotation_figures" },
        mode: "copy", overwrite: true

    input:
    tuple val(pair_id),
        val(segmentation),
        val(platform),
        val(sample_id),
        path(mapmycells_dir, stageAs: "mapmycells_in"),
        path(mender_dir, stageAs: "mender_in")

    output:
    tuple val(pair_id), val(segmentation), val(platform), path("annotation_figures/${platform.toLowerCase()}")

    script:
    def platformDir = platform.toLowerCase()
    """
    # whole-brain calls sit at <platform>/; region-only runs nest them deeper
    h5ad="mapmycells_in/${platformDir}/${sample_id}_mapmycells_annotated.h5ad"
    if [ ! -e "\$h5ad" ]; then
        h5ad=\$(find -L mapmycells_in -name "${sample_id}_mapmycells_annotated.h5ad" | sort | head -n 1)
    fi
    cells="mender_in/${sample_id}_mender_cells.parquet"
    [ -e "\$cells" ] || cells=\$(find -L mender_in -name "${sample_id}_mender_cells.parquet" | head -n 1)
    if [ -z "\$h5ad" ] || [ -z "\$cells" ]; then
        echo "ANNOTATION_FIGURES: missing MapMyCells h5ad ('\$h5ad') or MENDER cells ('\$cells') for ${sample_id}" >&2
        exit 1
    fi

    merxen-annotation-figures \\
        --mapmycells-h5ad "\$h5ad" \\
        --mender-cells "\$cells" \\
        --sample "${sample_id}" \\
        --out-dir "annotation_figures/${platformDir}"
    """
}
