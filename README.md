# SampleCICD

End-to-end demo architecture from your document:
- Streamlit frontend
- FastAPI backend
- Redis queue/broker
- Celery worker
- Flower monitoring UI
- Dockerized services
- GitHub Actions CI/CD
- Azure CLI deployment scripts

## Project structure
- `backend/`: FastAPI API that submits Celery tasks and checks status
- `worker/`: Celery worker + shared task definition
- `frontend/`: Streamlit UI
- `deploy/dev.env`: Dev environment values (non-secret)
- `deploy/prod.env`: Prod environment values (non-secret)
- `docker-compose.yml`: local end-to-end startup
- `.github/workflows/deploy.yml`: branch-based CI/CD (`develop` -> Dev, `main` -> Prod)
- `scripts/azure-deploy.ps1`: Azure ACR/App Service/Redis/Container Apps deployment by environment

## Run locally (Docker)
```bash
docker compose up --build
```

Then open:
- Frontend: http://localhost:8501
- Backend docs: http://localhost:8000/docs
- Flower dashboard: http://localhost:5555

## Dev/Prod deployment model
- `develop` branch deploys to Dev
- `main` branch deploys to Prod
- Update only non-secret values in:
  - `deploy/dev.env`
  - `deploy/prod.env`

## GitHub Secrets needed
- `AZURE_CREDENTIALS_DEV`: Service principal JSON for Dev
- `AZURE_CREDENTIALS_PROD`: Service principal JSON for Prod

Service principal JSON format:
```json
{
  "clientId": "<app-id>",
  "clientSecret": "<password>",
  "subscriptionId": "<subscription-id>",
  "tenantId": "<tenant-id>"
}
```

## One-time infra creation
```powershell
# Dev
./scripts/azure-deploy.ps1 -Environment dev -SubscriptionId <sub-id> -AcrUsername <acr-user> -AcrPassword <acr-pass>

# Prod
./scripts/azure-deploy.ps1 -Environment prod -SubscriptionId <sub-id> -AcrUsername <acr-user> -AcrPassword <acr-pass>
```
