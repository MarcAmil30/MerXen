"""Regression checks for the shared production tile operation."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
from scipy.ndimage import label

from merxen.config import CellposeConfig, MaskFilterConfig, MemoryConfig, TilingConfig
from merxen.segmentation import cellpose
from merxen.segmentation.model_identity import CellposeModelIdentity


def test_shared_tile_preserves_input_and_raw_labels() -> None:
    """Prepare the full selected halo once and keep raw labels when filtering."""
    source = np.arange(14 * 15 * 2, dtype=np.uint16).reshape(14, 15, 2)
    boxes = []

    def fetch(y0: int, y1: int, x0: int, x1: int) -> np.ndarray:
        boxes.append((y0, y1, x0, x1))
        return source[y0:y1, x0:x1]

    def evaluate(image: np.ndarray, **kwargs: object) -> tuple:
        del kwargs
        masks = np.zeros(image.shape[:2], np.uint32)
        masks[2:5, 2:5] = 1
        masks[6, 6] = 2
        return masks, [None, None, np.full(masks.shape, 2.5, np.float32)], None

    result = cellpose.run_cellpose_tile(
        fetch,
        {"tile_y0": 1, "tile_y1": 12, "tile_x0": 2, "tile_x1": 14},
        SimpleNamespace(eval=evaluate),
        CellposeConfig(gpu=False),
        MaskFilterConfig(min_area_px=3, n_jobs=1),
    )
    assert boxes == [(1, 12, 2, 14)]
    _, expected_input, _ = cellpose.prepare_cellpose_input(source[1:12, 2:14])
    np.testing.assert_array_equal(result.model_input, expected_input)
    assert set(np.unique(result.raw_masks)) == {0, 1, 2}
    assert set(np.unique(result.filtered_masks)) == {0, 1}
    assert np.all(result.cellprob_logits == 2.5)


def test_tiled_outputs_match_pre_refactor_reference(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Pin real filtering/stitching results captured before extracting hook C7."""
    image = np.arange(28 * 33 * 2, dtype=np.uint16).reshape(28, 33, 2) % 137
    config = CellposeConfig(gpu=False)

    def evaluate(array: np.ndarray, **kwargs: object) -> tuple:
        del kwargs
        masks, _ = label(array[:, :, 0] > 128)
        return masks, [None, None, array[:, :, 1].astype(np.float32) / 13], None

    monkeypatch.setattr(
        cellpose, "build_cellpose_model", lambda _: SimpleNamespace(eval=evaluate)
    )
    monkeypatch.setattr(
        cellpose,
        "identify_cellpose_model",
        lambda *_: CellposeModelIdentity(
            status="verified",
            model_name="cpsam_v2",
            weights_sha256="0" * 64,
            cellpose_version="4.2.1.1",
            torch_version="2.14.0+cu130",
            cellpose_config=config,
        ),
    )
    monkeypatch.setattr(cellpose, "choose_working_tile_size", lambda **_: 12)
    monkeypatch.setattr(cellpose, "clear_cuda_cache", lambda: None)
    monkeypatch.setattr(cellpose, "force_release", lambda **_: None)
    monkeypatch.setattr(cellpose, "enforce_memory_limit", lambda **_: None)
    mask_path = tmp_path / "cellpose_masks_tiled.npy"
    probs_path = tmp_path / "logits.npy"
    stats_path = tmp_path / "stats.json"
    cellpose.run_tiled_cellpose(
        lambda y0, y1, x0, x1: image[y0:y1, x0:x1],
        28,
        33,
        "reference",
        mask_path,
        config,
        MaskFilterConfig(n_jobs=1, min_area_px=3, max_eccentricity=1.0),
        TilingConfig(tile_size_candidates=[12], min_tile_size=12, stitch_overlap_px=2),
        MemoryConfig(),
        output_stitching_stats_path=stats_path,
        output_cellprob_path=probs_path,
    )
    stats = json.loads(stats_path.read_text())
    stats.pop("model_identity")
    assert np.any(np.load(mask_path))
    assert np.any(np.load(probs_path))
    actual = {
        "mask": hashlib.sha256(np.load(mask_path).tobytes()).hexdigest(),
        "logits": hashlib.sha256(np.load(probs_path).tobytes()).hexdigest(),
        "stats": hashlib.sha256(json.dumps(stats, sort_keys=True).encode()).hexdigest(),
    }
    # Mask and logits captured on HITL-0 (85942c1), before the C7 tile-body
    # extraction, and unchanged since: the empty-tile skip is inert on an image
    # with signal everywhere. The stats hash was re-pinned when the stitching
    # stats gained "empty_tiles_skipped".
    assert actual == {
        "mask": "6fc4dcd62aa278c3316f42f86a14c09401208ff0fcab77146cfab34dfc2ae1d4",
        "logits": "c42150e4e6a57b58b33be4d00f69dbf8ff7052c63bd5d6b9fd2d082324a0cec9",
        "stats": "aaa6f88dac76562148836893aac7197f219577640ee86abf9996458d65ea46f7",
    }


