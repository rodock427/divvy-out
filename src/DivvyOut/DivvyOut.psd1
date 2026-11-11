@{
    RootModule        = 'DivvyOut.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5b0d6c4e-8a51-4f7e-9d3c-2f1e7a9b6c10'
    Author            = 'DivvyOut'
    Description       = 'Charges internal software cost to each user''s manager.'
    PowerShellVersion = '7.2'
    RequiredModules   = @('ImportExcel')
    FunctionsToExport = @('Invoke-DivvyOut', 'Test-DivvyOutInput')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
