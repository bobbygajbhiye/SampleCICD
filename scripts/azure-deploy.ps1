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

function Invoke-Az {
    param([string]$Command)
    $displayCommand = $Command
    foreach ($secret in @($AcrPassword, $redisPassword)) {
        if ($secret) {
            $displayCommand = $displayCommand.Replace($secret, "****")
        }
    }

    Write-Host "> $displayCommand"

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = Invoke-Expression "$Command 2>&1"
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    foreach ($line in $output) {
        $displayLine = [string]$line
        foreach ($secret in @($AcrPassword, $redisPassword)) {
            if ($secret) {
                $displayLine = $displayLine.Replace($secret, "****")
            }
        }
        Write-Host $displayLine
    }

    if ($exitCode -ne 0) {
        throw "Command failed: $displayCommand"
    }
}

function Test-DnsName {
    param([string]$HostName)

    try {
        Resolve-DnsName -Name $HostName -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Wait-DnsName {
    param(
        [string]$HostName,
        [int]$Attempts = 18,
        [int]$DelaySeconds = 10
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        if (Test-DnsName $HostName) {
            return $true
        }

        Write-Host "Waiting for DNS to resolve '$HostName' ($i/$Attempts)..."
        Start-Sleep -Seconds $DelaySeconds
    }

    return $false
}

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
    Invoke-Az "az account set --subscription $SubscriptionId"
}

$location = [System.Environment]::GetEnvironmentVariable("AZURE_LOCATION")
$rg = [System.Environment]::GetEnvironmentVariable("AZURE_RESOURCE_GROUP")
$acr = [System.Environment]::GetEnvironmentVariable("AZURE_ACR_NAME")
$acrSku = [System.Environment]::GetEnvironmentVariable("AZURE_ACR_SKU")
$plan = [System.Environment]::GetEnvironmentVariable("AZURE_APP_PLAN")
$planLocation = [System.Environment]::GetEnvironmentVariable("AZURE_APP_PLAN_LOCATION")
$planSku = [System.Environment]::GetEnvironmentVariable("AZURE_APP_PLAN_SKU")
$backendApp = [System.Environment]::GetEnvironmentVariable("AZURE_BACKEND_APP")
$frontendApp = [System.Environment]::GetEnvironmentVariable("AZURE_FRONTEND_APP")
$redisHost = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_HOST")
$redisPort = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_PORT")
$redisDb = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_DB")
$redisPassword = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_PASSWORD")
$redisSslCertReqs = [System.Environment]::GetEnvironmentVariable("AZURE_REDIS_SSL_CERT_REQS")
$managedRedisName = [System.Environment]::GetEnvironmentVariable("AZURE_MANAGED_REDIS_NAME")
$managedRedisLocation = [System.Environment]::GetEnvironmentVariable("AZURE_MANAGED_REDIS_LOCATION")
$managedRedisSku = [System.Environment]::GetEnvironmentVariable("AZURE_MANAGED_REDIS_SKU")
$managedRedisClusteringPolicy = [System.Environment]::GetEnvironmentVariable("AZURE_MANAGED_REDIS_CLUSTERING_POLICY")
$caEnv = [System.Environment]::GetEnvironmentVariable("AZURE_CONTAINERAPPS_ENV")
$caWorker = [System.Environment]::GetEnvironmentVariable("AZURE_CONTAINERAPPS_WORKER")
$caFlower = [System.Environment]::GetEnvironmentVariable("AZURE_CONTAINERAPPS_FLOWER")
$imageTag = [System.Environment]::GetEnvironmentVariable("IMAGE_TAG")

if (-not $acrSku) { $acrSku = "Basic" }
if (-not $planSku) { $planSku = "B1" }
if (-not $planLocation) { $planLocation = $location }
if (-not $redisPort) { $redisPort = "6380" }
if (-not $redisDb) { $redisDb = "0" }
if (-not $redisSslCertReqs) { $redisSslCertReqs = "CERT_NONE" }
if (-not $managedRedisName) { $managedRedisName = "samplecicd-managed-redis-$Environment" }
if (-not $managedRedisLocation) { $managedRedisLocation = $location }
if (-not $managedRedisSku) { $managedRedisSku = "Balanced_B1" }
if (-not $managedRedisClusteringPolicy) { $managedRedisClusteringPolicy = "NoCluster" }
if (-not $imageTag -or $imageTag -match "latest$") {
    $imageTag = "$Environment-$(Get-Date -Format yyyyMMddHHmmss)"
}

Write-Host "Loaded env: location=$location rg=$rg acr=$acr plan=$plan managedRedis=$managedRedisName caEnv=$caEnv"
Write-Host "Using image tag: $imageTag"

$backendImage = "$acr.azurecr.io/square-backend:$imageTag"
$frontendImage = "$acr.azurecr.io/square-frontend:$imageTag"
$workerImage = "$acr.azurecr.io/square-worker:$imageTag"

Invoke-Az "az group create --name $rg --location $location"

if (-not $redisHost -or -not $redisPassword) {
    Invoke-Az "az extension add --name redisenterprise --upgrade --only-show-errors"

    $managedRedisExists = az redisenterprise list --resource-group $rg --query "[?name=='$managedRedisName'].name | [0]" -o tsv
    $managedRedisCreated = $false
    if (-not $managedRedisExists) {
        Invoke-Az "az redisenterprise create --name $managedRedisName --resource-group $rg --location $managedRedisLocation --sku $managedRedisSku --public-network-access Enabled"
        $managedRedisCreated = $true
    }

    $managedRedisDatabaseExists = az redisenterprise database list --cluster-name $managedRedisName --resource-group $rg --query "[0].id" -o tsv
    if (-not $managedRedisDatabaseExists) {
        Invoke-Az "az redisenterprise database create --cluster-name $managedRedisName --resource-group $rg --client-protocol Encrypted --access-keys-authentication Enabled --clustering-policy $managedRedisClusteringPolicy"
    } else {
        $currentClusteringPolicy = az redisenterprise database list --cluster-name $managedRedisName --resource-group $rg --query "[0].clusteringPolicy" -o tsv
        if ($currentClusteringPolicy -and $currentClusteringPolicy -ne $managedRedisClusteringPolicy) {
            if ($managedRedisCreated) {
                Invoke-Az "az redisenterprise database delete --cluster-name $managedRedisName --resource-group $rg --yes"
                Invoke-Az "az redisenterprise database create --cluster-name $managedRedisName --resource-group $rg --client-protocol Encrypted --access-keys-authentication Enabled --clustering-policy $managedRedisClusteringPolicy"
            } else {
                throw "Azure Managed Redis database '$managedRedisName' uses clusteringPolicy '$currentClusteringPolicy'. Celery Redis broker requires '$managedRedisClusteringPolicy'. Delete/recreate this Redis database or use a different Redis instance, then rerun."
            }
        }
        Invoke-Az "az redisenterprise database update --cluster-name $managedRedisName --resource-group $rg --access-keys-authentication Enabled"
    }

    $redisHost = az redisenterprise show --name $managedRedisName --resource-group $rg --query "hostName" -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $redisHost -or $redisHost -eq "None") {
        throw "Could not read Azure Managed Redis endpoint for '$managedRedisName'."
    }

    $managedRedisDatabasePort = az redisenterprise database list --cluster-name $managedRedisName --resource-group $rg --query "[0].port" -o tsv
    if ($LASTEXITCODE -eq 0 -and $managedRedisDatabasePort -and $managedRedisDatabasePort -ne "None") {
        $redisPort = $managedRedisDatabasePort
    }

    $redisKeys = az redisenterprise database list-keys --cluster-name $managedRedisName --resource-group $rg --query "[primaryKey,secondaryKey]" -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $redisKeys) {
        throw "Could not read Azure Managed Redis keys for '$managedRedisName'. Make sure access keys are enabled."
    }

    $redisPassword = (($redisKeys -split "\s+") | Where-Object { $_ })[0]
}

