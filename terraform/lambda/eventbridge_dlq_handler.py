import json
import os
import boto3
from pathlib import Path
from urllib import request, error
from logger import log_info, log_error, log_exception

ALB_BASE_URL = os.environ["ALB_BASE_URL"]
DOCS_API_PATH = os.environ.get("DOCS_API_PATH", "/api/documents")
TOKEN_SECRET_ARN = os.environ["INGESTION_API_TOKEN_ARN"]
ORIGIN_VERIFY_ARN = os.environ.get("ORIGIN_VERIFY_ARN")

secrets_client = boto3.client("secretsmanager")


def get_origin_verify_secret():
    log_info("Fetching Origin Verify Secret token from Secrets Manager")
    try:
        response = secrets_client.get_secret_value(SecretId=ORIGIN_VERIFY_ARN)
        log_info("Successfully fetched Origin Verify Secret")
        return response["SecretString"]
    except Exception:
        log_exception("Failed to fetch Origin Verify Secret from Secrets Manager")
        raise


def get_ingestion_token():
    log_info("Fetching ingestion API token from Secrets Manager")
    try:
        secret = secrets_client.get_secret_value(SecretId=TOKEN_SECRET_ARN)[
            "SecretString"
        ]
        log_info("Successfully fetched ingestion API token")
        return secret
    except Exception:
        log_exception("Failed to fetch ingestion API token from Secrets Manager")
        raise


def get_key_and_event_type(overrides):
    if not overrides:
        return None, None

    env_list = overrides[0].get("environment", [])
    env_map = {item.get("name"): item.get("value") for item in env_list}

    return env_map.get("S3_OBJECT_KEY"), env_map.get("EVENT_TYPE")


def status_from_event_type(event_type):
    if event_type == "Object Created":
        return "failed"
    if event_type == "Object Deleted":
        return "delete_failed"
    return None


def patch_status(document_id, status, token, origin_secret):
    url = f"{ALB_BASE_URL}{DOCS_API_PATH}/{document_id}"
    body = json.dumps({"status": status}).encode("utf-8")

    log_info(
        "Patching document status via management-api",
        document_id=document_id,
        status=status,
        url=url,
    )

    req = request.Request(url, data=body, method="PATCH")
    req.add_header("Content-Type", "application/json")
    req.add_header("x-api-token", token)
    req.add_header("X-Origin-Verify", origin_secret)

    try:
        resp = request.urlopen(req, timeout=30)
        resp_body = resp.read().decode("utf-8", "replace")
        log_info(
            "Patch status response",
            document_id=document_id,
            status=status,
            http_status=resp.getcode(),
            response_body=resp_body[:500],
        )
    except error.HTTPError as e:
        err_body = e.read().decode("utf-8", "replace")
        log_error(
            "HTTPError while patching document status",
            document_id=document_id,
            status=status,
            http_status=e.code,
            response_body=err_body[:500],
        )
        raise
    except error.URLError as e:
        log_error(
            "URLError while patching document status",
            document_id=document_id,
            status=status,
            reason=str(e),
        )
        raise


def handle_run_task_dlq(payload, token, origin_secret):
    key, event_type = get_key_and_event_type(payload.get("containerOverrides", []))

    if not key or not event_type:
        log_error(
            "Missing S3_OBJECT_KEY or EVENT_TYPE in RunTask payload; skipping",
            payload_keys=list(payload.keys()),
        )
        return

    status = status_from_event_type(event_type)
    if not status:
        log_error(
            "Unknown EVENT_TYPE in RunTask payload; skipping",
            event_type=event_type,
        )
        return

    document_id = Path(key).stem
    log_info(
        "Handling RunTask DLQ message",
        document_id=document_id,
        key=key,
        event_type=event_type,
        status=status,
    )
    patch_status(document_id, status, token, origin_secret)


def handle_ecs_task_failure(payload, token, origin_secret):
    detail = payload.get("detail", {})
    overrides = detail.get("overrides", {}).get("containerOverrides", [])

    key, event_type = get_key_and_event_type(overrides)

    if not key or not event_type:
        log_error(
            "Missing S3_OBJECT_KEY or EVENT_TYPE in ECS detail; skipping",
            detail_keys=list(detail.keys()),
        )
        return

    status = status_from_event_type(event_type)
    if not status:
        log_error(
            "Unknown EVENT_TYPE in ECS detail; skipping",
            event_type=event_type,
        )
        return

    document_id = Path(key).stem
    log_info(
        "Handling ECS Task failure event",
        document_id=document_id,
        key=key,
        event_type=event_type,
        status=status,
    )
    patch_status(document_id, status, token, origin_secret)


def handler(event, context):
    records = event.get("Records", [])
    log_info(
        "Status DLQ Lambda invocation received",
        aws_request_id=getattr(context, "aws_request_id", None),
        record_count=len(records),
    )

    if not records:
        log_info("No records in event; nothing to process")
        return

    try:
        token = get_ingestion_token()
    except Exception:
        log_exception("Aborting batch: could not fetch ingestion token")
        raise

    try:
        origin_secret = get_origin_verify_secret()
    except Exception:
        log_exception("Aborting batch: could not fetch Origin Verify Secret")
        raise

    for record in records:
        body = record.get("body", "")
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            log_error(
                "Bad JSON body in SQS message; skipping",
                raw_body=body[:200],
            )
            continue

        detail_type = payload.get("detail-type")

        if detail_type == "ECS Task State Change":
            handle_ecs_task_failure(payload, token, origin_secret)
            continue

        if "containerOverrides" in payload:
            handle_run_task_dlq(payload, token, origin_secret)
            continue

        log_error(
            "Unrecognized payload shape; skipping",
            payload_keys=list(payload.keys()),
            detail_type=detail_type,
        )
