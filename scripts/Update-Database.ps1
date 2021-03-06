# import shared code
. $PSScriptRoot\Common.ps1

function Apply-Changes
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeScriptsLocation,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $ConnectionInfo,

        [Parameter(Mandatory=$false)]
        [bool] $MarkOnlyMode = $false
    )

    [DBSCInfo[]] $appliedChanges = Get-AppliedChanges -connectionInfo $connectionInfo

    Write-Host 'Already applied changes:'
    $appliedChanges | Sort-Object -Property ChangeId | Format-Table ChangeId, AppliedAt, Notes -AutoSize

    Write-Host 'All existing on disk change scripts:'
    [FSSCInfo[]] $onDisk = Get-AllExistingChanges -dir $ChangeScriptsLocation | Populate-ExistingChangesStatus -applied $appliedChanges
    
    $onDisk | Format-Table ChangeId, CreatedAtUtc, Status, Info, Hash -AutoSize

    [FSSCInfo[]] $toBeApplied = $onDisk | Where-Object { $_.Status -eq [FSSCStatus]::Pending -or $_.Status -eq [FSSCStatus]::PendingOutOfOrder }

    Write-Host "Applying changes..."

    foreach($change in $toBeApplied)
    {
        Apply-ChangeScript -ChangeScript $change -MarkOnlyMode $MarkOnlyMode
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
        -ErrorAction Continue # do not whole this all if we can not recreate some functions
            
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
        -ErrorAction Continue # do not whole this all if we can not recreate some


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
        -folder $dir `
        -ErrorAction Continue # do not whole this all if we can not recreate some

    Write-Success "DONE `n"
}

function Update-Database
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory=$true)]
        [string] $ChangeScriptsLocation,

        [Parameter(Mandatory=$false)]
        [bool] $RecreateStoredProcedures = $false,

        [Parameter(Mandatory=$false)]
        [string] $StoredProceduresLocation,

        [Parameter(Mandatory=$false)]
        [bool] $RecreateFunctions = $false,

        [Parameter(Mandatory=$false)]
        [string] $FunctionsLocation,

        [Parameter(Mandatory=$false)]
        [bool] $RecreateViews = $false,

        [Parameter(Mandatory=$false)]
        [string] $ViewsLocation,

        [Parameter(Mandatory=$false)]
        [bool] $MakeDbRestrictedUserModeDuringUpdate = $true
    )
    Ensure-Directory -Dir $ChangeScriptsLocation -ErrorMessagePrefix "Changes scripts location is invalid." -ErrorAction Stop

    if ($RecreateStoredProcedures -eq $true) { Ensure-Directory -Dir $StoredProceduresLocation -ErrorMessagePrefix "SP location is invalid." -ErrorAction Stop }
    if ($RecreateFunctions -eq $true) { Ensure-Directory -Dir $FunctionsLocation -ErrorMessagePrefix "Functions location is invalid." -ErrorAction Stop }
    if ($RecreateViews -eq $true) { Ensure-Directory -Dir $ViewsLocation -ErrorMessagePrefix "Views location is invalid." -ErrorAction Stop }

    [DBConnectionInfo] $connectionInfo = Ensure-DatabaseConnectionInfo -ErrorAction Stop

    Write-Host "Updating database $($connectionInfo.Database)..."

    [bool] $versionControlEnabled = Check-IsVersionControlEnabled -ErrorAction Stop

    if (-not $versionControlEnabled)
    {
        Write-Host 'Version control not yet enabled... Enabling!'

        Enable-DatabaseUpdate
    }

    if ($MakeDbRestrictedUserModeDuringUpdate)
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
        Apply-Changes -ChangeScriptsLocation $ChangeScriptsLocation -ConnectionInfo $connectionInfo
        
        if ($RecreateFunctions) { Recreate-Functions -connectionInfo $connectionInfo -dir $FunctionsLocation }
        if ($RecreateViews) { Recreate-Views -connectionInfo $connectionInfo -dir $ViewsLocation }
        if ($RecreateStoredProcedures) { Recreate-SPs -connectionInfo $connectionInfo -dir $StoredProceduresLocation }

        Write-Host "Database update has been successfully completed."
    } catch
    {
        Write-Host "An error occured during database update process. $($_.Exception.Message)" -ForegroundColor Red
        # throw $_.Exception 
        throw # preserve stack trace
    }
    finally
    {
        if ($MakeDbRestrictedUserModeDuringUpdate)
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

function Mark-ChangeScriptsAsApplied
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory=$true)]
        [string] $ChangeScriptsLocation
    )

    Ensure-Directory -Dir $ChangeScriptsLocation -ErrorMessagePrefix "Changes scripts location is invalid." -ErrorAction Stop

    [DBConnectionInfo] $connectionInfo = Ensure-DatabaseConnectionInfo -ErrorAction Stop

    Write-Host "Updating database $($connectionInfo.Database)..."

    [bool] $versionControlEnabled = Check-IsVersionControlEnabled -ErrorAction Stop

    if (-not $versionControlEnabled)
    {
        Write-Host 'Version control not yet enabled... Enabling!'

        Enable-DatabaseUpdate
    }

    try
    {
        Apply-Changes -ChangeScriptsLocation $ChangeScriptsLocation -ConnectionInfo $connectionInfo -MarkOnlyMode $true

        Write-Host "Database update has been successfully completed."
    } catch
    {
        Write-Host "An error occured during database update process. $($_.Exception.Message)" -ForegroundColor Red
        # throw $_.Exception 
        throw # preserve stack trace
    }
}