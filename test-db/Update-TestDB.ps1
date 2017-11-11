Push-Location $PSScriptRoot

try
{
    Import-Module ..\scripts\DBUpdater.psm1 -Force

    Use-Database -Server . `
        -Database 'test6' `
        -DbUser 'sa' `
        -DbPass 'sa' `
        -UseAzureADAuth $false <# optional #>

    Update-Database -ChangeScriptsLocation '.\schema-changes' `
        -RecreateStoredProcedures $true `
        -StoredProceduresLocation '.\stored-procedures' <# optional #> `
        -RecreateFunctions $true <# optional #> `
        -FunctionsLocation '.\functions' <# optional #> `
        -RecreateViews $true <# optional #> `
        -ViewsLocation '.\views' <# optional #> `
        -MakeDbRestrictedUserModeDuringUpdate $true <# optional #>
} finally
{
    Pop-Location
}