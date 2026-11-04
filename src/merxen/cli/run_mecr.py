"""CLI commands for mutually exclusive co-expression rate analysis."""

from __future__ import annotations

from pathlib import Path

import click

from merxen.analysis.mecr import (
    build_mecr_count_table,
    load_atlas_broad_classes,
    run_mecr,
    run_mecr_reference,
)
from merxen.config import (
    MECR_DEFAULT_TAXONOMY_LEVELS,
    MecrConfig,
    MecrReferenceConfig,
    load_config_from_json,
)

_EXISTING_FILE = click.Path(path_type=Path, exists=True, dir_okay=False)


@click.command(name="mecr-count-table")
@click.option(
    "--h5ad",
    "h5ad_paths",
    type=_EXISTING_FILE,
    multiple=True,
    required=True,
    help="Raw atlas expression H5AD; repeat for each shard.",
)
@click.option("--cell-metadata", type=_EXISTING_FILE, required=True)
@click.option("--taxonomy-metadata", type=_EXISTING_FILE, required=True)
@click.option("--cluster-membership", type=_EXISTING_FILE, required=True)
@click.option(
    "--reference-atlas",
    type=click.Choice(["whb", "wmb"]),
    default="whb",
    show_default=True,
)
@click.option(
    "--taxonomy-level",
    default=None,
    help="Defaults to the level MECR_REFERENCE uses for the atlas.",
)
@click.option("--gene-symbol-column", default="gene_symbol", show_default=True)
@click.option("--chunk-rows", type=click.IntRange(min=1), default=25_000)
@click.option(
    "--output",
    "output_path",
    type=click.Path(path_type=Path, dir_okay=False),
    required=True,
)
def mecr_count_table_command(
    h5ad_paths: tuple[Path, ...],
    cell_metadata: Path,
    taxonomy_metadata: Path,
    cluster_membership: Path,
    reference_atlas: str,
    taxonomy_level: str | None,
    gene_symbol_column: str,
    chunk_rows: int,
    output_path: Path,
) -> None:
    """Precompute the atlas detection-count table MECR_REFERENCE can reuse."""
    level = taxonomy_level or MECR_DEFAULT_TAXONOMY_LEVELS[reference_atlas]
    class_by_cell = load_atlas_broad_classes(
        cell_metadata,
        taxonomy_metadata,
        cluster_membership,
        taxonomy_level=level,
        reference_atlas=reference_atlas,
    )
    written = build_mecr_count_table(
        list(h5ad_paths),
        class_by_cell,
        output_path,
        reference_atlas=reference_atlas,
        taxonomy_level=level,
        gene_symbol_column=gene_symbol_column,
        chunk_rows=chunk_rows,
    )
    click.echo(f"MECR count table written: {written}")


@click.command(name="mecr-reference")
@click.option(
    "--config",
    "config_path",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    required=True,
    help="Path to JSON config validated against MecrReferenceConfig.",
)
def mecr_reference_command(config_path: Path) -> None:
    """Discover paper-standard whole-brain mutually exclusive marker genes."""
    config = load_config_from_json(config_path, MecrReferenceConfig)
    assert isinstance(config, MecrReferenceConfig)
    outputs = run_mecr_reference(config)
    click.echo("MECR reference preparation complete:")
    for name, path in outputs.items():
        click.echo(f"- {name}: {path}")


@click.command(name="mecr")
@click.option(
    "--config",
    "config_path",
    type=click.Path(path_type=Path, exists=True, dir_okay=False),
    required=True,
    help="Path to JSON config validated against MecrConfig.",
)
def mecr_command(config_path: Path) -> None:
    """Score mutually exclusive co-expression in spatial cell tables."""
    config = load_config_from_json(config_path, MecrConfig)
    assert isinstance(config, MecrConfig)
    outputs = run_mecr(config)
    click.echo("MECR analysis complete:")
    for name, path in outputs.items():
        click.echo(f"- {name}: {path}")
