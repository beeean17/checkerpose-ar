"""
README implementation summary:
1. Flutter `camera` provides the live preview and the Y plane from `startImageStream`.
2. Android forwards those frames to this module through Chaquopy.
3. `calibrate_camera` follows the reference chessboard calibration flow and returns K/dist.
4. `get_ar_pose` follows the reference pose-estimation flow, then projects a vertical image plane
   so Flutter can paint a textured AR poster instead of a wireframe cube.

README demo video tips:
1. Lock the phone in portrait and keep the whole chessboard visible when collecting samples.
2. Capture 8 to 15 frames from different distances and tilt angles, not near-duplicates.
3. During the AR demo, keep the board filling roughly 60 percent of the preview for stability.
4. Record once with the telemetry visible so the `tvec` values prove real-time pose estimation.
"""

from __future__ import annotations

import json
from typing import Any

import cv2 as cv
import numpy as np


BOARD_FLAGS = (
    cv.CALIB_CB_ADAPTIVE_THRESH
    + cv.CALIB_CB_NORMALIZE_IMAGE
    + cv.CALIB_CB_FAST_CHECK
)


def calibrate_camera(
    image_list: Any,
    board_cols: int = 10,
    board_rows: int = 7,
    square_size_mm: float = 25.0,
    resize_scale: float = 0.5,
) -> str:
    image_list = _to_python(image_list)
    _validate_board_geometry(board_cols, board_rows, square_size_mm)
    if not isinstance(image_list, list):
        raise ValueError("Calibration images must be provided as a list.")

    board_pattern = (int(board_cols), int(board_rows))
    board_cellsize = float(square_size_mm)
    obj_template = _board_object_points(board_pattern, board_cellsize)

    img_points: list[np.ndarray] = []
    obj_points: list[np.ndarray] = []
    gray_size: tuple[int, int] | None = None

    for sample in image_list:
        gray = _decode_gray_frame(sample, resize_scale)
        complete, pts = _find_chessboard(gray, board_pattern)
        if complete:
            img_points.append(pts)
            obj_points.append(obj_template.copy())
            gray_size = gray.shape[::-1]

    if len(img_points) < 3 or gray_size is None:
        raise ValueError("At least 3 valid chessboard frames are required for calibration.")

    rms, K, dist_coeffs, _, _ = cv.calibrateCamera(
        obj_points,
        img_points,
        gray_size,
        None,
        None,
    )

    return json.dumps({
        "rms": float(rms),
        "usedImages": len(img_points),
        "boardCols": int(board_cols),
        "boardRows": int(board_rows),
        "squareSizeMm": float(square_size_mm),
        "imageWidth": int(gray_size[0]),
        "imageHeight": int(gray_size[1]),
        "K": K.reshape(-1).tolist(),
        "dist": dist_coeffs.reshape(-1).tolist(),
    })


def get_ar_pose(
    frame: Any,
    K: Any,
    dist: Any,
    board_cols: int = 10,
    board_rows: int = 7,
    square_size_mm: float = 25.0,
    resize_scale: float = 0.5,
) -> str:
    frame = _to_python(frame)
    K = _to_python(K)
    dist = _to_python(dist)
    _validate_board_geometry(board_cols, board_rows, square_size_mm)
    if not isinstance(frame, dict):
        raise ValueError("Frame payload must be a map.")
    if not isinstance(K, list) or len(K) != 9:
        raise ValueError("Calibration K must contain exactly 9 values.")
    if not isinstance(dist, list) or len(dist) < 4:
        raise ValueError("Calibration dist must contain at least 4 values.")

    board_pattern = (int(board_cols), int(board_rows))
    board_cellsize = float(square_size_mm)
    gray = _decode_gray_frame(frame, resize_scale)

    complete, img_points = _find_chessboard(gray, board_pattern)
    if not complete:
        return json.dumps({
            "found": False,
            "message": "Chessboard not found.",
        })

    object_points = _board_object_points(board_pattern, board_cellsize)
    camera_matrix = np.asarray(K, dtype=np.float64).reshape(3, 3)
    dist_coeffs = np.asarray(dist, dtype=np.float64).reshape(-1, 1)

    solved, rvec, tvec = cv.solvePnP(object_points, img_points, camera_matrix, dist_coeffs)
    if not solved:
        return json.dumps({
            "found": False,
            "message": "solvePnP failed.",
        })

    ar_plane = _standing_image_plane(board_pattern, board_cellsize)
    projected, _ = cv.projectPoints(ar_plane, rvec, tvec, camera_matrix, dist_coeffs)
    quad = projected.reshape(-1, 2)

    R, _ = cv.Rodrigues(rvec)
    camera_position = (-R.T @ tvec).reshape(-1)
    frame_height, frame_width = gray.shape[:2]

    return json.dumps({
        "found": True,
        "message": "Pose tracked.",
        "rvec": rvec.reshape(-1).tolist(),
        "tvec": tvec.reshape(-1).tolist(),
        "cameraPosition": camera_position.tolist(),
        "quad": [
            {
                "x": float(np.clip(point[0] / frame_width, 0.0, 1.0)),
                "y": float(np.clip(point[1] / frame_height, 0.0, 1.0)),
            }
            for point in quad
        ],
    })


