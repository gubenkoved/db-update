[CmdletBinding(SupportsShouldProcess=$True)]
param
(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string] $changeScriptsLocation,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [DBConnectionInfo] $connectionInfo,

    [Parameter(Mandatory=$true)]
    [bool] $autoPickupLostScripts = $false
)
 
. $PSScriptRoot\Common.ps1
#. D:\Repos\kb-modules\Database\Scripts\Common.ps1

function Get-AppliedDBChanges
{
    [OutputType([DBSCInfo[]])]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )

    $result = Invoke-Sqlcmd2 `
      -Query 'SELECT * FROM SchemaChanges' `
      -ConnectionInfo $connectionInfo `
      -ErrorAction Stop

    return $result `
        | % { New-Object DBSCInfo -Property @{Name = $_.ScriptName; AppliedAtUtc = $_.DateApplied; Notes = $_.Notes; Version = "$($_.MajorReleaseNumber).$($_.MinorReleaseNumber).$($_.BuildReleaseNumber).$($_.PointReleaseNumber)" } } `
        | Sort-Object -Property Version
}

function Populate-ExistingScriptStatus
{
   [OutputType([FSSCInfo[]])]
   param
   (
        [Parameter(Mandatory=$True, ValueFromPipeline=$True)]
		[FSSCInfo[]] $fsSCInfos,

        [Parameter(Mandatory=$True)]
        [DBSCInfo[]]
        $appliedChanges
   )

    process
    {
        foreach ($fsSc_ in $fsSCInfos)
        {
            [FSSCInfo] $fsSc = $fsSc_
            [version] $dbVersion = ($appliedChanges | Sort-Object -Property Version | Select-Object -Last 1).Version
            [DBSCInfo] $findResult = $appliedChanges | Where-Object { $fsSc.Version -eq $_.Version }

            if ($findResult)
            {
                $fsSc.StatusDesc = "Applied at $($findResult.AppliedAtUtc)"
                $fsSc.Status = [FSSCStatus]'Applied'
            } elseif ($fsSc.Version -lt $dbVersion)
            {
                $fsSc.StatusDesc = 'WARNING: LOST script!'
                $fsSc.Status = [FSSCStatus]'Lost'
            } else
            {
                $fsSc.StatusDesc = 'Pending'
                $fsSc.Status = [FSSCStatus]'Pending'
            }

            return $fsSc
        }
    }
}

function Get-DBVersion
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )
    
    [DBSCInfo[]] $allAppliedChanges = Get-AppliedDBChanges -connectionInfo $connectionInfo

    if ($allAppliedChanges.Count -gt 0)
    {
         return ($allAppliedChanges | Select-Object -Last 1).Version
    }
    
    return $null
}

function Apply-ChangeScript
{
    [CmdletBinding(SupportsShouldProcess=$True)]
    param
    (
        [Parameter(Mandatory=$true)]
        [FSSCInfo]
        $changeScript,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo,

        [Parameter(Mandatory=$false)]
        [string] $additionalNote = ""
    )

    $scriptName = $changeScript.Name

    Write-Host -NoNewline " Apply '$scriptName' change script... "

    [version]$scriptVer = $changeScript.Version

    $major = $scriptVer.Major
    $minor = $scriptVer.Minor
    $build = $scriptVer.Build
    $point = $scriptVer.Revision

    $notes = Get-ScriptNotes -schemaChangeInfo $changeScript
    $notes += " $additionalNote"
    $notes = $notes.Replace("'", "''") # encode just in case

    $sql = [IO.File]::ReadAllText($changeScript.Path)

    $sql += "
    GO
    ;INSERT INTO dbo.SchemaChanges (MajorReleaseNumber, MinorReleaseNumber, BuildReleaseNumber, PointReleaseNumber, ScriptName, DateApplied, Notes)
                VALUES ($major, $minor, $build, $point, '$scriptName', GETDATE(), '$notes')"

    $sql = Make-SQLAtomic $sql

    Write-Verbose ("`nExecuting SQL block:`n" + $sql);

    try
    {
        $elapsed = Measure-Command `
        {
            $output = Exec-SQL -query $sql -connectionInfo $connectionInfo -ErrorAction Stop
        } -ErrorAction Stop
        
        # ensure applied
        [DBSCInfo] $scriptDbApplicationInfo = Get-AppliedDBChanges -connectionInfo $connectionInfo `
            | Where-Object { $_.Version -eq $changeScript.Version }

        if (-not $scriptDbApplicationInfo)
        {
            throw "An error occured applying '$scriptName' change script`n $output"
        }

    } catch
    {
        Write-Host ("  FAILED -- {0}`n" -f $_.Exception.ToString()) `
            -ForegroundColor Red -BackgroundColor Yellow

        throw
    }
        
    Write-Success ('  SUCCESS ({0:F3} s.)' -f $elapsed.TotalSeconds)
}

[DBSCInfo[]] $appliedChanges = Get-AppliedDBChanges -connectionInfo $connectionInfo

Write-Host 'Already applied changes:'
$appliedChanges | Format-Table Version, AppliedAtUtc, Name, Notes -AutoSize

Write-Host 'All existing on disk DB update scripts:'

[FSSCInfo[]] $existing = Get-AllExistingChanges -dir $changeScriptsLocation `
    | Populate-ExistingScriptStatus -appliedChanges $appliedChanges

$existing | Format-Table Version, Name, CreatedAtUtc, Status, StatusDesc, @{Expression={Get-MD5FileHash $_.Path};Label="Hash"}

$dbVersion = Get-DBVersion -connectionInfo $connectionInfo

Write-Host "Current DB Version: $dbVersion"

[FSSCInfo[]] $toBeApplied = $existing `
    | Where-Object { $_.Status -eq [FSSCStatus]'Pending' } `
    | Sort-Object -Property Version

Write-Host "`nApplying changes..."

foreach($toApply in $toBeApplied)
{
    Apply-ChangeScript $toApply -connectionInfo $connectionInfo

    #Read-Host "Proceed?"
}

Write-Success "DONE`n"

[version] $dbVersion = Get-DBVersion -connectionInfo $connectionInfo

Write-Host "New DB Version: $dbVersion`n"

if ($autoPickupLostScripts -eq $true)
{
    [FSSCInfo[]] $lostScripts = $existing `
        | Where-Object { $_.Status -eq [FSSCStatus]'Lost' } `

    if ($lostScripts)
    {
        Write-Host "Automatically picking up $($lostScripts.Length) LOST script(s)..."

        foreach ($lostScript in $lostScripts)
        {
            try
            {
                Apply-ChangeScript $lostScript -connectionInfo $connectionInfo -additionalNote 'AUTO PICKUP LOST'
            } catch
            {
                # show and swallow error - we just trying to pick up lost script - if we can not - that's fine
                Write-Warning "Unable to apply lost script: $($_.Exception.Message)"
            }
        }

        Write-Success "DONE"
    }
}