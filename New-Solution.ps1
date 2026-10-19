<#
.SYNOPSIS
    Scaffolds a new .NET solution from the CLI.

.DESCRIPTION
    Asks for a solution name, creates a folder for it in the current location, then:
    git init, .gitignore, .editorconfig, global.json, solution file,
    Directory.Build.props, Directory.Packages.props (central package management),
    optional Clean/Onion layers (Domain, Application, Infrastructure) with test projects,
    optional Web API / Console / Blazor Server / Blazor WebAssembly app projects,
    optional Aspire AppHost + ServiceDefaults wired to the app projects,
    README.md, .gitattributes and CLAUDE.md, a "Solution Items" folder in the solution so the
    root config files are visible in Visual Studio, Claude Code setup,
    a build/test check and a first commit.

    Layer references (dependencies point inwards):
        Application    -> Domain
        Infrastructure -> Application (or Domain if there is no Application layer)
        Server hosts   -> Application + Infrastructure (composition roots)
        Blazor WASM    -> Application (never Infrastructure: it runs in the browser)

.EXAMPLE
    .\New-Solution.ps1
    .\New-Solution.ps1 -Name Acme.Billing
    .\New-Solution.ps1 -Name Acme.Billing -Location D:\Source
#>
[CmdletBinding()]
param(
    [string]$Name,
    [string]$Location = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers

function Invoke-Step {
    param([string]$Description, [scriptblock]$Command)
    Write-Host "==> $Description" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    # Out-Host keeps command output off the pipeline, so functions that call
    # Invoke-Step can still return clean values.
    & $Command | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Step failed: $Description (exit code $LASTEXITCODE)"
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = if ($Default) { '(Y/n)' } else { '(y/N)' }
    $answer = (Read-Host "$Prompt $suffix").Trim()
    if ([string]::IsNullOrEmpty($answer)) { return $Default }
    return $answer -match '^[yY]'
}

function Write-TextFile {
    # UTF-8 without BOM, absolute paths only
    param([string]$Path, [string]$Content)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Save-Xml {
    param([System.Xml.XmlDocument]$Xml, [string]$Path)
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.IndentChars = '  '
    $settings.OmitXmlDeclaration = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try { $Xml.Save($writer) } finally { $writer.Dispose() }
}

function Convert-ProjectToCentralPackages {
    <#
        Generated csproj files carry their own TargetFramework/Nullable/ImplicitUsings
        (which would override Directory.Build.props) and Version attributes on
        PackageReference (which error under central package management, NU1008).
        This removes the former and moves the latter into Directory.Packages.props.
    #>
    param([string]$ProjectPath, [string]$PackagesPropsPath)

    $proj = New-Object System.Xml.XmlDocument
    $proj.Load($ProjectPath)
    $pkgs = New-Object System.Xml.XmlDocument
    $pkgs.Load($PackagesPropsPath)

    foreach ($propName in 'TargetFramework', 'Nullable', 'ImplicitUsings') {
        foreach ($node in @($proj.SelectNodes("//$propName"))) {
            [void]$node.ParentNode.RemoveChild($node)
        }
    }

    $group = $pkgs.SelectSingleNode('//ItemGroup[PackageVersion]')
    if (-not $group) {
        $group = $pkgs.CreateElement('ItemGroup')
        [void]$pkgs.DocumentElement.AppendChild($group)
    }

    $known = @{}
    foreach ($existing in @($pkgs.SelectNodes('//PackageVersion'))) {
        $known[$existing.GetAttribute('Include')] = $true
    }

    foreach ($ref in @($proj.SelectNodes('//PackageReference[@Version]'))) {
        $id = $ref.GetAttribute('Include')
        if (-not $known.ContainsKey($id)) {
            $entry = $pkgs.CreateElement('PackageVersion')
            $entry.SetAttribute('Include', $id)
            $entry.SetAttribute('Version', $ref.GetAttribute('Version'))
            [void]$group.AppendChild($entry)
            $known[$id] = $true
        }
        $ref.RemoveAttribute('Version')
    }

    Save-Xml -Xml $proj -Path $ProjectPath
    Save-Xml -Xml $pkgs -Path $PackagesPropsPath
}

function Add-SolutionItems {
    <#
        Puts root-level files (Directory.Build.props, .editorconfig, README, ...) into a
        "Solution Items" solution folder so Visual Studio shows them in Solution Explorer.
        The entries point at the real files (they are not copies). Handles both the newer
        .slnx (XML) format and classic .sln.
    #>
    param([string]$SolutionPath, [string[]]$Files)

    $folderName = 'Solution Items'

    if ($SolutionPath.EndsWith('.slnx', [System.StringComparison]::OrdinalIgnoreCase)) {
        $xml = New-Object System.Xml.XmlDocument
        $xml.Load($SolutionPath)

        $folder = $xml.CreateElement('Folder')
        $folder.SetAttribute('Name', "/$folderName/")
        foreach ($file in $Files) {
            $entry = $xml.CreateElement('File')
            $entry.SetAttribute('Path', $file)
            [void]$folder.AppendChild($entry)
        }
        [void]$xml.DocumentElement.PrependChild($folder)
        Save-Xml -Xml $xml -Path $SolutionPath
        return
    }

    # Classic .sln: add a solution-folder "project" with a SolutionItems section
    $folderTypeGuid = '{2150E333-8FDC-42A3-9474-1A3956D46DE8}'
    $folderGuid = [guid]::NewGuid().ToString('B').ToUpper()

    $block = @()
    $block += "Project(`"$folderTypeGuid`") = `"$folderName`", `"$folderName`", `"$folderGuid`""
    $block += "`tProjectSection(SolutionItems) = preProject"
    foreach ($file in $Files) { $block += "`t`t$file = $file" }
    $block += "`tEndProjectSection"
    $block += 'EndProject'

    $lines = [System.IO.File]::ReadAllLines($SolutionPath)
    $globalIndex = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i].Trim() -eq 'Global') { $globalIndex = $i; break }
    }
    if ($globalIndex -lt 1) { throw "Could not find the 'Global' section in $SolutionPath" }

    $result = @($lines[0..($globalIndex - 1)]) + $block + @($lines[$globalIndex..($lines.Length - 1)])
    [System.IO.File]::WriteAllLines($SolutionPath, $result, (New-Object System.Text.UTF8Encoding($true)))
}

