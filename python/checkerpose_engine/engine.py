from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import cv2 as cv
import numpy as np


@dataclass(frozen=True)
class BoardSpec:
    board_rows: int
    board_cols: int
    square_size_mm: float


@dataclass(frozen=True)
class Calibration:
    camera_matrix: np.ndarray
    dist_coeffs: np.ndarray
    image_size: tuple[int, int] | None = None
    distortion_model: str | None = None

    def scaled_to(self, frame_width: int, frame_height: int) -> "Calibration":
        if not self.image_size:
            return self

        source_width, source_height = self.image_size
        if source_width <= 0 or source_height <= 0:
            return self

        scale_x = frame_width / float(source_width)
        scale_y = frame_height / float(source_height)

        scaled = self.camera_matrix.copy()
        scaled[0, 0] *= scale_x
        scaled[0, 2] *= scale_x
        scaled[1, 1] *= scale_y
        scaled[1, 2] *= scale_y
        return Calibration(
            camera_matrix=scaled,
            dist_coeffs=self.dist_coeffs.copy(),
            image_size=(frame_width, frame_height),
            distortion_model=self.distortion_model,
        )


@dataclass(frozen=True)
class PoseResult:
    rvec: np.ndarray
    tvec: np.ndarray
    reprojection_error: float
    corners_found: bool
    timestamp_ms: int


@dataclass(frozen=True)
class LinePrimitive:
    start: tuple[float, float]
    end: tuple[float, float]
    color: tuple[int, int, int]
    thickness: int


@dataclass(frozen=True)
class LabelPrimitive:
    text: str
    anchor: tuple[float, float]
    color: tuple[int, int, int]


@dataclass(frozen=True)
class OverlayPrimitives:
    lines: list[LinePrimitive]
    polygons: list[list[tuple[float, float]]]
    labels: list[LabelPrimitive]


def load_calibration(path: str | Path) -> Calibration:
    with Path(path).open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    camera_matrix = np.asarray(payload.get("camera_matrix") or payload.get("K"), dtype=np.float64)
    dist_coeffs = np.asarray(
        payload.get("dist_coeffs") or payload.get("dist_coef"),
        dtype=np.float64,
    ).reshape(-1)
    if camera_matrix.size != 9:
        raise ValueError("Calibration JSON must include a 3x3 camera matrix.")

    image_size = None
    if isinstance(payload.get("image_size"), dict):
        image_size = (
            int(payload["image_size"].get("width", 0)),
            int(payload["image_size"].get("height", 0)),
        )
    elif payload.get("image_width") and payload.get("image_height"):
        image_size = (int(payload["image_width"]), int(payload["image_height"]))

    distortion_model = None
    if isinstance(payload.get("score_best_model"), dict):
        distortion_model = payload["score_best_model"].get("dist_model")

    return Calibration(
        camera_matrix=camera_matrix.reshape(3, 3),
        dist_coeffs=dist_coeffs,
        image_size=image_size,
        distortion_model=distortion_model,
    )


def estimate_pose(
    frame_bgr: np.ndarray,
    board_spec: BoardSpec,
    calibration: Calibration,
) -> PoseResult | None:
    gray = cv.cvtColor(frame_bgr, cv.COLOR_BGR2GRAY)
    pattern_size = (board_spec.board_cols, board_spec.board_rows)

    found, corners = cv.findChessboardCorners(
        gray,
        pattern_size,
        flags=cv.CALIB_CB_ADAPTIVE_THRESH
        | cv.CALIB_CB_NORMALIZE_IMAGE
        | cv.CALIB_CB_FAST_CHECK,
    )
    if not found:
        found, corners = cv.findChessboardCornersSB(gray, pattern_size)
    if not found or corners is None:
        return None

    criteria = (cv.TERM_CRITERIA_EPS + cv.TERM_CRITERIA_MAX_ITER, 30, 0.001)
    corners = cv.cornerSubPix(gray, corners, (11, 11), (-1, -1), criteria)

    object_points = _board_object_points(board_spec)
    scaled_calibration = calibration.scaled_to(frame_bgr.shape[1], frame_bgr.shape[0])
    solved, rvec, tvec = cv.solvePnP(
        object_points,
        corners,
        scaled_calibration.camera_matrix,
        scaled_calibration.dist_coeffs,
    )
    if not solved:
        return None

    reprojected, _ = cv.projectPoints(
        object_points,
        rvec,
        tvec,
        scaled_calibration.camera_matrix,
        scaled_calibration.dist_coeffs,
    )
    reprojection_error = float(
        np.sqrt(np.mean(np.sum((reprojected.reshape(-1, 2) - corners.reshape(-1, 2)) ** 2, axis=1)))
    )

    return PoseResult(
        rvec=rvec.reshape(3),
        tvec=tvec.reshape(3),
        reprojection_error=reprojection_error,
        corners_found=True,
        timestamp_ms=int(time.time() * 1000),
    )


