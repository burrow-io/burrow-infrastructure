import json
import os
from services.secrets import fetch_secret
from events.task_failure import handle_task_failure
from utils.logger import log_info, log_error, log_exception

TOKEN_SECRET_ARN = os.environ["INGESTION_API_TOKEN_ARN"]
ORIGIN_VERIFY_ARN = os.environ["ORIGIN_VERIFY_ARN"]
DB_PASSWORD_ARN = os.environ["DB_PASSWORD_SECRET_ARN"]


def handler(event, context):
    records = event.get("Records", [])
    log_info("DLQ Lambda invocation received", record_count=len(records))

    if not records:
        log_info("No records in event; nothing to process")
        return

    try:
        api_token = fetch_secret(TOKEN_SECRET_ARN, "API token")
        origin_secret = fetch_secret(ORIGIN_VERIFY_ARN, "Origin Verify Secret")
        db_password = fetch_secret(DB_PASSWORD_ARN, "DB password")
    except Exception:
        log_exception("Aborting batch: could not fetch required secrets")
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

        try:
            handle_task_failure(payload, api_token, origin_secret, db_password)
        except Exception:
            log_exception(
                "Failed to handle task failure event",
                payload_keys=list(payload.keys()),
            )
            raise