function Add-Project {
    <#
        dotnet new + central-package cleanup + remove template placeholder + add to solution.
        Returns the project's relative path (e.g. src/Acme.Billing.Domain/Acme.Billing.Domain.csproj).
        Relies on script-scope $root, $packagesPath and $slnFile.
    #>
    param(
        [string]$Template,
        [string]$ProjectName,
        [string]$Folder,
        [string[]]$ExtraArgs = @()
    )

    $relPath = "$Folder/$ProjectName/$ProjectName.csproj"

    Invoke-Step "dotnet new $Template ($ProjectName)" {
        dotnet new $Template -n $ProjectName -o "$Folder/$ProjectName" --no-restore @ExtraArgs
    }

    Write-Host "==> Adjusting $ProjectName csproj for shared props / central packages" -ForegroundColor Cyan
    Convert-ProjectToCentralPackages -ProjectPath (Join-Path $root $relPath) -PackagesPropsPath $packagesPath

    # classlib's Class1.cs is never wanted
    $placeholder = Join-Path $root "$Folder/$ProjectName/Class1.cs"
    if (Test-Path $placeholder) { Remove-Item $placeholder }

    Invoke-Step "Add $ProjectName to solution" {
        dotnet sln $slnFile.Name add $relPath --solution-folder $Folder
    }

    return $relPath
}

function Add-References {
    param([string]$From, [string[]]$To)
    foreach ($target in @($To | Where-Object { $_ })) {
        $fromName = [System.IO.Path]::GetFileNameWithoutExtension($From)
        $toName   = [System.IO.Path]::GetFileNameWithoutExtension($target)
        Invoke-Step "Reference $toName from $fromName" { dotnet add $From reference $target }
    }
}

function Get-LatestPackageVersion {
    <#
        Latest stable version of a package on nuget.org within one major version.
        EF Core majors track .NET majors (EF 10 needs net10.0), so the major is taken
        from the SDK; plain "latest" would break as soon as the next major ships.
    #>
    param([string]$Id, [int]$Major)

    $url = "https://api.nuget.org/v3-flatcontainer/$($Id.ToLowerInvariant())/index.json"
    try {
        $index = Invoke-RestMethod -Uri $url -ErrorAction Stop
    }
    catch {
        throw "Could not reach nuget.org to look up $Id ($($_.Exception.Message))."
    }

    $latest = @($index.versions |
        Where-Object { $_ -match "^$Major\.\d+\.\d+$" } |
        Sort-Object { [version]$_ } -Descending |
        Select-Object -First 1)
    if ($latest.Count -eq 0) {
        throw "No stable $Major.x release of $Id found on nuget.org."
    }
    return $latest[0]
}

function Add-PackageReference {
    <#
        Adds a version-less PackageReference to the project and the matching PackageVersion
        to Directory.Packages.props (central package management). Done directly in XML so
        nothing restores mid-scaffold. Relies on script-scope $root and $packagesPath.
    #>
    param([string]$ProjectPath, [string]$Id, [string]$Version, [switch]$PrivateAssets)

    $fullPath = Join-Path $root $ProjectPath
    $proj = New-Object System.Xml.XmlDocument
    $proj.Load($fullPath)

    if (-not $proj.SelectSingleNode("//PackageReference[@Include='$Id']")) {
        $group = $proj.SelectSingleNode('//ItemGroup[PackageReference]')
        if (-not $group) {
            $group = $proj.CreateElement('ItemGroup')
            [void]$proj.DocumentElement.AppendChild($group)
        }
        $ref = $proj.CreateElement('PackageReference')
        $ref.SetAttribute('Include', $Id)
        if ($PrivateAssets) {
            $pa = $proj.CreateElement('PrivateAssets')
            $pa.InnerText = 'all'
            [void]$ref.AppendChild($pa)
            $ia = $proj.CreateElement('IncludeAssets')
            $ia.InnerText = 'runtime; build; native; contentfiles; analyzers; buildtransitive'
            [void]$ref.AppendChild($ia)
        }
        [void]$group.AppendChild($ref)
        Save-Xml -Xml $proj -Path $fullPath
    }

    $pkgs = New-Object System.Xml.XmlDocument
    $pkgs.Load($packagesPath)
    if (-not $pkgs.SelectSingleNode("//PackageVersion[@Include='$Id']")) {
        $versions = $pkgs.SelectSingleNode('//ItemGroup[PackageVersion]')
        if (-not $versions) {
            $versions = $pkgs.CreateElement('ItemGroup')
            [void]$pkgs.DocumentElement.AppendChild($versions)
        }
        $entry = $pkgs.CreateElement('PackageVersion')
        $entry.SetAttribute('Include', $Id)
        $entry.SetAttribute('Version', $Version)
        [void]$versions.AppendChild($entry)
        Save-Xml -Xml $pkgs -Path $packagesPath
    }

    Write-Host "==> $Id $Version -> $([System.IO.Path]::GetFileNameWithoutExtension($ProjectPath))" -ForegroundColor Cyan
}