if (-not $redisHost) { throw "AZURE_REDIS_HOST is required and could not be discovered from Azure Managed Redis." }
if (-not $redisPassword) { throw "AZURE_REDIS_PASSWORD is required and could not be discovered from Azure Managed Redis." }
if (-not (Wait-DnsName $redisHost)) {
    throw "Redis host '$redisHost' does not resolve yet. Check Azure Managed Redis provisioning status and rerun after it is ready."
}

$acrExists = az acr list --resource-group $rg --query "[?name=='$acr'].name | [0]" -o tsv
if (-not $acrExists) {
    Invoke-Az "az acr create --resource-group $rg --name $acr --sku $acrSku"
}
Invoke-Az "az acr login --name $acr"

Invoke-Az "docker build -t square-backend:$imageTag ./backend"
Invoke-Az "docker build -t square-frontend:$imageTag ./frontend"
Invoke-Az "docker build -t square-worker:$imageTag ./worker"

Invoke-Az "docker tag square-backend:$imageTag $backendImage"
Invoke-Az "docker tag square-frontend:$imageTag $frontendImage"
Invoke-Az "docker tag square-worker:$imageTag $workerImage"

Invoke-Az "docker push $backendImage"
Invoke-Az "docker push $frontendImage"
Invoke-Az "docker push $workerImage"

$planExists = az appservice plan list --resource-group $rg --query "[?name=='$plan'].name | [0]" -o tsv
if (-not $planExists) {
    Invoke-Az "az appservice plan create --name $plan --resource-group $rg --is-linux --sku $planSku --location $planLocation"
}

