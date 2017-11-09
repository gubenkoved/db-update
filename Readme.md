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

# Process

During database update:
- Special metadata table (`dbo.__SchemaChanges`) to keep track of applied changes is created if missing 
- All not applied changes are atomically applied in lexicographic order
- Functions/views/SPs are droped and recreated (if requested)

During the first run if version control is not enabled yet, the special metadata table (`dbo.__SchemaChanges`) would be created. This table tracks change scripts execution against database instance. Change with ID `__init.sql` will be marked as executed.

It's guaranteed by scripts runner that each change script would be treated _atomically_ (succeeds or fails as whole) and would be comitted to database instance only _once_.

The name of the schema change file is unique identifier of migration. This identifier is used to check whether or not specific change is applied.

## Functions/Views/SPs

Functions, views and SPs stored in form of their definitions (e.g. `create stored procedure ...`) and script runner will (if requested) drop all SPs (or functions or views) and recreate them via execution all scripts in specified folder (for SPs specified in 'storedProceduresLocation' parameter).

Order of execution these definition files is _lexicographic_. So If you have SP `A` calling SP `B`, make sure file containig `A` SP goes before file with `B` lexicographically.

Order of groups is following:
1. Functions
2. Views
3. Stored procedures

It would fulfill majority of cases, but if you need to use View in a function -- it's _not supported_ scenarion. Please keed this in mind.

# Usage

Run the following PS command against your database.

```PowerShell
.\Update-Database.ps1 -serverInstance localhost `
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
```

# Example

See example with complete folder structure in the 'test-db' folder. Just create blank DB on your local server and run it agains.


