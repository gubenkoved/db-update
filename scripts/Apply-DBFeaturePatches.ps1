[CmdletBinding(SupportsShouldProcess=$True)]
Param
(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string] $featureScriptsLocation,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string] $featureScriptsPrefix,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [DBConnectionInfo] $connectionInfo
)

. $PSScriptRoot\Common.ps1

function Create-FeatureChangesTrackingTableIfMissing()
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )

    [string] $query = "if (object_id('dbo.FeatureChanges') IS NULL)
    begin
    CREATE TABLE [dbo].[FeatureChanges](
    [ScriptName] [nvarchar](256) NOT NULL,
    [DateApplied] [datetime] NOT NULL,
    [Notes] [nvarchar](max) NULL,
    CONSTRAINT [PK_FeatureChanges] PRIMARY KEY CLUSTERED 
    (
    [ScriptName] ASC
    )
    )
  end"

    $result = Invoke-Sqlcmd2 `
      -Query $query `
      -ConnectionInfo $connectionInfo `
      -ErrorAction Stop
}

function Get-AppliedDBFeatureChanges
{
    [OutputType([FeatureDBSCInfo[]])]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )
    
    [array] $sqlResult = Invoke-Sqlcmd2 `
      -Query 'SELECT * FROM FeatureChanges' `
      -ConnectionInfo $connectionInfo `
      -ErrorAction Stop

    [FeatureDBSCInfo[]] $result = $sqlResult `
        | % { New-Object FeatureDBSCInfo -Property @{Name = $_.ScriptName; AppliedAtUtc = $_.DateApplied; Notes = $_.Notes; } } `
        | Sort-Object -Property Version

    return $result
}

function Get-AllExistingFeatureChanges
{
   [OutputType([FeatureFSSCInfo[]])]
   param
   (
     [string]
     $dir
   )

    [FeatureFSSCInfo[]] $scripts = Get-ChildItem $dir `
        | Where-Object { $_.Name.StartsWith($featureScriptsPrefix) -and $_.Name.EndsWith('.sql')  } `
        | % { New-Object FeatureFSSCInfo -Property @{`
            Name = $_.Name
            Path = $_.FullName
            CreatedAtUtc = $_.CreationTimeUtc
            Status = [FSSCStatus] 'Undefined' } } `
        | Sort-Object -Property ScriptName

    return $scripts
}

function Populate-ExistingFeatureScriptStatus
{
   [OutputType([FeatureFSSCInfo[]])]
   param
   (
        [Parameter(Mandatory=$True, ValueFromPipeline=$True)]
		[FeatureFSSCInfo[]] $fsSCInfos,

        [Parameter(Mandatory=$True)]
        [FeatureDBSCInfo[]]
        $appliedFeatureChanges
   )

    process
    {
        foreach ($fsSc_ in $fsSCInfos)
        {
            [FeatureFSSCInfo] $fsSc = $fsSc_
            [string] $lastAppliedFeatureScriptName = ($appliedFeatureChanges | Sort-Object -Property Name | Select-Object -Last 1).Name
            [FeatureDBSCInfo] $findResult = $appliedFeatureChanges | Where-Object { $fsSc.Name -eq $_.Name }

            if ($findResult)
            {
                $fsSc.StatusDesc = "Applied at $($findResult.AppliedAtUtc)"
                $fsSc.Status = [FSSCStatus]'Applied'
            } elseif ($fsSc.Name -lt $lastAppliedFeatureScriptName)
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

function Apply-FeatureChangeScript
{
    [CmdletBinding(SupportsShouldProcess=$True)]
    param
    (
        [FeatureFSSCInfo]
        $featureScript,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )

    Write-Host -NoNewline " Apply '$($featureScript.Name)' feature update script... "

    $notes = Get-ScriptNotes -path $featureScript.Path
    $notes = $notes.Replace("'", "''") # encode just in case

    $sql = [IO.File]::ReadAllText($featureScript.Path)

    $sql += "
    GO
    ;INSERT INTO dbo.FeatureChanges (ScriptName, DateApplied, Notes)
                VALUES ('$($featureScript.Name)', GETDATE(), '$notes')"

    $sql = Make-SQLAtomic $sql

    Write-Verbose ("`nExecuting SQL block:`n" + $sql);

    try
    {
        $elapsed = Measure-Command `
        {
            $output = Exec-SQL -query $sql -connectionInfo $connectionInfo
        }

        # ensure applied
        [FeatureDBSCInfo] $lastAppliedFeaturePatch = Get-AppliedDBFeatureChanges -connectionInfo $connectionInfo `
          | Sort-Object -Property { $_.Name } `
          | Select-Object -Last 1

        if ($lastAppliedFeaturePatch.Name -ne $featureScript.Name)
        {
            throw "An error occured applying '$($featureScript.ScriptName)' feature change script.`n$output"
        }
        
    } catch
    {
        Write-Host ("  FAILED -- {0}`n" -f $_.Exception.ToString()) `
            -ForegroundColor Red -BackgroundColor Yellow

        throw
    }
        
    Write-Success ('  SUCCESS ({0:F3} s.)' -f $elapsed.TotalSeconds)
}

function Main()
{
    Create-FeatureChangesTrackingTableIfMissing -connectionInfo $connectionInfo

    [FeatureDBSCInfo[]] $appliedFeatureChanges = Get-AppliedDBFeatureChanges -connectionInfo $connectionInfo

    Write-Host 'Already applied feature changes:'
    $appliedFeatureChanges | Format-Table Name, AppliedAtUtc, Notes -AutoSize

    Write-Host 'All existing on disk DB feature update scripts:'
    [FeatureFSSCInfo[]] $existingFeatureChanges = Get-AllExistingFeatureChanges -dir $featureScriptsLocation -connectionInfo $connectionInfo `
        | Populate-ExistingFeatureScriptStatus -appliedFeatureChanges $appliedFeatureChanges
    
    $existingFeatureChanges | Format-Table Name, CreatedAtUtc, Status, StatusDesc -AutoSize

    [FeatureFSSCInfo[]] $fcToBeApplied = $existingFeatureChanges | Where-Object { $_.Status -eq [FSSCStatus] 'Pending' }

    Write-Host "`nApplying feature changes..."

    foreach($fc in $fcToBeApplied)
    {
        Apply-FeatureChangeScript -featureScript $fc -connectionInfo $connectionInfo
    }

    Write-Success "DONE`n"
}

Main