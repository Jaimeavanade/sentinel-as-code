param(
  [Parameter(Mandatory=$true)]
  [string]$ResourceGroup,

  [Parameter(Mandatory=$true)]
  [string]$Workspace,

  [Parameter(Mandatory=$true)]
  [string]$Region,

  # IMPORTANT: desde el workflow lo pasamos como string (coma-separado).
  [Parameter(Mandatory=$false)]
  [string]$Solutions = "",

  # IMPORTANT: desde el workflow lo pasamos como string (coma-separado).
  [Parameter(Mandatory=$false)]
  [string]$SeveritiesToInclude = "High,Medium",

  [Parameter(Mandatory=$false)]
  [string]$IsGov = "false"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Normalización (quita espacios/saltos de línea invisibles)
$ResourceGroup = $ResourceGroup.Trim()
$Workspace     = $Workspace.Trim()
$Region        = $Region.Trim()
$Solutions     = $Solutions.Trim()
$SeveritiesToInclude = $SeveritiesToInclude.Trim()

Write-Host "== Set-SentinelContent.ps1 =="
Write-Host "ResourceGroup: $ResourceGroup"
Write-Host "Workspace:     $Workspace"
Write-Host "Region:        $Region"
Write-Host "Solutions(raw):     >$Solutions<"
Write-Host "Severities(raw):    >$SeveritiesToInclude<"
Write-Host "IsGov:         $IsGov"

# Si Region viene en formato "France Central", avisamos
if ($Region -match "\s") {
  Write-Warning "REGION contiene espacios ('$Region'). En Azure suele ser 'francecentral', 'westeurope', etc."
}

# 1) Comprobar contexto Az
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
  throw "Az modules no disponibles. azure/powershell debería cargarlos automáticamente."
}

# 2) Obtener subscription actual (viene del azure/login)
$ctx = Get-AzContext
if (-not $ctx) { throw "No hay contexto Az (Get-AzContext vacío). ¿Falló azure/login?" }

$subscriptionId = $ctx.Subscription.Id
Write-Host "SubscriptionId: $subscriptionId"

# 3) Obtener el Workspace ResourceId
$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $Workspace -ErrorAction Stop
$workspaceId = $ws.ResourceId
Write-Host "WorkspaceId: $workspaceId"

# 4) Parsear severities
$sevList = @()
if (-not [string]::IsNullOrWhiteSpace($SeveritiesToInclude)) {
  $sevList = $SeveritiesToInclude.Split(",") | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ }
}
Write-Host "Severities(parsed): $($sevList -join ', ')"

# 5) Parsear soluciones (coma-separado)
$solutionList = @()
if (-not [string]::IsNullOrWhiteSpace($Solutions)) {
  $solutionList = $Solutions.Split(",") | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ }
}

if ($solutionList.Count -eq 0) {
  Write-Host "No hay soluciones definidas en SENTINEL_SOLUTIONS. Nada que instalar."
  exit 0
}

Write-Host "Solutions(parsed): $($solutionList -join ' | ')"
Write-Host "Instalando soluciones (mejor esfuerzo)..."

foreach ($solutionName in $solutionList) {
  Write-Host ""
  Write-Host "==> Installing/Updating solution: $solutionName"

  # Nombre del recurso "solution" (debe ser único en el RG)
  $resourceName = "SentinelSolution-$($solutionName -replace '[^a-zA-Z0-9\-]', '-')"

  # Endpoint ARM (método genérico OMSGallery)
  $apiVersion = "2015-11-01-preview"
  $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationsManagement/solutions/$resourceName?api-version=$apiVersion"

  $body = @{
    location   = $Region
    properties = @{
      workspaceResourceId = $workspaceId
      containedResources  = @()
    }
    plan = @{
      name      = $solutionName
      publisher = "Microsoft"
      product   = "OMSGallery/$solutionName"
      promotionCode = ""
    }
  } | ConvertTo-Json -Depth 10

  try {
    Invoke-AzRestMethod -Method PUT -Uri $uri -Payload $body -ErrorAction Stop | Out-Null
    Write-Host "OK: solicitado despliegue para $solutionName"
  }
  catch {
    Write-Warning "No se pudo instalar '$solutionName' con el método genérico (OMSGallery)."
    Write-Warning "Error: $($_.Exception.Message)"
    Write-Warning "Esto puede ser normal: algunas soluciones modernas se gestionan vía Content Hub (Microsoft.SecurityInsights)."
    throw
  }
}

Write-Host ""
Write-Host "Fin."
