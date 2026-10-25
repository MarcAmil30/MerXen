/*
 * The store per platform that the terminal analyses start from.
 *
 * Every writer after mask quantification works on its own hard-linked copy of
 * the store (workflows/bin/merxen-link-copy) and declares it as an output, so
 * no stage writes into another one outputs. This subworkflow follows that
 * chain up to the clustered tables and emits the newest store per platform.
 */

include { CLUSTERING_SQUIDPY_IMPORT } from "../modules/clustering_squidpy"

// Per platform, the store the terminal analyses start from. Alignment and the
// clustered tables each write into their own copy (bin/merxen-link-copy), so
// this follows the chain: mask quantification -> alignment, when the pair is
// aligned -> CLUSTERING_SQUIDPY_IMPORT, when clustered tables are written.
// The import runs once per platform for every segmentation, so the
// segmentations never write one store side by side.
workflow CLUSTERING_TABLES {
    take:
    sample_rows_ch
    downstream_zarrs_ch    // key, pairId, platform, mask-quantification store
    alignment_results_ch   // pairId, MERSCOPE store, Xenium store, transform, coords, align_out
    clustering_results_ch  // pairId, segmentation, samplesJson, clustering_squidpy_out

    main:
    pair_settings_ch = sample_rows_ch.map { pairId, _row, settings -> tuple(pairId, settings) }

    aligned_zarrs_ch = alignment_results_ch
        .map { pairId, merscopeLatest, xeniumLatest, _t, _c, _o ->
            tuple(pairId, merscopeLatest, xeniumLatest)
        }
        .combine(pair_settings_ch, by: 0)
        .filter { _pairId, _m, _x, settings -> settings.need_alignment_results }
        .flatMap { pairId, merscopeLatest, xeniumLatest, _settings ->
            [
                tuple("${pairId}|MERSCOPE", pairId, "MERSCOPE", merscopeLatest.toString()),
                tuple("${pairId}|XENIUM", pairId, "XENIUM", xeniumLatest.toString()),
            ]
        }

    unaligned_zarrs_ch = downstream_zarrs_ch
        .map { key, pairId, platform, zarr -> tuple(pairId, key, platform, zarr) }
        .combine(pair_settings_ch, by: 0)
        .filter { _pairId, _key, _platform, _zarr, settings -> !settings.need_alignment_results }
        .map { pairId, key, platform, zarr, _settings -> tuple(key, pairId, platform, zarr) }

    post_align_zarrs_ch = aligned_zarrs_ch.mix(unaligned_zarrs_ch)

    // one group per pair, holding every segmentation's clustering output
    clustering_groups_ch = clustering_results_ch
        .combine(pair_settings_ch, by: 0)
        .filter { _pairId, _seg, _samplesJson, _outDir, _settings ->
            params.clustering_squidpy_write_spatialdata_table
        }
        .map { pairId, segmentation, samplesJson, outDir, settings ->
            tuple(
                groupKey(pairId, settings.analysis_input_segmentations.size()),
                segmentation,
                samplesJson,
                outDir,
            )
        }
        .groupTuple(remainder: true)
        .flatMap { pairKey, segmentations, samplesJsons, outDirs ->
            def pairId = pairKey.getGroupTarget().toString()
            def samples = new groovy.json.JsonSlurper().parseText(samplesJsons[0].toString())
            samples.collect { sample ->
                def platform = sample.platform.toString()
                def h5ads = outDirs.collect { outDir ->
                    java.nio.file.Paths.get(outDir.toString())
                        .resolve(platform.toLowerCase())
                        .resolve("${sample.sample_id}_clustered.h5ad")
                }
                tuple("${pairId}|${platform}", segmentations, h5ads)
            }
        }

    // key, pairId, platform, store, segmentations, H5ADs
    imported_zarrs_ch = CLUSTERING_SQUIDPY_IMPORT(post_align_zarrs_ch.join(clustering_groups_ch))
        .map { key, pairId, platform, zarr -> tuple(key, pairId, platform, zarr.toString()) }

    not_imported_zarrs_ch = post_align_zarrs_ch
        .map { key, pairId, platform, zarr -> tuple(pairId, key, platform, zarr) }
        .combine(pair_settings_ch, by: 0)
        .filter { _pairId, _key, _platform, _zarr, settings ->
            !(settings.run_clustering_squidpy && params.clustering_squidpy_write_spatialdata_table)
        }
        .map { pairId, key, platform, zarr, _settings -> tuple(key, pairId, platform, zarr) }

    emit:
    imported_zarrs_ch.mix(not_imported_zarrs_ch)
}