function Add-ServiceDefaultsCalls {
    <#
        Inserts builder.AddServiceDefaults() and app.MapDefaultEndpoints() into a
        minimal-hosting Program.cs (Web API / Blazor Server templates).
    #>
    param([string]$ProgramPath)

    $nl   = [Environment]::NewLine
    $text = [System.IO.File]::ReadAllText($ProgramPath)
    if ($text -match 'AddServiceDefaults') { return }

    $builderRe = [regex]'(?m)^(var builder = WebApplication\.CreateBuilder\(args\);[ \t]*\r?\n)'
    $runRe     = [regex]'(?m)^(app\.Run\(\);)'

    if (-not $builderRe.IsMatch($text) -or -not $runRe.IsMatch($text)) {
        Write-Warning "Could not find the expected lines in $ProgramPath. Add builder.AddServiceDefaults() and app.MapDefaultEndpoints() manually."
        return
    }

    $text = $builderRe.Replace($text, '$1' + 'builder.AddServiceDefaults();' + $nl, 1)
    $text = $runRe.Replace($text, 'app.MapDefaultEndpoints();' + $nl + $nl + '$1', 1)
    Write-TextFile $ProgramPath $text
}

function Add-InfrastructureCall {
    <#
        Inserts builder.Services.AddInfrastructure(...) straight after the builder line in a
        minimal-hosting Program.cs, plus the using for the Infrastructure namespace.
    #>
    param([string]$ProgramPath, [string]$InfraNamespace, [string]$ConnectionName)

    $nl   = [Environment]::NewLine
    $text = [System.IO.File]::ReadAllText($ProgramPath)
    if ($text -match 'AddInfrastructure') { return }

    $builderRe = [regex]'(?m)^(var builder = WebApplication\.CreateBuilder\(args\);[ \t]*\r?\n)'
    if (-not $builderRe.IsMatch($text)) {
        Write-Warning "Could not find the builder line in $ProgramPath. Add builder.Services.AddInfrastructure(...) manually."
        return
    }

    $call = (
        'builder.Services.AddInfrastructure(',
        "    builder.Configuration.GetConnectionString(`"$ConnectionName`")",
        "        ?? throw new InvalidOperationException(`"Connection string '$ConnectionName' is not configured.`"));",
        ''
    ) -join $nl

    $text = $builderRe.Replace($text, '$1' + $call.Replace('$', '$$'), 1)

    # using goes first; add a blank line after it if the file had no usings of its own
    $usingLine = "using $InfraNamespace;" + $nl
    if (-not $text.StartsWith('using ')) { $usingLine += $nl }
    Write-TextFile $ProgramPath ($usingLine + $text)
}

function Set-DevConnectionString {
    # Adds ConnectionStrings:<Name> to an appsettings file (creates the file if missing)
    param([string]$SettingsPath, [string]$Name, [string]$Value)

    $json = if (Test-Path $SettingsPath) {
        Get-Content $SettingsPath -Raw | ConvertFrom-Json
    } else {
        [pscustomobject]@{}
    }
    if (-not $json.PSObject.Properties['ConnectionStrings']) {
        $json | Add-Member -NotePropertyName 'ConnectionStrings' -NotePropertyValue ([pscustomobject]@{})
    }
    $json.ConnectionStrings | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Write-TextFile $SettingsPath ($json | ConvertTo-Json -Depth 10)
}

# ---------------------------------------------------------------- prerequisites

foreach ($tool in 'git', 'dotnet') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' was not found on PATH. Install it and try again."
    }
}

# ---------------------------------------------------------------- inputs

if ([string]::IsNullOrWhiteSpace($Name)) {
    $Name = (Read-Host 'Solution name (e.g. Acme.Billing)').Trim()
}
if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_.]*$') {
    throw "'$Name' is not a valid solution name. Use letters, digits, '_' and '.', starting with a letter or '_'."
}

# Clean/Onion layers. Application and Infrastructure only make sense on top of Domain.
$createDomain         = Read-YesNo "Create src/$Name.Domain and tests/$Name.Domain.Tests?"
$createApplication    = $false
$createInfrastructure = $false
if ($createDomain) {
    $createApplication    = Read-YesNo "Create src/$Name.Application and tests/$Name.Application.Tests?"
    $createInfrastructure = Read-YesNo "Create src/$Name.Infrastructure?"
}

# SDK version drives global.json, the target framework (10.0.100 -> net10.0) and the EF Core major
$sdkVersion = (& dotnet --version).Trim()
$sdkMajor   = [int]$sdkVersion.Split('.')[0]
$tfm        = "net$sdkMajor.0"