def _decode_gray_frame(sample: Any, resize_scale: float) -> np.ndarray:
    sample = _to_python(sample)
    if not isinstance(sample, dict):
        raise ValueError("Each frame sample must be a map.")

    width = int(sample["width"])
    height = int(sample["height"])
    bytes_per_row = int(sample["bytesPerRow"])
    rotation_degrees = int(sample.get("rotationDegrees", 0))
    raw_bytes = sample["bytes"]
    if isinstance(raw_bytes, (bytes, bytearray)):
        buffer = bytes(raw_bytes)
    else:
        # Chaquopy Java byte[] proxy: convert via bytearray for safety.
        buffer = bytes(bytearray(raw_bytes))
    expected_length = height * bytes_per_row
    if len(buffer) < expected_length:
        raise ValueError(
            f"Frame buffer is too short. expected at least {expected_length} bytes, got {len(buffer)}."
        )

    gray = np.frombuffer(buffer, dtype=np.uint8).reshape((height, bytes_per_row))[:, :width]
    gray = _rotate(gray, rotation_degrees)

    if resize_scale != 1.0:
        gray = cv.resize(gray, None, fx=resize_scale, fy=resize_scale, interpolation=cv.INTER_AREA)
    return gray


def _rotate(gray: np.ndarray, rotation_degrees: int) -> np.ndarray:
    rotation = rotation_degrees % 360
    if rotation == 90:
        return cv.rotate(gray, cv.ROTATE_90_CLOCKWISE)
    if rotation == 180:
        return cv.rotate(gray, cv.ROTATE_180)
    if rotation == 270:
        return cv.rotate(gray, cv.ROTATE_90_COUNTERCLOCKWISE)
    return gray


def _find_chessboard(gray: np.ndarray, board_pattern: tuple[int, int]) -> tuple[bool, np.ndarray | None]:
    complete, pts = cv.findChessboardCorners(gray, board_pattern, BOARD_FLAGS)
    if not complete:
        complete, pts = cv.findChessboardCornersSB(gray, board_pattern)
    if not complete or pts is None:
        return False, None

    if pts.dtype != np.float32:
        pts = pts.astype(np.float32)

    criteria = (cv.TERM_CRITERIA_EPS + cv.TERM_CRITERIA_MAX_ITER, 30, 0.001)
    refined = cv.cornerSubPix(gray, pts, (11, 11), (-1, -1), criteria)
    return True, refined


def _validate_board_geometry(board_cols: int, board_rows: int, square_size_mm: float) -> None:
    if int(board_cols) < 2:
        raise ValueError("board_cols must be at least 2.")
    if int(board_rows) < 2:
        raise ValueError("board_rows must be at least 2.")
    if float(square_size_mm) <= 0:
        raise ValueError("square_size_mm must be greater than 0.")


def _to_python(value: Any) -> Any:
    if value is None or isinstance(value, (str, bytes, bytearray, bool, int, float)):
        return value

    if isinstance(value, dict):
        return {
            str(_to_python(key)): _to_python(nested_value)
            for key, nested_value in value.items()
        }

    if isinstance(value, (list, tuple)):
        return [_to_python(item) for item in value]

    # Chaquopy can surface Java Set objects (e.g. from HashMap.keySet()).
    # A Set has toArray() but not size()/get(), so handle it before the Map check.
    if hasattr(value, "toArray") and not hasattr(value, "get"):
        return [_to_python(item) for item in value.toArray()]

    # Chaquopy can also surface Java Map-like objects from Kotlin/Flutter payloads.
    if hasattr(value, "keySet") and hasattr(value, "get"):
        keys = _to_python(value.keySet())
        return {
            str(_to_python(key)): _to_python(value.get(key))
            for key in keys
        }

    # Chaquopy can surface Java ArrayList-like objects which are not normal Python iterables.
    if hasattr(value, "size") and hasattr(value, "get"):
        return [_to_python(value.get(index)) for index in range(int(value.size()))]

    # Fallback: try Java Iterator for any remaining Iterable-like objects.
    if hasattr(value, "iterator"):
        result = []
        it = value.iterator()
        while it.hasNext():
            result.append(_to_python(it.next()))
        return result

    # Chaquopy Java byte[] and other array proxies support len + indexing.
    if hasattr(value, "__len__") and hasattr(value, "__getitem__"):
        try:
            return bytes(value)
        except (TypeError, ValueError, OverflowError):
            return [_to_python(value[i]) for i in range(len(value))]

    return value


def _board_object_points(board_pattern: tuple[int, int], board_cellsize: float) -> np.ndarray:
    obj_pts = [
        [c, r, 0.0]
        for r in range(board_pattern[1])
        for c in range(board_pattern[0])
    ]
    return np.asarray(obj_pts, dtype=np.float32) * board_cellsize


def _standing_image_plane(board_pattern: tuple[int, int], board_cellsize: float) -> np.ndarray:
    board_width = max(board_pattern[0] - 1, 1) * board_cellsize
    board_height = max(board_pattern[1] - 1, 1) * board_cellsize
    plane_width = min(board_width * 0.55, board_cellsize * 4.0)
    plane_height = min(board_height * 1.1, board_cellsize * 6.0)
    origin_x = max((board_width - plane_width) * 0.5, 0.0)
    origin_y = max(board_height * 0.55, board_cellsize)

    # The bottom edge sits on the board plane, and the top edge uses the negative Z axis
    # so the image looks like a vertical billboard.
    return np.asarray(
        [
            [origin_x, origin_y, 0.0],
            [origin_x + plane_width, origin_y, 0.0],
            [origin_x + plane_width, origin_y, -plane_height],
            [origin_x, origin_y, -plane_height],
        ],
        dtype=np.float32,
    )