def project_object(
    pose: PoseResult,
    calibration: Calibration,
    object_spec: BoardSpec | None = None,
) -> OverlayPrimitives:
    if object_spec is None:
        object_spec = BoardSpec(board_rows=7, board_cols=10, square_size_mm=25.0)

    points_3d, edges, polygons, labels = _custom_object_geometry(object_spec.square_size_mm)
    image_points, _ = cv.projectPoints(
        np.asarray(points_3d, dtype=np.float32),
        pose.rvec.reshape(3, 1),
        pose.tvec.reshape(3, 1),
        calibration.camera_matrix,
        calibration.dist_coeffs,
    )
    points_2d = image_points.reshape(-1, 2)

    lines = [
        LinePrimitive(
            start=tuple(points_2d[start_index]),
            end=tuple(points_2d[end_index]),
            color=(80, 225, 190) if start_index < 8 else (248, 203, 88),
            thickness=4 if start_index < 8 else 3,
        )
        for start_index, end_index in edges
    ]
    polygon_points = [
        [tuple(points_2d[index]) for index in polygon]
        for polygon in polygons
    ]
    label_primitives = [
        LabelPrimitive(
            text=text,
            anchor=tuple(points_2d[index] + np.asarray(offset, dtype=np.float32)),
            color=(245, 245, 245),
        )
        for text, index, offset in labels
    ]
    return OverlayPrimitives(lines=lines, polygons=polygon_points, labels=label_primitives)


def draw_overlay(frame_bgr: np.ndarray, overlay: OverlayPrimitives) -> np.ndarray:
    canvas = frame_bgr.copy()
    for polygon in overlay.polygons:
        if len(polygon) >= 3:
            pts = np.asarray(polygon, dtype=np.int32).reshape(-1, 1, 2)
            cv.polylines(canvas, [pts], isClosed=True, color=(70, 200, 180), thickness=2)

    for line in overlay.lines:
        cv.line(
            canvas,
            tuple(int(value) for value in line.start),
            tuple(int(value) for value in line.end),
            line.color,
            line.thickness,
            lineType=cv.LINE_AA,
        )

    for label in overlay.labels:
        cv.putText(
            canvas,
            label.text,
            tuple(int(value) for value in label.anchor),
            cv.FONT_HERSHEY_DUPLEX,
            0.8,
            label.color,
            2,
            lineType=cv.LINE_AA,
        )

    return canvas


def overlay_to_dict(overlay: OverlayPrimitives) -> dict[str, object]:
    return {
        "lines": [
            {
                "start": list(line.start),
                "end": list(line.end),
                "color": list(line.color),
                "thickness": line.thickness,
            }
            for line in overlay.lines
        ],
        "polygons": [[list(point) for point in polygon] for polygon in overlay.polygons],
        "labels": [
            {
                "text": label.text,
                "anchor": list(label.anchor),
                "color": list(label.color),
            }
            for label in overlay.labels
        ],
    }


def _board_object_points(board_spec: BoardSpec) -> np.ndarray:
    obj_points = [
        [col * board_spec.square_size_mm, row * board_spec.square_size_mm, 0.0]
        for row in range(board_spec.board_rows)
        for col in range(board_spec.board_cols)
    ]
    return np.asarray(obj_points, dtype=np.float32)


def _custom_object_geometry(square_size_mm: float) -> tuple[list[list[float]], list[tuple[int, int]], list[list[int]], list[tuple[str, int, tuple[float, float]]]]:
    unit = square_size_mm
    points = [
        [0.0, 0.0, 0.0],
        [2.0 * unit, 0.0, 0.0],
        [2.0 * unit, 2.0 * unit, 0.0],
        [0.0, 2.0 * unit, 0.0],
        [0.0, 0.0, -2.0 * unit],
        [2.0 * unit, 0.0, -2.0 * unit],
        [2.0 * unit, 2.0 * unit, -2.0 * unit],
        [0.0, 2.0 * unit, -2.0 * unit],
        [3.0 * unit, 0.5 * unit, 0.0],
        [4.0 * unit, 0.5 * unit, 0.0],
        [3.5 * unit, 0.5 * unit, -3.0 * unit],
        [4.8 * unit, 1.6 * unit, -1.0 * unit],
        [5.8 * unit, 2.8 * unit, -1.0 * unit],
        [5.4 * unit, 1.9 * unit, -1.0 * unit],
        [6.4 * unit, 0.8 * unit, -1.0 * unit],
    ]
    edges = [
        (0, 1),
        (1, 2),
        (2, 3),
        (3, 0),
        (4, 5),
        (5, 6),
        (6, 7),
        (7, 4),
        (0, 4),
        (1, 5),
        (2, 6),
        (3, 7),
        (8, 10),
        (9, 10),
        (11, 12),
        (13, 14),
    ]
    polygons = [[0, 1, 2, 3], [4, 5, 6, 7]]
    labels = [("CheckerPose", 6, (10.0, -10.0))]
    return points, edges, polygons, labels
