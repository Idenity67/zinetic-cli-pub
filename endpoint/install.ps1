& {
    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $version = 'p1-04-uat-20261019-g8c60f5b'
    $baseUrl = 'https://github.com/Idenity67/zinetic-endpoint-pub/releases/download/p1-04-uat-20261019-g8c60f5b'
    if ($env:ZINETIC_ENDPOINT_BASE_URL) {
        $baseUrl = $env:ZINETIC_ENDPOINT_BASE_URL
    }
    $baseUrl = $baseUrl.TrimEnd('/')
    $hashes = @{
        'zinetic-windows-amd64.exe'  = '18a3d10037aac463a97d31125de8f2196932abe6533d017eba7126e2840201cc'
        'zineticd-windows-amd64.exe' = '719193599533fe91f1e4ee892b8e36bda079f029e2bd22f5e66db5da693828ed'
        'zinetic-windows-arm64.exe'  = 'a8bc0739033e9d89d1fb98afc0803e6fa2269a2df56ab71b9996e4758e8022ca'
        'zineticd-windows-arm64.exe' = 'cd7e0707285c33c8357d7b2ce41aa3bda784b5cb640aa3f9eff2a4dd1f0ff2dd'
    }
    $serviceName = 'ZineticEndpointCollector'
    $macCommand = 'curl -fsSL https://cli.zinetic.net/endpoint/install.sh | bash'

    function Stop-Installer([string]$message) {
        throw "zinetic installer: $message"
    }

    function Get-EndpointArchitecture {
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        switch ([int]$cpu.Architecture) {
            9 { return 'amd64' }
            12 { return 'arm64' }
        }
        Stop-Installer "this processor ($($cpu.Architecture)) is not supported; Zinetic Endpoint runs on x64 and Arm64 Windows"
    }

    function Get-InstalledVersion([string]$directory) {
        $exe = Join-Path $directory 'zinetic.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            return ''
        }
        try {
            $first = @(& $exe version 2>$null)[0]
        } catch {
            return ''
        }
        if ("$first" -match '^zinetic\s+(\S+)') {
            return $Matches[1]
        }
        return ''
    }

    function Test-SamePath([string]$a, [string]$b) {
        return $a.Trim().TrimEnd('\') -ieq $b.Trim().TrimEnd('\')
    }

    function Add-MachinePath([string]$directory) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
        try {
            $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $entries = @($raw -split ';' | Where-Object { $_ -ne '' })
            foreach ($entry in $entries) {
                if (Test-SamePath $entry $directory) {
                    return $false
                }
            }
            $key.SetValue('Path', ((@($entries) + $directory) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        } finally {
            $key.Close()
        }
        try {
            if (-not ('ZineticInstaller.Native' -as [type])) {
                Add-Type -Namespace ZineticInstaller -Name Native -MemberDefinition '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);'
            }
            $result = [UIntPtr]::Zero
            [void][ZineticInstaller.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
        } catch {
            Write-Host 'Windows was not told about the new PATH; sign out and back in if zinetic is not found in new windows.'
        }
        return $true
    }

    function Copy-Program([string]$source, [string]$destination) {
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                Copy-Item -LiteralPath $source -Destination $destination -Force
                return
            } catch {
                if ($attempt -eq 10) {
                    Stop-Installer "could not replace $($destination): $($_.Exception.Message)"
                }
                Start-Sleep -Seconds 1
            }
        }
    }

    if ($version -like '*@*') {
        Stop-Installer 'this installer template has not been rendered for a release'
    }
    if ($env:OS -ne 'Windows_NT') {
        Stop-Installer "this installer is for Windows; on macOS run: $macCommand"
    }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Installer 'administrator rights are needed. Open PowerShell with "Run as administrator" and run the command again.'
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Host 'TLS 1.2 could not be enabled for this PowerShell session; the download may fail.'
    }

    $arch = Get-EndpointArchitecture
    $programFiles = $env:ProgramW6432
    if (-not $programFiles) {
        $programFiles = $env:ProgramFiles
    }
    $installDir = Join-Path $programFiles 'Zinetic'
    $installed = Get-InstalledVersion $installDir

    if (($installed -eq $version) -and ($env:ZINETIC_ENDPOINT_REINSTALL -ne '1') -and (Test-Path -LiteralPath (Join-Path $installDir 'zineticd.exe'))) {
        Write-Host "Zinetic Endpoint $version is already installed in $installDir."
        Write-Host 'To install it again, set $env:ZINETIC_ENDPOINT_REINSTALL = "1" and run the installer again.'
    } else {
        if ($installed -and ($installed -ne $version)) {
            Write-Host "Upgrading Zinetic Endpoint from $installed to $version ($arch)"
        } else {
            Write-Host "Installing Zinetic Endpoint $version ($arch)"
        }
        $work = Join-Path ([IO.Path]::GetTempPath()) ('zinetic-endpoint-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work | Out-Null
        try {
            foreach ($name in @('zinetic', 'zineticd')) {
                $file = "$name-windows-$arch.exe"
                $download = Join-Path $work $file
                Write-Host "Downloading $file"
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$file" -OutFile $download
                } catch {
                    Stop-Installer "could not download $baseUrl/$($file): $($_.Exception.Message); nothing was installed"
                }
                $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash.ToLowerInvariant()
                if ($actual -ne $hashes[$file]) {
                    Stop-Installer "$file does not match the published checksum (expected $($hashes[$file]), got $actual); nothing was installed"
                }
            }
            Write-Host 'Checksums verified'

            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and ($service.Status -ne 'Stopped')) {
                Write-Host 'Stopping the endpoint service to replace its program'
                Stop-Service -Name $serviceName -Force
                $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
            }
            if (-not (Test-Path -LiteralPath $installDir)) {
                New-Item -ItemType Directory -Path $installDir | Out-Null
            }
            foreach ($name in @('zinetic', 'zineticd')) {
                Copy-Program (Join-Path $work "$name-windows-$arch.exe") (Join-Path $installDir "$name.exe")
            }
            if ($service) {
                Write-Host 'Restarting the endpoint service with the new version'
                & (Join-Path $installDir 'zineticd.exe') collector start
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning 'the endpoint service did not restart; run: zinetic endpoint restart'
                }
            }
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }

        $installed = Get-InstalledVersion $installDir
        if ($installed -ne $version) {
            Stop-Installer "the programs were copied, but $installDir\zinetic.exe reports version '$installed' instead of $version"
        }
        Write-Host ''
        Write-Host "Zinetic Endpoint $version is installed in $installDir."
    }

    if (Add-MachinePath $installDir) {
        Write-Host "Added $installDir to the system PATH. Terminal windows that were already open need to be reopened."
    }
    $onPath = $false
    foreach ($entry in @($env:Path -split ';')) {
        if ($entry -and (Test-SamePath $entry $installDir)) {
            $onPath = $true
        }
    }
    if (-not $onPath) {
        $env:Path = "$env:Path;$installDir"
    }

    Write-Host ''
    Write-Host 'Next, set up this device:'
    Write-Host '  zinetic endpoint setup'
}
