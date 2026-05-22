import os
from celery import Celery


def _env_bool(name: str, default: str = "false") -> bool:
    return os.getenv(name, default).strip().lower() in {"1", "true", "yes", "on"}


redis_host = os.getenv("REDIS_HOST", "redis")
redis_port = os.getenv("REDIS_PORT", "6379")
redis_db = os.getenv("REDIS_DB", "0")
redis_password = os.getenv("REDIS_PASSWORD", "")
redis_ssl = _env_bool("REDIS_SSL", "false")
redis_ssl_cert_reqs = os.getenv("REDIS_SSL_CERT_REQS", "CERT_NONE")

if not redis_port or redis_port.lower() in {"none", "null"}:
    redis_port = "10000" if redis_ssl else "6379"

redis_scheme = "rediss" if redis_ssl else "redis"
redis_auth = f":{redis_password}@" if redis_password else ""

if redis_ssl:
    broker_url = (
        f"{redis_scheme}://{redis_auth}{redis_host}:{redis_port}/{redis_db}"
        f"?ssl_cert_reqs={redis_ssl_cert_reqs}"
    )
else:
    broker_url = f"{redis_scheme}://{redis_auth}{redis_host}:{redis_port}/{redis_db}"

celery_app = Celery("tasks", broker=broker_url, backend=broker_url)
celery_app.conf.update(
    broker_transport_options={
        "priority_steps": [0],
        "sep": ":",
        "queue_order_strategy": "sorted",
    },
    task_default_queue=os.getenv("CELERY_QUEUE", "{celery}"),
)


@celery_app.task(name="square_number")
def square_number(num: int) -> int:
    return num * num
