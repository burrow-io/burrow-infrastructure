import boto3
from utils.logger import log_info, log_exception

secrets_client = boto3.client("secretsmanager")


def fetch_secret(secret_arn, secret_name):
    log_info(f"Fetching {secret_name} from Secrets Manager")
    try:
        response = secrets_client.get_secret_value(SecretId=secret_arn)
        log_info(f"Successfully fetched {secret_name}")
        return response["SecretString"]
    except Exception:
        log_exception(f"Failed to fetch {secret_name}")
        raise
