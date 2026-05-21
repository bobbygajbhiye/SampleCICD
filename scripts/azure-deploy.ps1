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
$acrSku = [System.Environment]::GetEnvironmentVariable("AZURE_ACR_SKU")
$plan = [System.Environment]::GetEnvironmentVariable("AZURE_APP_PLAN")
$planSku = [System.Environment]::GetEnvironmentVariable("AZURE_APP_PLAN_SKU")
$backendApp = [System.Environment]::GetEnvironmentVariable("AZURE_BACKEND_APP")
$frontendApp = [System.Environment]::GetEnvironmentVariable("AZURE_FRONTEND_APP")
$redisName = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_NAME")
$redisSku = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_SKU")
$redisFamily = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_FAMILY")
$redisCapacity = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_CAPACITY")
$redisPort = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_PORT")
$redisDb = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_DB")
$caEnv = [System.Environment]::GetEnvironmentVariable("AZURE_CONTAINERAPPS_ENV")
$caWorker = [System.Environment]::GetEnvironmentVariable("AZURE_CONTAINERAPPS_WORKER")
$caFlower = [System.Environment]::GetEnvironmentVariable("AZURE_CONTAINERAPPS_FLOWER")
$imageTag = [System.Environment]::GetEnvironmentVariable("IMAGE_TAG")

$backendImage = "$acr.azurecr.io/square-backend:$imageTag"
$frontendImage = "$acr.azurecr.io/square-frontend:$imageTag"
$workerImage = "$acr.azurecr.io/square-worker:$imageTag"

az group create --name $rg --location $location
if (-not $acrSku) { $acrSku = "Basic" }
if (-not $planSku) { $planSku = "B1" }
if (-not $redisName) { $redisName = "$($Environment)-samplecicd-redis" }
if (-not $redisSku) { $redisSku = "Basic" }
if (-not $redisFamily) { $redisFamily = "C" }
if (-not $redisCapacity) { $redisCapacity = "0" }
if (-not $redisPort) { $redisPort = "6379" }
if (-not $redisDb) { $redisDb = "0" }

az acr create --resource-group $rg --name $acr --sku $acrSku
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

az appservice plan create --name $plan --resource-group $rg --is-linux --sku $planSku

az webapp create --resource-group $rg --plan $plan --name $backendApp --deployment-container-image-name $backendImage
az webapp create --resource-group $rg --plan $plan --name $frontendApp --deployment-container-image-name $frontendImage

if ($AcrUsername -and $AcrPassword) {
    az webapp config container set --name $backendApp --resource-group $rg --docker-custom-image-name $backendImage --docker-registry-server-url "https://$acr.azurecr.io" --docker-registry-server-user $AcrUsername --docker-registry-server-password $AcrPassword
    az webapp config container set --name $frontendApp --resource-group $rg --docker-custom-image-name $frontendImage --docker-registry-server-url "https://$acr.azurecr.io" --docker-registry-server-user $AcrUsername --docker-registry-server-password $AcrPassword
}

az redis create --name $redisName --resource-group $rg --location $location --sku $redisSku --vm-size "${redisFamily}${redisCapacity}"

az extension add --name containerapp --upgrade --only-show-errors

az containerapp env create --name $caEnv --resource-group $rg --location $location --enable-workload-profiles $false

if (az containerapp show --name $caWorker --resource-group $rg 2>$null) {
    az containerapp update --name $caWorker --resource-group $rg --image $workerImage --set-env-vars REDIS_HOST="$redisName.redis.cache.windows.net" REDIS_PORT="$redisPort" REDIS_DB="$redisDb"
} else {
    az containerapp create --name $caWorker --resource-group $rg --environment $caEnv --image $workerImage --min-replicas 1 --max-replicas 2 --set-env-vars REDIS_HOST="$redisName.redis.cache.windows.net" REDIS_PORT="$redisPort" REDIS_DB="$redisDb"
}

if (az containerapp show --name $caFlower --resource-group $rg 2>$null) {
    az containerapp update --name $caFlower --resource-group $rg --image $workerImage --ingress external --target-port 5555 --command celery --args "-A tasks.celery_app flower --port=5555" --set-env-vars REDIS_HOST="$redisName.redis.cache.windows.net" REDIS_PORT="$redisPort" REDIS_DB="$redisDb"
} else {
    az containerapp create --name $caFlower --resource-group $rg --environment $caEnv --image $workerImage --ingress external --target-port 5555 --min-replicas 0 --max-replicas 1 --command celery --args "-A tasks.celery_app flower --port=5555" --set-env-vars REDIS_HOST="$redisName.redis.cache.windows.net" REDIS_PORT="$redisPort" REDIS_DB="$redisDb"
}

Write-Host "Deployment completed for environment: $Environment"
