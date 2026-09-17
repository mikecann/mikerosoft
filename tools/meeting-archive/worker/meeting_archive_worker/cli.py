"""Noninteractive JSON CLI for transfer clients and the Bruce worker service."""

from __future__ import annotations

import argparse
import importlib
import json
import socket
import sys
import threading
import uuid
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .archive import ArchiveConflict, ArchiveStore
from .manifest import ManifestError, verify_incoming
from .media_validation import MediaValidationError
from .durable_files import atomic_write_bytes, atomic_write_text
from .model_processor import render_markdown
from .queue import Job, JobQueue, QueueConflict
from .speakers import SpeakerRegistry


class PermanentProcessingError(RuntimeError):
    """An adapter can raise this to make a failed job visible without retrying."""


def _print_json(value: Any, *, stream=None) -> None:
    print(
        json.dumps(value, sort_keys=True, separators=(",", ":")),
        file=stream or sys.stdout,
    )


def _verified_json(incoming: Path) -> dict[str, Any]:
    verified = verify_incoming(incoming)
    return {
        "schema_version": 1,
        "meeting_id": verified.meeting_id,
        "manifest_revision": verified.revision,
        "manifest_sha256": verified.manifest_sha256,
        "verified_files": [
            {
                "path": item.path,
                "size_bytes": item.size_bytes,
                "sha256": item.sha256,
                "kind": item.kind,
            }
            for item in verified.files
        ],
    }


def _load_processor(specification: str) -> Callable[[Path, Job], None]:
    if ":" not in specification:
        raise ValueError("--processor must use module:function syntax.")
    module_name, function_name = specification.rsplit(":", 1)
    processor = getattr(importlib.import_module(module_name), function_name)
    if not callable(processor):
        raise ValueError(f"{specification} is not callable.")
    return processor


def _calendar_candidates(metadata: dict[str, Any]) -> list[dict[str, str | None]]:
    result = []
    for raw in metadata.get("attendees", []):
        if isinstance(raw, str) and raw.strip():
            result.append({"name": raw.strip(), "email": None, "response_status": None, "source": None})
        elif isinstance(raw, dict) and isinstance(raw.get("name"), str) and raw["name"].strip():
            result.append({
                "name": raw["name"].strip(),
                "email": raw.get("email") if isinstance(raw.get("email"), str) else None,
                "response_status": raw.get("response_status") if isinstance(raw.get("response_status"), str) else None,
                "source": raw.get("source") if isinstance(raw.get("source"), str) else None,
            })
    return result


class _Heartbeat:
    def __init__(self, queue: JobQueue, job: Job, lease_seconds: float):
        self.queue = queue
        self.job = job
        self.lease_seconds = lease_seconds
        self.stop = threading.Event()
        self.error: BaseException | None = None
        self.thread = threading.Thread(target=self._run, name="meeting-archive-lease", daemon=True)

    def __enter__(self) -> "_Heartbeat":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.stop.set()
        self.thread.join()

    def _run(self) -> None:
        interval = max(0.05, self.lease_seconds / 3)
        while not self.stop.wait(interval):
            try:
                self.queue.renew(self.job, self.lease_seconds)
            except BaseException as error:
                self.error = error
                self.stop.set()
                return


