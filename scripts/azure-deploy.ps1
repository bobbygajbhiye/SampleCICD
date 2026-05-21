param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$AcrUsername,

    [Parameter(Mandatory = $false)]
    [string]$AcrPassword
)

$ErrorActionPreference = "Stop"

$envFile = Join-Path $PSScriptRoot "..\deploy\$Environment.env"
if (-not (Test-Path $envFile)) {
    throw "Environment file not found: $envFile"
}

Get-Content $envFile | ForEach-Object {
    if ($_ -and -not $_.StartsWith("#")) {
        $parts = $_ -split "=", 2
        if ($parts.Count -eq 2) {
            [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim())
        }
    }
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
}

$location = [System.Environment]::GetEnvironmentVariable("AZURE_LOCATION")
$rg = [System.Environment]::GetEnvironmentVariable("AZURE_RESOURCE_GROUP")
$acr = [System.Environment]::GetEnvironmentVariable("AZURE_ACR_NAME")
$plan = [System.Environment]::GetEnvironmentVariable("AZURE_APP_PLAN")
$backendApp = [System.Environment]::GetEnvironmentVariable("AZURE_BACKEND_APP")
$frontendApp = [System.Environment]::GetEnvironmentVariable("AZURE_FRONTEND_APP")
$redisAci = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_ACI_NAME")
$workerAci = [System.Environment]::GetEnvironmentVariable("AZURE_WORKER_ACI_NAME")
$imageTag = [System.Environment]::GetEnvironmentVariable("IMAGE_TAG")

$backendImage = "$acr.azurecr.io/square-backend:$imageTag"
$frontendImage = "$acr.azurecr.io/square-frontend:$imageTag"
$workerImage = "$acr.azurecr.io/square-worker:$imageTag"

az group create --name $rg --location $location
az acr create --resource-group $rg --name $acr --sku Basic
az acr login --name $acr

docker build -t square-backend:$imageTag ./backend
docker build -t square-frontend:$imageTag ./frontend
docker build -t square-worker:$imageTag ./worker

docker tag square-backend:$imageTag $backendImage
docker tag square-frontend:$imageTag $frontendImage
docker tag square-worker:$imageTag $workerImage

docker push $backendImage
docker push $frontendImage
docker push $workerImage

az appservice plan create --name $plan --resource-group $rg --is-linux --sku B1

az webapp create --resource-group $rg --plan $plan --name $backendApp --deployment-container-image-name $backendImage
az webapp create --resource-group $rg --plan $plan --name $frontendApp --deployment-container-image-name $frontendImage

if ($AcrUsername -and $AcrPassword) {
    az webapp config container set --name $backendApp --resource-group $rg --docker-custom-image-name $backendImage --docker-registry-server-url "https://$acr.azurecr.io" --docker-registry-server-user $AcrUsername --docker-registry-server-password $AcrPassword
    az webapp config container set --name $frontendApp --resource-group $rg --docker-custom-image-name $frontendImage --docker-registry-server-url "https://$acr.azurecr.io" --docker-registry-server-user $AcrUsername --docker-registry-server-password $AcrPassword
}

az container create --resource-group $rg --name $redisAci --image redis:7-alpine --ports 6379

if ($AcrUsername -and $AcrPassword) {
    az container create --resource-group $rg --name $workerAci --image $workerImage --registry-login-server "$acr.azurecr.io" --registry-username $AcrUsername --registry-password $AcrPassword
} else {
    Write-Warning "Skipping worker ACI deployment without ACR credentials."
}

Write-Host "Deployment completed for environment: $Environment"
