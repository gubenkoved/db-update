# Origins

Inspired and based on this article by Jeff Atwood:

https://blog.codinghorror.com/get-your-database-under-version-control/

# Prerequisites

- ODBC 13.1

    https://www.microsoft.com/en-us/download/details.aspx?id=53339 
- Microsoft® Command Line Utilities 13.1 for SQL Server®

    https://www.microsoft.com/en-us/download/details.aspx?id=53591 
- Microsoft Online Services Sign-In Assistant for IT Professionals RTW

    http://go.microsoft.com/fwlink/?LinkId=234947 
- Microsoft® SQL Server® 2016 Feature Pack (PowerShellTools.msi)

    https://www.microsoft.com/en-us/download/details.aspx?id=52676

- PowerShell module for SQL Server if missing

    https://www.powershellgallery.com/packages/SqlServer/

```PowerShell
Install-Module -Name SqlServer 
```

*Note:* In some cases differnt version of `Invoke-Sqlcmd` might be already installed and causing troubles. Make sure your version of `Invoke-Sqlcmd` supports `-ConnectionString` parameter. Personally I ended up with renaming this directory that contains old `Invoke-Sqlcmd`:

`C:\Program Files\Microsoft SQL Server\130\Tools\PowerShell\Modules\SQLPS`

# Process

During database update:
- Special metadata table (`dbo.__SchemaChanges`) to keep track of applied changes is created (if missing)
- All not applied changes are atomically applied in _lexicographic_ order
- Functions/views/SPs are droped and recreated in _lexicographic_ order (if requested)

During the first run if version control is not enabled yet, the special metadata table (`dbo.__SchemaChanges`) would be created. This table tracks change scripts execution against database instance. Change with ID `__init.sql` will be marked as executed as part of the first run.

It's guaranteed by scripts runner that each change script would be treated _atomically_ (succeeds or fails as a whole) and would be committed to the database instance only _once_.

The name of the schema change file is unique identifier of migration. This identifier is used to check whether specific change is applied.

## Functions/Views/SPs

Functions, views and SPs stored in form of their definitions (e.g. `create stored procedure ...`) and script runner will (if requested) drop all SPs (or functions or views) and recreate them via execution all scripts in specified folder (for SPs specified in `StoredProceduresLocation` parameter).

Order of execution these definition files is _lexicographic_. So If you have SP `A` calling SP `B`, make sure file containig `A` SP goes before file with `B` _lexicographically_. This is one of the limitation of this holistic approach. However you can always to file renames to manage order.

Order of groups is following:
1. Functions
2. Views
3. Stored procedures

It would fulfill majority of cases, but if you need to use View in a function -- it's _not supported_ scenario. Please keed this in mind.

# Usage

Package contains PowerShell module called `DBUpdater` which contains the following functions:

- `Use-Database` points module to the database, should be invoked prior to commands that require DB connection
- `Enable-DatabaseUpdate` creates metadata table in the database (this is optional as it will be done in scope of `Update-Database` if needed)
- `Update-Database` runs database update process
- `New-ChangeScriptFile` creates new schema change file with given naming convention `yyyyMMddHHmmss_name`

Here is the sample that allows to run database update.

```PowerShell
Import-Module .\DBUpdater.psm1

Use-Database -Server . `
    -Database 'test' `
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
```

# Example

See example with complete folder structure in the `test-db` folder. Just create blank DB on your local server and run it against.