# EF Core persistence inside Infrastructure
$createPersistence = $false
$dbProvider        = $null
if ($createInfrastructure) {
    $createPersistence = Read-YesNo "Add EF Core persistence to $Name.Infrastructure?" -Default $false
    if ($createPersistence) {
        Write-Host '  1) SQL Server'
        Write-Host '  2) SQLite'
        $providerChoice = (Read-Host 'Database provider (1/2, Enter for SQL Server)').Trim()
        $dbProvider = switch ($providerChoice) {
            ''      { @{ Label = 'SQL Server'; Package = 'Microsoft.EntityFrameworkCore.SqlServer'; Method = 'UseSqlServer' } }
            '1'     { @{ Label = 'SQL Server'; Package = 'Microsoft.EntityFrameworkCore.SqlServer'; Method = 'UseSqlServer' } }
            '2'     { @{ Label = 'SQLite';     Package = 'Microsoft.EntityFrameworkCore.Sqlite';    Method = 'UseSqlite' } }
            default { throw "'$providerChoice' is not a valid choice. Pick 1 or 2." }
        }

        # Look the version up now so a network problem fails before anything is created
        Write-Host "Looking up the latest EF Core $sdkMajor.x on nuget.org..." -ForegroundColor Cyan
        $efVersion = Get-LatestPackageVersion -Id 'Microsoft.EntityFrameworkCore' -Major $sdkMajor
        Write-Host "EF Core $efVersion ($($dbProvider.Label))" -ForegroundColor Cyan
    }
}

# Application project types: menu key -> dotnet template + project name suffix
#   Kind 'Host'   = runs on the server; composition root; can join Aspire
#   Kind 'Client' = runs in the browser; never references Infrastructure
#   WebHost       = minimal-hosting Program.cs that gets AddServiceDefaults()/MapDefaultEndpoints()
$appCatalog = [ordered]@{
    '1' = @{ Label = 'Web API';                         Template = 'webapi';     Suffix = 'Api';     Kind = 'Host';   WebHost = $true;  Args = @() }
    '2' = @{ Label = 'Console app';                     Template = 'console';    Suffix = 'Console'; Kind = 'Host';   WebHost = $false; Args = @() }
    '3' = @{ Label = 'Blazor Server';                   Template = 'blazor';     Suffix = 'Web';     Kind = 'Host';   WebHost = $true;  Args = @('--interactivity', 'Server', '--all-interactive') }
    '4' = @{ Label = 'Blazor WebAssembly (standalone)'; Template = 'blazorwasm'; Suffix = 'Wasm';    Kind = 'Client'; WebHost = $false; Args = @() }
}

Write-Host ''
Write-Host 'Application projects to add:'
foreach ($key in $appCatalog.Keys) {
    Write-Host ('  {0}) {1}  ->  src/{2}.{3}' -f $key, $appCatalog[$key].Label, $Name, $appCatalog[$key].Suffix)
}
$appSelection = Read-Host 'Choose one or more, comma-separated (Enter for none)'
$appChoices = @($appSelection -split '[,\s]+' | Where-Object { $_ } | Select-Object -Unique)
foreach ($choice in $appChoices) {
    if (-not $appCatalog.Contains($choice)) {
        throw "'$choice' is not a valid choice. Pick from: $($appCatalog.Keys -join ', ')."
    }
}

# Aspire: only offered when there is at least one server-side host to orchestrate
$hostChoices  = @($appChoices | Where-Object { $appCatalog[$_].Kind -eq 'Host' })
$createAspire = $false
if ($hostChoices.Count -gt 0) {
    Write-Host ''
    $createAspire = Read-YesNo "Add Aspire (src/$Name.AppHost + src/$Name.ServiceDefaults)?"
}

if ($createAspire) {
    $listOutput = & dotnet new list aspire-apphost 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $listOutput -notmatch 'aspire-apphost') {
        if (-not (Read-YesNo 'Aspire project templates are not installed. Install Aspire.ProjectTemplates now?')) {
            throw 'Aspire templates are required for the AppHost. Run: dotnet new install Aspire.ProjectTemplates'
        }
        Invoke-Step 'Install Aspire templates' { dotnet new install Aspire.ProjectTemplates }
    }
    $global:LASTEXITCODE = 0
}

$root = Join-Path $Location $Name
if ((Test-Path $root) -and (Get-ChildItem $root -Force | Select-Object -First 1)) {
    throw "Folder '$root' already exists and is not empty."
}
New-Item -ItemType Directory -Path $root -Force | Out-Null

Write-Host ''
Write-Host "Creating '$Name' in $root" -ForegroundColor Green
Write-Host "SDK $sdkVersion, target framework $tfm" -ForegroundColor Green
Write-Host ''

