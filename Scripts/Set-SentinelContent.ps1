param(
  [Parameter(Mandatory=$true)]
  [string]$ResourceGroup,

  [Parameter(Mandatory=$true)]
  [string]$Workspace,

  [Parameter(Mandatory=$true)]
  [string]$Region,

  [Parameter(Mandatory=$false)]
  [string[]]$Solutions = @(),

  [Parameter(Mandatory=$false)]
  [string[]]$SeveritiesToInclude = @("High","Medium"),

  [Parameter(Mandatory=$false)]
  [string]$IsGov = "false"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Normalización (quita espacios/saltos de línea invisibles)
$ResourceGroup = $ResourceGroup.Trim()
$Workspace     = $Workspace.Trim()
$Region        = $Region.Trim()

# Si Region viene en formato "France Central", avisamos
if ($Region -match "\s") {
  Write-Warning "REGION contiene espacios ('$Region'). En Azure suele ser 'francecentral', 'westeurope', etc."
}

Write-Host "== Set-SentinelContent.ps1 =="
Write-Host "ResourceGroup: $ResourceGroup"
Write-Host "Workspace:     $Workspace"
Write-Host "Region:        $Region"
Write-Host "Solutions:     $($Solutions -join ', ')"
Write-Host "Severities:    $($SeveritiesToInclude -join ', ')"
Write-Host "IsGov:         $IsGov"

# 1) Comprobar contexto Az
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
  throw "Az modules no disponibles. azure/powershell debería cargarlos automáticamente."
}

# 2) Obtener subscription actual (viene del azure/login)
$ctx = Get-AzContext
if (-not $ctx) { throw "No hay contexto Az (Get-AzContext vacío). ¿Falló azure/login?" }

$subscriptionId = $ctx.Subscription.Id
Write-Host "SubscriptionId: $subscriptionId"


Write-Host "Workspace(raw)='>$Workspace<'"
Write-Host "ResourceGroup(raw)='>$ResourceGroup<'"
Write-Host "Region(raw)='>$Region<


# 3) Obtener el Workspace ResourceId
$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $Workspace -ErrorAction Stop
$workspaceId = $ws.ResourceId
Write-Host "WorkspaceId: $workspaceId"

# 4) Instalar soluciones de Content Hub (Sentinel)
# Nota: esto usa la API de "Microsoft.OperationsManagement/solutions" en el RG del workspace.
# Algunas soluciones modernas se gestionan vía "Microsoft.SecurityInsights" / Content Hub.
# Empezamos con una instalación genérica y, si tu tenant requiere el endpoint específico de Content Hub,
# lo ajustamos en el siguiente paso con el error exacto que salga.

if ($Solutions.Count -eq 0) {
  Write-Host "No hay soluciones definidas en SOLUTIONS. Nada que instalar."
  exit 0
}

# Normaliza: si viene como string con comas, conviértelo a array
if ($Solutions.Count -eq 1 -and $Solutions[0] -match ",") {
  $Solutions = $Solutions[0].Split(",") | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ }
}

Write-Host "Instalando soluciones (mejor esfuerzo)..."

foreach ($sol in $Solutions) {
  $solutionName = $sol.Trim().Trim('"')
  if ([string]::IsNullOrWhiteSpace($solutionName)) { continue }

  Write-Host ""
  Write-Host "==> Installing/Updating solution: $solutionName"

  # Nombre del recurso "solution" (debe ser único en el RG)
  $resourceName = "SentinelSolution-$($solutionName -replace '[^a-zA-Z0-9\-]', '-')"

  # Endpoint ARM
  $apiVersion = "2015-11-01-preview"
  $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationsManagement/solutions/$resourceName?api-version=$apiVersion"

  # Body genérico (depende del publisher/product; si falla, veremos el error y lo afinamos)
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
    Write-Warning "No se pudo instalar $solutionName con el método genérico. Error: $($_.Exception.Message)"
    Write-Warning "Esto puede ser normal: algunas soluciones se despliegan vía Content Hub (Microsoft.SecurityInsights)."
    throw
  }
}

Write-Host ""
Write-Host "Fin. Si necesitas también desplegar reglas/workbooks desde archivos, dime qué contenido quieres desplegar y lo añadimos."
