# Usage

Run the following PS command against your database.

```PowerShell
.\Database-Update.ps1 -serverInstance localhost `
    -dbuser 'sa' `
    -dbpass 'sa' `
    -database 'test' `
    -changeScriptsLocation '.\schema-changes' `
    -recreateStoredProcedures $true `
    -storedProceduresLocation '.\stored-procedures' `
    -recreateFunctions $true `
    -functionsLocation '.\functions' `
    -recreateViews $true `
    -viewsLocation '.\views'
```

This command will:
- Create metadata table `SchemaChanges` to track applied schema change scripts (if DB is not under tracking yet)
- Atomically apply pending change scripts
- Drop and recreate (if requested) functions/views/SPs (in order)

See example with complete folder structure in the 'test-db' folder.
