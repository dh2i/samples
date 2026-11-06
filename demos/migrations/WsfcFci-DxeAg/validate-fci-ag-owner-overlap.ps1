[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterGroupName = "SQL Server (MSSQLSERVER)",

    [Parameter(Mandatory = $false)]
    [string]$FciReplicaName = "SQLWINS1FCI",

    [Parameter(Mandatory = $false)]
    [string[]]$AgReplicaNodes = @("sqlwins2n1", "sqlwins2n2")
)

$ErrorActionPreference = "Stop"

function Normalize-NodeName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    return $Name.Trim().ToLowerInvariant()
}

function Get-OwnerNodeNames {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $results = @()
    $ownerEntries = @(Get-ClusterOwnerNode -InputObject $InputObject)

    foreach ($entry in $ownerEntries) {
        if ($null -eq $entry) {
            continue
        }

        # Different FailoverClusters versions can return different shapes.
        if ($entry -is [string]) {
            $results += $entry
            continue
        }

        if ($entry.PSObject.Properties.Match('Name').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$entry.Name)) {
            $results += [string]$entry.Name
            continue
        }

        if ($entry.PSObject.Properties.Match('NodeName').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$entry.NodeName)) {
            $results += [string]$entry.NodeName
            continue
        }

        if ($entry.PSObject.Properties.Match('OwnerNodes').Count -gt 0 -and $null -ne $entry.OwnerNodes) {
            foreach ($ownerNode in @($entry.OwnerNodes)) {
                if ($null -eq $ownerNode) {
                    continue
                }

                if ($ownerNode.PSObject.Properties.Match('Name').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$ownerNode.Name)) {
                    $results += [string]$ownerNode.Name
                    continue
                }

                $ownerNodeText = [string]$ownerNode
                if (-not [string]::IsNullOrWhiteSpace($ownerNodeText)) {
                    $results += $ownerNodeText
                }
            }
            continue
        }

        $entryText = [string]$entry
        if (-not [string]::IsNullOrWhiteSpace($entryText)) {
            $results += $entryText
        }
    }

    return @($results | Sort-Object -Unique)
}

function Get-NormalizedOwnerNodes {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    return @(
        Get-OwnerNodeNames -InputObject $InputObject |
            ForEach-Object { Normalize-NodeName $_ } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-Overlap {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string[]]$Left,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string[]]$Right
    )

    $leftValues = @($Left | Where-Object { $_ })
    $rightValues = @($Right | Where-Object { $_ })

    if ($leftValues.Count -eq 0 -or $rightValues.Count -eq 0) {
        return @()
    }

    return @($leftValues | Where-Object { $_ -in $rightValues } | Sort-Object -Unique)
}

try {
    Import-Module FailoverClusters -ErrorAction Stop
}
catch {
    Write-Error "FailoverClusters module could not be loaded. Run this script on a WSFC node with Failover Clustering tools installed."
    exit 10
}

try {
    $clusterGroup = Get-ClusterGroup -Name $ClusterGroupName -ErrorAction Stop
}
catch {
    Write-Error "Cluster group '$ClusterGroupName' not found."
    exit 11
}

$fciGroupOwnerNodes = Get-NormalizedOwnerNodes -InputObject $clusterGroup
$agNodes = @($AgReplicaNodes | ForEach-Object { Normalize-NodeName $_ } | Where-Object { $_ })

if ($null -eq $fciGroupOwnerNodes) {
    $fciGroupOwnerNodes = @()
}

if ($agNodes.Count -eq 0) {
    Write-Error "No AG replica nodes were provided. Pass -AgReplicaNodes with one or more node names."
    exit 12
}

$groupOverlap = Get-Overlap -Left $agNodes -Right $fciGroupOwnerNodes

$resourceOverlaps = @()
$resourceOwnerUnion = @()
$clusterResources = @(Get-ClusterResource | Where-Object { $_.OwnerGroup -eq $clusterGroup.Name })

foreach ($resource in $clusterResources) {
    $resourceOwners = Get-NormalizedOwnerNodes -InputObject $resource
    if ($resourceOwners.Count -eq 0) {
        continue
    }

    $resourceOwnerUnion += $resourceOwners
    $overlap = Get-Overlap -Left $agNodes -Right $resourceOwners
    if ($overlap.Count -gt 0) {
        $resourceOverlaps += [pscustomobject]@{
            ResourceName = $resource.Name
            OverlapNodes = $overlap
        }
    }
}

$resourceOwnerUnion = @($resourceOwnerUnion | Sort-Object -Unique)
if ($null -eq $resourceOwnerUnion) {
    $resourceOwnerUnion = @()
}
$resourceUnionOverlap = Get-Overlap -Left $agNodes -Right $resourceOwnerUnion

Write-Host "=== FCI vs AG Owner Overlap Validation ==="
Write-Host "FCI Replica Name  : $FciReplicaName"
Write-Host "Cluster Group     : $ClusterGroupName"
Write-Host "FCI Group Owners  : $($fciGroupOwnerNodes -join ', ')"
Write-Host "FCI Resource Owners (union): $($resourceOwnerUnion -join ', ')"
Write-Host "AG Replica Nodes  : $($agNodes -join ', ')"

if ($resourceOverlaps.Count -gt 0) {
    Write-Host ""
    Write-Host "Resource-level overlap details:" -ForegroundColor Yellow
    foreach ($item in $resourceOverlaps) {
        Write-Host (" - {0}: {1}" -f $item.ResourceName, ($item.OverlapNodes -join ', ')) -ForegroundColor Yellow
    }
}

if ($groupOverlap.Count -gt 0 -or $resourceUnionOverlap.Count -gt 0) {
    Write-Host ""
    Write-Host "OVERLAP DETECTED:" -ForegroundColor Red
    Write-Host "The following nodes are both FCI possible owners and AG replicas:" -ForegroundColor Red
    @(($groupOverlap + $resourceUnionOverlap) | Sort-Object -Unique) | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "SQL Server AG creation can fail with error 19405 in this state."
    exit 2
}

Write-Host ""
Write-Host "No overlap detected. FCI owners and AG replica nodes are disjoint." -ForegroundColor Green
exit 0
