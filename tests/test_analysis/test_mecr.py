"""Tests for paper-standard mutually exclusive co-expression rate analysis."""

from __future__ import annotations

import json
from pathlib import Path

import anndata as ad
import numpy as np
import pandas as pd
import pytest
from click.testing import CliRunner
from scipy import sparse

from merxen.analysis.mecr import (
    build_mecr_count_table,
    compute_mecr_pair_metrics,
    discover_markers_from_count_table,
    discover_reference_markers,
    load_atlas_broad_classes,
    load_atlas_panel_reference,
    load_whb_panel_reference,
    plot_class_pair_mecr_heatmaps,
    plot_platform_mecr_comparison,
    plot_reference_mecr_histogram,
    read_mecr_count_table,
    run_mecr,
    run_mecr_reference,
    select_barnyard_pairs,
    summarize_mecr_pair_metrics,
)
from merxen.cli.run_mecr import mecr_count_table_command
from merxen.config import MecrConfig, MecrReferenceConfig, MecrSampleConfig


def test_compute_mecr_pair_metrics_uses_binary_intersection_over_union() -> None:
    """Each cross-class pair should use detected-both divided by detected-either."""
    adata = ad.AnnData(
        X=sparse.csr_matrix(
            np.array(
                [
                    [3, 2, 0],
                    [1, 0, 0],
                    [0, 4, 0],
                    [0, 0, 0],
                ]
            )
        ),
        var=pd.DataFrame(index=["GeneA", "GeneB", "GeneC"]),
    )
    markers = pd.DataFrame(
        {
            "gene": ["GeneA", "GeneB", "GeneC"],
            "broad_class": ["Astrocytes", "Neurons", "Astrocytes"],
        }
    )

    result = compute_mecr_pair_metrics(adata, markers)

    assert len(result) == 2
    gene_a_pair = result[
        (result["gene_1"] == "GeneA") & (result["gene_2"] == "GeneB")
    ].iloc[0]
    assert gene_a_pair["cells_gene_1"] == 2
    assert gene_a_pair["cells_gene_2"] == 2
    assert gene_a_pair["cells_both"] == 1
    assert gene_a_pair["cells_either"] == 3
    assert gene_a_pair["mecr"] == pytest.approx(1 / 3)
    assert not ((result["gene_1"] == "GeneA") & (result["gene_2"] == "GeneC")).any()


def test_compute_mecr_pair_metrics_records_zero_union_as_nan() -> None:
    """Pairs with neither marker detected should remain auditable but unscored."""
    adata = ad.AnnData(
        X=sparse.csr_matrix((3, 2), dtype=np.int64),
        var=pd.DataFrame(index=["GeneA", "GeneB"]),
    )
    markers = pd.DataFrame(
        {
            "gene": ["GeneA", "GeneB"],
            "broad_class": ["Astrocytes", "Neurons"],
        }
    )

    result = compute_mecr_pair_metrics(adata, markers)
    summary = summarize_mecr_pair_metrics(
        result,
        sample_id="sample",
        platform="XENIUM",
        segmentation="reseg",
        n_cells=3,
        n_panel_genes=2,
        n_reference_markers=2,
    )

    assert len(result) == 1
    assert result.iloc[0]["cells_either"] == 0
    assert np.isnan(result.iloc[0]["mecr"])
    assert summary["mecr"] is None
    assert summary["n_zero_union_pairs"] == 1