$backendExists = az webapp list --resource-group $rg --query "[?name=='$backendApp'].name | [0]" -o tsv
if (-not $backendExists) {
    Invoke-Az "az webapp create --resource-group $rg --plan $plan --name $backendApp --container-image-name $backendImage"
}

$frontendExists = az webapp list --resource-group $rg --query "[?name=='$frontendApp'].name | [0]" -o tsv
if (-not $frontendExists) {
    Invoke-Az "az webapp create --resource-group $rg --plan $plan --name $frontendApp --container-image-name $frontendImage"
}

if ($AcrUsername -and $AcrPassword) {
    Invoke-Az "az webapp config container set --name $backendApp --resource-group $rg --container-image-name $backendImage --container-registry-url https://$acr.azurecr.io --container-registry-user $AcrUsername --container-registry-password $AcrPassword"
    Invoke-Az "az webapp config container set --name $frontendApp --resource-group $rg --container-image-name $frontendImage --container-registry-url https://$acr.azurecr.io --container-registry-user $AcrUsername --container-registry-password $AcrPassword"
}

Invoke-Az "az webapp config appsettings set --name $backendApp --resource-group $rg --settings WEBSITES_PORT=8000 REDIS_HOST=$redisHost REDIS_PORT=$redisPort REDIS_DB=$redisDb REDIS_SSL=true REDIS_SSL_CERT_REQS=$redisSslCertReqs"
Invoke-Az "az webapp config appsettings set --name $frontendApp --resource-group $rg --settings WEBSITES_PORT=8501 API_BASE_URL=https://$backendApp.azurewebsites.net"
Invoke-Az "az webapp config appsettings set --name $backendApp --resource-group $rg --settings REDIS_PASSWORD=$redisPassword CELERY_QUEUE='{celery}'"
Invoke-Az "az extension add --name containerapp --upgrade --only-show-errors"

$caEnvExists = az containerapp env list --resource-group $rg --query "[?name=='$caEnv'].name | [0]" -o tsv
if (-not $caEnvExists) {
    Invoke-Az "az containerapp env create --name $caEnv --resource-group $rg --location $location --enable-workload-profiles false"
}

$workerExists = az containerapp list --resource-group $rg --query "[?name=='$caWorker'].name | [0]" -o tsv
if ($workerExists) {
    Invoke-Az "az containerapp update --name $caWorker --resource-group $rg --image $workerImage --set-env-vars REDIS_HOST=$redisHost REDIS_PORT=$redisPort REDIS_DB=$redisDb REDIS_PASSWORD=$redisPassword REDIS_SSL=true REDIS_SSL_CERT_REQS=$redisSslCertReqs CELERY_QUEUE='{celery}'"
} else {
    Invoke-Az "az containerapp create --name $caWorker --resource-group $rg --environment $caEnv --image $workerImage --registry-server $acr.azurecr.io --registry-username $AcrUsername --registry-password $AcrPassword --min-replicas 1 --max-replicas 2 --env-vars REDIS_HOST=$redisHost REDIS_PORT=$redisPort REDIS_DB=$redisDb REDIS_PASSWORD=$redisPassword REDIS_SSL=true REDIS_SSL_CERT_REQS=$redisSslCertReqs CELERY_QUEUE='{celery}'"
}

$flowerExists = az containerapp list --resource-group $rg --query "[?name=='$caFlower'].name | [0]" -o tsv
if ($flowerExists) {
    Invoke-Az "az containerapp update --name $caFlower --resource-group $rg --image $workerImage --command celery --args ""-A tasks.celery_app flower --port=5555"" --set-env-vars REDIS_HOST=$redisHost REDIS_PORT=$redisPort REDIS_DB=$redisDb REDIS_PASSWORD=$redisPassword REDIS_SSL=true REDIS_SSL_CERT_REQS=$redisSslCertReqs CELERY_QUEUE='{celery}'"
    Invoke-Az "az containerapp update --name $caFlower --resource-group $rg --min-replicas 1 --max-replicas 1"
    Invoke-Az "az containerapp ingress enable --name $caFlower --resource-group $rg --type external --target-port 5555"
} else {
    Invoke-Az "az containerapp create --name $caFlower --resource-group $rg --environment $caEnv --image $workerImage --registry-server $acr.azurecr.io --registry-username $AcrUsername --registry-password $AcrPassword --ingress external --target-port 5555 --min-replicas 1 --max-replicas 1 --command celery --args ""-A tasks.celery_app flower --port=5555"" --env-vars REDIS_HOST=$redisHost REDIS_PORT=$redisPort REDIS_DB=$redisDb REDIS_PASSWORD=$redisPassword REDIS_SSL=true REDIS_SSL_CERT_REQS=$redisSslCertReqs CELERY_QUEUE='{celery}'"
}

Invoke-Az "az webapp restart --name $backendApp --resource-group $rg"
Invoke-Az "az webapp restart --name $frontendApp --resource-group $rg"
Write-Host "Deployment completed for environment: $Environment"