def _process_ready(args: argparse.Namespace) -> int:
    queue = JobQueue(args.db)
    owner = args.worker_id or f"{socket.gethostname()}:{uuid.uuid4()}"
    job = queue.claim_ready(owner, args.lease_seconds)
    if job is None:
        _print_json({"schema_version": 1, "processed": False, "reason": "no_ready_job"})
        return 0
    try:
        processor = _load_processor(args.processor)
        archive_directory = Path(job.archive_path)
        if not archive_directory.is_absolute():
            archive_directory = Path(args.archive_root) / archive_directory
        with _Heartbeat(queue, job, args.lease_seconds) as heartbeat:
            os.environ["MEETING_ARCHIVE_WORKER_DB"] = str(args.db)
            processor(archive_directory, job)
        if heartbeat.error is not None:
            raise QueueConflict(f"Lost the job lease during processing: {heartbeat.error}")
        queue.complete(job)
    except PermanentProcessingError as error:
        queue.fail(job, str(error), transient=False)
        _print_json(
            {"schema_version": 1, "processed": False, "job_id": job.id, "error": str(error)},
            stream=sys.stderr,
        )
        return 1
    except Exception as error:
        try:
            retry_at = queue.fail(
                job,
                str(error),
                transient=True,
                base_delay_seconds=args.retry_base_seconds,
            )
        except QueueConflict:
            retry_at = None
        _print_json(
            {
                "schema_version": 1,
                "processed": False,
                "job_id": job.id,
                "error": str(error),
                "retry_at": retry_at,
            },
            stream=sys.stderr,
        )
        return 1
    _print_json(
        {
            "schema_version": 1,
            "processed": True,
            "job_id": job.id,
            "meeting_id": job.meeting_id,
        },
    )
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="meeting-archive-worker")
    commands = result.add_subparsers(dest="command", required=True)

    verify = commands.add_parser("verify", help="verify an incoming finalized bundle")
    verify.add_argument("incoming", type=Path)

    accept = commands.add_parser("accept", help="accept and durably queue a verified bundle")
    accept.add_argument("incoming", type=Path, nargs="?")
    accept.add_argument("--incoming", dest="incoming_option", type=Path)
    accept.add_argument("--manifest-sha256")
    accept.add_argument("--archive-root", type=Path, required=True)
    accept.add_argument("--db", type=Path, required=True)
    accept.add_argument(
        "--validate-media",
        action="store_true",
        help="ffprobe and fully decode finalized media before allowing cleanup",
    )

    status = commands.add_parser("status", help="print durable queue state")
    status.add_argument("--db", type=Path, required=True)
    status.add_argument(
        "--meeting-id",
        action="append",
        default=[],
        help="limit output to a meeting UUID; repeat up to 100 times",
    )

    retry = commands.add_parser("retry", help="release failed processing or publication work")
    retry.add_argument("--meeting-id", required=True)
    retry.add_argument("--db", type=Path, required=True)

    process = commands.add_parser("process-ready", help="process at most one ready heavy job")
    process.add_argument("--archive-root", type=Path, required=True)
    process.add_argument("--db", type=Path, required=True)
    process.add_argument("--processor", required=True, help="Python module:function adapter")
    process.add_argument("--worker-id")
    process.add_argument("--lease-seconds", type=float, default=900)
    process.add_argument("--retry-base-seconds", type=float, default=60)
    review = commands.add_parser("review-speakers")
    review.add_argument("--archive-dir", type=Path, required=True)
    review.add_argument("--revision", type=int, required=True)
    review.add_argument("--db", type=Path, required=True)
    identify = commands.add_parser("identify")
    identify.add_argument("--meeting-id", required=True)
    identify.add_argument("--revision", type=int, required=True)
    identify.add_argument("--speaker-id", required=True)
    identify.add_argument("--name", required=True)
    identify.add_argument("--db", type=Path, required=True)
    locate = commands.add_parser("locate")
    locate.add_argument("--meeting-id", required=True)
    locate.add_argument("--archive-root", type=Path, required=True)
    locate.add_argument("--db", type=Path, required=True)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "verify":
            _print_json(_verified_json(args.incoming))
            return 0
        if args.command == "accept":
            incoming = args.incoming_option or args.incoming
            if incoming is None:
                raise ValueError("accept requires INCOMING or --incoming INCOMING.")
            if args.incoming_option is not None and args.incoming is not None:
                raise ValueError("Pass the incoming directory once.")
            acknowledgement = ArchiveStore(
                args.archive_root,
                args.db,
                validate_media=args.validate_media,
            ).accept(
                incoming,
                expected_manifest_sha256=args.manifest_sha256,
            )
            _print_json(acknowledgement)
            return 0
        if args.command == "status":
            if len(args.meeting_id) > 100:
                raise ValueError("status accepts at most 100 --meeting-id values.")
            meeting_ids = {
                str(uuid.UUID(value)).lower()
                for value in args.meeting_id
            } if args.meeting_id else None
            status = JobQueue(args.db).status(meeting_ids)
            from .service import PublicationQueue

            processing_job_ids = {int(job["id"]) for job in status["jobs"]}
            status["publication"] = PublicationQueue(args.db).status(
                processing_job_ids if meeting_ids is not None else None,
            )
            _print_json(status)
            return 0
        if args.command == "retry":
            meeting_id = str(uuid.UUID(args.meeting_id)).lower()
            processing = JobQueue(args.db).retry_failed(meeting_id)
            publication = None
            if processing["state"] == "succeeded":
                from .service import PublicationQueue

                publication = PublicationQueue(args.db).retry_failed(processing["job_id"])
            _print_json({
                "schema_version": 1,
                "meeting_id": meeting_id,
                "retried": processing["retried"] or bool(
                    publication and publication["retried"],
                ),
                "processing": processing,
                "publication": publication,
            })
            return 0
        if args.command == "process-ready":
            return _process_ready(args)
        if args.command == "review-speakers":
            transcript = json.loads((args.archive_dir / "transcripts" / f"v{args.revision}" / "transcript.json").read_text(encoding="utf-8"))
            assignments = SpeakerRegistry(args.db).assignments(transcript["meeting_id"], args.revision)
            speaker_ids = sorted({turn["speaker"] for turn in transcript["turns"] if "speaker" in turn})
            metadata = json.loads((args.archive_dir / "metadata.json").read_text(encoding="utf-8"))
            registry = SpeakerRegistry(args.db)
            speakers = []
            for value in speaker_ids:
                observation = registry.observation_record(transcript["meeting_id"], args.revision, value)
                embedding, model_id = observation if observation else (None, None)
                scores = registry.ranked_suggestions(embedding, model_id) if embedding else []
                suggested = registry.suggest(embedding, model_id=model_id) if embedding else None
                excerpts = [
                    {
                        **{key: turn[key] for key in ("start", "end", "text", "channel_origin")},
                        "playback_path": str(args.archive_dir / "playback" / "meeting.mp4")
                        if (args.archive_dir / "playback" / "meeting.mp4").is_file()
                        else None,
                    }
                    for turn in transcript["turns"] if turn.get("speaker") == value
                ][:3]
                speakers.append({"speaker_id": value, "name": assignments.get(value), "suggested_name": suggested, "suggestion_score": scores[0][0] if scores else None, "suggestion_margin": (scores[0][0] - scores[1][0]) if len(scores) > 1 else None, "embedding_available": embedding is not None, "excerpts": excerpts})
            _print_json({"schema_version": 1, "meeting_id": transcript["meeting_id"], "manifest_revision": args.revision, "speakers": speakers, "calendar_candidates": _calendar_candidates(metadata)})
            return 0
        if args.command == "identify":
            registry = SpeakerRegistry(args.db)
            enrolled = registry.confirm_observation(args.meeting_id, args.revision, args.speaker_id, args.name)
            acknowledgement = JobQueue(args.db).acceptance(args.meeting_id)
            if acknowledgement:
                meeting_directory = Path(acknowledgement["archive_path"])
                transcript_path = meeting_directory / "transcripts" / f"v{args.revision}" / "transcript.json"
                if transcript_path.is_file():
                    transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
                    if (
                        transcript.get("meeting_id") != args.meeting_id
                        or transcript.get("manifest_revision") != args.revision
                    ):
                        raise ValueError("Transcript identity does not match the identify request.")
                    for turn in transcript.get("turns", []):
                        if turn.get("speaker") == args.speaker_id:
                            turn["name"] = args.name
                    # Markdown is a derived view. Commit it before JSON, which
                    # is the receipt read by review and publication clients.
                    atomic_write_text(transcript_path.with_name("transcript.md"), render_markdown(transcript))
                    atomic_write_bytes(
                        transcript_path,
                        (json.dumps(transcript, sort_keys=True, ensure_ascii=False, indent=2) + "\n").encode(),
                    )
                    from .service import PublicationQueue

                    PublicationQueue(args.db).refresh(
                        int(acknowledgement["queue_job_id"]),
                        str(meeting_directory),
                    )
            _print_json({"schema_version": 1, "confirmed": True, "meeting_id": args.meeting_id, "manifest_revision": args.revision, "speaker_id": args.speaker_id, "name": args.name, "voice_profile_enrolled": enrolled})
            return 0
        if args.command == "locate":
            acknowledgement = JobQueue(args.db).acceptance(args.meeting_id)
            if acknowledgement is None:
                raise ValueError(f"Meeting {args.meeting_id} is not accepted in this archive.")
            path = Path(acknowledgement["archive_path"])
            if not path.is_absolute():
                path = args.archive_root / path
            _print_json({"schema_version": 1, "meeting_id": args.meeting_id, "archive_path": str(path)})
            return 0
        raise AssertionError(f"Unknown command {args.command}")
    except (
        ManifestError,
        MediaValidationError,
        ArchiveConflict,
        QueueConflict,
        ValueError,
        OSError,
        json.JSONDecodeError,
    ) as error:
        _print_json(
            {"schema_version": 1, "error": type(error).__name__, "message": str(error)},
            stream=sys.stderr,
        )
        return 2
