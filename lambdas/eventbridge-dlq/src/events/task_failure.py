from pathlib import Path
from services.db import check_chunks_exist
from services.api import update_document_status
from utils.logger import log_info, log_error


def get_document_info(overrides):
    if not overrides:
        return None, None

    env_list = overrides[0].get("environment", [])
    env_map = {item.get("name"): item.get("value") for item in env_list}

    s3_key = env_map.get("S3_OBJECT_KEY")
    event_type = env_map.get("EVENT_TYPE")

    if not s3_key or not event_type:
        return None, None

    document_id = Path(s3_key).stem

    return document_id, event_type


def determine_status(event_type, document_id, db_password):
    if event_type == "Object Created":
        if check_chunks_exist(document_id, db_password):
            log_info(
                "Chunks found in Aurora for failed task - marking as finished",
                document_id=document_id,
            )
            return "finished"
        return "failed"

    if event_type == "Object Tags Added":
        if check_chunks_exist(document_id, db_password):
            log_info(
                "Chunks still exist in Aurora for failed deletion - marking as delete_failed",
                document_id=document_id,
            )
            return "delete_failed"
        log_info(
            "No chunks found in Aurora for failed deletion - marking as deleted",
            document_id=document_id,
        )
        return "deleted"

    return None


def handle_task_failure(payload, api_token, origin_secret, db_password):
    detail = payload.get("detail", {})
    overrides = detail.get("overrides", {}).get("containerOverrides")

    if overrides is None:
        request_params = detail.get("requestParameters", {})
        overrides = request_params.get("overrides", {}).get("containerOverrides")

    if overrides is None:
        overrides = payload.get("containerOverrides")

    document_id, event_type = get_document_info(overrides)

    if not document_id or not event_type:
        log_error(
            "Missing S3_OBJECT_KEY or EVENT_TYPE in task failure event; skipping",
            payload_keys=list(payload.keys()),
        )
        return

    status = determine_status(event_type, document_id, db_password)

    if not status:
        log_error(
            "Unknown EVENT_TYPE in task failure event; skipping",
            event_type=event_type,
            document_id=document_id,
        )
        return

    log_info(
        "Handling task failure event",
        document_id=document_id,
        event_type=event_type,
        status=status,
    )

    update_document_status(document_id, status, api_token, origin_secret)
