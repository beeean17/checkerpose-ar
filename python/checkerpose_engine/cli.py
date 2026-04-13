from __future__ import annotations

import argparse
from pathlib import Path

import cv2 as cv

from .engine import BoardSpec, draw_overlay, estimate_pose, load_calibration, project_object


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="checkerpose_ar",
        description="Run chessboard camera pose estimation and a custom AR overlay on desktop.",
    )
    parser.add_argument(
        "--calibration",
        default="assets/calibration/sample_results.json",
        help="Path to the Homework #3 calibration JSON.",
    )
    parser.add_argument("--camera", default=0, type=int, help="Camera index for cv.VideoCapture.")
    parser.add_argument("--board-rows", default=7, type=int, help="Chessboard inner-corner rows.")
    parser.add_argument("--board-cols", default=10, type=int, help="Chessboard inner-corner cols.")
    parser.add_argument("--square-size-mm", default=25.0, type=float, help="Square size in millimeters.")
    parser.add_argument(
        "--save-dir",
        default="docs/screenshots",
        help="Directory for saved demo screenshots.",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    calibration = load_calibration(args.calibration)
    board_spec = BoardSpec(
        board_rows=args.board_rows,
        board_cols=args.board_cols,
        square_size_mm=args.square_size_mm,
    )

    capture = cv.VideoCapture(args.camera)
    if not capture.isOpened():
        raise SystemExit(f"Could not open camera index {args.camera}.")

    save_dir = Path(args.save_dir)
    save_dir.mkdir(parents=True, exist_ok=True)

    print("Press q to quit, s to save the current annotated frame.")

    frame_index = 0
    while True:
        ok, frame = capture.read()
        if not ok:
            break

        scaled_calibration = calibration.scaled_to(frame.shape[1], frame.shape[0])
        pose = estimate_pose(frame, board_spec, scaled_calibration)
        annotated = frame

        if pose is not None:
            overlay = project_object(pose, scaled_calibration, board_spec)
            annotated = draw_overlay(frame, overlay)
            cv.putText(
                annotated,
                f"reproj={pose.reprojection_error:.2f}",
                (12, 28),
                cv.FONT_HERSHEY_DUPLEX,
                0.8,
                (245, 245, 245),
                2,
                lineType=cv.LINE_AA,
            )
        else:
            cv.putText(
                annotated,
                "Chessboard not found",
                (12, 28),
                cv.FONT_HERSHEY_DUPLEX,
                0.8,
                (30, 90, 220),
                2,
                lineType=cv.LINE_AA,
            )

        cv.imshow("CheckerPose AR", annotated)
        key = cv.waitKey(1) & 0xFF
        if key == ord("q"):
            break
        if key == ord("s"):
            output = save_dir / f"checkerpose_{frame_index:04d}.png"
            cv.imwrite(str(output), annotated)
            print(f"Saved {output}")
        frame_index += 1

    capture.release()
    cv.destroyAllWindows()
