Set-StrictMode -Version 3.0

# Vendor rule modules register themselves here (Rules/*.ps1). Key = profile Vendor name.
$script:VendorRules = @{}
$script:ToolVersion = (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DivvyOut.psd1')).ModuleVersion

foreach ($dir in 'Private', 'Rules', 'Public') {
    foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot $dir) -Filter *.ps1 | Sort-Object Name) { . $file.FullName }
}
