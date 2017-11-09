[CmdletBinding()]
Param
(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string] $serverInstance,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string] $database,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string] $dbuser,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string] $dbpass,

    [Parameter(Mandatory=$false)]
    [bool] $useADAuth = $false,

    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_})]
    [string] $changeScriptsLocation,

    [Parameter(Mandatory=$false)]
    [bool] $recreateStoredProcedures = $true,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string] $storedProceduresLocation,

    [Parameter(Mandatory=$false)]
    [bool] $recreateFunctions = $true,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string] $functionsLocation,

    [Parameter(Mandatory=$false)]
    [bool] $recreateViews = $true,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string] $viewsLocation,

    [Parameter(Mandatory=$false)]
    [bool] $makeDbRestrictedUserModeDuringUpdate = $true
)

# import common library function
. $PSScriptRoot\Common.ps1

function Apply-Changes
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $changeScriptsLocation,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )

    [DBSCInfo[]] $appliedChanges = Get-AppliedChanges -connectionInfo $connectionInfo

    Write-Host 'Already applied changes:'
    $appliedChanges | Sort-Object -Property ChangeId | Format-Table ChangeId, AppliedAt, Notes -AutoSize

    Write-Host 'All existing on disk change scripts:'
    [FSSCInfo[]] $onDisk = Get-AllExistingChanges -dir $changeScriptsLocation | Populate-ExistingChangesStatus -applied $appliedChanges
    
    $onDisk | Format-Table ChangeId, CreatedAtUtc, Status, Info, Hash -AutoSize

    [FSSCInfo[]] $toBeApplied = $onDisk | Where-Object { $_.Status -eq [FSSCStatus]::Pending -or $_.Status -eq [FSSCStatus]::PendingOutOfOrder }

    Write-Host "`nApplying changes..."

    foreach($change in $toBeApplied)
    {
        Apply-ChangeScript -changeScript $change -connectionInfo $connectionInfo
    }

    Write-Success "DONE`n"
}

function Recreate-Functions
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $dir,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )

    Write-Host -NoNewline 'Drop all functions... '

    try
    {
        Invoke-Sqlcmd2 `
            -Query "DECLARE @sql NVARCHAR(MAX) = N'';

                    SELECT @sql += N'DROP FUNCTION '
                        + schema_name(schema_id) + '.' + QUOTENAME(name) + ';
                        '
                    FROM sys.objects
                    WHERE type_desc LIKE '%FUNCTION%';

                    EXEC sp_executesql @sql;" `
            -ConnectionInfo $connectionInfo `
            -ErrorAction SilentlyContinue # it's OK if we were unable to drop all functions

        Write-Success 'OK'
    }
    catch
    {
        Write-Warning "FAILED: $($_.Exception.Message)"
        throw
    }

    Write-Host 'Recreate functions...'

    Run-SqlScriptsInFolder `
        -connectionInfo $connectionInfo `
        -folder $dir `
        -continueOnErrors $true
            
    Write-Success "DONE `n"
}

function Recreate-Views
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $dir,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )

    Write-Host -NoNewline 'Drop all views... '

    try
    {
        Invoke-Sqlcmd2 `
            -Query "DECLARE @sql NVARCHAR(MAX) = N'';

                    SELECT @sql += N'DROP VIEW '
                        + QUOTENAME(name) + '; '
                    FROM sys.views
                    where schema_name(schema_id) <> 'sys'

                    select @sql

                    EXEC sp_executesql @sql;" `
            -ConnectionInfo $connectionInfo `
            -ErrorAction Stop | Out-Null

        Write-Success 'OK'
    }
    catch
    {
        Write-Warning "FAILED: $($_.Exception.Message)"
        throw
    }

    Write-Host 'Recreate views...'

    Run-SqlScriptsInFolder `
        -connectionInfo $connectionInfo `
        -folder $dir `
        -continueOnErrors $false

    Write-Success "DONE `n"
}

function Recreate-SPs
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $dir,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )

    Write-Host -NoNewline 'Drop all stored procedures... '

    try
    {
        Invoke-Sqlcmd2 `
        -Query "DECLARE @sql NVARCHAR(MAX) = N'';

                    SELECT @sql += N'DROP PROCEDURE ' + schema_name(schema_id) + '.'
                        + QUOTENAME(name) + '; '
                    FROM sys.procedures

                    EXEC sp_executesql @sql;" `
        -ConnectionInfo $connectionInfo `
        -ErrorAction Stop

        Write-Success 'OK'
    }
    catch
    {
        Write-Warning "FAILED: $($_.Exception.Message)"
        throw
    }

    Write-Host 'Recreate stored procedures...'

    Run-SqlScriptsInFolder `
        -connectionInfo $connectionInfo `
        -folder $dir

    Write-Success "DONE `n"
}

# MAIN - UPDATE PROCESS

function Update-Database
{
    [DBConnectionInfo] $connectionInfo = Create-ConnectionInfo -Server $serverInstance -Database $database -DbUser $dbuser -DbPass $dbpass -UseAzureADAuth $useADAuth
    [bool] $versionControlEnabled = Check-IsVersionControlEnabled -connectionInfo $connectionInfo -errorAction Stop

    if (-not $versionControlEnabled)
    {
        Write-Host 'Version control not yet enabled... Initialize with zero version'

        . $PSScriptRoot\Start-DBVersionControl.ps1 -connectionInfo $connectionInfo
    }

    if ($makeDbRestrictedUserModeDuringUpdate)
    {
        Write-Host -NoNewline 'Make DB RESTRICTED_USER mode ... '

        Invoke-Sqlcmd2 `
            -Query "ALTER DATABASE [$($connectionInfo.Database)] SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;" `
            -QueryTimeout 120 `
            -ConnectionInfo $connectionInfo `
            -ErrorAction Stop

        Write-Success "OK`n"
    }

    try
    {
        # apply changes
        Apply-Changes -changeScriptsLocation $changeScriptsLocation -connectionInfo $connectionInfo

        if ($recreateFunctions)
        {
            Recreate-Functions -connectionInfo $connectionInfo -dir $functionsLocation
        }

        if ($recreateViews)
        {
            Recreate-Views -connectionInfo $connectionInfo -dir $viewsLocation
        }

        if ($recreateStoredProcedures)
        {
            Recreate-SPs -connectionInfo $connectionInfo -dir $storedProceduresLocation
        }

        exit 0
    } catch
    {
        #Write-Error -NoNewline "ERROR occured $($_.Exception.Message)"

        #Write-Error "An error occured during database update process."

        throw $_.Exception
    }
    finally
    {
        if ($makeDbRestrictedUserModeDuringUpdate)
        {
            Write-Host -NoNewline "`nMake DB MULTI_USER back... "

            Invoke-Sqlcmd2 `
                -Query "ALTER DATABASE [$($connectionInfo.Database)] SET MULTI_USER;" `
                -ConnectionInfo $connectionInfo `
                -ErrorAction Stop
        }

        Write-Success 'OK'
    }
}

Update-Database