Push-Location $root
try {

    # ------------------------------------------------------------ 1. repo + hygiene
    Invoke-Step 'git init'                { git init -b main }
    Invoke-Step 'dotnet new gitignore'    { dotnet new gitignore }
    Invoke-Step 'dotnet new editorconfig' { dotnet new editorconfig }
    Invoke-Step 'dotnet new globaljson'   { dotnet new globaljson --sdk-version $sdkVersion --roll-forward latestFeature }

    # Template code isn't ours: under 'latest-recommended' analysis, CA1852 (seal internal types)
    # fails the build on the WeatherForecast samples in the Web API / Blazor templates.
    # Keep it as an editor suggestion rather than a build error.
    Add-Content -Path (Join-Path $root '.editorconfig') -Value @'

# Scaffold overrides
[*.cs]
dotnet_diagnostic.CA1852.severity = suggestion
'@

    # Keep machine-specific Claude settings out of git
    $gitignore = Join-Path $root '.gitignore'
    if (-not (Select-String -Path $gitignore -SimpleMatch '.claude/settings.local.json' -Quiet)) {
        Add-Content -Path $gitignore -Value "`n# Claude Code (machine-specific)`n.claude/settings.local.json"
    }

    Write-Host '==> .gitattributes' -ForegroundColor Cyan
    $gitattributes = @'
# Normalise line endings in the repository; working copies use the platform default
* text=auto

# Classic Visual Studio solution files need CRLF
*.sln text eol=crlf

# Binary files
*.png binary
*.jpg binary
*.jpeg binary
*.gif binary
*.ico binary
*.snk binary
'@
    Write-TextFile (Join-Path $root '.gitattributes') $gitattributes

    # ------------------------------------------------------------ 2. solution
    Invoke-Step 'dotnet new sln' { dotnet new sln -n $Name }
    $slnFile = Get-ChildItem -Path $root -Filter "$Name.sln*" | Select-Object -First 1
    if (-not $slnFile) { throw 'Solution file was not created.' }

    # ------------------------------------------------------------ 3. shared build config
    $buildProps = @'
<Project>
  <PropertyGroup>
    <TargetFramework>{{Tfm}}</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>latest</LangVersion>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
    <AnalysisLevel>latest-recommended</AnalysisLevel>
    <Deterministic>true</Deterministic>
  </PropertyGroup>
</Project>
'@.Replace('{{Tfm}}', $tfm)

    $packagesProps = @'
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
    <CentralPackageTransitivePinningEnabled>true</CentralPackageTransitivePinningEnabled>
  </PropertyGroup>
</Project>
'@

    Write-Host '==> Directory.Build.props + Directory.Packages.props' -ForegroundColor Cyan
    Write-TextFile (Join-Path $root 'Directory.Build.props')    $buildProps
    Write-TextFile (Join-Path $root 'Directory.Packages.props') $packagesProps
    $packagesPath = Join-Path $root 'Directory.Packages.props'

    # ------------------------------------------------------------ 4. layers
    $projectLines       = @()   # collected for README / CLAUDE.md
    $domainPath         = $null
    $applicationPath    = $null
    $infrastructurePath = $null

    if ($createDomain) {
        $domainPath      = Add-Project -Template classlib -ProjectName "$Name.Domain"       -Folder src
        $domainTestsPath = Add-Project -Template xunit    -ProjectName "$Name.Domain.Tests" -Folder tests
        Add-References -From $domainTestsPath -To $domainPath

        $projectLines += ('- `src/{0}.Domain` - entities, value objects, domain logic (no dependencies)' -f $Name)
        $projectLines += ('- `tests/{0}.Domain.Tests` - xUnit tests for Domain' -f $Name)
    }

    if ($createApplication) {
        $applicationPath      = Add-Project -Template classlib -ProjectName "$Name.Application"       -Folder src
        $applicationTestsPath = Add-Project -Template xunit    -ProjectName "$Name.Application.Tests" -Folder tests
        Add-References -From $applicationPath      -To $domainPath
        Add-References -From $applicationTestsPath -To $applicationPath

        $projectLines += ('- `src/{0}.Application` - use cases and interfaces (ports); references Domain' -f $Name)
        $projectLines += ('- `tests/{0}.Application.Tests` - xUnit tests for Application' -f $Name)
    }

    if ($createInfrastructure) {
        $infrastructurePath = Add-Project -Template classlib -ProjectName "$Name.Infrastructure" -Folder src
        $innerLayer = if ($applicationPath) { $applicationPath } else { $domainPath }
        Add-References -From $infrastructurePath -To $innerLayer

        $innerName = if ($applicationPath) { 'Application' } else { 'Domain' }
        $projectLines += ('- `src/{0}.Infrastructure` - persistence, external services; implements {1} interfaces' -f $Name, $innerName)
    }

    if ($createPersistence) {
        $infraNamespace = "$Name.Infrastructure"
        $persistenceDir = Join-Path $root "src/$infraNamespace/Persistence"
        New-Item -ItemType Directory -Path (Join-Path $persistenceDir 'Configurations') -Force | Out-Null

        Add-PackageReference -ProjectPath $infrastructurePath -Id 'Microsoft.EntityFrameworkCore' -Version $efVersion
        Add-PackageReference -ProjectPath $infrastructurePath -Id $dbProvider.Package           -Version $efVersion

        Write-Host '==> Persistence/AppDbContext.cs + DependencyInjection.cs' -ForegroundColor Cyan

        $dbContext = @'
using Microsoft.EntityFrameworkCore;

namespace {{Ns}}.Persistence;

public sealed class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        ArgumentNullException.ThrowIfNull(modelBuilder);

        // Picks up every IEntityTypeConfiguration<T> in Persistence/Configurations
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(AppDbContext).Assembly);
        base.OnModelCreating(modelBuilder);
    }
}
'@.Replace('{{Ns}}', $infraNamespace)
        Write-TextFile (Join-Path $persistenceDir 'AppDbContext.cs') $dbContext

        # git does not track empty folders
        Write-TextFile (Join-Path $persistenceDir 'Configurations/.gitkeep') ''

        # Lets `dotnet ef` create the context before any host wires up AddInfrastructure.
        # Local development connection only; real connection strings come from configuration.
        # (single backslash here; doubled below when written into a C# string literal)
        $devConnection = if ($dbProvider.Method -eq 'UseSqlite') {
            "Data Source=$Name.db"
        } else {
            "Server=(localdb)\MSSQLLocalDB;Database=$Name;Trusted_Connection=True;TrustServerCertificate=True"
        }
        $factory = @'
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace {{Ns}}.Persistence;

