import os
import psycopg2
from utils.logger import log_info, log_exception

DB_HOST = os.environ["DB_HOST"]
DB_PORT = os.environ["DB_PORT"]
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
TABLE_NAME = "burrow_table_hybrid2"


def check_chunks_exist(document_id, db_password):
    log_info(
        "Checking Aurora for existing chunks",
        document_id=document_id,
        table_name=f"data_{TABLE_NAME}",
    )

    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=db_password,
            connect_timeout=10,
        )
        cur = conn.cursor()

        query = f"""
            SELECT COUNT(*)
            FROM data_{TABLE_NAME}
            WHERE metadata_->>'doc_id' = %s
        """
        cur.execute(query, (document_id,))
        count = cur.fetchone()[0]

        cur.close()
        conn.close()

        log_info(
            "Aurora chunk check complete",
            document_id=document_id,
            chunk_count=count,
            chunks_exist=count > 0,
        )

        return count > 0

    except Exception:
        log_exception(
            "Failed to check Aurora for chunks",
            document_id=document_id,
        )
        raise
