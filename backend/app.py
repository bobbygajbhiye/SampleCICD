import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from celery.result import AsyncResult
from tasks import celery_app, square_number

app = FastAPI(title="Square API", version="1.0.0")


class SquareRequest(BaseModel):
    number: int = Field(..., ge=-1_000_000, le=1_000_000)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/square")
def submit_square(req: SquareRequest) -> dict:
    task = square_number.delay(req.number)
    return {"task_id": task.id, "message": "Task submitted"}


@app.get("/task/{task_id}")
def get_task_status(task_id: str) -> dict:
    result = AsyncResult(task_id, app=celery_app)

    response = {"task_id": task_id, "status": result.status}

    if result.successful():
        response["result"] = result.result
    elif result.failed():
        response["error"] = str(result.result)

    return response
