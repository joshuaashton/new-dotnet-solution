# New-Solution

A PowerShell script that scaffolds a new .NET solution the way I like to start projects: Clean/Onion layers, central package management, strict build settings, optional Aspire and EF Core, and a first commit, all from one interactive command.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- .NET SDK (the installed version decides the target framework, e.g. SDK 10.0.x → `net10.0`)
- git
- For Aspire: the Aspire project templates (the script offers to install them)
- For Aspire with SQL Server: Docker or Podman running when you start the AppHost
- Optional: [Claude Code](https://claude.com/claude-code) on `PATH` (offered at the end)

## Setup

Clone this repo, then add a shortcut to your PowerShell profile (`notepad $PROFILE`):

```powershell
function nsln { & "C:\Development\Scripts\New-Solution.ps1" @args }
```

If scripts are blocked, allow local ones once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Copies cloned with git aren't marked as downloaded. If you download the script directly instead, run `Unblock-File` on it.

## Usage

```powershell
nsln                                     # asks for everything
nsln -Name Acme.Billing                  # skips the name prompt
nsln -Name Acme.Billing -Location D:\Src # creates D:\Src\Acme.Billing
```

The script creates a folder named after the solution in the current (or given) location. It refuses to run if that folder already exists and isn't empty.

## What it asks

| Prompt | Default | What you get |
|---|---|---|
| Solution name | (required) | Letters, digits, `_` and `.`, e.g. `Acme.Billing` |
| Domain + tests? | Yes | `src/X.Domain`, `tests/X.Domain.Tests` |
| Application + tests? | Yes (only asked if Domain) | `src/X.Application`, `tests/X.Application.Tests` |
| Infrastructure? | Yes (only asked if Domain) | `src/X.Infrastructure` |
| EF Core persistence? | No (only asked if Infrastructure) | DbContext, DI registration, migrations tooling (see below) |
| Database provider | SQL Server | SQL Server or SQLite |
| App projects | None | Any of: Web API (`X.Api`), Console (`X.Console`), Blazor Server (`X.Web`), Blazor WebAssembly standalone (`X.Wasm`) |
| Aspire? | Yes (only asked if a server app was chosen) | `src/X.AppHost`, `src/X.ServiceDefaults` |
| Launch Claude Code? | No | Opens `claude` in the new folder so you can run `/init` |

## What it creates

### Always

- `git init` on `main`, `.gitignore` (plus `.claude/settings.local.json`), `.gitattributes`
- `.editorconfig` (with CA1852 relaxed so template sample code builds)
- `global.json` pinned to the installed SDK, rolling forward to the latest feature band
- Solution file (`.slnx` or `.sln`, whichever the SDK creates), with a **Solution Items** folder so root config shows in Visual Studio
- `Directory.Build.props`: target framework, nullable, implicit usings, latest C#, **warnings as errors**, code style enforced in build, `latest-recommended` analysers, deterministic builds
- `Directory.Packages.props`: central package management with transitive pinning. Every generated project is cleaned up to match (no `Version` on `PackageReference`, no per-project framework settings)
- `README.md` and `CLAUDE.md` describing the projects, architecture rules and commands
- A build, a test run, a vulnerable-package check and an initial commit

### Project references

Dependencies point inwards only:

```
Application    → Domain
Infrastructure → Application  (or Domain if there's no Application layer)
Api / Web / Console → Application + Infrastructure   (composition roots)
Wasm           → Application  (never Infrastructure; it runs in the browser)
AppHost        → every server app
Server apps    → ServiceDefaults (when Aspire is on)
```

### With Aspire

- `builder.AddServiceDefaults()` and `app.MapDefaultEndpoints()` added to the API and Blazor Server `Program.cs`
- The AppHost registers every server app. If there's both an API and a Blazor Server app, the front end gets `.WithReference(api).WaitFor(api)`.
- Start everything with `dotnet run --project src/X.AppHost` (or F5 in Visual Studio).

### With EF Core persistence

In `X.Infrastructure`:

- `Persistence/AppDbContext.cs` applies every `IEntityTypeConfiguration<T>` in the assembly
- `Persistence/AppDbContextFactory.cs` is a design-time factory, so migrations work before anything is wired up
- `Persistence/Configurations/`: put entity configurations here
- `DependencyInjection.cs`: `services.AddInfrastructure(connectionString)`

In the API / Blazor Server apps:

- `builder.Services.AddInfrastructure(...)` reading connection string `appdb`
- `appsettings.Development.json` with a local `appdb` connection string (LocalDB for SQL Server, `X.db` for SQLite)
- `Microsoft.EntityFrameworkCore.Tools`, so both Package Manager Console and `dotnet ef` work

With Aspire and SQL Server, the AppHost also gets a SQL Server container (with a data volume) and an `appdb` database, referenced by each web app. Its connection string overrides the LocalDB one at runtime.

EF Core package versions are the latest stable release that matches the SDK's major version (EF 10 for SDK 10), looked up on nuget.org before anything is created.

**Running migrations from Package Manager Console:** set *Default project* to `X.Infrastructure`. If the AppHost is the startup project, pass the API explicitly:

```powershell
Add-Migration Initial -StartupProject X.Api -OutputDir Persistence/Migrations
Update-Database -StartupProject X.Api
```

## Known vulnerable packages

The script's own build ignores NuGet audit warnings (NU1901–NU1904), so a new advisory against a template's transitive dependency can't stop a scaffold. The generated solution stays strict: if anything vulnerable was found, the script lists it and warns you, and your first normal build fails until you pin a patched version in `Directory.Packages.props`, e.g.

```xml
<PackageVersion Include="MessagePack" Version="2.5.303" />
```

Remove the pin once the package that brings it in (Aspire, in that example) ships a fixed version. `dotnet nuget why <Package>` shows the chain.

## Adding projects later

Keep new projects under `src/` or `tests/`:

```powershell
dotnet new classlib -n Acme.Billing.Reporting -o src/Acme.Billing.Reporting
dotnet sln add src/Acme.Billing.Reporting --solution-folder src
```

Then remove `TargetFramework`, `Nullable` and `ImplicitUsings` from the new `.csproj` (they come from `Directory.Build.props`), and move any package versions into `Directory.Packages.props`.