def test_run_mecr_writes_platform_and_combined_outputs(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The stage entry point should produce its complete reporting contract."""
    markers_path = tmp_path / "markers.csv"
    pd.DataFrame(
        {
            "gene": ["GeneA", "GeneB"],
            "broad_class": ["Astrocytes", "Neurons"],
        }
    ).to_csv(markers_path, index=False)
    adata = ad.AnnData(
        X=sparse.csr_matrix([[1, 1], [1, 0], [0, 1]]),
        var=pd.DataFrame(index=["GeneA", "GeneB"]),
    )
    monkeypatch.setattr(
        "merxen.analysis.mecr.load_spatial_count_table",
        lambda _sample: adata.copy(),
    )
    config = MecrConfig(
        pair_id="PAIR1",
        segmentation="reseg",
        output_dir=tmp_path / "out",
        samples=[
            MecrSampleConfig(
                sample_id="PAIR1_XENIUM",
                platform="XENIUM",
                zarr_path=tmp_path / "unused.zarr",
            )
        ],
        reference_markers_path=markers_path,
    )

    outputs = run_mecr(config)

    assert all(path.exists() for path in outputs.values())
    summary = pd.read_csv(outputs["combined_summary_csv"]).iloc[0]
    assert summary["mecr"] == pytest.approx(1 / 3)
    assert summary["n_scored_pairs"] == 1
    pairs = pd.read_csv(outputs["combined_pairs_csv"])
    assert pairs.loc[0, "cells_either"] == 3
    assert outputs["distribution_plot"].with_suffix(".pdf").exists()


def test_select_barnyard_pairs_combines_selection_strategies() -> None:
    """Barnyard selection should cover canonical, high-rate, and detected pairs."""
    pair_metrics = pd.DataFrame(
        {
            "gene_1": ["SLC17A7", "GeneA", "GeneC"],
            "class_1": ["Neurons", "Astrocytes", "Fibroblasts"],
            "gene_2": ["GFAP", "GeneB", "GeneD"],
            "class_2": ["Astrocytes", "Microglia", "Vascular cells"],
            "mecr": [0.1, 0.9, 0.2],
            "cells_either": [50, 2, 1_000],
        }
    )

    selected = select_barnyard_pairs(pair_metrics, top_n=3)

    assert set(zip(selected["gene_1"], selected["gene_2"], strict=True)) == {
        ("SLC17A7", "GFAP"),
        ("GeneA", "GeneB"),
        ("GeneC", "GeneD"),
    }
    reasons = selected.set_index("gene_1")["selection_reason"]
    assert "canonical" in reasons["SLC17A7"]
    assert "highest_mean_mecr" in reasons["GeneA"]
    assert "most_detected" in reasons["GeneC"]


def test_mecr_summary_plots_write_png_and_pdf(tmp_path: Path) -> None:
    """Reference, shared-platform, and class-pair plots should be reproducible."""
    rows = []
    for platform, rates in (("MERSCOPE", [0.1, 0.3]), ("XENIUM", [0.2, 0.25])):
        for index, rate in enumerate(rates):
            rows.append(
                {
                    "sample_id": f"sample_{platform}",
                    "platform": platform,
                    "gene_1": f"Gene{index}A",
                    "class_1": "Astrocytes",
                    "gene_2": f"Gene{index}B",
                    "class_2": "Neurons" if index == 0 else "Microglia",
                    "cells_either": 100 + index,
                    "mecr": rate,
                }
            )
    pair_metrics = pd.DataFrame(rows)
    output_paths = [
        plot_reference_mecr_histogram(
            pair_metrics,
            tmp_path / "reference.png",
        ),
        plot_platform_mecr_comparison(
            pair_metrics,
            tmp_path / "platform.png",
            title="Platform comparison",
        ),
        plot_class_pair_mecr_heatmaps(
            pair_metrics,
            tmp_path / "classes.png",
            title="Class-pair comparison",
        ),
    ]

    for path in output_paths:
        assert path.exists()
        assert path.with_suffix(".pdf").exists()


def test_discover_reference_markers_applies_strict_detection_rules() -> None:
    """Markers must pass 25%/1%, and genes qualifying twice must be removed."""
    labels = np.array(["A", "A", "B", "B", *(["C"] * 100)])
    matrix = np.zeros((len(labels), 4), dtype=np.float32)
    matrix[0, 0] = 2.0  # A marker: 50% in A, 0% elsewhere.
    matrix[2, 1] = 2.0  # B marker: 50% in B, 0% elsewhere.
    matrix[4:34, 2] = 2.0  # C marker: 30% in C, 0% elsewhere.
    matrix[0, 3] = 1.0
    matrix[2, 3] = 1.0  # Qualifies for A and B (1/102 in each rest).
    reference = ad.AnnData(
        X=sparse.csr_matrix(matrix),
        obs=pd.DataFrame(
            {"broad_class": pd.Categorical(labels)},
            index=[f"cell_{index}" for index in range(len(labels))],
        ),
        var=pd.DataFrame(index=["GeneA", "GeneB", "GeneC", "Ambiguous"]),
    )

    statistics, markers = discover_reference_markers(
        reference,
        class_key="broad_class",
        target_classes=["A", "B", "C"],
        min_target_fraction=0.25,
        max_other_fraction=0.01,
    )

    assert set(markers["gene"]) == {"GeneA", "GeneB", "GeneC"}
    assert "Ambiguous" not in set(markers["gene"])
    ambiguous = statistics[statistics["gene"] == "Ambiguous"]
    assert ambiguous["qualifying_class_count"].max() == 2
    assert not ambiguous["is_unique_marker"].any()


def test_discover_reference_markers_uses_strict_threshold_boundaries() -> None:
    """Exactly 25% target detection must not pass the paper's >25% rule."""
    labels = np.array([*(["A"] * 4), *(["B"] * 100)])
    matrix = np.zeros((len(labels), 1), dtype=np.float32)
    matrix[0, 0] = 1.0
    reference = ad.AnnData(
        X=sparse.csr_matrix(matrix),
        obs=pd.DataFrame(
            {"broad_class": pd.Categorical(labels)},
            index=[f"cell_{index}" for index in range(len(labels))],
        ),
        var=pd.DataFrame(index=["BoundaryGene"]),
    )

    _, markers = discover_reference_markers(
        reference,
        class_key="broad_class",
        target_classes=["A", "B"],
        min_target_fraction=0.25,
        max_other_fraction=0.01,
    )

    assert markers.empty


def test_load_whb_panel_reference_joins_taxonomy_and_aggregates_symbols(
    tmp_path: Path,
) -> None:
    """WHB cells should be classed through metadata and genes exposed by symbol."""
    var = pd.DataFrame(
        {"gene_symbol": ["GeneA", "GeneB", "GeneB"]},
        index=["ENSG1", "ENSG2", "ENSG3"],
    )
    neurons_path = tmp_path / "neurons.h5ad"
    nonneurons_path = tmp_path / "nonneurons.h5ad"
    ad.AnnData(
        X=sparse.csr_matrix([[2, 0, 0]]),
        obs=pd.DataFrame(index=["neuron_cell"]),
        var=var,
    ).write_h5ad(neurons_path)
    ad.AnnData(
        X=sparse.csr_matrix([[0, 1, 2]]),
        obs=pd.DataFrame(index=["astro_cell"]),
        var=var,
    ).write_h5ad(nonneurons_path)

    cell_metadata_path = tmp_path / "cell_metadata.csv"
    pd.DataFrame(
        {
            "cell_label": ["neuron_cell", "astro_cell"],
            "cluster_alias": ["1", "2"],
        }
    ).to_csv(cell_metadata_path, index=False)
    taxonomy_path = tmp_path / "taxonomy.csv"
    pd.DataFrame(
        {
            "label": ["neuron_label", "astro_label"],
            "name": ["Upper-layer intratelencephalic", "Astrocyte"],
            "cluster_annotation_term_set_label": ["SUPC", "SUPC"],
        }
    ).to_csv(taxonomy_path, index=False)
    membership_path = tmp_path / "membership.csv"
    pd.DataFrame(
        {
            "cluster_annotation_term_label": ["neuron_label", "astro_label"],
            "cluster_annotation_term_set_label": ["SUPC", "SUPC"],
            "cluster_alias": ["1", "2"],
        }
    ).to_csv(membership_path, index=False)
    config = MecrReferenceConfig(
        output_dir=tmp_path / "out",
        samples=[
            MecrSampleConfig(
                sample_id="sample",
                platform="XENIUM",
                zarr_path=tmp_path / "unused.zarr",
            )
        ],
        neurons_h5ad_path=neurons_path,
        nonneurons_h5ad_path=nonneurons_path,
        cell_metadata_path=cell_metadata_path,
        taxonomy_metadata_path=taxonomy_path,
        cluster_membership_path=membership_path,
        taxonomy_level="SUPC",
        target_broad_classes=["Neurons", "Astrocytes"],
        reference_chunk_rows=1,
    )

    result = load_whb_panel_reference(
        config,
        panel_genes=["GeneA", "GeneB", "MissingGene"],
    )

    assert result.shape == (2, 2)
    assert list(result.var_names) == ["GeneA", "GeneB"]
    assert set(result.obs["broad_class"].astype(str)) == {
        "Neurons",
        "Astrocytes",
    }
    dense = result.X.toarray()
    astro_row = np.flatnonzero(
        result.obs["broad_class"].astype(str).to_numpy() == "Astrocytes"
    )[0]
    assert np.count_nonzero(dense[astro_row]) == 1


def test_wmb_reference_defaults_cover_whole_brain_classes(tmp_path: Path) -> None:
    """WMB selection should supply its taxonomy and broad-class defaults."""
    config = MecrReferenceConfig(
        output_dir=tmp_path / "out",
        samples=[
            MecrSampleConfig(
                sample_id="mouse",
                platform="MERSCOPE",
                zarr_path=tmp_path / "unused.zarr",
            )
        ],
        reference_atlas="wmb",
    )

    assert config.taxonomy_level == "CCN20230722_CLAS"
    assert config.target_broad_classes == [
        "Neurons",
        "Astrocytes/Ependymal",
        "Oligodendrocyte lineage",
        "OEC",
        "Vascular cells",
        "Microglia",
    ]


def test_load_wmb_panel_reference_streams_all_expression_shards(
    tmp_path: Path,
) -> None:
    """Generic MECR reference loading should retain cells from every WMB shard."""
    var = pd.DataFrame(
        {"gene_symbol": ["Gnai3", "Slc17a7"]},
        index=["ENSMUSG1", "ENSMUSG2"],
    )
    shard_paths: list[Path] = []
    for index, (cell_labels, values) in enumerate(
        (
            (["glut_cell"], [[1, 3]]),
            (["oec_cell", "unannotated_raw_cell"], [[4, 0], [2, 1]]),
        )
    ):
        shard_path = tmp_path / f"wmb_{index}.h5ad"
        ad.AnnData(
            X=sparse.csr_matrix(values),
            obs=pd.DataFrame(index=cell_labels),
            var=var,
        ).write_h5ad(shard_path)
        shard_paths.append(shard_path)

    cell_metadata_path = tmp_path / "cell_metadata.csv"
    pd.DataFrame(
        {
            "cell_label": ["glut_cell", "oec_cell"],
            "cluster_alias": ["1", "2"],
        }
    ).to_csv(cell_metadata_path, index=False)
    taxonomy_path = tmp_path / "taxonomy.csv"
    pd.DataFrame(
        {
            "label": ["class_glut", "class_oec"],
            "name": ["01 IT-ET Glut", "32 OEC"],
            "cluster_annotation_term_set_label": ["CCN20230722_CLAS"] * 2,
        }
    ).to_csv(taxonomy_path, index=False)
    membership_path = tmp_path / "membership.csv"
    pd.DataFrame(
        {
            "cluster_annotation_term_label": ["class_glut", "class_oec"],
            "cluster_annotation_term_set_label": ["CCN20230722_CLAS"] * 2,
            "cluster_alias": ["1", "2"],
        }
    ).to_csv(membership_path, index=False)
    config = MecrReferenceConfig(
        output_dir=tmp_path / "out",
        samples=[
            MecrSampleConfig(
                sample_id="mouse",
                platform="MERSCOPE",
                zarr_path=tmp_path / "unused.zarr",
            )
        ],
        reference_atlas="wmb",
        reference_h5ad_paths=shard_paths,
        cell_metadata_path=cell_metadata_path,
        taxonomy_metadata_path=taxonomy_path,
        cluster_membership_path=membership_path,
        target_broad_classes=["Neurons", "OEC"],
        reference_chunk_rows=1,
    )

    result = load_atlas_panel_reference(
        config,
        panel_genes=["Gnai3", "Slc17a7"],
    )

    assert result.shape == (2, 2)
    assert set(result.obs["broad_class"].astype(str)) == {"Neurons", "OEC"}
    assert (
        result.uns["merxen_mecr_reference"]["n_raw_cells_without_taxonomy_metadata"]
        == 1
    )


def _write_whb_atlas_fixture(tmp_path: Path) -> MecrReferenceConfig:
    """Write a two-shard WHB-shaped atlas with known markers.

    GeneA is a neuron marker, GeneB (split over two columns) an astrocyte
    marker, GeneC is detected everywhere, and two Splatter cells sit outside
    the target classes.
    """
    var = pd.DataFrame(
        {"gene_symbol": ["GeneA", "GeneB", "GeneB", "GeneC"]},
        index=["ENSG1", "ENSG2", "ENSG3", "ENSG4"],
    )
    neurons = np.array(
        [[1, 0, 0, 1], [2, 0, 0, 1], [1, 0, 0, 1], [3, 0, 0, 1], [0, 0, 0, 1]]
    )
    nonneurons = np.array(
        [
            [0, 1, 0, 1],
            [0, 0, 2, 1],
            [0, 1, 1, 1],
            [0, 0, 1, 0],
            [0, 1, 0, 0],
            [4, 4, 0, 4],
            [1, 0, 0, 0],
        ]
    )
    neuron_cells = [f"neuron_{index}" for index in range(5)]
    nonneuron_cells = [f"astro_{index}" for index in range(5)] + [
        "splatter_0",
        "splatter_1",
    ]
    neurons_path = tmp_path / "neurons.h5ad"
    nonneurons_path = tmp_path / "nonneurons.h5ad"
    ad.AnnData(
        X=sparse.csr_matrix(neurons),
        obs=pd.DataFrame(index=neuron_cells),
        var=var,
    ).write_h5ad(neurons_path)
    ad.AnnData(
        X=sparse.csr_matrix(nonneurons),
        obs=pd.DataFrame(index=nonneuron_cells),
        var=var,
    ).write_h5ad(nonneurons_path)

    aliases = {"neuron": "1", "astro": "2", "splatter": "3"}
    cell_metadata_path = tmp_path / "cell_metadata.csv"
    pd.DataFrame(
        {
            "cell_label": neuron_cells + nonneuron_cells,
            "cluster_alias": [
                aliases[cell.split("_")[0]] for cell in neuron_cells + nonneuron_cells
            ],
        }
    ).to_csv(cell_metadata_path, index=False)
    taxonomy_path = tmp_path / "taxonomy.csv"
    pd.DataFrame(
        {
            "label": ["neuron_label", "astro_label", "splatter_label"],
            "name": ["Upper-layer intratelencephalic", "Astrocyte", "Splatter"],
            "cluster_annotation_term_set_label": ["SUPC", "SUPC", "SUPC"],
        }
    ).to_csv(taxonomy_path, index=False)
    membership_path = tmp_path / "membership.csv"
    pd.DataFrame(
        {
            "cluster_annotation_term_label": [
                "neuron_label",
                "astro_label",
                "splatter_label",
            ],
            "cluster_annotation_term_set_label": ["SUPC", "SUPC", "SUPC"],
            "cluster_alias": ["1", "2", "3"],
        }
    ).to_csv(membership_path, index=False)
    return MecrReferenceConfig(
        output_dir=tmp_path / "out",
        samples=[
            MecrSampleConfig(
                sample_id="sample",
                platform="XENIUM",
                zarr_path=tmp_path / "unused.zarr",
            )
        ],
        neurons_h5ad_path=neurons_path,
        nonneurons_h5ad_path=nonneurons_path,
        cell_metadata_path=cell_metadata_path,
        taxonomy_metadata_path=taxonomy_path,
        cluster_membership_path=membership_path,
        taxonomy_level="SUPC",
        target_broad_classes=["Neurons", "Astrocytes"],
        reference_chunk_rows=2,
    )


def _build_fixture_count_table(
    config: MecrReferenceConfig,
    output_path: Path,
) -> Path:
    assert config.cell_metadata_path is not None
    assert config.taxonomy_metadata_path is not None
    assert config.cluster_membership_path is not None
    assert config.neurons_h5ad_path is not None
    assert config.nonneurons_h5ad_path is not None
    class_by_cell = load_atlas_broad_classes(
        config.cell_metadata_path,
        config.taxonomy_metadata_path,
        config.cluster_membership_path,
        taxonomy_level="SUPC",
        reference_atlas="whb",
    )
    return build_mecr_count_table(
        [config.neurons_h5ad_path, config.nonneurons_h5ad_path],
        class_by_cell,
        output_path,
        reference_atlas="whb",
        taxonomy_level="SUPC",
        chunk_rows=3,
    )


PANEL_GENES = ["GeneA", "geneb", "GeneC", "MissingGene"]


def test_count_table_markers_match_raw_atlas_route(tmp_path: Path) -> None:
    """The count table must reproduce the raw-atlas statistics and markers."""
    config = _write_whb_atlas_fixture(tmp_path)
    reference = load_atlas_panel_reference(config, panel_genes=PANEL_GENES)
    raw_statistics, raw_markers = discover_reference_markers(
        reference,
        class_key="broad_class",
        target_classes=config.target_broad_classes,
    )
    count_table = read_mecr_count_table(
        _build_fixture_count_table(config, tmp_path / "counts.parquet")
    )
    table_statistics, table_markers = discover_markers_from_count_table(
        count_table,
        PANEL_GENES,
        target_classes=config.target_broad_classes,
    )

    compared = [
        "gene",
        "broad_class",
        "target_fraction",
        "other_fraction",
        "n_target_cells",
        "n_other_cells",
        "passes_detection_thresholds",
        "qualifying_class_count",
        "is_unique_marker",
    ]
    pd.testing.assert_frame_equal(
        raw_statistics[compared], table_statistics[compared], check_dtype=False
    )
    pd.testing.assert_frame_equal(
        raw_markers[["gene", "broad_class"]], table_markers[["gene", "broad_class"]]
    )
    assert list(table_markers["gene"]) == ["geneb", "GeneA"]
    assert table_statistics["wilcoxon_score"].isna().all()


def test_build_mecr_count_table_counts_every_class(tmp_path: Path) -> None:
    """Non-target classes are kept and duplicate symbols collapse to one row."""
    config = _write_whb_atlas_fixture(tmp_path)
    count_table = read_mecr_count_table(
        _build_fixture_count_table(config, tmp_path / "counts.parquet")
    )

    assert count_table.class_sizes == {"Astrocytes": 5, "Neurons": 5, "Splatter": 2}
    assert list(count_table.counts["gene_token"]) == ["genea", "geneb", "genec"]
    gene_b = count_table.counts.set_index("gene_token").loc["geneb"]
    assert gene_b["Astrocytes"] == 5
    assert gene_b["Splatter"] == 1
    assert count_table.metadata["taxonomy_level"] == "SUPC"


def test_run_mecr_reference_uses_count_table_without_atlas(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With a count table, the stage needs no raw atlas or metadata inputs."""
    fixture = _write_whb_atlas_fixture(tmp_path)
    table_path = _build_fixture_count_table(fixture, tmp_path / "counts.parquet")
    monkeypatch.setattr(
        "merxen.analysis.mecr.collect_spatial_panel_genes",
        lambda _samples: PANEL_GENES,
    )
    config = MecrReferenceConfig(
        output_dir=tmp_path / "reference_out",
        samples=fixture.samples,
        count_table_path=table_path,
        taxonomy_level="SUPC",
        target_broad_classes=["Neurons", "Astrocytes"],
    )

    outputs = run_mecr_reference(config)

    assert all(path.exists() for path in outputs.values())
    markers = pd.read_csv(outputs["markers_csv"])
    assert list(markers["gene"]) == ["geneb", "GeneA"]
    assert pd.read_csv(outputs["reference_pairs_csv"]).empty
    manifest = json.loads(outputs["manifest"].read_text())
    assert manifest["reference_source"] == "count_table"
    assert manifest["reference_class_counts"] == {"Neurons": 5, "Astrocytes": 5}


def test_run_mecr_reference_rejects_count_table_from_other_taxonomy(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A table built at another taxonomy level must not be used silently."""
    fixture = _write_whb_atlas_fixture(tmp_path)
    table_path = _build_fixture_count_table(fixture, tmp_path / "counts.parquet")
    monkeypatch.setattr(
        "merxen.analysis.mecr.collect_spatial_panel_genes",
        lambda _samples: PANEL_GENES,
    )
    config = MecrReferenceConfig(
        output_dir=tmp_path / "reference_out",
        samples=fixture.samples,
        count_table_path=table_path,
        target_broad_classes=["Neurons", "Astrocytes"],
    )

    with pytest.raises(ValueError, match="taxonomy_level"):
        run_mecr_reference(config)


def test_read_mecr_count_table_rejects_plain_parquet(tmp_path: Path) -> None:
    """Parquet files without MerXen metadata are refused."""
    path = tmp_path / "plain.parquet"
    pd.DataFrame({"gene_token": ["genea"]}).to_parquet(path)

    with pytest.raises(ValueError, match="not a MerXen MECR count table"):
        read_mecr_count_table(path)


def test_mecr_count_table_command_writes_table(tmp_path: Path) -> None:
    """The CLI builds a readable table from atlas files."""
    config = _write_whb_atlas_fixture(tmp_path)
    output_path = tmp_path / "cli_counts.parquet"

    result = CliRunner().invoke(
        mecr_count_table_command,
        [
            "--h5ad",
            str(config.neurons_h5ad_path),
            "--h5ad",
            str(config.nonneurons_h5ad_path),
            "--cell-metadata",
            str(config.cell_metadata_path),
            "--taxonomy-metadata",
            str(config.taxonomy_metadata_path),
            "--cluster-membership",
            str(config.cluster_membership_path),
            "--taxonomy-level",
            "SUPC",
            "--output",
            str(output_path),
        ],
    )

    assert result.exit_code == 0, result.output
    assert read_mecr_count_table(output_path).class_sizes["Neurons"] == 5
