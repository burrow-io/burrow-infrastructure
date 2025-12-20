import os
import boto3
import psycopg2


def handler(event, context):
    """Initialize pgvector extension in Aurora PostgreSQL."""

    # Get password from Secrets Manager
    secrets = boto3.client('secretsmanager')
    password = secrets.get_secret_value(SecretId=os.environ['DB_PASSWORD_SECRET_ARN'])['SecretString']

    # Connect and install extension
    conn = psycopg2.connect(
        host=os.environ['DB_ENDPOINT'],
        port=5432,
        database=os.environ['DB_NAME'],
        user=os.environ['DB_USER'],
        password=password,
        connect_timeout=30
    )

    try:
        with conn.cursor() as cursor:
            cursor.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        conn.commit()
    finally:
        conn.close()