/// <summary>Used by dotnet ef at design time only (migrations). Not used at runtime.</summary>
public sealed class AppDbContextFactory : IDesignTimeDbContextFactory<AppDbContext>
{
    public AppDbContext CreateDbContext(string[] args)
    {
        var options = new DbContextOptionsBuilder<AppDbContext>()
            .{{Method}}("{{Connection}}")
            .Options;

        return new AppDbContext(options);
    }
}
'@.Replace('{{Ns}}', $infraNamespace).Replace('{{Method}}', $dbProvider.Method).Replace('{{Connection}}', $devConnection.Replace('\', '\\'))
        Write-TextFile (Join-Path $persistenceDir 'AppDbContextFactory.cs') $factory

        $di = @'
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using {{Ns}}.Persistence;

namespace {{Ns}};

public static class DependencyInjection
{
    public static IServiceCollection AddInfrastructure(this IServiceCollection services, string connectionString)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        services.AddDbContext<AppDbContext>(options => options.{{Method}}(connectionString));

        return services;
    }
}
'@.Replace('{{Ns}}', $infraNamespace).Replace('{{Method}}', $dbProvider.Method)
        Write-TextFile (Join-Path $root "src/$infraNamespace/DependencyInjection.cs") $di

        $projectLines += ('  - `Persistence/` - EF Core `AppDbContext` ({0}); entity configurations go in `Persistence/Configurations`' -f $dbProvider.Label)
    }

    # What each kind of app project should reference
    $innermostUsable = if ($applicationPath) { $applicationPath } else { $domainPath }
    $hostRefs   = @($innermostUsable, $infrastructurePath | Where-Object { $_ })
    $clientRefs = @($innermostUsable | Where-Object { $_ })

    # ------------------------------------------------------------ 5. app projects
    $createdHosts = @()   # for Aspire wiring

    foreach ($key in $appChoices) {
        $app     = $appCatalog[$key]
        $appName = "$Name.$($app.Suffix)"
        $appPath = Add-Project -Template $app.Template -ProjectName $appName -Folder src -ExtraArgs $app.Args

        $refs = if ($app.Kind -eq 'Host') { $hostRefs } else { $clientRefs }
        Add-References -From $appPath -To $refs

        if ($app.Kind -eq 'Host') {
            $createdHosts += [pscustomobject]@{
                Name     = $appName
                Path     = $appPath
                Resource = $app.Suffix.ToLowerInvariant()
                WebHost  = $app.WebHost
            }
        }

        $projectLines += ('- `src/{0}` - {1} (run: `dotnet run --project src/{0}`)' -f $appName, $app.Label)
    }

    # EF Core tooling goes in the startup project. Tools gives the Package Manager Console
    # commands (Add-Migration, Update-Database) and brings in Design, which the dotnet ef CLI needs.
    $efStartupProject = $null
    if ($createPersistence) {
        if ($createdHosts.Count -gt 0) {
            $efStartupProject = $createdHosts[0].Name
            foreach ($h in $createdHosts) {
                Add-PackageReference -ProjectPath $h.Path -Id 'Microsoft.EntityFrameworkCore.Tools' -Version $efVersion -PrivateAssets
            }
        }
        else {
            $efStartupProject = "$Name.Infrastructure"
            Add-PackageReference -ProjectPath $infrastructurePath -Id 'Microsoft.EntityFrameworkCore.Tools' -Version $efVersion -PrivateAssets
        }
    }

    # Call AddInfrastructure from each web host and give it a local development connection string.
    # Under Aspire the AppHost's connection string (an environment variable) overrides this one.
    $connectionName = 'appdb'
    if ($createPersistence) {
        foreach ($h in $createdHosts | Where-Object { $_.WebHost }) {
            Write-Host "==> Wiring AddInfrastructure into $($h.Name)" -ForegroundColor Cyan
            Add-InfrastructureCall -ProgramPath (Join-Path $root "src/$($h.Name)/Program.cs") `
                -InfraNamespace "$Name.Infrastructure" -ConnectionName $connectionName
            Set-DevConnectionString -SettingsPath (Join-Path $root "src/$($h.Name)/appsettings.Development.json") `
                -Name $connectionName -Value $devConnection
        }
    }

    # ------------------------------------------------------------ 6. Aspire
    $appHostName  = "$Name.AppHost"
    $useAspireSql = $false
    if ($createAspire) {
        $serviceDefaultsPath = Add-Project -Template aspire-servicedefaults -ProjectName "$Name.ServiceDefaults" -Folder src
        $appHostPath         = Add-Project -Template aspire-apphost         -ProjectName $appHostName            -Folder src

        foreach ($h in $createdHosts) {
            Add-References -From $h.Path -To $serviceDefaultsPath
            if ($h.WebHost) {
                Add-ServiceDefaultsCalls -ProgramPath (Join-Path $root "src/$($h.Name)/Program.cs")
            }
        }
        Add-References -From $appHostPath -To @($createdHosts | ForEach-Object { $_.Path })

        # SQL Server persistence: the AppHost runs SQL Server in a container and hands the
        # 'appdb' connection string to each web host. Aspire.Hosting.SqlServer must match the
        # AppHost's Aspire version, which the template has just written.
        if ($createPersistence -and $dbProvider.Method -eq 'UseSqlServer') {
            $aspireVersion = $null
            $pkgsXml = New-Object System.Xml.XmlDocument
            $pkgsXml.Load($packagesPath)
            $hostingNode = $pkgsXml.SelectSingleNode("//PackageVersion[@Include='Aspire.Hosting.AppHost']")
            if ($hostingNode) { $aspireVersion = $hostingNode.GetAttribute('Version') }
            if (-not $aspireVersion) {
                $appHostCsproj = Get-Content (Join-Path $root $appHostPath) -Raw
                if ($appHostCsproj -match 'Aspire\.AppHost\.Sdk/([0-9][^"]*)') { $aspireVersion = $Matches[1] }
                elseif ($appHostCsproj -match 'Name="Aspire\.AppHost\.Sdk"\s+Version="([^"]+)"') { $aspireVersion = $Matches[1] }
            }

            if ($aspireVersion) {
                Add-PackageReference -ProjectPath $appHostPath -Id 'Aspire.Hosting.SqlServer' -Version $aspireVersion
                $useAspireSql = $true
            }
            else {
                Write-Warning 'Could not work out the Aspire version, so SQL Server was not added to the AppHost. The API will use the LocalDB connection string in appsettings.Development.json.'
            }
        }

        # AppHost entry point: one AddProject per host; web hosts get the database and the API
        $dbRefs = if ($useAspireSql) { "`n    .WithReference($connectionName)`n    .WaitFor($connectionName)" } else { '' }

        $apiHost = $createdHosts | Where-Object { $_.Resource -eq 'api' } | Select-Object -First 1
        $body = @('var builder = DistributedApplication.CreateBuilder(args);', '')
        if ($useAspireSql) {
            $body += 'var sql = builder.AddSqlServer("sql")'
            $body += '    .WithDataVolume();'
            $body += ''
            $body += "var $connectionName = sql.AddDatabase(`"$connectionName`");"
            $body += ''
        }
        if ($apiHost) {
            $body += ('var api = builder.AddProject<Projects.{0}>("api"){1};' -f $apiHost.Name.Replace('.', '_'), $dbRefs)
        }
        foreach ($h in $createdHosts | Where-Object { $_ -ne $apiHost }) {
            $line = 'builder.AddProject<Projects.{0}>("{1}")' -f $h.Name.Replace('.', '_'), $h.Resource
            if ($h.WebHost) { $line += $dbRefs }
            if ($apiHost -and $h.WebHost) { $line += "`n    .WithReference(api)`n    .WaitFor(api)" }
            $body += "$line;"
        }
        $body += ''
        $body += 'builder.Build().Run();'
        $body += ''

        $appHostDir = Join-Path $root "src/$appHostName"
        $entryFile = @('AppHost.cs', 'Program.cs') |
            ForEach-Object { Join-Path $appHostDir $_ } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if (-not $entryFile) { $entryFile = Join-Path $appHostDir 'AppHost.cs' }
        Write-Host '==> Writing AppHost entry point' -ForegroundColor Cyan
        Write-TextFile $entryFile ($body -join "`n")

        $projectLines += ('- `src/{0}.ServiceDefaults` - Aspire telemetry, health checks, resilience' -f $Name)
        $projectLines += ('- `src/{0}` - Aspire orchestrator; start here: `dotnet run --project src/{0}`' -f $appHostName)
    }

    # ------------------------------------------------------------ 7. docs + Claude
    $projectsText = if ($projectLines.Count -gt 0) { $projectLines -join "`n" } else { '- (none yet)' }

    $architectureText = ''
    if ($createApplication -or $createInfrastructure) {
        $rules = @('Clean/Onion architecture: dependencies point inwards only.', '')
        $rules += '- Domain references nothing else in the solution and takes no infrastructure packages (no EF Core, no HTTP).'
        if ($createApplication) {
            $rules += '- Application references Domain only. Use cases live here, plus the interfaces (ports) for persistence and external services.'
        }
        if ($createInfrastructure) {
            $rules += '- Infrastructure implements those interfaces (EF Core, HTTP clients, file system, etc.). Nothing inner references it.'
        }
        $rules += '- App projects are composition roots: they wire up DI and stay thin. No business logic in controllers, endpoints or components.'
        $architectureText = "`n## Architecture`n" + ($rules -join "`n") + "`n"
    }

    if ($createPersistence) {
        $efLines = @(
            '',
            "## Database ($($dbProvider.Label), EF Core)",
            '- `AppDbContext` lives in `src/' + $Name + '.Infrastructure/Persistence`; register it with `services.AddInfrastructure(connectionString)`.',
            '- One `IEntityTypeConfiguration<T>` per entity in `Persistence/Configurations`; no data annotations on Domain entities.',
            ('- Web hosts call `AddInfrastructure` with connection string `{0}`; the local development value is in each host''s `appsettings.Development.json`.' -f $connectionName),
            $(if ($useAspireSql) { '- Running through the AppHost starts SQL Server in a container (Docker or Podman must be running) and overrides that connection string. Data persists in a Docker volume between runs.' } else { $null }),
            '- Migrations from Visual Studio Package Manager Console (startup project: ' + $efStartupProject + ', Default project: ' + $Name + '.Infrastructure):',
            '  - Add: `Add-Migration <Name> -OutputDir Persistence/Migrations`',
            '  - Apply: `Update-Database`',
            '- Migrations from a terminal (needs `dotnet tool install --global dotnet-ef`):',
            '  - Add: `dotnet ef migrations add <Name> --project src/' + $Name + '.Infrastructure --startup-project src/' + $efStartupProject + ' --output-dir Persistence/Migrations`',
            '  - Apply: `dotnet ef database update --project src/' + $Name + '.Infrastructure --startup-project src/' + $efStartupProject + '`',
            ''
        )
        $architectureText += (@($efLines | Where-Object { $null -ne $_ }) -join "`n")
    }

    $runText = if ($createAspire) {
        "`n# Run everything via Aspire`ndotnet run --project src/$appHostName"
    } else { '' }

    $readme = @'
# {{Name}}

> TODO: describe what this solution is for.

## Structure

{{Projects}}

Root-level configuration (`Directory.Build.props`, `Directory.Packages.props`, `.editorconfig`, `global.json`) is listed under **Solution Items** in Visual Studio.
{{Architecture}}
## Getting started

Requires the .NET SDK version pinned in `global.json`.

```powershell
dotnet build
dotnet test{{Run}}
```

## Conventions

- Package versions are managed centrally in `Directory.Packages.props`; do not put `Version` on `PackageReference` items.
- Shared compiler settings live in `Directory.Build.props`. Warnings are treated as errors.
- Code style is enforced by `.editorconfig`.
'@.Replace('{{Name}}', $Name).Replace('{{Projects}}', $projectsText).Replace('{{Architecture}}', $architectureText).Replace('{{Run}}', $runText)

    Write-Host '==> README.md starter' -ForegroundColor Cyan
    Write-TextFile (Join-Path $root 'README.md') $readme

    $claudeRun = if ($createAspire) { "`n- Run: ``dotnet run --project src/$appHostName`` (Aspire dashboard opens with it)" } else { '' }

    $claudeMd = @'
# {{Name}}

## Build and test
- Build: `dotnet build`
- Test: `dotnet test`{{Run}}

## Projects
{{Projects}}
{{Architecture}}
## Conventions
- Source in `src/`, tests in `tests/`.
- Shared settings live in `Directory.Build.props`; package versions live in `Directory.Packages.props` (central package management). Do not put `Version` on `PackageReference` items.
- Warnings are treated as errors. Style rules are in `.editorconfig`.
'@.Replace('{{Name}}', $Name).Replace('{{Projects}}', $projectsText).Replace('{{Architecture}}', $architectureText).Replace('{{Run}}', $claudeRun)

    Write-Host '==> CLAUDE.md starter' -ForegroundColor Cyan
    Write-TextFile (Join-Path $root 'CLAUDE.md') $claudeMd

    # ------------------------------------------------------------ 7b. Solution Items folder (visible in Visual Studio)
    Write-Host '==> Solution Items folder' -ForegroundColor Cyan
    $solutionItems = @(
        'README.md', 'CLAUDE.md', '.editorconfig', '.gitignore', '.gitattributes',
        'global.json', 'Directory.Build.props', 'Directory.Packages.props', 'nuget.config'
    ) | Where-Object { Test-Path (Join-Path $root $_) }
    Add-SolutionItems -SolutionPath $slnFile.FullName -Files $solutionItems

    # ------------------------------------------------------------ 8. verify
    # NuGet audit warnings (NU1901-NU1904: known vulnerable packages) are relaxed for this
    # check only, so a new advisory against a template's transitive package can't stop the
    # scaffold. The solution itself stays strict: your first normal build will fail on them.
    # %3B is an escaped ';' (a bare ';' would separate MSBuild properties).
    $auditRelaxed = '-p:WarningsNotAsErrors=NU1901%3BNU1902%3BNU1903%3BNU1904'
    Invoke-Step 'dotnet build' { dotnet build --nologo $auditRelaxed }
    if ($createDomain) {
        Invoke-Step 'dotnet test' { dotnet test --nologo --no-build }
    }

    # Report any vulnerable packages now rather than leaving them to be discovered later
    Write-Host '==> Checking for vulnerable packages' -ForegroundColor Cyan
    $vulnReport = & dotnet list package --vulnerable --include-transitive 2>&1 | Out-String
    $global:LASTEXITCODE = 0
    $hasVulnerablePackages = $vulnReport -match 'has the following vulnerable packages'
    if ($hasVulnerablePackages) {
        Write-Host $vulnReport
    }

    # ------------------------------------------------------------ 9. first commit
    Write-Host '==> Initial commit' -ForegroundColor Cyan
    git add -A
    git commit -m 'Initial solution scaffold'
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Commit failed (is git user.name / user.email set?). Files are staged; commit manually.'
    }

    Write-Host ''
    Write-Host "Done. Solution created at $root" -ForegroundColor Green

    if ($hasVulnerablePackages) {
        Write-Host ''
        Write-Warning ('Vulnerable packages were found (listed above). Your next normal build will fail on them. ' +
            'Pin a patched version in Directory.Packages.props, e.g. <PackageVersion Include="MessagePack" Version="2.5.303" />, then rebuild.')
    }

    # ------------------------------------------------------------ 10. optionally launch Claude
    if (Read-YesNo 'Launch Claude Code here now so you can run /init?' -Default $false) {
        if (Get-Command claude -ErrorAction SilentlyContinue) {
            claude
        }
        else {
            Write-Warning "'claude' was not found on PATH."
        }
    }
}
finally {
    Pop-Location
}
