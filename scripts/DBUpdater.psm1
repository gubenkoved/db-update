# Import SqlServer module -- we will need advanced Invoke-Sqlcmd from there
Import-module SqlServer

# import shared code
. $PSScriptRoot\Common.ps1
. $PSScriptRoot\New-ChangeScriptFile.ps1
. $PSScriptRoot\Update-Database.ps1

$Script:ConnectionInfo = $null

# Write-Host "Welcome to DBUpdater!"

Export-ModuleMember -Function New-ChangeScriptFile
Export-ModuleMember -Function Use-Database
Export-ModuleMember -Function Enable-DatabaseUpdate
Export-ModuleMember -Function Update-Database

# dev time exports
# Export-ModuleMember -Function Get-AppliedChanges
# Export-ModuleMember -Function Get-AllExistingChanges