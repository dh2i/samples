[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterGroupName = "SQL Server (MSSQLSERVER)",

    [Parameter(Mandatory = $false)]
    [string[]]$AllowedOwners = @("sqlwins1n1", "sqlwins1n2"),

    [Parameter(Mandatory = $false)]
    [switch]$SkipResources,

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

function Normalize-NodeName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    return $Name.Trim().ToLowerInvariant()
}

$normalizedAllowedOwners = @(
    $AllowedOwners |
        ForEach-Object { Normalize-NodeName $_ } |
        Where-Object { $_ } |
        Sort-Object -Unique
)

if ($normalizedAllowedOwners.Count -lt 1) {
    throw "AllowedOwners must contain at least one node name."
}

Import-Module FailoverClusters -ErrorAction Stop

$clusterGroup = Get-ClusterGroup -Name $ClusterGroupName -ErrorAction Stop

Write-Host "Applying possible owners for group '$ClusterGroupName'..."
Write-Host "Allowed owners: $($normalizedAllowedOwners -join ', ')"

# Set group-level possible owners.
$clusterGroup | Set-ClusterOwnerNode -Owners $normalizedAllowedOwners

if (-not $SkipResources) {
    $resources = @(Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $clusterGroup.Name })
    foreach ($resource in $resources) {
        Write-Host "Setting resource owners: $($resource.Name)"
        $resource | Set-ClusterOwnerNode -Owners $normalizedAllowedOwners
    }
}

Write-Host ""
Write-Host "Updated possible owners successfully." -ForegroundColor Green

if ($PassThru) {
    [pscustomobject]@{
        ClusterGroupName = $clusterGroup.Name
        AllowedOwners    = $normalizedAllowedOwners
        ResourcesUpdated = if ($SkipResources) { 0 } else { @($resources).Count }
    }
}
