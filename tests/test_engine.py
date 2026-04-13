from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

import cv2 as cv
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from python.checkerpose_engine.engine import (  # noqa: E402
    BoardSpec,
    Calibration,
    estimate_pose,
    load_calibration,
    overlay_to_dict,
    project_object,
)


class CheckerPoseEngineTests(unittest.TestCase):
    def test_load_calibration_supports_legacy_results(self) -> None:
        payload = {
            "K": [[610.0, 0.0, 320.0], [0.0, 608.0, 240.0], [0.0, 0.0, 1.0]],
            "dist_coef": [0.01, -0.03, 0.0, 0.0, 0.0],
            "score_best_model": {"dist_model": "BC2"},
            "image_size": {"width": 640, "height": 480},
        }
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(payload, handle)
            path = Path(handle.name)

        calibration = load_calibration(path)
        self.assertEqual(calibration.camera_matrix.shape, (3, 3))
        self.assertEqual(calibration.image_size, (640, 480))
        self.assertEqual(calibration.distortion_model, "BC2")

    def test_project_object_returns_overlay_primitives(self) -> None:
        calibration = Calibration(
            camera_matrix=np.array([[640.0, 0.0, 320.0], [0.0, 640.0, 240.0], [0.0, 0.0, 1.0]], dtype=np.float64),
            dist_coeffs=np.zeros(5, dtype=np.float64),
            image_size=(640, 480),
        )
        pose = type(
            "PoseStub",
            (),
            {
                "rvec": np.zeros(3, dtype=np.float64),
                "tvec": np.array([0.0, 0.0, 800.0], dtype=np.float64),
                "reprojection_error": 0.0,
                "corners_found": True,
                "timestamp_ms": 0,
            },
        )()
        overlay = project_object(pose, calibration, BoardSpec(7, 10, 25.0))
        overlay_dict = overlay_to_dict(overlay)
        self.assertGreater(len(overlay.lines), 0)
        self.assertIn("lines", overlay_dict)
        self.assertIn("labels", overlay_dict)

    def test_estimate_pose_on_synthetic_chessboard(self) -> None:
        board_spec = BoardSpec(board_rows=4, board_cols=5, square_size_mm=30.0)
        frame = synthetic_chessboard_image(board_spec.board_cols, board_spec.board_rows, square_px=56)
        calibration = Calibration(
            camera_matrix=np.array([[900.0, 0.0, frame.shape[1] / 2], [0.0, 900.0, frame.shape[0] / 2], [0.0, 0.0, 1.0]], dtype=np.float64),
            dist_coeffs=np.zeros(5, dtype=np.float64),
            image_size=(frame.shape[1], frame.shape[0]),
        )

        pose = estimate_pose(frame, board_spec, calibration)
        self.assertIsNotNone(pose)
        self.assertTrue(pose.corners_found)
        self.assertEqual(pose.rvec.shape, (3,))
        self.assertEqual(pose.tvec.shape, (3,))


def synthetic_chessboard_image(board_cols: int, board_rows: int, square_px: int) -> np.ndarray:
    cols = board_cols + 1
    rows = board_rows + 1
    width = cols * square_px + 80
    height = rows * square_px + 80
    image = np.full((height, width), 255, dtype=np.uint8)

    for row in range(rows):
        for col in range(cols):
            if (row + col) % 2 == 0:
                top = 40 + row * square_px
                left = 40 + col * square_px
                image[top : top + square_px, left : left + square_px] = 0

    return cv.cvtColor(image, cv.COLOR_GRAY2BGR)


if __name__ == "__main__":
    unittest.main()