def test_empty_tiles_skip_cellpose(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Run the model only on the tiles that hold signal.

    A crop that keeps the vendor canvas so micron coordinates stay valid is
    fill value outside its window, so most of the tile grid is zero. Cellpose
    costs full wall clock on such a tile and finds nothing.
    """
    image = np.zeros((28, 33, 2), dtype=np.uint16)
    image[20:27, 24:32, :] = 200
    config = CellposeConfig(gpu=False)
    evaluated: list[tuple[int, ...]] = []

    def evaluate(array: np.ndarray, **kwargs: object) -> tuple:
        del kwargs
        evaluated.append(array.shape[:2])
        masks, _ = label(array[:, :, 0] > 128)
        return masks, [None, None, array[:, :, 1].astype(np.float32)], None

    monkeypatch.setattr(
        cellpose, "build_cellpose_model", lambda _: SimpleNamespace(eval=evaluate)
    )
    monkeypatch.setattr(
        cellpose,
        "identify_cellpose_model",
        lambda *_: CellposeModelIdentity(
            status="verified",
            model_name="cpsam_v2",
            weights_sha256="0" * 64,
            cellpose_version="4.2.1.1",
            torch_version="2.14.0+cu130",
            cellpose_config=config,
        ),
    )
    monkeypatch.setattr(cellpose, "choose_working_tile_size", lambda **_: 12)
    monkeypatch.setattr(cellpose, "clear_cuda_cache", lambda: None)
    monkeypatch.setattr(cellpose, "force_release", lambda **_: None)
    monkeypatch.setattr(cellpose, "enforce_memory_limit", lambda **_: None)
    mask_path = tmp_path / "cellpose_masks_tiled.npy"
    stats_path = tmp_path / "stats.json"

    cellpose.run_tiled_cellpose(
        lambda y0, y1, x0, x1: image[y0:y1, x0:x1],
        28,
        33,
        "corner_crop",
        mask_path,
        config,
        MaskFilterConfig(n_jobs=1, min_area_px=3, max_eccentricity=1.0),
        TilingConfig(tile_size_candidates=[12], min_tile_size=12, stitch_overlap_px=2),
        MemoryConfig(),
        output_stitching_stats_path=stats_path,
    )

    # 4 core rows x 5 core columns; the signal block reaches 2 rows and 3
    # columns of them, so 6 tiles are segmented and the other 14 are skipped.
    stats = json.loads(stats_path.read_text())
    assert stats["tiles_total"] == 20
    assert stats["empty_tiles_skipped"] == 14
    assert len(evaluated) == 6
    mask = np.load(mask_path)
    assert np.any(mask)
    # Every label sits inside the block of signal.
    assert not np.any(mask[:20, :])
    assert not np.any(mask[:, :24])


def test_empty_tile_skip_is_conservative_about_background() -> None:
    """Treat a tile as empty only when every channel is zero everywhere."""
    assert cellpose.tile_is_empty(np.zeros((4, 4, 2), dtype=np.uint16))
    offset = np.ones((4, 4, 2), dtype=np.uint16)
    assert not cellpose.tile_is_empty(offset)
    one_channel = np.zeros((4, 4, 2), dtype=np.uint16)
    one_channel[2, 2, 1] = 1
    assert not cellpose.tile_is_empty(one_channel)


def test_probe_center_picks_the_first_tile_with_signal() -> None:
    """Probe where the data is, not the geometric center of a corner crop."""
    image = np.zeros((28, 33), dtype=np.uint16)
    image[20:27, 24:32] = 200
    center = cellpose.find_signal_probe_center(
        fetch_tile_fn=lambda y0, y1, x0, x1: image[y0:y1, x0:x1],
        height=28,
        width=33,
        tile_size=12,
        dataset_name="corner_crop",
    )
    # Center of the signal inside the first 12 x 12 grid window holding any,
    # which is rows 12..24 x cols 24..33 -- not the tile's geometric center,
    # which is background.
    assert center == (21, 27)
    cy, cx = center
    assert image[cy, cx] == 200
    assert (
        cellpose.find_signal_probe_center(
            fetch_tile_fn=lambda y0, y1, x0, x1: np.zeros(
                (y1 - y0, x1 - x0), dtype=np.uint16
            ),
            height=28,
            width=33,
            tile_size=12,
            dataset_name="all_empty",
        )
        is None
    )
