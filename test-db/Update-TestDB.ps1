..\scripts\Update-Database.ps1 -serverInstance localhost `
    -dbuser 'sa' `
    -dbpass 'sa' `
    -database 'test' `
    -changeScriptsLocation '.\schema-changes' `
    -recreateStoredProcedures $true <# optional #> `
    -storedProceduresLocation '.\stored-procedures' <# optional #> `
    -recreateFunctions $true <# optional #> `
    -functionsLocation '.\functions' <# optional #> `
    -recreateViews $true <# optional #> `
    -viewsLocation '.\views' <# optional #> `
    -useADAuth $false <# optional #> `
    -makeDbRestrictedUserModeDuringUpdate $true <# optional #>