import os
import requests
from utils.logger import log_info, log_error

ALB_BASE_URL = os.environ["ALB_BASE_URL"]
DOCS_API_PATH = os.environ.get("DOCS_API_PATH", "/api/documents")


def update_document_status(document_id, status, api_token, origin_secret):
    url = f"{ALB_BASE_URL}{DOCS_API_PATH}/{document_id}"

    log_info(
        "Updating document status",
        document_id=document_id,
        status=status,
        url=url,
    )

    try:
        response = requests.patch(
            url,
            json={"status": status},
            headers={
                "Content-Type": "application/json",
                "x-api-token": api_token,
                "X-Origin-Verify": origin_secret,
            },
            timeout=30,
        )

        log_info(
            "Status update response",
            document_id=document_id,
            status=status,
            http_status=response.status_code,
            response_body=response.text[:500],
        )

        response.raise_for_status()

    except requests.RequestException as e:
        log_error(
            "Failed to update document status",
            document_id=document_id,
            status=status,
            error=str(e),
        )
        raise
