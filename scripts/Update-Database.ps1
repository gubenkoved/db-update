[CmdletBinding(SupportsShouldProcess=$True)]
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
    [bool] $applyFeatureChangeScripts = $false,

    [Parameter(Mandatory=$false)]
    [bool] $autoPickupLostScripts = $false
)

Push-Location
Add-PSSnapin SqlServerCmdletSnapin100 -ErrorAction SilentlyContinue
Add-PSSnapin SqlServerProviderSnapin100 -ErrorAction SilentlyContinue
Import-Module sqlps -disablenamechecking -ErrorAction SilentlyContinue
Pop-Location

# import common library function
. $PSScriptRoot\Common.ps1

[DBConnectionInfo] $connectionInfo = Create-ConnectionInfo -Server $serverInstance -Database $database -DbUser $dbuser -DbPass $dbpass
[bool] $versionControlEnabled = Check-DBVersionControl -connectionInfo $connectionInfo -errorAction Stop

if (-not $versionControlEnabled)
{
    Write-Host 'Version control not yet enabled... Initialize with zero version'

    . $PSScriptRoot\Start-DBVersionControl.ps1 -connectionInfo $connectionInfo -currentVersion "0.0.0.0"
}

Write-Host -NoNewline 'Make DB RESTRICTED_USER mode ... '

Invoke-Sqlcmd2 `
    -Query "ALTER DATABASE $($connectionInfo.Database) SET RESTRICTED_USER WITH ROLLBACK IMMEDIATE;" `
    -QueryTimeout 120 `
    -ConnectionInfo $connectionInfo `
    -ErrorAction Stop

Write-Success 'OK'

try
{
    # apply change scripts
    . $PSScriptRoot\Apply-DBPatches.ps1 `
        -changeScriptsLocation $changeScriptsLocation `
        -connectionInfo $connectionInfo `
        -autoPickupLostScripts $autoPickupLostScripts `
        -Verbose

    # apply feature change scripts
    if ($applyFeatureChangeScripts -eq $true)
    {
        Write-Host "Applying feature change scripts`n"

        . $PSScriptRoot\Apply-DBFeaturePatches.ps1 `
            -featureScriptsLocation $changeScriptsLocation `
            -connectionInfo $connectionInfo `
            -featureScriptsPrefix 'feature.' `
            -Verbose
    }

    if ($recreateFunctions)
    {
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
            -folder $functionsLocation `
            -continueOnErrors $true
            
       Write-Success "DONE `n"
    }

    if ($recreateViews)
    {
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
            -folder $viewsLocation `
            -continueOnErrors $false

        Write-Success "DONE `n"
    }

    if ($recreateStoredProcedures)
    {
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
            -folder $storedProceduresLocation

        Write-Success "DONE `n"
    }

    exit 0
} catch
{
    #Write-Error -NoNewline "ERROR occured $($_.Exception.Message)"

    #Write-Error "An error occured during database update process."

    throw
}
finally
{
    Write-Host -NoNewline "`nMake DB MULTI_USER back... "

    Invoke-Sqlcmd2 `
        -Query "ALTER DATABASE $($connectionInfo.Database) SET MULTI_USER;" `
        -ConnectionInfo $connectionInfo `
        -ErrorAction Stop

    Write-Success 'OK'
}